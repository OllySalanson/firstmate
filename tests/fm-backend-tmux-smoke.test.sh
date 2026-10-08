#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

wait_for_capture_text() {  # <target> <text> [samples]
  local target=$1 text=$2 samples=${3:-100} out i=0
  while [ "$i" -lt "$samples" ]; do
    out=$(fm_backend_tmux_capture "$target" 200 2>/dev/null || true)
    case "$out" in
      *"$text"*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
SHIM_DIR=
NS_JOB=
trap cleanup_all EXIT

cleanup_all() {
  env -u TMUX -u TMUX_PANE "$REAL_TMUX" -L "$SOCKET" -f /dev/null kill-server >/dev/null 2>&1 || true
  env -u TMUX -u TMUX_PANE "$REAL_TMUX" -L "$SOCKET-other" -f /dev/null kill-server >/dev/null 2>&1 || true
  [ -n "${NS_JOB:-}" ] && kill "$NS_JOB" 2>/dev/null
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, with no inherited TMUX and no host config, so bin/backends/tmux.sh's
# bare `tmux ...` invocations never touch the host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec env -u TMUX -u TMUX_PANE "$REAL_TMUX" -L "$SOCKET" -f /dev/null "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

SESSION="smoke"
WINDOW="fm-smoke1"
TARGET="$SESSION:$WINDOW"

# --- create session ----------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" >/dev/null \
  || fail "fm_backend_tmux_create_task failed to create the task window"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "created window is not visible in the real session"

# A second create for the SAME window name must refuse (mirrors fm-spawn.sh's
# duplicate-window guard).
if fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_create_task should refuse an existing window name"
fi
pass "real tmux: fm_backend_tmux_create_task creates a window and refuses a duplicate"

# --- send text + Enter -------------------------------------------------------

# A newly-created interactive shell can exist before its startup files and line
# editor are ready to accept Enter. Prove command execution with an output token
# that does not appear contiguously in the command, retrying the harmless probe
# until the shell acknowledges it.
SHELL_READY=false
for _ in $(seq 1 100); do
  tmux send-keys -t "$TARGET" C-c
  tmux send-keys -t "$TARGET" -l "printf 'shell-%s\\n' ready"
  tmux send-keys -t "$TARGET" Enter
  if wait_for_capture_text "$TARGET" "shell-ready" 10; then
    SHELL_READY=true
    break
  fi
done
[ "$SHELL_READY" = true ] || fail "the tmux task shell did not become ready"

tmux send-keys -t "$TARGET" "cd /tmp && PS1='smoke\$ ' && clear && printf 'setup-%s\\n' ready" Enter
wait_for_capture_text "$TARGET" "setup-ready" || fail "the tmux task shell did not complete setup"

fm_backend_tmux_send_text_line "$TARGET" "printf 'captain-on-deck-%s\\n' line" \
  || fail "fm_backend_tmux_send_text_line failed"
wait_for_capture_text "$TARGET" "captain-on-deck-line" \
  || fail "fm_backend_tmux_send_text_line did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real tmux: fm_backend_tmux_send_text_line did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter"

# --- send_literal + send_key(Enter), the two-step form fm-spawn.sh uses for the
# harness launch command (literal send, settle, then a separate Enter) --------

fm_backend_tmux_send_literal "$TARGET" "printf 'literal-then-key-%s\\n' captain" \
  || fail "fm_backend_tmux_send_literal failed"
fm_backend_tmux_send_key "$TARGET" Enter || fail "fm_backend_tmux_send_key Enter failed"
wait_for_capture_text "$TARGET" "literal-then-key-captain" \
  || fail "fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real tmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter submit as two separate steps"

# --- capture bounds -----------------------------------------------------------
# Print enough numbered lines to overflow the pane's visible height, then
# confirm a small capture window (-S -N) surfaces only the RECENT tail (the
# earliest lines scroll out of a small window) while a large one reaches back
# far enough to still see the earliest line - the same -S -N bounding fm-peek.sh
# and fm-watch.sh rely on for a bounded, cheap pane read.
fm_backend_tmux_send_text_line "$TARGET" "for i in \$(seq 1 80); do echo tag-line-\$i; done"
wait_for_capture_text "$TARGET" "tag-line-80" \
  || fail "the numbered output did not complete before capture"
small=$(fm_backend_tmux_capture "$TARGET" 3) || fail "fm_backend_tmux_capture (small window) failed"
case "$small" in
  *tag-line-1$'\n'*) fail "a 3-line capture should not still see the very first numbered line"$'\n'"$small" ;;
esac
case "$small" in
  *tag-line-80*) : ;;
  *) fail "a 3-line capture should still contain the most recent output"$'\n'"$small" ;;
esac
large=$(fm_backend_tmux_capture "$TARGET" 200) || fail "fm_backend_tmux_capture (large window) failed"
case "$large" in
  *tag-line-1$'\n'*) : ;;
  *) fail "a 200-line capture should reach back far enough to see the first numbered line"$'\n'"$large" ;;
esac
pass "real tmux: fm_backend_tmux_capture's -S -N bound trims old history for a small window and reaches it for a large one"

# --- resolve_bare_selector (live-window-listing) -----------------------------

resolved=$(fm_backend_tmux_resolve_bare_selector "$WINDOW") \
  || fail "fm_backend_tmux_resolve_bare_selector failed to find the live window"
[ "$resolved" = "$TARGET" ] || fail "fm_backend_tmux_resolve_bare_selector resolved to '$resolved', expected '$TARGET'"
pass "real tmux: fm_backend_tmux_resolve_bare_selector (list-live) finds the created window by name"

if fm_backend_tmux_resolve_bare_selector "no-such-window-xyz" 2>/dev/null; then
  fail "fm_backend_tmux_resolve_bare_selector should fail for a nonexistent window"
fi
pass "real tmux: fm_backend_tmux_resolve_bare_selector fails for a window that does not exist"

# --- exact-window targeting -------------------------------------------------
# tmux answers `display-message -t <session>:<absent-window>` from the session's
# active window and exits 0, matches an absent window name by prefix for the
# commands that do fail on a missing window, and parses a dot in a window name
# as a pane separator. Each case first asserts that raw tmux divergence, so it
# cannot pass vacuously on a tmux that stopped doing it, then asserts the
# adapter reads and writes only the exact window named.

wait_for_shell() {  # <target> <token>
  local target=$1 token=$2
  for _ in $(seq 1 100); do
    tmux send-keys -t "$target" -l "printf '$token-%s\\n' ready"
    tmux send-keys -t "$target" Enter
    wait_for_capture_text "$target" "$token-ready" 10 && return 0
  done
  return 1
}

DEAD="fm-smoke-dead"
fm_backend_tmux_create_task "$SESSION" "$DEAD" "$HOME" >/dev/null \
  || fail "could not create the window that will die"
tmux kill-window -t "=$SESSION:=$DEAD" || fail "could not kill the dying window"
tmux select-window -t "=$SESSION:=$WINDOW" || fail "could not activate the sibling window"
raw=$(tmux display-message -p -t "$SESSION:$DEAD" '#{window_name}') \
  || fail "precondition: raw display-message on a missing window was expected to exit 0"
[ "$raw" = "$WINDOW" ] \
  || fail "precondition: raw display-message on a missing window was expected to name the active sibling, got '$raw'"
if fm_backend_target_exists tmux "$SESSION:$DEAD"; then
  fail "a missing window in a live session read as existing while a sibling window is active"
fi
fm_backend_target_exists tmux "$TARGET" || fail "the live sibling window read as missing"
if out=$(fm_backend_tmux_current_command "$SESSION:$DEAD"); then
  fail "current_command answered for a missing window: '$out'"
fi
if out=$(fm_backend_tmux_current_path "$SESSION:$DEAD"); then
  fail "current_path answered for a missing window: '$out'"
fi
if fm_backend_capture tmux "$SESSION:$DEAD" 5 >/dev/null 2>&1; then
  fail "capture succeeded for a missing window"
fi
state=$(fm_backend_agent_state tmux "$SESSION:$DEAD")
[ "$state" = missing ] || fail "a missing window beside an active sibling should classify missing, got '$state'"
pass "real tmux: a missing window reads missing while a sibling window is active"

LONG="fm-smoke-prefix-long"
fm_backend_tmux_create_task "$SESSION" "$LONG" "$HOME" >/dev/null \
  || fail "could not create the prefix neighbor window"
wait_for_shell "$SESSION:=$LONG" long || fail "the prefix neighbor shell did not become ready"
tmux capture-pane -p -t "$SESSION:fm-smoke-prefix" >/dev/null 2>&1 \
  || fail "precondition: raw capture-pane was expected to reach the prefix neighbor"
if fm_backend_target_exists tmux "$SESSION:fm-smoke-prefix"; then
  fail "an absent window read as existing through its prefix neighbor"
fi
if fm_backend_tmux_send_text_line "$SESSION:fm-smoke-prefix" "printf 'misrouted-%s\\n' prefix" 2>/dev/null; then
  fail "send_text_line succeeded for an absent window"
fi
sleep 0.3
case "$(tmux capture-pane -p -t "=$SESSION:=$LONG")" in
  *misrouted-prefix*) fail "text for an absent window was typed into its prefix neighbor" ;;
esac
pass "real tmux: an absent window is never reached through a prefix-matching neighbor"

DOTTED="fm-smoke.dotted"
fm_backend_tmux_create_task "$SESSION" "$DOTTED" "$HOME" >/dev/null \
  || fail "could not create the dotted window"
raw=$(tmux display-message -p -t "$SESSION:$DOTTED" '#{window_name}') || raw=
[ "$raw" != "$DOTTED" ] \
  || fail "precondition: raw tmux was expected to misparse a dotted window name"
fm_backend_target_exists tmux "$SESSION:$DOTTED" || fail "a live dotted window read as missing"
fm_backend_tmux_send_text_line "$SESSION:$DOTTED" "printf 'dotted-%s\\n' reached" \
  || fail "send_text_line failed for a live dotted window"
wait_for_capture_text "$SESSION:$DOTTED" "dotted-reached" \
  || fail "text for a dotted window did not reach it"
pass "real tmux: a window whose name contains a dot is addressed exactly"

SIBLING="fm-smoke-rel-v2"
DOTTED_SIBLING="$SIBLING.0"
fm_backend_tmux_create_task "$SESSION" "$SIBLING" "$HOME" >/dev/null \
  || fail "could not create the live sibling window"
fm_backend_tmux_create_task "$SESSION" "$DOTTED_SIBLING" "$HOME" >/dev/null \
  || fail "could not create the dotted task window"
SIBLING_PANE=$(tmux list-panes -s -t "=$SESSION:" -F '#{window_name} #{pane_id}' | awk -v n="$SIBLING" '$1 == n { print $2 }')
DOTTED_SIBLING_PANE=$(tmux list-panes -s -t "=$SESSION:" -F '#{window_name} #{pane_id}' | awk -v n="$DOTTED_SIBLING" '$1 == n { print $2 }')
[ -n "$SIBLING_PANE" ] && [ -n "$DOTTED_SIBLING_PANE" ] || fail "could not read the sibling windows' panes"
pane=$(fm_tmux_exact_pane "$SESSION:$DOTTED_SIBLING") || fail "the live dotted task window read as missing"
[ "$pane" = "$DOTTED_SIBLING_PANE" ] || fail "the dotted task window resolved to '$pane', expected '$DOTTED_SIBLING_PANE'"
tmux kill-pane -t "$DOTTED_SIBLING_PANE" || fail "could not kill the dotted task window"
raw=$(tmux display-message -p -t "$SESSION:$DOTTED_SIBLING" '#{pane_id}') || raw=
[ "$raw" = "$SIBLING_PANE" ] \
  || fail "precondition: raw tmux was expected to read the dead '$DOTTED_SIBLING' as pane 0 of '$SIBLING', got '$raw'"
if fm_backend_target_exists tmux "$SESSION:$DOTTED_SIBLING"; then
  fail "a dead dotted task window read as existing through its sibling's pane 0"
fi
state=$(fm_backend_agent_state tmux "$SESSION:$DOTTED_SIBLING")
[ "$state" = missing ] || fail "a dead dotted task window should classify missing, got '$state'"
if fm_backend_capture tmux "$SESSION:$DOTTED_SIBLING" 5 >/dev/null 2>&1; then
  fail "capture succeeded for a dead dotted task window"
fi
if fm_backend_tmux_send_text_line "$SESSION:$DOTTED_SIBLING" "printf 'misrouted-%s\\n' sibling" 2>/dev/null; then
  fail "send_text_line succeeded for a dead dotted task window"
fi
sleep 0.3
case "$(tmux capture-pane -p -t "$SIBLING_PANE")" in
  *misrouted-sibling*) fail "text for a dead dotted task window was typed into its sibling" ;;
esac
pass "real tmux: a dead task window named <sibling>.0 reads missing, never as its live sibling's pane"

SPLIT_PANE=$(tmux split-window -d -P -F '#{pane_id}' -t "=$SESSION:=$WINDOW") \
  || fail "could not split the task window"
ACTIVE_PANE=$(fm_tmux_exact_pane "$TARGET") || fail "the split task window read as missing"
[ "$ACTIVE_PANE" != "$SPLIT_PANE" ] || fail "precondition: the split pane was expected to stay inactive"
WINDOW_INDEX=$(fm_tmux_pane_read "$TARGET" '#{window_index}') || fail "could not read the task window index"
for override in "$SESSION:$WINDOW.1" "$SESSION:$WINDOW_INDEX.1"; do
  pane=$(fm_backend_operator_target tmux "$override") || fail "a live operator override '$override' read as missing"
  [ "$pane" = "$SPLIT_PANE" ] || fail "operator override '$override' resolved to '$pane', expected '$SPLIT_PANE'"
done
pane=$(fm_backend_operator_target tmux "$SESSION:$WINDOW.0") || fail "operator override window.0 read as missing"
[ "$pane" = "$ACTIVE_PANE" ] || fail "operator override window.0 resolved to '$pane', expected '$ACTIVE_PANE'"
resolved=$(fm_backend_operator_target tmux "$TARGET") || fail "an exact operator target read as missing"
[ "$resolved" = "$TARGET" ] || fail "an exact operator target was rewritten to '$resolved'"
for absent in "$SESSION:$WINDOW.7" "$SESSION:$DEAD.1" "$SESSION:fm-smoke-prefix.1" "$SESSION:$WINDOW_INDEX.7"; do
  if out=$(fm_backend_operator_target tmux "$absent"); then
    fail "an absent window or pane '$absent' resolved as an operator override to '$out'"
  fi
done
if fm_backend_target_exists tmux "$SESSION:$WINDOW.1"; then
  fail "a recorded target was read as window.pane instead of an exact window name"
fi
fm_backend_tmux_send_text_line "$(fm_backend_operator_target tmux "$SESSION:$WINDOW.1")" "printf 'split-%s\\n' reached" \
  || fail "send_text_line failed for a resolved operator window.pane override"
wait_for_capture_text "$SPLIT_PANE" "split-reached" || fail "text for an operator window.pane override did not reach the split pane"
case "$(tmux capture-pane -p -t "$ACTIVE_PANE")" in
  *split-reached*) fail "text for an operator window.pane override was typed into the window's active pane" ;;
esac
pass "real tmux: an operator session:window.pane override reaches that exact pane, and recorded targets never read it"

SHADOW="$WINDOW.1"
fm_backend_tmux_create_task "$SESSION" "$SHADOW" "$HOME" >/dev/null \
  || fail "could not create the window whose name looks like window.pane"
SHADOW_PANE=$(tmux list-panes -s -t "=$SESSION:" -F '#{window_name} #{pane_id}' | awk -v n="$SHADOW" '$1 == n { print $2 }')
[ -n "$SHADOW_PANE" ] || fail "could not read the shadowing window's pane"
resolved=$(fm_backend_operator_target tmux "$SESSION:$SHADOW") || fail "a live window named like window.pane read as missing"
pane=$(fm_tmux_exact_pane "$resolved") || fail "the operator target for the shadowing window read as missing"
[ "$pane" = "$SHADOW_PANE" ] \
  || fail "an exact window named '$SHADOW' lost to the window.pane reading: got '$pane', expected '$SHADOW_PANE'"
tmux kill-pane -t "$SHADOW_PANE" || fail "could not kill the shadowing window"
pane=$(fm_backend_operator_target tmux "$SESSION:$SHADOW") || fail "the operator window.pane override stopped resolving once the shadowing window died"
[ "$pane" = "$SPLIT_PANE" ] || fail "the operator override resolved to '$pane' after the shadow died, expected '$SPLIT_PANE'"
pass "real tmux: an existing window named like window.pane wins over the operator pane selector"

# --- kill and recovery-grade missing-window classification ------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
state=$(fm_backend_agent_state tmux "$TARGET")
[ "$state" = missing ] \
  || fail "a real missing window in a readable session should classify as missing, got '$state'"
# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: kill removes the window and the readable session inventory authoritatively classifies it missing"

# --- endpoint identity and provable absence -----------------------------------
#
# A `missing` window is reclaimable only when the identity recorded at spawn
# proves it gone (bin/backends/tmux.sh). These drive that proof against real
# tmux servers: the window moved, the agent's pane joined into another window,
# the pane closed, on a server this process does not address, its server
# exited, and the machine restarted.

point_shim_at() {  # <socket-name>
  cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec env -u TMUX -u TMUX_PANE "$REAL_TMUX" -L "$1" -f /dev/null "\$@"
SH
  chmod +x "$SHIM_DIR/tmux"
}

absence_proof() {  # <meta> -> "<verdict> <proof>"
  fm_backend_tmux_endpoint_absence_proof "$1" | tr '\t' ' '
}

tmux has-session -t "=$SESSION" 2>/dev/null || tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: could not ensure the session for the absence cases"
ABS_WINDOW=fm-absence1
fm_backend_tmux_create_task "$SESSION" "$ABS_WINDOW" "$HOME" >/dev/null \
  || fail "could not create the window whose identity is recorded"
ABS_META="$SHIM_DIR/absence.meta"
fm_backend_tmux_endpoint_identity "$SESSION:$ABS_WINDOW" > "$ABS_META" \
  || fail "the endpoint identity of a live window could not be read"
SERVER_PID=$(tmux display-message -p '#{pid}')
ABS_WID=$(tmux list-windows -t "=$SESSION" -F '#{window_name} #{window_id}' | awk -v n="$ABS_WINDOW" '$1 == n { print $2 }')
ABS_PANE=$(tmux list-panes -t "$ABS_WID" -F '#{pane_id}')
[ "$(fm_backend_meta_exact_value "$ABS_META" tmux_server_pid)" = "$SERVER_PID" ] \
  || fail "the recorded server pid is not the live server's: $(cat "$ABS_META")"
[ "$(fm_backend_meta_exact_value "$ABS_META" tmux_pane_id)" = "$ABS_PANE" ] \
  || fail "the recorded pane id is not the live pane's: $(cat "$ABS_META")"
fm_backend_meta_exact_value "$ABS_META" tmux_boot >/dev/null \
  || fail "the recorded identity carries no boot: $(cat "$ABS_META")"
fm_backend_meta_exact_value "$ABS_META" tmux_server_start >/dev/null \
  || fail "the recorded identity carries no server start: $(cat "$ABS_META")"
pass "real tmux: a live window's endpoint identity names its boot, its server process, and its pane id"

tmux rename-window -t "$ABS_WID" "$ABS_WINDOW-moved" || fail "could not rename the recorded window"
[ "$(fm_backend_agent_state tmux "$SESSION:$ABS_WINDOW")" = missing ] \
  || fail "a renamed window should read missing at its recorded address"
proof=$(absence_proof "$ABS_META")
case "$proof" in
  "unproven "*"still exists on the tmux server"*) ;;
  *) fail "a window that only moved must not be proven gone: $proof" ;;
esac
pass "real tmux: a window that moved on its server is never proven gone"

# The captain joins the agent's pane beside another window to watch it: its
# original single-pane window is destroyed, but the agent keeps running.
HOST_WID=$(tmux new-window -dP -F '#{window_id}' -t "=$SESSION:" -n fm-absence-host) \
  || fail "could not create the window the agent's pane is joined into"
tmux join-pane -d -s "$ABS_PANE" -t "$HOST_WID" || fail "could not join the agent's pane into another window"
tmux list-windows -a -F '#{window_id}' | grep -Fqx -- "$ABS_WID" \
  && fail "joining the only pane out of the recorded window should have destroyed that window"
[ "$(fm_backend_agent_state tmux "$SESSION:$ABS_WINDOW")" = missing ] \
  || fail "a window whose pane was joined away should read missing at its recorded address"
proof=$(absence_proof "$ABS_META")
case "$proof" in
  "unproven "*"pane $ABS_PANE still exists on the tmux server"*) ;;
  *) fail "an agent pane joined into another window must not be proven gone: $proof" ;;
esac
pass "real tmux: an agent pane joined into another window is never proven gone"

tmux kill-pane -t "$ABS_PANE" || fail "could not close the recorded pane"
proof=$(absence_proof "$ABS_META")
case "$proof" in
  "gone "*"pane $ABS_PANE was closed on the tmux server that still runs"*) ;;
  *) fail "a pane closed on its still-running server should be proven gone: $proof" ;;
esac
pass "real tmux: a pane closed on its running server is proven gone"

# A window on a second server, judged from a process that addresses the first.
"$REAL_TMUX" -L "$SOCKET-other" -f /dev/null new-session -d -s other -x 200 -y 50 \
  || fail "real tmux: could not start the second server"
point_shim_at "$SOCKET-other"
OTHER_META="$SHIM_DIR/other.meta"
fm_backend_tmux_endpoint_identity "other:0" > "$OTHER_META" \
  || fail "the second server's window identity could not be read"
OTHER_PID=$(tmux display-message -p '#{pid}')
point_shim_at "$SOCKET"
[ "$(fm_backend_meta_exact_value "$OTHER_META" tmux_server_pid)" = "$OTHER_PID" ] \
  || fail "the second window's identity names the wrong server: $(cat "$OTHER_META")"
[ "$OTHER_PID" != "$SERVER_PID" ] || fail "the two servers should be different processes"
proof=$(absence_proof "$OTHER_META")
case "$proof" in
  "unproven "*"is still running, but this process addresses a different server (pid $SERVER_PID)"*) ;;
  *) fail "a window on a live server this process does not address must not be proven gone: $proof" ;;
esac
pass "real tmux: a window on a running server this process does not address is never proven gone"

"$REAL_TMUX" -L "$SOCKET-other" -f /dev/null kill-server || fail "could not stop the second server"
i=0
while kill -0 "$OTHER_PID" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
proof=$(absence_proof "$OTHER_META")
case "$proof" in
  "gone "*"(pid $OTHER_PID) has exited"*) ;;
  *) fail "a window whose server exited should be proven gone: $proof" ;;
esac
pass "real tmux: a window whose server process exited is proven gone"

if [ "$(readlink /proc/self/ns/user 2>/dev/null)" = 'user:[4026531837]' ] \
  && [ "$(readlink /proc/self/ns/time 2>/dev/null)" = 'time:[4026531834]' ]; then
  # Recorded from the initial namespaces, the window carries the kernel start
  # of this pid namespace's pid 1: the Linux system incarnation it lives in.
  INIT_START=$(awk '{ sub(/.*\) /, ""); print $20 }' /proc/1/stat)
  [ "$(fm_backend_meta_exact_value "$ABS_META" tmux_pidns_init_start)" = "$INIT_START" ] \
    || fail "the recorded identity should carry this namespace's pid 1 start ($INIT_START): $(cat "$ABS_META")"
  pass "real tmux: a window recorded in the initial namespaces names its Linux system incarnation"

  # A WSL2 distro restart, judged by the real kernel reads: a record from
  # another pid namespace whose own pid 1 and tmux server both started before
  # this namespace's pid 1 did.
  RESTART_META="$SHIM_DIR/restart.meta"
  printf 'tmux_boot=%s\ntmux_pidns=pid:[1]\ntmux_pidns_init_start=0\ntmux_server_pid=%s\ntmux_server_start=starttime=0\ntmux_pane_id=%%1\n' \
    "$(cat /proc/sys/kernel/random/boot_id)" "$SERVER_PID" > "$RESTART_META"
  proof=$(absence_proof "$RESTART_META")
  case "$proof" in
    "gone "*"has restarted on this same boot (a WSL2 distro restart)"*"$(readlink /proc/self/ns/pid)"*"tick $INIT_START"*) ;;
    *) fail "a window from an earlier Linux system incarnation on this boot should be proven gone: $proof" ;;
  esac
  pass "real tmux: a window from an earlier Linux system incarnation on an unchanged boot is proven gone"
else
  echo "skip - not in the initial user and time namespaces; the restart incarnation case is pinned by tests/fm-control-relaunch.test.sh"
fi

# A window recorded inside an unprivileged sandbox nested in this still-running
# system, judged from outside it: it carries no incarnation, and its pid
# namespace is not this one, so it is never proven gone.
NS_DIR="$SHIM_DIR/pidns"
if [ -e /proc/self/ns/pid ] && command -v unshare >/dev/null 2>&1 \
  && unshare --user --map-root-user --pid --fork --kill-child --mount-proc true 2>/dev/null; then
  mkdir -p "$NS_DIR"
  cat > "$NS_DIR/inner.sh" <<'SH'
#!/usr/bin/env bash
# Runs as pid 1 of the sandbox: its own tmux server on its own socket, a
# recorded window, then a wait until told to end.
set -u
root=$1 dir=$2 real_tmux=$3
mkdir -p "$dir/bin"
printf '#!/usr/bin/env bash\nexec env -u TMUX -u TMUX_PANE %q -S %q -f /dev/null "$@"\n' "$real_tmux" "$dir/sock" > "$dir/bin/tmux"
chmod +x "$dir/bin/tmux"
PATH="$dir/bin:$PATH"
. "$root/bin/fm-backend.sh"
fm_backend_source tmux || exit 1
tmux new-session -d -s ns -x 100 -y 30 || exit 1
fm_backend_tmux_create_task ns fm-ns "$HOME" >/dev/null || exit 1
fm_backend_tmux_endpoint_identity ns:fm-ns > "$dir/meta.tmp" || exit 1
mv "$dir/meta.tmp" "$dir/meta"
while [ ! -e "$dir/stop" ] && [ -d "$dir" ]; do sleep 0.1; done
tmux kill-server
SH
  chmod +x "$NS_DIR/inner.sh"
  unshare --user --map-root-user --pid --fork --kill-child --mount-proc \
    "$NS_DIR/inner.sh" "$ROOT" "$NS_DIR" "$REAL_TMUX" &
  NS_JOB=$!
  i=0
  while [ ! -s "$NS_DIR/meta" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  NS_META="$NS_DIR/meta"
  [ -s "$NS_META" ] || fail "the window inside the sandbox was never recorded"
  NS_PIDNS=$(fm_backend_meta_exact_value "$NS_META" tmux_pidns) \
    || fail "the window recorded in the sandbox carries no namespace: $(cat "$NS_META")"
  [ "$NS_PIDNS" != "$(readlink /proc/self/ns/pid)" ] \
    || fail "the window should have been recorded in a different pid namespace: $NS_PIDNS"
  ! fm_backend_meta_exact_value "$NS_META" tmux_pidns_init_start >/dev/null 2>&1 \
    || fail "a sandbox with its own user namespace must not record an incarnation: $(cat "$NS_META")"
  proof=$(absence_proof "$NS_META")
  case "$proof" in
    "foreign "*"different namespace ($(readlink /proc/self/ns/pid))"*"($NS_PIDNS)"*) ;;
    *) fail "a window in a sandbox that is still running must not be proven gone: $proof" ;;
  esac
  pass "real tmux: a window recorded in a running sandbox's pid namespace is never proven gone"
  : > "$NS_DIR/stop"
  wait "$NS_JOB" || fail "the sandbox did not end cleanly"
  NS_JOB=
else
  echo "skip - no unprivileged pid namespace here; the foreign namespace case is pinned by tests/fm-control-relaunch.test.sh"
fi

if [ -r /proc/sys/kernel/random/boot_id ] && [ -e /proc/self/ns/pid ]; then
  # A restart, staged by presenting a different boot identity beside the real
  # process table. The live first server's window must still be proven gone,
  # because no process survives a restart.
  BOOT_PROC="$SHIM_DIR/proc"
  mkdir -p "$BOOT_PROC/sys/kernel/random"
  printf '%s\n' 00000000-0000-0000-0000-000000000000 > "$BOOT_PROC/sys/kernel/random/boot_id"
  ln -s /proc/self "$BOOT_PROC/self"
  proof=$(FM_TMUX_PROC_ROOT_OVERRIDE="$BOOT_PROC" absence_proof "$ABS_META")
  case "$proof" in
    "gone "*"the machine has restarted since the endpoint was created"*) ;;
    *) fail "a window from a previous boot should be proven gone: $proof" ;;
  esac
  pass "real tmux: a window recorded in a previous boot is proven gone"
else
  echo "skip - no Linux boot identity here; the restart case is pinned by tests/fm-control-relaunch.test.sh"
fi

cleanup_all
trap - EXIT
