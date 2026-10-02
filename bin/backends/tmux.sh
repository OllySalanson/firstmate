#!/usr/bin/env bash
# bin/backends/tmux.sh - the tmux session-provider adapter.
#
# Reference backend (AGENTS.md section 8; data/fm-backend-design-d7). P1 moves
# the tmux command sequences that fm-send.sh, fm-peek.sh, fm-watch.sh,
# fm-spawn.sh, and fm-teardown.sh already ran inline into named functions
# here, running the EXACT same commands in the EXACT same order, so the
# default (tmux, `backend=` absent) path stays byte-identical. Sourced only
# through bin/fm-backend.sh's fm_backend_source, never directly.
#
# Worktree acquisition (running `treehouse get` inside the pane, and polling
# its cwd) is unchanged by this extraction: P1 scopes only the session
# provider, not the worktree provider, so fm-spawn.sh still drives that part
# inline with these same send/current-path primitives.
#
# The verified composer/busy-detection and verify-and-retry-submit primitives
# already live in bin/fm-tmux-lib.sh, shared with the away-mode daemon
# (bin/fm-supervise-daemon.sh); this adapter sources that file and re-exports
# its submit core under the backend's naming convention rather than
# duplicating it, so the two consumers cannot drift apart.
# shellcheck source=bin/fm-tmux-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-agent-process-lib.sh"

# fm_backend_tmux_resolve_bare_selector: the live-window-listing fallback for a
# selector that is neither an explicit target nor a task selector routed
# through meta - an ad hoc window name with no recorded task. Mirrors the
# `tmux list-windows -a ... | grep` pipeline that used to live inline in
# fm-send.sh's and fm-peek.sh's own (until now duplicated) resolve().
fm_backend_tmux_resolve_bare_selector() {  # <name>
  local name=$1
  tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$name\$" \
    || { echo "error: no window named $name" >&2; return 1; }
}

# Every primitive below that takes a <target> resolves it through
# fm_tmux_exact_pane or fm_tmux_pane_read (bin/fm-tmux-lib.sh) first, so an
# absent window fails instead of reading or typing into a neighbor.

# fm_backend_tmux_capture: bounded plain-text pane capture.
fm_backend_tmux_capture() {  # <target> <lines>
  local pane
  pane=$(fm_tmux_exact_pane "$1") || { echo "error: no tmux pane for $1" >&2; return 1; }
  tmux capture-pane -p -t "$pane" -S -"$2"
}

# fm_backend_tmux_visible_capture: the visible viewport only. `-S -0` starts at
# the first line of the pane rather than in its history, so nothing scrolled out
# of view can appear in the result - the guarantee a trust-dialog predicate
# needs, which the scrollback-bounded capture above cannot give.
fm_backend_tmux_visible_capture() {  # <target>
  local pane
  pane=$(fm_tmux_exact_pane "$1") || { echo "error: no tmux pane for $1" >&2; return 1; }
  tmux capture-pane -p -t "$pane" -S -0
}

# fm_backend_tmux_send_key: one named key.
fm_backend_tmux_send_key() {  # <target> <key>
  local pane
  pane=$(fm_tmux_exact_pane "$1") || { echo "error: no tmux pane for $1" >&2; return 1; }
  tmux send-keys -t "$pane" "$2"
}

# fm_backend_tmux_send_text_submit: type <text> into <target> once, then
# submit with Enter, retried (Enter only, never retyped) until the composer
# clears. Re-exports fm_tmux_submit_core (bin/fm-tmux-lib.sh) verbatim; see
# that file for the composer-verification contract and echoed verdicts.
fm_backend_tmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  fm_tmux_submit_core "$@"
}

# fm_backend_tmux_container_ensure: reuse the current tmux session when
# firstmate itself runs inside tmux, else ensure a dedicated detached
# "firstmate" session exists. Mirrors fm-spawn.sh's container-ensure block;
# prints the resolved session name.
fm_backend_tmux_container_ensure() {
  if [ -n "${TMUX:-}" ]; then
    tmux display-message -p '#S'
  else
    tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate
    printf 'firstmate'
  fi
}

# fm_backend_tmux_create_task: create the task's window in <proj-abs>,
# refusing an existing <window-name> in <session>. Mirrors fm-spawn.sh's
# duplicate-check-then-new-window sequence, including the exact error text
# (session:window, matching how fm-spawn.sh composed its own $T). Prints the
# created window's stable window id on stdout for the caller to target.
#
# Robustness (fm-spawn tmux window handling under a non-default captain config):
#   - Capture a STABLE window id with -P -F '#{window_id}', and let tmux append
#     at the next free index by targeting the session with a trailing colon
#     ("$ses:"), so a non-default base-index (e.g. base-index 1) cannot collide.
#   - PIN the window name by disabling automatic-rename and allow-rename on the
#     new window: the captain's tmux may rename the window away from fm-<id> once
#     treehouse cd's into the worktree, which would break name-based targeting.
# The returned window id lets callers target the window even if its name is ever
# lost, so worktree discovery cannot fall back to the active client's window.
fm_backend_tmux_create_task() {  # <session> <window-name> <proj-abs> -> prints window id
  local ses=$1 wname=$2 proj_abs=$3 wid
  if tmux list-windows -t "$ses" -F '#{window_name}' | grep -qx "$wname"; then
    echo "error: window $ses:$wname already exists" >&2
    return 1
  fi
  wid=$(tmux new-window -dP -F '#{window_id}' -t "$ses:" -n "$wname" -c "$proj_abs") || return 1
  tmux set-window-option -t "$wid" automatic-rename off 2>/dev/null || true
  tmux set-window-option -t "$wid" allow-rename off 2>/dev/null || true
  printf '%s\n' "$wid"
}

# fm_backend_tmux_current_path: the live pane's current working directory, or
# empty when the exact pane is absent or unreadable.
fm_backend_tmux_current_path() {  # <target>
  fm_tmux_pane_read "$1" '#{pane_current_path}'
}

# fm_backend_tmux_send_text_line: send one line of TEXT then Enter, with no
# composer verification - used for the fixed spawn-time commands
# (`treehouse get`, the GOTMPDIR export) that already ran this exact sequence
# inline in fm-spawn.sh.
fm_backend_tmux_send_text_line() {  # <target> <text>
  local pane
  pane=$(fm_tmux_exact_pane "$1") || { echo "error: no tmux pane for $1" >&2; return 1; }
  tmux send-keys -t "$pane" "$2" Enter
}

# fm_backend_tmux_send_literal: send TEXT as literal bytes with no
# submission - the caller sends Enter separately (fm-spawn.sh's launch-command
# send pauses between the literal send and Enter for the harness to settle).
fm_backend_tmux_send_literal() {  # <target> <text>
  local pane
  pane=$(fm_tmux_exact_pane "$1") || { echo "error: no tmux pane for $1" >&2; return 1; }
  tmux send-keys -t "$pane" -l "$2"
}

# fm_backend_tmux_window_inventory: <session-target>'s window names, one per
# line on stdout, together with a verdict on the READ ITSELF, which is what
# every caller that must not guess depends on:
#   0 - the inventory was read; its lines are that session's windows.
#   2 - tmux answered definitively that the session, or its whole server, is
#       absent, so no window of that session exists.
#   1 - the read could not be made at all, and proves nothing either way. A
#       transient tmux problem, or a tmux that is not even on PATH, must never
#       be read as an absent endpoint: that mistake launches a duplicate agent
#       for fm_backend_tmux_agent_state and reports a live window as closed for
#       fm_backend_tmux_kill.
# The target is passed through exactly as the caller means it, so a caller that
# requires the exact recorded session asks for `=session` and still gets the
# same classification.
fm_backend_tmux_window_inventory() {  # <session-target>
  local windows
  if windows=$(LC_ALL=C tmux list-windows -t "$1" -F '#{window_name}' 2>&1); then
    printf '%s\n' "$windows"
    return 0
  fi
  case "$windows" in
    *"can't find session:"*|*"no server running on "*|*"error connecting to "*" (No such file or directory)"|*"error connecting to "*" (Connection refused)")
      return 2
      ;;
  esac
  return 1
}

# fm_backend_tmux_kill: remove one explicitly named task window.
# Empty, omitted, and malformed targets return nonzero before invoking tmux so
# tmux can never interpret an empty target as the caller's current window.
#
# A close that did not succeed is resolved, never assumed: `kill-window` fails
# for the ordinary already-exited window exactly as it does for a window that
# is still there, so its status alone cannot tell a benign cleanup from a
# stranded endpoint. The re-read below settles which one happened, under the
# window's EXACT recorded identity (`=session` plus a whole-line name match -
# never a prefix, which would read a neighbor as this window's survivor).
# Only a read that actually happened can settle it, so the same classification
# fm_backend_tmux_agent_state uses applies here: a window still present is the
# kill failing to do its job, a definitively absent session or server is the
# silent success, and an inventory that could not be read refuses rather than
# calling a window it never saw closed. An already-gone window, and a whole
# server that is already gone, stay silent successes. Verified against real
# tmux 3.7c: killing a live window, re-killing the same gone window, and
# killing into a dead session all return 0 here
# (docs/verification/runtime-backends.md "Endpoint close").
fm_backend_tmux_kill() {  # <target>
  local target=${1:-} session window windows inventory_status
  case "$target" in
    *:*)
      session=${target%%:*}
      window=${target#*:}
      ;;
    *) return 1 ;;
  esac
  case "$session:$window" in
    :*|*:|*:*:*) return 1 ;;
  esac
  tmux kill-window -t "=$session:=$window" 2>/dev/null && return 0
  windows=$(fm_backend_tmux_window_inventory "=$session")
  inventory_status=$?
  if [ "$inventory_status" -eq 2 ]; then
    return 0
  fi
  if [ "$inventory_status" -ne 0 ]; then
    echo "error: tmux window $session:$window could not be read after its close, so whether it survived is unknown" >&2
    return 1
  fi
  printf '%s\n' "$windows" | grep -qxF -- "$window" || return 0
  echo "error: tmux window $session:$window is still present after its close" >&2
  return 1
}

# fm_backend_tmux_current_command: <target>'s live foreground process name -
# tmux's own `#{pane_current_command}`, already resolved from the pty's
# foreground process group (verified empirically with real tmux 3.6a: a
# harness invoked interactively stays the reported command even while it
# shells out to subcommands that do not take over the pty - e.g. `bash -c
# "sleep 30"` alone reports "sleep" because bash execs directly into it, but
# a persisting parent script running `sleep` as a child reports the PARENT's
# own name throughout; the value reverts to the shell's own name only once
# the foreground command actually exits). Empty, with a nonzero status, when
# the exact pane is absent or unreadable.
fm_backend_tmux_current_command() {  # <target>
  fm_tmux_pane_read "$1" '#{pane_current_command}'
}

# The process-name classifier every liveness signal below feeds
# (fm_agent_process_classify_name) is owned by bin/fm-agent-process-lib.sh,
# shared with the Herdr adapter so both backends mean the same thing by
# `agent`, `shell`, and `other`.

# fm_backend_tmux_foreground_comms: the kernel-side names of every process in
# <target>'s pane tty foreground process group, one full value per line.
# Empty on any failure.
#
# This is the foreground-process-group half of the liveness probe, and it exists
# because `#{pane_current_command}` and `ps -o comm=` expose different name
# fields whose roles vary by platform. On macOS the tmux field can carry a
# harness-rewritten title (Claude Code 2.1.220 reports `2.1.220`) while `comm`
# retains executable identity; the portable Linux regression observes the
# reverse for its version-named executable. Reading both `comm` and argv[0]
# preserves an identifying install path without making either platform's field
# assignment load-bearing.
#
# Scoping to the foreground process group rather than to the pane's descendants
# is what keeps the probe honest in the other direction: a harness-named process
# left running in the background of an otherwise idle pane is deliberately NOT
# reported, so a genuinely agent-free pane still classifies `dead`. It also
# reports every member of a multi-process launcher (the Pi Launcher path runs a
# `pi-signed` wrapper and a `pi` engine in one group), so no launcher needs its
# own special case here.
#
# Like fm_backend_tmux_current_command it reads only the exact pane <target>
# names, and reads nothing when that pane is absent.
fm_backend_tmux_foreground_comms() {  # <target>
  local target=$1 tty pid pgid tpgid comm
  tty=$(fm_tmux_pane_read "$target" '#{pane_tty}') || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        printf '%s\n' "$comm"
      done
}

# The foreground group's full command lines. Needed because a node-bundle
# harness carries its identity in argv[1] rather than in its command name or
# argv[0]; bin/fm-gemini-lib.sh owns what counts as evidence inside one.
fm_backend_tmux_foreground_args() {  # <target>
  local target=$1 tty pid pgid tpgid comm args
  tty=$(fm_tmux_pane_read "$target" '#{pane_tty}') || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || continue
        [ -n "$args" ] && printf '%s\n' "$args"
      done
}

fm_backend_tmux_foreground_pids() {  # <target>
  local target=$1 tty pid pgid tpgid comm
  tty=$(fm_tmux_pane_read "$target" '#{pane_tty}') || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        printf '%s\n' "$pid"
      done
}

fm_backend_tmux_foreground_argv0s() {  # <target>
  local target=$1 tty pid pgid tpgid comm args argv0
  tty=$(fm_tmux_pane_read "$target" '#{pane_tty}') || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || continue
        args=${args#"${args%%[![:space:]]*}"}
        argv0=${args%%[[:space:]]*}
        [ -n "$argv0" ] && printf '%s\n' "$argv0"
      done
}

# fm_backend_tmux_agent_state: recovery-grade harness-agent state for one
# recorded target. See bin/fm-backend.sh's fm_backend_agent_state for the
# shared state vocabulary and docs/tmux-backend.md "Agent liveness probe" for
# the empirical basis. The exact recorded session is inventoried first so an
# absent window is told apart from an unreadable one; the pane reads after it
# go through the exact-pane resolver and so can never describe a neighbor.
# An omitted window or a definitive missing-session/server response is
# `missing`; any other inventory or pane read failure is `unreadable`, so a
# transient tmux problem never licenses a duplicate.
# fm_backend_tmux_window_inventory above owns that read classification, shared
# with fm_backend_tmux_kill so both mean the same thing by an absent session.
#
# The verdict combines two independent name sources rather than trusting either
# alone. Either source naming a verified harness is enough for `alive`, because
# a false `dead` is the one outcome that can launch a duplicate agent onto a
# live worktree, while the foreground process group - when it is readable - is
# authoritative for the negative verdicts, since it is the only source that can
# distinguish a truly idle pane from a rewritten process title.
fm_backend_tmux_agent_state() {  # <target>
  local target=$1 comm session window windows inventory_status
  local foreground argv0s name pid fg_seen=0 fg_shell=0 fg_other=0
  case "$target" in
    *:*:*|'':*|*:'') printf 'unreadable'; return 0 ;;
    *:*) ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  session=${target%%:*}
  window=${target#*:}
  windows=$(fm_backend_tmux_window_inventory "=$session")
  inventory_status=$?
  if [ "$inventory_status" -ne 0 ]; then
    if [ "$inventory_status" -eq 2 ]; then
      printf 'missing'
    else
      printf 'unreadable'
    fi
    return 0
  fi
  if ! printf '%s\n' "$windows" | grep -Fqx "$window"; then
    printf 'missing'
    return 0
  fi

  foreground=$(fm_backend_tmux_foreground_comms "$target")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    fg_seen=1
    case "$(fm_agent_process_classify_name "$name")" in
      agent) printf 'alive'; return 0 ;;
      shell) fg_shell=1 ;;
      *) fg_other=1 ;;
    esac
  done <<EOF
$foreground
EOF

  argv0s=$(fm_backend_tmux_foreground_argv0s "$target")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ "$(fm_agent_process_classify_name '' "$name")" = agent ]; then
      printf 'alive'
      return 0
    fi
  done <<EOF
$argv0s
EOF

  # Preserve argv boundaries where the platform exposes them. This is needed
  # when the Gemini script path contains whitespace, which flattened ps output
  # cannot represent unambiguously.
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if fm_gemini_pid_is_gemini "$pid"; then
      printf 'alive'
      return 0
    fi
  done <<EOF
$(fm_backend_tmux_foreground_pids "$target")
EOF

  # Fall back to flattened arguments on platforms without /proc. Positive
  # evidence only - a bare interpreter still reaches the negative verdicts.
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if fm_gemini_args_are_gemini "$name"; then
      printf 'alive'
      return 0
    fi
  done <<EOF
$(fm_backend_tmux_foreground_args "$target")
EOF

  comm=$(fm_backend_tmux_current_command "$target") || {
    printf 'unreadable'
    return 0
  }
  if [ "$(fm_agent_process_classify_name "$comm")" = agent ]; then
    printf 'alive'
    return 0
  fi

  # A readable foreground process group settles the negative verdicts: only a
  # group that is nothing but shells is confidently agent-free.
  if [ "$fg_seen" -eq 1 ]; then
    if [ "$fg_other" -eq 0 ] && [ "$fg_shell" -eq 1 ]; then
      printf 'dead'
    else
      printf 'ambiguous'
    fi
    return 0
  fi

  case "$comm" in
    '') printf 'unreadable'; return 0 ;;
  esac
  case "$(fm_agent_process_classify_name "$comm")" in
    shell) printf 'dead' ;;
    *) printf 'ambiguous' ;;
  esac
}

# Backward-compatible three-state view for callers that only need a yes/no
# agent verdict. The detailed state contract is owned by fm_backend_agent_state.
fm_backend_tmux_agent_alive() {  # <target>
  case "$(fm_backend_tmux_agent_state "$1")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}

# --- Endpoint identity and provable absence ---------------------------------
#
# fm_backend_tmux_agent_state's `missing` cannot by itself say a task window is
# GONE: every tmux read describes only the server this process addresses, so a
# window on a server it cannot see reads exactly like a destroyed one. These
# helpers close that gap with kernel facts recorded at spawn rather than with
# any wider tmux read:
#
#   tmux_boot=          the kernel boot identity the window was created in
#                       (Linux /proc/sys/kernel/random/boot_id, macOS
#                       kern.bootsessionuuid). A different current boot proves
#                       every process of the recorded one - the tmux server and
#                       the agent with it - is gone.
#   tmux_pidns=         the pid namespace those pids are numbered in (Linux
#                       only; absent where the platform has none).
#   tmux_server_pid=    the server process that holds the window, and
#   tmux_server_start=  that process's kernel start identity. Within one boot
#                       and namespace a pid plus its start identity names one
#                       process, so its absence proves the server - and every
#                       window it held - is gone.
#   tmux_window_id=     the server-unique `@N` id of the window. While the
#                       recorded server still runs and IS the server this
#                       process addresses, that id missing from its complete
#                       inventory proves the window itself was closed.
#
# Wall-clock comparisons (boot time against spawn time) are deliberately not
# used: WSL2's clock is observed to step after host sleep, and a stepped clock
# could otherwise date a live window to before the current boot.
#
# FM_TMUX_PROC_ROOT_OVERRIDE (else FM_PROC_ROOT_OVERRIDE, as in
# bin/fm-wake-lib.sh) relocates every /proc read here, so a test can stage a
# restart or an exited server without relocating unrelated process reads.

# The current kernel boot identity, or nonzero when the platform exposes none.
fm_backend_tmux_boot_id() {
  local proc_root=${FM_TMUX_PROC_ROOT_OVERRIDE:-${FM_PROC_ROOT_OVERRIDE:-/proc}} id=
  if [ -r "$proc_root/sys/kernel/random/boot_id" ]; then
    id=$(cat "$proc_root/sys/kernel/random/boot_id" 2>/dev/null) || id=
  elif [ "$(uname 2>/dev/null)" = Darwin ]; then
    id=$(sysctl -n kern.bootsessionuuid 2>/dev/null) || id=
  fi
  case "$id" in
    ''|*[!A-Za-z0-9-]*) return 1 ;;
  esac
  printf '%s\n' "$id"
}

# This process's pid namespace, empty where the platform has no /proc
# namespaces (a pid there is numbered system-wide).
fm_backend_tmux_pidns() {
  local proc_root=${FM_TMUX_PROC_ROOT_OVERRIDE:-${FM_PROC_ROOT_OVERRIDE:-/proc}} ns
  [ -e "$proc_root/self" ] || [ -L "$proc_root/self" ] || return 0
  ns=$(readlink "$proc_root/self/ns/pid" 2>/dev/null) || return 1
  [ -n "$ns" ] || return 1
  case "$ns" in *[[:space:]]*) return 1 ;; esac
  printf '%s\n' "$ns"
}

# fm_backend_tmux_process_start <pid>: the process's kernel start identity.
# Prints it and returns 0; returns 2 when no process with that pid exists;
# returns 1 when that could not be established. Only the start time is used,
# never the process name: tmux renames its server's comm to `tmux: server`
# (verified, tmux 3.4), and a renamed process must never read as a different
# one.
fm_backend_tmux_process_start() {  # <pid>
  local pid=${1-} proc_root=${FM_TMUX_PROC_ROOT_OVERRIDE:-${FM_PROC_ROOT_OVERRIDE:-/proc}} stat_line starttime out rc=0
  local -a stat_fields
  case "$pid" in ''|*[!0-9]*|0) return 1 ;; esac
  if [ -e "$proc_root/self" ] || [ -L "$proc_root/self" ]; then
    [ -e "$proc_root/$pid" ] || return 2
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || {
      # The process may have exited between the two reads.
      [ -e "$proc_root/$pid" ] || return 2
      return 1
    }
    # After the final comm delimiter, array index 19 is proc stat field 22:
    # start time in clock ticks since boot.
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in ''|*[!0-9]*) return 1 ;; esac
    printf 'starttime=%s\n' "$starttime"
    return 0
  fi
  # No /proc: ps exits 1 with no output for a pid that does not exist. LC_ALL
  # and TZ are pinned so the rendered start date cannot change with the
  # reader's locale or zone.
  out=$(LC_ALL=C TZ=UTC0 ps -p "$pid" -o lstart= 2>/dev/null) || rc=$?
  out=$(printf '%s' "$out" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    case "$out" in *$'\n'*) return 1 ;; esac
    printf 'lstart=%s\n' "$out"
    return 0
  fi
  [ "$rc" -eq 1 ] && [ -z "$out" ] && return 2
  return 1
}

# fm_backend_tmux_endpoint_identity <target>: the identity lines above for the
# live window <target> names, ready to append to a task record. Prints nothing
# and returns 1 when the boot identity is unreadable; the server and window
# lines are printed only when every one of them was read, so a record never
# carries half a server identity.
fm_backend_tmux_endpoint_identity() {  # <target>
  local target=${1-} boot pidns ids server_pid window_id start
  boot=$(fm_backend_tmux_boot_id) || return 1
  ids=$(fm_tmux_pane_read "$target" '#{pid} #{window_id}') || ids=
  server_pid=${ids%% *}
  window_id=${ids#* }
  printf 'tmux_boot=%s\n' "$boot"
  pidns=$(fm_backend_tmux_pidns) || return 0
  case "$server_pid" in ''|*[!0-9]*) return 0 ;; esac
  case "${window_id#@}" in ''|*[!0-9]*) return 0 ;; esac
  [ "$window_id" != "${window_id#@}" ] || return 0
  start=$(fm_backend_tmux_process_start "$server_pid") || return 0
  [ -z "$pidns" ] || printf 'tmux_pidns=%s\n' "$pidns"
  printf 'tmux_server_pid=%s\n' "$server_pid"
  printf 'tmux_server_start=%s\n' "$start"
  printf 'tmux_window_id=%s\n' "$window_id"
}

# fm_backend_tmux_endpoint_absence_proof <meta>: decide, from the identity a
# task record carries, whether its window is provably gone. Call it only after
# fm_backend_tmux_agent_state read `missing`. Prints "gone\t<proof>" or
# "unproven\t<reason>" with exactly one TAB; bin/fm-control-lib.sh's
# fm_control_endpoint_absence_verdict owns how callers act on it.
fm_backend_tmux_endpoint_absence_proof() {  # <meta>
  local meta=${1-} rec_boot rec_ns rec_pid rec_start rec_wid boot ns start rc addressed windows
  rec_boot=$(fm_backend_meta_exact_value "$meta" tmux_boot 2>/dev/null) || rec_boot=
  if [ -z "$rec_boot" ]; then
    printf 'unproven\ttmux absence cannot be proven from this task record: it carries no endpoint identity (it predates tmux_boot= recording), and a server-wide window inventory only describes the tmux server this process addresses, so a window absent from it may still be alive on another'
    return 0
  fi
  boot=$(fm_backend_tmux_boot_id) || {
    printf 'unproven\tthis machine'"'"'s current boot identity could not be read, so a restart since the endpoint was created cannot be proven'
    return 0
  }
  if [ "$boot" != "$rec_boot" ]; then
    printf 'gone\tthe machine has restarted since the endpoint was created (boot %s, now %s), and no process survives a restart' "$rec_boot" "$boot"
    return 0
  fi
  rec_pid=$(fm_backend_meta_exact_value "$meta" tmux_server_pid 2>/dev/null) || rec_pid=
  rec_start=$(fm_backend_meta_exact_value "$meta" tmux_server_start 2>/dev/null) || rec_start=
  rec_wid=$(fm_backend_meta_exact_value "$meta" tmux_window_id 2>/dev/null) || rec_wid=
  if [ -z "$rec_pid" ] || [ -z "$rec_start" ] || [ -z "$rec_wid" ]; then
    printf 'unproven\tthe machine has not restarted since the endpoint was created, and the record carries no tmux server identity to prove the window gone without one'
    return 0
  fi
  rec_ns=$(fm_backend_meta_exact_value "$meta" tmux_pidns 2>/dev/null) || rec_ns=
  ns=$(fm_backend_tmux_pidns) || ns='<unreadable>'
  if [ "$ns" != "$rec_ns" ]; then
    printf 'unproven\tthis process numbers pids in a different namespace (%s) from the one the endpoint was recorded in (%s), so the recorded tmux server pid cannot be checked from here' "${ns:-none}" "${rec_ns:-none}"
    return 0
  fi
  rc=0
  start=$(fm_backend_tmux_process_start "$rec_pid") || rc=$?
  case "$rc" in
    2)
      printf 'gone\tthe tmux server that held it (pid %s) has exited, and its windows went with it' "$rec_pid"
      return 0
      ;;
    0) ;;
    *)
      printf 'unproven\tthe recorded tmux server process (pid %s) could not be read, so whether it still holds the window is unknown' "$rec_pid"
      return 0
      ;;
  esac
  if [ "$start" != "$rec_start" ]; then
    printf 'gone\tthe tmux server that held it (pid %s) has exited - that pid now belongs to a process started later - and its windows went with it' "$rec_pid"
    return 0
  fi
  # The recorded server still runs. Its own inventory settles the window only
  # when it IS the server this process addresses.
  addressed=$(tmux display-message -p '#{pid}' 2>/dev/null) || addressed=
  if [ "$addressed" != "$rec_pid" ]; then
    printf 'unproven\tthe tmux server that held it (pid %s) is still running, but this process addresses %s, so its windows cannot be read from here' "$rec_pid" "${addressed:+a different server (pid $addressed)}${addressed:-no server}"
    return 0
  fi
  windows=$(tmux list-windows -a -F '#{window_id}' 2>/dev/null) || {
    printf 'unproven\tthe tmux server that held it (pid %s) is still running, but its window inventory could not be read' "$rec_pid"
    return 0
  }
  if printf '%s\n' "$windows" | grep -Fqx -- "$rec_wid"; then
    printf 'unproven\tits window %s still exists on the tmux server that holds it, but no longer at the recorded address, so an agent may still be running in it' "$rec_wid"
    return 0
  fi
  printf 'gone\tits window %s was closed on the tmux server that still runs (pid %s)' "$rec_wid" "$rec_pid"
}
