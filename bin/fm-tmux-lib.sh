#!/usr/bin/env bash
# fm-tmux-lib.sh — shared tmux pane primitives for firstmate.
#
# ONE tmux source for delivery-busy detection, composer capture primitives,
# and verified submit.
# Both the away-mode daemon and bin/fm-send.sh reach these primitives through
# backend dispatch, while bin/fm-composer-lib.sh owns the shared verdict.
#
# Composer shapes and verdicts are owned by bin/fm-composer-lib.sh.
# This file owns only tmux's styled capture, cursor and Pi identity primitives,
# delivery busy read, and submit conversions that consume the shared verdict.
# Styled captures remain internal; fm-peek and every human-facing capture stay
# plain.
#
# OpenCode's busy-queued Enter conversion accepts only structurally proven
# pending text after retries, while the separate turn-started conversion accepts
# an unknown post-Enter composer only after this submit observed an idle baseline
# become busy.
# The queued-Enter policy itself lives in fm_composer_queued_enter_verdict
# (bin/fm-composer-lib.sh); this file supplies tmux's pane-busy primitive.
#
# FM_COMPOSER_IDLE_RE is interpreted by the shared classifier with its structural
# and styling safety gates.
# FM_BUSY_REGEX overrides the rendered delivery-busy matching used here.
#
# NOT a task-state source: task busy state is owned by bin/fm-busy-lib.sh's
# semantic contract. The matching below serves only delivery guards: the submit
# acknowledgement and the away-mode supervisor-pane busy guard. Both ask about
# the pane receiving input, not the state of a recorded worker task. Matching
# stays harness-scoped so one harness's output cannot make another read busy.
#
# All functions are `set -u` and `set -e` safe (guarded tmux calls, explicit
# returns) so they can be sourced into either context.
#
# Composer classification is NOT owned here: every shape, glyph, border
# family, geometry rule, and verdict decision lives in the shared
# bin/fm-composer-lib.sh (fm_composer_classify_screen), sourced below and
# reused by every backend adapter so the decision cannot drift. This file
# keeps only tmux's genuine capture-side primitives - the styled pane
# capture, the #{cursor_y} cursor read, the pi foreground-process identity
# probe, and the capability descriptor - plus the busy detection and submit
# cores that consume the shared verdict.

# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-composer-lib.sh"
# shellcheck source=bin/fm-cursor-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-cursor-lib.sh"


# fm_tmux_strip_ghost: thin adapter over the shared, fleet-wide ghost extractor
# fm_composer_strip_ghost (bin/fm-composer-lib.sh). It drops de-emphasised
# ghost/placeholder runs - dim/faint (SGR 2, claude's/codex's/cursor's ghost) AND a
# dark/muted truecolor foreground (grok's placeholder) - from one captured,
# styled composer line and prints the plain, real-typed text. Kept as a named
# tmux entry point (and for existing callers/tests) but owns no logic of its own,
# so the tmux and herdr adapters cannot drift apart on what counts as ghost text.
fm_tmux_strip_ghost() { fm_composer_strip_ghost; }

# fm_tmux_pane_read: print tmux <format> for the EXACT pane <target> names, or
# return 1 when that pane does not exist. This is the single owner of turning a
# recorded tmux target into a pane; every tmux primitive that takes a target
# goes through it (directly, or through fm_tmux_exact_pane below).
#
# tmux's own target resolution cannot answer that question. For an absent
# window, pane, or session, `display-message -p -t` answers from the session's
# active window (or prints nothing) and still exits 0, so a dead worker window
# in a live session reads alive and its reads describe some other worker. The
# commands that do fail on an absent target (`capture-pane`, `send-keys`,
# `list-panes`) still match a window NAME by pattern and then by prefix, so
# `sess:fm-a` reaches `fm-abc` once `fm-a` is gone; and tmux always parses a dot
# after the colon as a pane separator, so a task id containing `.` cannot be
# named at all. This reader therefore never lets tmux pick the pane: it lists
# the panes of the exactly named window (or of the whole exact session when tmux
# cannot name that window exactly, or of the exact pane or window id), selects
# the row by comparing names and ids in the shell, and reads <format> in that
# same listing, so the value can never come from a pane other than the one
# matched.
#
# Accepted targets: `%<pane-id>`, `@<window-id>`, `<session>`, and
# `<session>:<window>`, where session is a name (optionally `=`-prefixed) or a
# `$<session-id>`, and window is a name (optionally `=`-prefixed), a numeric
# index (tried before a window of that name, as tmux does), or `@<window-id>`.
# A window target reads that window's active pane and a bare session its active
# window's active pane, as tmux means those targets. Any other shape reads as
# absent; a `.pane` suffix is part of the window name, never a pane selector.
fm_tmux_pane_read() {  # <target> <format>
  local target=${1-} format=${2-} tab scope lookup session='' window='' rows
  local sid sname pid wid widx wname wact pact value index_hit=0 index_value='' name_hit=0 name_value=''
  tab=$(printf '\t')
  case "$target" in
    %*|@*)
      case "${target#?}" in ''|*[!0-9]*) return 1 ;; esac
      scope=''
      lookup=$target
      ;;
    ''|:*|*:|*:*:*) return 1 ;;
    *)
      session=${target%%:*}
      case "$target" in *:*) window=${target#*:} ;; esac
      session=${session#=}
      window=${window#=}
      [ -n "$session" ] || return 1
      case "$target" in *:*) [ -n "$window" ] || return 1 ;; esac
      scope=-s
      # A session name is only matched exactly in the `=name:` form; `-s -t
      # =name` without the colon is parsed as a window and falls back.
      case "$session" in
        '$'*) lookup="$session:" ;;
        *) lookup="=$session:" ;;
      esac
      # An ordinary window name lists only that window: tmux resolves `=name`
      # exactly there and fails on an absent one. A dotted name cannot be named
      # to tmux, a numeric one may be an index, and a leading `+-!^$` is a tmux
      # window token, so those keep the whole-session listing.
      case "$window" in
        @*) scope=''; lookup=$window ;;
        ''|*.*|[-+!^\$]*) ;;
        *[!0-9]*) scope=''; lookup="$lookup=$window" ;;
      esac
      ;;
  esac
  # Every free-text field carries a leading `=` so an empty value cannot make
  # `read` collapse adjacent tab separators and shift the fields.
  rows=$(tmux list-panes ${scope:+"$scope"} -t "$lookup" -F "#{session_id}$tab=#{session_name}$tab#{pane_id}$tab#{window_id}$tab#{window_index}$tab=#{window_name}$tab#{window_active}$tab#{pane_active}$tab=$format" 2>/dev/null) || return 1
  while IFS=$tab read -r sid sname pid wid widx wname wact pact value; do
    sname=${sname#=}
    wname=${wname#=}
    value=${value#=}
    case "$target" in
      %*)
        [ "$pid" = "$target" ] || continue
        printf '%s\n' "$value"
        return 0
        ;;
      @*)
        [ "$wid" = "$target" ] && [ "$pact" = 1 ] || continue
        printf '%s\n' "$value"
        return 0
        ;;
    esac
    case "$session" in
      '$'*) [ "$sid" = "$session" ] || continue ;;
      *) [ "$sname" = "$session" ] || continue ;;
    esac
    [ "$pact" = 1 ] || continue
    case "$window" in
      '')
        [ "$wact" = 1 ] || continue
        printf '%s\n' "$value"
        return 0
        ;;
      @*)
        [ "$wid" = "$window" ] || continue
        printf '%s\n' "$value"
        return 0
        ;;
      *[!0-9]*) ;;
      *)
        if [ "$widx" = "$window" ]; then
          index_hit=1
          index_value=$value
        fi
        ;;
    esac
    if [ "$wname" = "$window" ] && [ "$name_hit" -eq 0 ]; then
      name_hit=1
      name_value=$value
    fi
  done <<EOF
$rows
EOF
  if [ "$index_hit" -eq 1 ]; then
    printf '%s\n' "$index_value"
    return 0
  fi
  if [ "$name_hit" -eq 1 ]; then
    printf '%s\n' "$name_value"
    return 0
  fi
  return 1
}

# fm_tmux_exact_pane: the `%<pane-id>` of the exact pane <target> names, or
# return 1 when it does not exist. Callers hand this id, never the raw target,
# to `capture-pane` and `send-keys`, which fail on an absent pane id instead of
# matching a neighbor by prefix.
fm_tmux_exact_pane() {  # <target>
  local pane
  pane=$(fm_tmux_pane_read "${1-}" '#{pane_id}') || return 1
  case "$pane" in
    %*) printf '%s\n' "$pane" ;;
    *) return 1 ;;
  esac
}

# --- tmux composer capture and capability primitives ------------------------
#
# These four functions are the ONLY tmux-specific composer knowledge left:
# how to capture a styled screen, how to read the cursor row, how to probe a
# live pi agent, and the static capability facts. Every shape, glyph, border
# family, and verdict decision lives in the shared owner
# (bin/fm-composer-lib.sh, fm_composer_classify_screen), so a new harness
# shape is taught there once and never here.

# fm_tmux_composer_capture: the visible pane WITH ANSI styling. The styled
# capture is consumed internally by the classifier and is NEVER surfaced
# (fm-peek and every human/LLM-facing path stay plain).
fm_tmux_composer_capture() {  # <target>
  local pane
  pane=$(fm_tmux_exact_pane "$1") || return 1
  tmux capture-pane -e -p -t "$pane" -S 0 -E - 2>/dev/null
}

# fm_tmux_composer_cursor_row: the pane's cursor row, zero-based, relative to
# the visible pane - tmux's genuine primitive that no other backend has.
fm_tmux_composer_cursor_row() {  # <target>
  fm_tmux_pane_read "$1" '#{cursor_y}'
}

# fm_tmux_composer_caps: the tmux capability descriptor - static data, not
# logic (see the capability model in bin/fm-composer-lib.sh).
fm_tmux_composer_caps() {
  printf 'styled=1\ncursor=1\nidentity=1\nrows=0\n'
}

# fm_tmux_composer_identity: the tmux agent-identity probe backing the
# separated (pi) composer shape, tmux's analogue of herdr's native
# `agent get`. It answers only for pi, from two live signals:
#   - identity: the pane tty's FOREGROUND process group (pgid = tpgid, the
#     same scoping as fm_backend_tmux_foreground_comms) contains a pi-family
#     process (pi, pi-signed, pi-launcher - docs/verification/
#     runtime-backends.md "Agent liveness name sources"), falling back to
#     tmux's own foreground-derived #{pane_current_command}. A pane whose
#     agent died to a shell has no pi foreground process and gets NO identity,
#     which is exactly what keeps the strict blank-row rule honest: a blank
#     row between two stale rules stays unknown.
#   - status: pi's verified busy footer via fm_pane_is_busy, mapped onto the
#     idle/working vocabulary herdr's probe reports natively.
# Prints "pi<TAB>idle" or "pi<TAB>working"; exits 1 when the pane is not a
# live pi.
fm_tmux_composer_identity() {  # <target>
  local target=$1 tty pgid tpgid comm found=0 status
  tty=$(fm_tmux_pane_read "$target" '#{pane_tty}') || tty=
  case "$tty" in
    /dev/*)
      while read -r _ pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        case "${comm##*/}" in
          pi|pi-signed|pi-launcher|Pi) found=1 ;;
        esac
      done <<EOF
$(LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null)
EOF
      ;;
  esac
  if [ "$found" -ne 1 ]; then
    comm=$(fm_tmux_pane_read "$target" '#{pane_current_command}') || comm=
    case "${comm##*/}" in
      pi|pi-signed|pi-launcher) found=1 ;;
    esac
  fi
  [ "$found" -eq 1 ] || return 1
  status=$(fm_pane_busy_state "$target" pi)
  case "$status" in
    busy) printf 'pi\tworking' ;;
    idle) printf 'pi\tidle' ;;
    *) return 1 ;;
  esac
}

# fm_tmux_composer_state: the tmux composer verdict - a thin adapter over the
# shared screen classifier. The verdict contract (empty | pending |
# pending-unproven | unknown, positive proof required for empty, unrecognized
# future verdicts failing safe) is owned by bin/fm-composer-lib.sh. Identity
# is fetched lazily, only when the classifier reports the verdict depends on
# it (a pi separator pair under the cursor), so the common read never pays
# for the process probe.
fm_tmux_composer_state() {  # <target> -> empty|pending|pending-unproven|unknown
  local target=$1 cy pane verdict identity
  cy=$(fm_tmux_composer_cursor_row "$target") || { printf 'unknown'; return 0; }
  case "$cy" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  pane=$(fm_tmux_composer_capture "$target") || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(fm_tmux_composer_caps)" "$pane" "$cy")
  if [ "$verdict" = need-identity ]; then
    if ! identity=$(fm_tmux_composer_identity "$target") || [ -z "$identity" ]; then
      identity='probe-absent'
    fi
    verdict=$(fm_composer_classify_screen "$(fm_tmux_composer_caps)" "$pane" "$cy" "$identity")
    [ "$verdict" != need-identity ] || verdict=unknown
  fi
  # Cursor Agent CLI parks its terminal cursor OUTSIDE its composer, below the
  # footer, with #{cursor_flag} 0 - so on a Cursor pane tmux's cursor row is not
  # a composer locator and the cursor-anchored read can only ever answer
  # `unknown`. Reclassify that pane the way every cursorless backend already
  # classifies it, letting the bottom-most shape win, which is the same rule
  # herdr, zellij, cmux, and orca use for every harness including this one.
  # Gated on Cursor's own structural process identity, never on the verdict
  # alone, so the strict blank-row posture that owns `unknown` for every other
  # harness is untouched.
  if [ "$verdict" = unknown ] && fm_tmux_pane_is_cursor "$target"; then
    verdict=$(fm_composer_classify_screen "$(fm_tmux_composer_caps)" "$pane" '')
  fi
  printf '%s' "$verdict"
}

# fm_tmux_pane_is_cursor: true when the pane's FOREGROUND process group contains
# a genuine Cursor Agent CLI process. Cursor runs as a bundled node script, so
# tmux's own #{pane_current_command} reports a bare `node`; identity therefore
# comes from Cursor's name or install tree in the command path or argv[0], whose
# single owner is bin/fm-cursor-lib.sh. The foreground scoping (pgid = tpgid)
# matches fm_tmux_composer_identity, so a pane whose agent exited to a shell has
# no Cursor foreground process and gets no reclassification.
fm_tmux_pane_is_cursor() {  # <target>
  local target=$1 tty pid pgid tpgid comm args argv0
  tty=$(fm_tmux_pane_read "$target" '#{pane_tty}') || return 1
  case "$tty" in /dev/*) ;; *) return 1 ;; esac
  while read -r pid pgid tpgid comm; do
    [ -n "$comm" ] || continue
    [ "$pgid" = "$tpgid" ] || continue
    args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || args=
    args=${args#"${args%%[![:space:]]*}"}
    argv0=${args%%[[:space:]]*}
    fm_cursor_process_matches "$comm" '' "$argv0" && return 0
  done <<EOF
$(LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null)
EOF
  return 1
}

# fm_pane_input_pending: 0 when the composer is not proven empty, so pending
# text, ambiguous structure, unreadable state, and future verdicts all defer.
fm_pane_input_pending() {  # <target>
  [ "$(fm_tmux_composer_state "$1")" != empty ]
}

# fm_pane_is_busy: 0 if the pane's last few non-blank lines show a busy footer
# (an agent mid-turn). Scans a 40-line tail like fm-watch.sh.
fm_pane_busy_state() {  # <target> [harness] -> busy|idle|unknown
  local win=$1 harness=${2:-} pane tail40 visible
  pane=$(fm_tmux_exact_pane "$win") || { printf 'unknown'; return 0; }
  tail40=$(tmux capture-pane -p -t "$pane" -S -40 2>/dev/null) \
    || { printf 'unknown'; return 0; }
  visible=$(printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -12)
  [ -n "$visible" ] || { printf 'unknown'; return 0; }
  if printf '%s' "$visible" | fm_busy_lines_match "$harness"; then
    printf 'busy'
  else
    printf 'idle'
  fi
}

fm_pane_is_busy() {  # <target> [harness]
  [ "$(fm_pane_busy_state "$1" "${2:-}")" = busy ]
}

# fm_tmux_submit_core: type <text> into <target> ONCE, then submit with Enter,
# verifying the composer cleared. Retries Enter ONLY — never retypes, because a
# swallowed Enter leaves our text in the composer and retyping would duplicate
# it. Echoes the final proof-carrying verdict on stdout so callers can require
# exact `empty` before treating submission as confirmed.
# Busy-queued Enter (opencode 1.18.4): the harness accepts Enter while mid-turn
# and queues it for after the current turn, but keeps the typed text visible in
# the composer. Once the Enter-retry budget is spent and a structurally proven
# composer still reads "pending", the submit core falls back to
# `fm_pane_is_busy`: a busy pane means the Enter was accepted and queued (report
# `empty` so the caller does not re-send), while an idle pane keeps `pending` as
# a genuine swallow. Pending-unproven receives the same Enter retry budget but
# never reaches this exception.
# Turn-started confirmation (the strict blank-row posture's counterpart): a
# harness whose mid-turn screen the classifier cannot positively identify (pi
# replaces its separated composer while working) reads `unknown` right after a
# successful submit. When and only when the pane was IDLE before the text was
# typed, an idle-to-busy transition across our Enter is proof the harness
# accepted the submission - the same semantic signal herdr's native
# agent-state confirmation uses, read from the pane's verified busy footer.
# The busy read is polled across the remaining retry budget because the turn
# takes a beat to render. Without the baseline (a direct
# fm_tmux_submit_enter_core caller, or a pane already busy before typing) an
# `unknown` verdict is preserved untouched: busy conversion without the
# transition evidence could mark an undelivered message delivered.
fm_tmux_submit_enter_core() {  # <target> <retries> <enter-sleep> [baseline-idle]
  local target=$1 retries=$2 sleep_s=$3 baseline_idle=${4:-} i=0 j state busy_state
  # Resolve once, so every Enter and every read lands on the same exact pane.
  target=$(fm_tmux_exact_pane "$target") || { printf 'unknown'; return 0; }
  while :; do
    tmux send-keys -t "$target" Enter 2>/dev/null || true
    sleep "$sleep_s"
    state=$(fm_tmux_composer_state "$target")
    case "$state" in
      pending|pending-unproven) ;;
      unknown)
        if [ "$baseline_idle" = 1 ]; then
          j=0
          while [ "$j" -lt "$retries" ]; do
            if fm_pane_is_busy "$target"; then
              printf 'empty'
              return 0
            fi
            j=$((j + 1))
            [ "$j" -ge "$retries" ] || sleep "$sleep_s"
          done
        fi
        printf 'unknown'
        return 0
        ;;
      *) printf '%s' "$state"; return 0 ;;
    esac
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || break
  done
  if [ "$state" != pending ]; then
    printf '%s' "$state"
    return 0
  fi
  # Retries exhausted, composer still shows proven pending.
  # Busy conversion is owned by fm_composer_queued_enter_verdict.
  busy_state=idle
  fm_pane_is_busy "$target" && busy_state=busy
  fm_composer_queued_enter_verdict "$state" "$busy_state"
}

fm_tmux_submit_core() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 baseline_idle='' baseline_state
  target=$(fm_tmux_exact_pane "$target") || { printf 'send-failed'; return 0; }
  # The turn-started baseline must predate our own typing: a pane already
  # busy before the text lands can turn "busy" for reasons unrelated to our
  # Enter, so only a clean idle-to-busy transition may confirm a submit.
  baseline_state=$(fm_pane_busy_state "$target")
  [ "$baseline_state" = idle ] && baseline_idle=1
  tmux send-keys -t "$target" -l "$text" 2>/dev/null || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_tmux_submit_enter_core "$target" "$retries" "$sleep_s" "$baseline_idle"
}
