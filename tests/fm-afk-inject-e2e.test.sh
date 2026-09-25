#!/usr/bin/env bash
# tests/fm-afk-inject-e2e.test.sh - private-socket end-to-end test for the afk
# daemon's injection path. It covers three operator-visible injection contracts:
#
#   Scenario A (human-partial-input): a partial line is typed into the
#     supervisor pane with NO Enter, then an escalation fires. The daemon must
#     DEFER (not merge the digest into the human's text). After the pane goes
#     idle, the digest arrives as a separate, clean submission.
#
#   Scenario B (swallowed-Enter): the first Enter the daemon sends is dropped.
#     The daemon must retry Enter (NOT retype the digest) and deliver exactly
#     ONE clean submission: no concatenation, no duplicate.
#
#   Scenario C (normal digest): no human input and no swallowed Enter.
#     A captain-relevant status must deliver exactly ONE sentinel-prefixed,
#     single-line digest with no duplicate or spurious user submission.
#
# Isolation: all test tmux runs on a dedicated socket (tmux -L afk-e2e-<pid>).
# A tmux shim first on PATH redirects the daemon's bare `tmux` calls to the
# private socket. The daemon points at a throwaway state dir (FM_STATE_OVERRIDE)
# and the test pane (FM_SUPERVISOR_TARGET). Nothing touches the live fleet.
# FM_SUPERVISOR_BACKEND=tmux is passed explicitly (not left to auto-detection):
# this test's own process may itself be running inside herdr (HERDR_ENV=1 is
# inherited by every process herdr manages a pane for), which would otherwise
# leak into the spawned daemon subprocess and misdetect backend=herdr against
# what is actually a tmux pane on the private socket.
#
# Assert on submitted CONTENT (logged verbatim by the supervisor pane), not pane
# appearance - terminal line-wrapping looks like newlines but isn't.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

# Skip gracefully if tmux is not installed.
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="afk-e2e-$$"
STATE_DIR=
TMUX_SHIM_DIR=
LOG_FILE=
DAEMON_PID=
SUPERVISOR_PANE=
LOOP_SCRIPT=

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup_all() {
  if [ -n "${DAEMON_PID:-}" ]; then
    afk_exit "${STATE_DIR:-}" 2>/dev/null || true
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  if [ -n "${SOCKET:-}" ] && [ -n "${REAL_TMUX:-}" ]; then
    "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  fi
  rm -rf "${TMUX_SHIM_DIR:-}" 2>/dev/null || true
  rm -rf "${STATE_DIR:-}" 2>/dev/null || true
}
trap cleanup_all EXIT

# --- setup ------------------------------------------------------------------

STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-e2e.XXXXXX")
mkdir -p "$STATE_DIR"
LOG_FILE="$STATE_DIR/submitted.log"
: > "$LOG_FILE"

# Source the daemon to get FM_INJECT_MARK, afk_enter, afk_exit.
# shellcheck source=/dev/null
. "$DAEMON"

# Private tmux server with a supervisor session.
"$REAL_TMUX" -L "$SOCKET" new-session -d -s supervisor -x 200 -y 50
SUPERVISOR_PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t supervisor '#{pane_id}')

# Supervisor pane loop: a small deterministic composer that logs each submitted
# line verbatim (hex + text + classification). It draws the in-progress input
# itself instead of relying on the terminal driver's canonical-mode echo, because
# tmux cursor placement for that echo varies across CI environments.
LOOP_SCRIPT="$STATE_DIR/supervisor-loop.sh"
cat > "$LOOP_SCRIPT" <<'LOOP'
#!/usr/bin/env bash
MARK=$'\xE2\x81\xA3'
LOG="$1"
OLD_STTY=$(stty -g 2>/dev/null || true)
[ -z "$OLD_STTY" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
cleanup() {
  [ -z "$OLD_STTY" ] || stty "$OLD_STTY" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

_buf=
# The drawn composer row carries a real agent prompt glyph, matching the
# production supervisor pane this daemon injects into: under the strict
# container-proof rule (captain decision blank-row-injection-posture) a bare
# unidentified row is never a safe injection target, so the fixture must
# render the shape the classifier positively proves - "❯ " when idle,
# "❯ <buffer>" while input is pending. The glyph is rendering only; it never
# enters the buffer, so submitted-content assertions are unchanged.
redraw() {
  printf '\r\033[K\xe2\x9d\xaf %s' "$_buf"
}
submit_line() {
  local _line=$_buf _c _hex
  if [ "${_line:0:1}" = "$MARK" ]; then
    _c="injection"
  else
    _c="user"
  fi
  _hex=$(printf '%s' "$_line" | od -An -tx1 | tr -d ' \n')
  printf '%s\t%s\t%s\n' "$_hex" "$_line" "$_c" >> "$LOG"
  _buf=
  printf '\r\033[K\n'
  redraw
}

redraw
while IFS= read -r -n 1 _ch; do
  if [ -z "$_ch" ]; then
    submit_line
    continue
  fi
  case "$_ch" in
    $'\r'|$'\n') submit_line ;;
    $'\177'|$'\b') _buf=${_buf%?}; redraw ;;
    *) _buf="${_buf}${_ch}"; redraw ;;
  esac
done
LOOP
chmod +x "$LOOP_SCRIPT"

# Start the loop in the supervisor pane.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" \
  "bash '$LOOP_SCRIPT' '$LOG_FILE'" Enter
sleep 1  # let the loop start and settle

# tmux shim: redirects bare `tmux` to the private socket. Optionally swallows
# the first Enter (file-based flag) for Scenario B.
TMUX_SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-shim.XXXXXX")
cat > "$TMUX_SHIM_DIR/tmux" <<SHIM
#!/usr/bin/env bash
if [ "\${1:-}" = "send-keys" ] && [ -f "$STATE_DIR/.swallow-enter" ]; then
  shift
  _args=()
  for _arg in "\$@"; do
    if [ "\$_arg" = "Enter" ] && [ -f "$STATE_DIR/.swallow-enter" ]; then
      rm -f "$STATE_DIR/.swallow-enter"
      continue
    fi
    _args+=("\$_arg")
  done
  exec "$REAL_TMUX" -L "$SOCKET" send-keys "\${_args[@]}"
fi
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SHIM
chmod +x "$TMUX_SHIM_DIR/tmux"

# Create a fake crewmate window (the watcher lists fm-* windows for stale
# detection). The pane is an inert shell - it just needs to exist.
"$REAL_TMUX" -L "$SOCKET" new-window -d -n fm-fake-c1 -t supervisor

start_daemon() {
  PATH="$TMUX_SHIM_DIR:$PATH" \
  FM_STATE_OVERRIDE="$STATE_DIR" \
  FM_SUPERVISOR_TARGET="$SUPERVISOR_PANE" \
  FM_SUPERVISOR_BACKEND=tmux \
  FM_ESCALATE_BATCH_SECS=0 \
  FM_HOUSEKEEPING_TICK=1 \
  FM_POLL=1 \
  FM_SIGNAL_GRACE=1 \
  FM_HEARTBEAT=999999 \
  FM_CHECK_INTERVAL=999999 \
  FM_INJECT_CONFIRM_SLEEP=0.3 \
  FM_INJECT_CONFIRM_RETRIES=5 \
  FM_STALE_ESCALATE_SECS=999999 \
  nohup "$DAEMON" >"$STATE_DIR/daemon.out" 2>"$STATE_DIR/daemon.err" &
  DAEMON_PID=$!
  # Wait for the daemon to start and acquire the lock.
  local i=0
  while [ "$i" -lt 30 ]; do
    [ -f "$STATE_DIR/.supervise-daemon.pid" ] && break
    sleep 0.2
    i=$((i + 1))
  done
  [ -f "$STATE_DIR/.supervise-daemon.pid" ] || {
    echo "daemon stderr:" >&2; cat "$STATE_DIR/daemon.err" >&2
    fail "daemon did not start (no pid file after 6s)"
  }
}

stop_daemon() {
  [ -n "${DAEMON_PID:-}" ] || return 0
  afk_exit "$STATE_DIR" 2>/dev/null || true
  kill "$DAEMON_PID" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
  DAEMON_PID=""
  sleep 1
}

reset_state() {
  # Clear daemon and watcher state for a fresh scenario.
  rm -f "$STATE_DIR"/*.status \
         "$STATE_DIR"/.subsuper-* \
         "$STATE_DIR"/.wake-queue* \
         "$STATE_DIR"/.watch.lock* \
         "$STATE_DIR"/.watcher-down* \
         "$STATE_DIR"/.last-* \
         "$STATE_DIR"/.hash-* \
         "$STATE_DIR"/.count-* \
         "$STATE_DIR"/.stale-* \
         "$STATE_DIR"/.seen-* \
         "$STATE_DIR"/.heartbeat-streak \
         "$STATE_DIR"/.swallow-enter \
         2>/dev/null || true
  : > "$LOG_FILE"
}

# --- pane_input_pending environment self-check ------------------------------
# Verify that pane_input_pending (which uses cursor_y + capture-pane) can detect
# typed text in this tmux environment. If it can't, the e2e cannot prove the
# operator-visible injection contracts it owns.

selfcheck_pane_input_pending() {
  local check_text="selfcheck-marker-12345"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" -l "$check_text"
  if wait_for_pane_input_pending; then
    # Detected - clean up the text and proceed.
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" Enter
    sleep 0.3
    return 0
  fi
  # Not detected - print diagnostics and fail.
  echo "pane_input_pending cannot detect typed text in this tmux environment" >&2
  local _cy _line
  _cy=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SUPERVISOR_PANE" '#{cursor_y}' 2>/dev/null)
  echo "  cursor_y=$_cy" >&2
  echo "  pane capture (first 10 lines):" >&2
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SUPERVISOR_PANE" 2>/dev/null | head -10 | sed 's/^/    /' >&2
  _line=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SUPERVISOR_PANE" 2>/dev/null | sed -n "$((_cy + 1))p")
  echo "  cursor line: '$_line'" >&2
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" Enter
  fail "pane_input_pending self-check failed"
}

wait_for_pane_input_pending() {
  local i=0
  while [ "$i" -lt 30 ]; do
    if PATH="$TMUX_SHIM_DIR:$PATH" pane_input_pending "$SUPERVISOR_PANE"; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

selfcheck_pane_input_pending

# --- Scenario A: human-partial-input ----------------------------------------

test_scenario_a() {
  reset_state
  afk_enter "$STATE_DIR"
  start_daemon

  # Type partial text into the supervisor pane with NO Enter. This simulates the
  # captain returning and starting to type before afk has been cleared.
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" -l "human draft text"
  wait_for_pane_input_pending \
    || fail "Scenario A: human draft text did not become detectable as pending input"

  # Write a captain-relevant status to trigger a real escalation through the
  # real watcher child.
  echo "done: PR https://example.test/pr/100" > "$STATE_DIR/fake-c1.status"

  # Wait for the watcher to detect the change and the daemon to attempt inject.
  sleep 6

  # Assert: the digest was NOT injected while the pane had pending input.
  if grep -q 'Supervisor escalate' "$LOG_FILE"; then
    fail "Scenario A: daemon injected while pane had pending input (merged with human text?)"
  fi

  # Assert: no merged line (human text + digest) was submitted.
  if grep -q 'human draft text.*Supervisor escalate' "$LOG_FILE" 2>/dev/null || \
     grep -q 'Supervisor escalate.*human draft text' "$LOG_FILE" 2>/dev/null; then
    fail "Scenario A: human text and digest were merged into one line"
  fi

  # Now submit the human's text (Enter). The pane goes idle.
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" Enter
  sleep 0.5

  # Wait for the daemon to retry injection (housekeeping tick = 1s).
  sleep 6

  # Assert: human text was submitted alone (as a user message).
  grep -q 'human draft text' "$LOG_FILE" \
    || fail "Scenario A: human text not in log after submit"

  # Assert: digest arrived after the pane went idle.
  grep -q 'Supervisor escalate' "$LOG_FILE" \
    || fail "Scenario A: digest not injected after pane went idle"

  # Assert: human text and digest are on SEPARATE lines (never merged).
  if grep -q 'human draft text.*Supervisor escalate' "$LOG_FILE" || \
     grep -q 'Supervisor escalate.*human draft text' "$LOG_FILE"; then
    fail "Scenario A: human text and digest merged into one line (after idle)"
  fi

  # Assert: the human text line is classified as "user", not "injection".
  local human_line
  human_line=$(grep 'human draft text' "$LOG_FILE" | head -1)
  case "$human_line" in
    *user) ;;  # correct
    *) fail "Scenario A: human text misclassified (expected user): $human_line" ;;
  esac

  # Assert: the digest line is classified as "injection".
  local digest_line
  digest_line=$(grep 'Supervisor escalate' "$LOG_FILE" | head -1)
  case "$digest_line" in
    *injection) ;;  # correct
    *) fail "Scenario A: digest misclassified (expected injection): $digest_line" ;;
  esac

  stop_daemon
  pass "Scenario A: partial input defers injection; digest arrives clean after idle"
}

# --- Scenario B: swallowed-Enter --------------------------------------------

test_scenario_b() {
  reset_state
  afk_enter "$STATE_DIR"

  # Arm the swallow: the daemon's first Enter will be dropped by the shim.
  touch "$STATE_DIR/.swallow-enter"

  start_daemon

  # Write a captain-relevant status to trigger a real escalation.
  echo "done: PR https://example.test/pr/200" > "$STATE_DIR/fake-c1.status"

  # Wait for the daemon to process the escalation and attempt inject (with the
  # swallowed Enter, the retry path fires).
  sleep 8

  # Assert: exactly ONE terminal-safe marker in the log (no duplicate, no loss).
  local marker_count
  marker_count=$(awk -F '\t' '{ hex=$1; count += gsub(/e281a3/, "", hex) } END { print count + 0 }' "$LOG_FILE")
  [ "$marker_count" -eq 1 ] \
    || fail "Scenario B: expected exactly 1 U+2063 marker, got $marker_count (duplicate or lost)"

  # Assert: the digest line is classified as "injection" and starts with the
  # terminal-safe sentinel marker (hex starts with e281a3).
  local digest_line digest_hex
  digest_line=$(grep 'Supervisor escalate' "$LOG_FILE" | head -1)
  digest_hex=$(printf '%s' "$digest_line" | cut -f1)
  case "$digest_hex" in
    e281a3*) ;;  # correct: starts with the terminal-safe sentinel marker
    *) fail "Scenario B: digest does not start with sentinel marker (hex: $digest_hex)" ;;
  esac

  # Assert: exactly ONE user-message line was submitted (no spurious empty lines
  # from extra Enters). The log should have exactly 1 injection line and 0 user
  # lines.
  local user_count
  user_count=$(grep -c $'\tuser$' "$LOG_FILE" || true)
  [ "$user_count" -eq 0 ] \
    || fail "Scenario B: expected 0 user lines, got $user_count (spurious Enter submitted empty line?)"

  stop_daemon
  pass "Scenario B: swallowed Enter produces exactly one clean digest"
}

# --- Scenario C: normal status, single clean digest -------------------------
# No human input, no swallowed Enter: a captain-relevant status must produce
# exactly ONE sentinel-prefixed, single-line digest, submitted once. This owns
# the marker + single-line + no-duplicate operator contract that the deleted
# fake-tmux units used to assert via internal send-keys counts.

test_scenario_c() {
  reset_state
  afk_enter "$STATE_DIR"
  start_daemon

  echo "done: PR https://example.test/pr/300" > "$STATE_DIR/fake-c1.status"
  sleep 6

  # Exactly one terminal-safe marker in the submitted log (no duplicate, no loss).
  local marker_count
  marker_count=$(awk -F '\t' '{ hex=$1; count += gsub(/e281a3/, "", hex) } END { print count + 0 }' "$LOG_FILE")
  [ "$marker_count" -eq 1 ] \
    || fail "Scenario C: expected exactly 1 U+2063 marker, got $marker_count"

  # The digest is classified as an injection and starts with the sentinel byte.
  local digest_line digest_hex
  digest_line=$(grep 'Supervisor escalate' "$LOG_FILE" | head -1)
  case "$digest_line" in
    *injection) ;;
    *) fail "Scenario C: digest misclassified (expected injection): $digest_line" ;;
  esac
  digest_hex=$(printf '%s' "$digest_line" | cut -f1)
  case "$digest_hex" in
    e281a3*) ;;
    *) fail "Scenario C: digest does not start with sentinel marker (hex: $digest_hex)" ;;
  esac

  # The digest was submitted as ONE line (a multi-line digest would log >1 line),
  # and no spurious user-classified lines were submitted.
  local user_count
  user_count=$(grep -c $'\tuser$' "$LOG_FILE" || true)
  [ "$user_count" -eq 0 ] \
    || fail "Scenario C: expected 0 user lines, got $user_count (spurious submission?)"

  stop_daemon
  pass "Scenario C: a normal captain status injects exactly one clean single-line sentinel digest"
}

# --- Claude-shaped composer scenarios (D, E, F) -----------------------------
# Claude Code 2.1.28x draws its composer as a `─` rule pair around `❯` and the
# draft, wraps a long single-line draft onto indented rows, strips U+2063 on the
# first Enter without submitting ("Removed 1 invisible character"), and deletes
# one wrapped row per Ctrl+U (all measured live on 2.1.282 in tmux,
# 2026-09-25). claude-loop.sh reproduces exactly those behaviors, so these
# scenarios pin with real tmux and no harness the away digest that was left
# typed but unsent in the captain's composer: its wrapped rows started with `#`
# and `|`, the composer read unknown, and the second Enter never came.
# They drive the daemon's own flush in-process against that pane; the daemon
# process scenarios above own the watcher-to-digest path.

CLAUDE_COLS=100
CLAUDE_WIDTH=$((CLAUDE_COLS - 2))
CLAUDE_LOG="$STATE_DIR/claude-submitted.log"
CLAUDE_NO_SUBMIT="$STATE_DIR/.claude-no-submit"
CLAUDE_LOOP="$STATE_DIR/claude-loop.sh"
cat > "$CLAUDE_LOOP" <<'LOOP'
#!/usr/bin/env bash
# claude-loop.sh <submitted-log> <no-submit-flag> <columns>
MARK=$'\xE2\x81\xA3'
LOG=$1 NO_SUBMIT=$2 COLS=$3
WIDTH=$((COLS - 2))
OLD_STTY=$(stty -g 2>/dev/null || true)
[ -z "$OLD_STTY" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
restore() { [ -z "$OLD_STTY" ] || stty "$OLD_STTY" 2>/dev/null || true; }
trap restore EXIT
trap 'exit 0' INT TERM
RULE=
while [ "${#RULE}" -lt "$COLS" ]; do RULE="${RULE}-"; done
RULE=${RULE//-/$'\xe2\x94\x80'}
_buf= _notice= _count=0
# Claude's screen: a notice row above the top rule once U+2063 was stripped,
# `❯` + NBSP when empty, the draft wrapped at WIDTH with a two-column indent,
# the closing rule, a footer, and the cursor at the end of the draft.
redraw() {
  local shown=${_buf//$MARK/} row=0 top=3 len last=0 col
  printf '\033[H\033[2J'
  printf 'submitted %s\r\n' "$_count"
  if [ -n "$_notice" ]; then printf '%s\r\n' "$_notice"; top=4; fi
  printf '%s\r\n' "$RULE"
  if [ -z "$shown" ]; then
    printf '\xe2\x9d\xaf\xc2\xa0\r\n'
  else
    printf '\xe2\x9d\xaf %s\r\n' "${shown:0:WIDTH}"
    row=1
    while [ "$((row * WIDTH))" -lt "${#shown}" ]; do
      printf '  %s\r\n' "${shown:$((row * WIDTH)):WIDTH}"
      row=$((row + 1))
    done
  fi
  printf '%s\r\n' "$RULE"
  printf '  ? for shortcuts'
  len=${#shown}
  [ "$len" -eq 0 ] || last=$(((len - 1) / WIDTH))
  col=$((3 + len - last * WIDTH))
  [ "$col" -le "$COLS" ] || col=$COLS
  printf '\033[%d;%dH' "$((top + last))" "$col"
}
# Enter: the first one on a marked draft only strips the mark; the no-submit
# flag makes Enter do nothing at all (a submit that never lands).
submit() {
  case "$_buf" in
    *"$MARK"*)
      _buf=${_buf//$MARK/}
      _notice='Removed 1 invisible character - review and press Enter to send'
      return
      ;;
  esac
  [ ! -e "$NO_SUBMIT" ] || return
  [ -n "$_buf" ] || return
  printf '%s\n' "$_buf" >> "$LOG"
  _count=$((_count + 1))
  _buf= _notice=
}
# Ctrl+U: delete back to the start of the current wrapped row.
delete_row() {
  local len=${#_buf} cut
  [ "$len" -gt 0 ] || return
  cut=$((len % WIDTH))
  [ "$cut" -gt 0 ] || cut=$WIDTH
  _buf=${_buf:0:$((len - cut))}
}
redraw
while IFS= read -r -n 1 _ch; do
  case "$_ch" in
    ''|$'\r'|$'\n') submit ;;
    $'\x15') delete_row ;;
    $'\177'|$'\b') _buf=${_buf%?} ;;
    *) _buf="${_buf}${_ch}" ;;
  esac
  # Draw once per burst, not once per key.
  read -r -t 0 || redraw
done
LOOP
chmod +x "$CLAUDE_LOOP"
: > "$CLAUDE_LOG"
"$REAL_TMUX" -L "$SOCKET" new-session -d -s claude -x "$CLAUDE_COLS" -y 40 \
  "bash '$CLAUDE_LOOP' '$CLAUDE_LOG' '$CLAUDE_NO_SUBMIT' '$CLAUDE_COLS'"
CLAUDE_PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t claude '#{pane_id}')
sleep 0.5

claude_call() {  # <function> [args...]: run a daemon function against the claude pane
  PATH="$TMUX_SHIM_DIR:$PATH" FM_STATE_OVERRIDE="$STATE_DIR" \
    FM_SUPERVISOR_TARGET="$CLAUDE_PANE" FM_SUPERVISOR_BACKEND=tmux \
    FM_INJECT_CONFIRM_SLEEP=0.3 FM_INJECT_CONFIRM_RETRIES=3 LOG="$STATE_DIR/claude-inject.log" \
    "$@"
}

claude_screen() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$CLAUDE_PANE"
}

claude_state() {
  claude_call fm_tmux_composer_state "$CLAUDE_PANE"
}

wait_claude_state() {  # <verdict>
  local i=0
  while [ "$i" -lt 30 ]; do
    [ "$(claude_state)" = "$1" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

claude_reset() {
  local i=0
  rm -f "$CLAUDE_NO_SUBMIT" "$STATE_DIR"/.subsuper-* "$STATE_DIR/claude-inject.log"
  while [ "$i" -lt 30 ] && [ "$(claude_state)" != empty ]; do
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$CLAUDE_PANE" C-u
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(claude_state)" = empty ] || fail "claude-shaped pane did not return to an empty composer"
  : > "$CLAUDE_LOG"
  afk_enter "$STATE_DIR"
}

# Three items that take two digests under the default bound. The first is laid
# out so that, behind the two-digest header, one wrapped row of the typed digest
# starts with `#412` and the next starts with the ` | ` separator: the two row
# shapes that read as a dead-shell prompt and a structural edge outside a
# composer.
claude_items() {
  local head="FIRSTMATE_OP: v1 away-supervisor: Supervisor escalate (2 of 3 event(s); 1 more follow): "
  local pad1 item1 fill
  pad1=$(printf '%*s' "$((CLAUDE_WIDTH - ${#head}))" '' | tr ' ' 'a')
  item1="${pad1}#412 #413 #414 merged into release"
  fill=$((2 * CLAUDE_WIDTH - ${#head} - ${#item1} - 1))
  item1="${item1}$(printf '%*s' "$fill" '' | tr ' ' 'b')"
  printf '%s\n' "$item1"
  printf '%s\n' "signal: rr-edge-redeploy.status: done: deployed mcp from main ff5cbdd; verified mcp ACTIVE v22->v23, rejects unauthenticated calls, read-only search_products OK; clerk-process untouched on v32; FYI the L-Foot + 2x M8 T-Nut 'Box of 320' variant has no SKU and is priced GBP 15, so box-packing skips it and quotes are unaffected"
  printf '%s\n' "check: merge landed: rr-flat-roof-tnuts-fix https://example.test/pr/12 away -> check: merge landed: rr-flat-roof-tnuts-fix https://example.test/pr/12 away; the deploy of every edge function that bundles packages/calc follows once the release branch is cut and checks are green"
}

test_scenario_d() {
  local item encoded line n rc screen
  local -a items
  claude_reset
  while IFS= read -r item; do escalate_add "$STATE_DIR" "$item"; done <<EOF
$(claude_items)
EOF

  # The layout this scenario exists for must really be on screen: type the
  # first digest by hand and assert its `#` and `|` rows, then clear it through
  # the same payload-proven clear the daemon uses.
  items=()
  while IFS= read -r item; do items+=("$item"); done < "$STATE_DIR/.subsuper-escalations"
  escalate_digest "${items[@]}" || fail "Scenario D: escalate_digest failed"
  fm_operational_input_encode away-supervisor "$ESCALATE_DIGEST" encoded
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$CLAUDE_PANE" -l "$encoded"
  wait_claude_state pending || fail "Scenario D: the wrapped digest did not read pending (got $(claude_state))"
  screen=$(claude_screen)
  printf '%s\n' "$screen" | grep -q '^  #412 ' \
    || fail "Scenario D: no wrapped row starts with #412; the layout drifted: $screen"
  printf '%s\n' "$screen" | grep -q '^  | ' \
    || fail "Scenario D: no wrapped row starts with the | separator; the layout drifted: $screen"
  claude_call fm_backend_composer_clear_payload tmux "$CLAUDE_PANE" "$encoded" \
    || fail "Scenario D: the payload-proven clear did not empty a composer holding only the digest"
  [ "$(claude_state)" = empty ] || fail "Scenario D: composer not empty after the clear"

  claude_call escalate_flush "$STATE_DIR"; rc=$?
  [ "$rc" -eq 0 ] || fail "Scenario D: first flush failed: $(cat "$STATE_DIR/claude-inject.log" 2>/dev/null)"
  [ "$(wc -l < "$CLAUDE_LOG" | tr -d ' ')" -eq 1 ] || fail "Scenario D: expected one submission, got: $(cat "$CLAUDE_LOG")"
  line=$(sed -n 1p "$CLAUDE_LOG")
  case "$line" in
    "FIRSTMATE_OP: v1 away-supervisor: Supervisor escalate (2 of 3 event(s); 1 more follow): "*"#412 #413 #414"*" | signal: rr-edge-redeploy"*) ;;
    *) fail "Scenario D: first digest is not the two leading items: $line" ;;
  esac
  n=$(printf '%s' "$line" | wc -c | tr -d ' ')
  [ "$((n + 3))" -le 760 ] || fail "Scenario D: first digest typed $((n + 3)) bytes, over the 760-byte bound"
  [ "$(wc -l < "$STATE_DIR/.subsuper-escalations" | tr -d ' ')" -eq 1 ] \
    || fail "Scenario D: the third item did not stay buffered: $(cat "$STATE_DIR/.subsuper-escalations")"
  [ "$(claude_state)" = empty ] || fail "Scenario D: text left in the composer after a delivered digest"

  claude_call escalate_flush "$STATE_DIR" || fail "Scenario D: second flush failed"
  [ "$(wc -l < "$CLAUDE_LOG" | tr -d ' ')" -eq 2 ] || fail "Scenario D: expected two submissions, got: $(cat "$CLAUDE_LOG")"
  case "$(sed -n 2p "$CLAUDE_LOG")" in
    "FIRSTMATE_OP: v1 away-supervisor: Supervisor escalate (1 event(s)): check: merge landed: rr-flat-roof-tnuts-fix"*) ;;
    *) fail "Scenario D: second digest is not the remaining item: $(sed -n 2p "$CLAUDE_LOG")" ;;
  esac
  [ ! -s "$STATE_DIR/.subsuper-escalations" ] || fail "Scenario D: buffer not empty after both digests"
  pass "Scenario D: a long digest with # and | wrapped rows submits on a Claude-shaped composer, in bounded digests"
}

test_scenario_e() {
  claude_reset
  touch "$CLAUDE_NO_SUBMIT"
  escalate_add "$STATE_DIR" "needs-decision: pick A or B for merged PRs #400 #401 #402 #403 #404 #405 #406 #407 #408 #409 #410 #411 #412 #413 #414 #415 #416 #417 #418 #419 #420"
  claude_call escalate_flush "$STATE_DIR" && fail "Scenario E: a submit that never landed reported delivery"
  [ ! -s "$CLAUDE_LOG" ] || fail "Scenario E: something was submitted: $(cat "$CLAUDE_LOG")"
  [ "$(claude_state)" = empty ] || fail "Scenario E: the unsent digest was left in the composer: $(claude_screen)"
  claude_screen | grep -q 'FIRSTMATE_OP' && fail "Scenario E: digest text still visible: $(claude_screen)"
  grep -q 'cleared the unsent digest' "$STATE_DIR/claude-inject.log" \
    || fail "Scenario E: the daemon log does not record the clear: $(cat "$STATE_DIR/claude-inject.log")"
  grep -q 'pick A or B' "$STATE_DIR/.subsuper-escalations" || fail "Scenario E: the escalation was dropped from the buffer"

  rm -f "$CLAUDE_NO_SUBMIT"
  claude_call escalate_flush "$STATE_DIR" || fail "Scenario E: the retry after a cleared failure did not deliver"
  [ "$(wc -l < "$CLAUDE_LOG" | tr -d ' ')" -eq 1 ] || fail "Scenario E: expected exactly one delivery, got: $(cat "$CLAUDE_LOG")"
  grep -c 'FIRSTMATE_OP' "$CLAUDE_LOG" | grep -qx 1 || fail "Scenario E: the retried digest was duplicated: $(cat "$CLAUDE_LOG")"
  pass "Scenario E: a submit that cannot be confirmed clears its own digest, keeps the escalation, and retries cleanly"
}

test_scenario_f() {
  local encoded
  claude_reset
  # A draft the captain typed: the digest is never typed and never cleared.
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$CLAUDE_PANE" -l "captain draft #412 | keep me"
  wait_claude_state pending || fail "Scenario F: the captain draft did not read pending"
  escalate_add "$STATE_DIR" "done: PR https://example.test/pr/400"
  claude_call escalate_flush "$STATE_DIR" && fail "Scenario F: the digest was delivered over a captain draft"
  claude_screen | grep -q 'captain draft #412' || fail "Scenario F: the captain draft was changed: $(claude_screen)"
  claude_screen | grep -q 'FIRSTMATE_OP' && fail "Scenario F: the digest was typed into the captain draft"

  # The captain types behind an unsent digest: the clear refuses, because the
  # composer no longer shows exactly the digest.
  claude_reset
  fm_operational_input_encode away-supervisor "Supervisor escalate (1 event(s)): done: PR https://example.test/pr/401" encoded
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$CLAUDE_PANE" -l "$encoded"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$CLAUDE_PANE" -l " and the captain added this"
  wait_claude_state pending || fail "Scenario F: the combined draft did not read pending"
  claude_call fm_backend_composer_clear_payload tmux "$CLAUDE_PANE" "$encoded" \
    && fail "Scenario F: the clear deleted a composer holding the captain's text"
  claude_screen | grep -q 'the captain added this' || fail "Scenario F: the captain's text was deleted: $(claude_screen)"
  pass "Scenario F: text the captain typed is never typed over and never cleared"
}

test_scenario_a
test_scenario_b
test_scenario_c
test_scenario_d
test_scenario_e
test_scenario_f

echo "all e2e injection tests passed"
