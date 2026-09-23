#!/usr/bin/env bash
# fm-memory-watchdog.sh - the one memory watchdog that owns worker admission,
# the critical-line heavy-job stop, and the flagship-first dispatch order.
#
# Usage:
#   fm-memory-watchdog.sh status
#       Human-readable gate state: memory used, reservations, the three lines,
#       the job ceilings, the flagship, deferred work, and whether the watchdog loop is running.
#   fm-memory-watchdog.sh queue
#       This home's dispatchable queued work (bin/fm-tasks-axi.sh ready) in
#       dispatch order: the flagship project's items first, then everything
#       else, each group in the backlog's own request order.
#   fm-memory-watchdog.sh flagship [<project> | --clear]
#       Print, set, or clear config/flagship.
#   fm-memory-watchdog.sh admit <task-id> [--relaunch] [--override]
#       Admission for one ship or scout worker, called by bin/fm-spawn.sh for a
#       fresh spawn and by bin/fm-control.sh (or a direct fm-spawn --relaunch)
#       for a relaunch, which --relaunch marks. Exit 0 admits and records a
#       reservation; exit 75 defers (the task is recorded as deferred and the
#       loop reports when room frees); exit 1 is an error such as a malformed
#       config/memory-gate. --override admits regardless, still recording the
#       reservation, for a spawn or relaunch the captain explicitly directed.
#       Without a readable /proc/meminfo the gate admits with a warning rather
#       than blocking every spawn.
#   fm-memory-watchdog.sh poll
#       One watcher-cycle call (bin/fm-watch.sh): make sure the loop runs while
#       this home has task records or deferred work, then print one
#       `memory-watchdog: ...` summary of events not yet surfaced, or nothing.
#   fm-memory-watchdog.sh ensure | loop | tick
#       ensure starts the detached singleton loop when it is needed and not
#       running; loop is that process; tick is one loop iteration (tests).
#
# Why a detached loop rather than only the watcher poll: the watcher closes on
# every actionable wake and is re-armed only when firstmate's handling turn
# ends, which can be minutes on a busy fleet, and a test suite or browser can
# climb from the close line to a frozen VM faster than one 15 s poll. The loop
# ticks every FM_MEMORY_WATCHDOG_POLL seconds (default 3), is started and kept
# alive by the watcher and by fm-spawn, holds a pid lock so only one runs per
# home, and exits by itself once the home has had no task records and no
# deferred work for FM_MEMORY_WATCHDOG_IDLE_EXIT seconds (default 60), so it
# is never an always-on daemon. The watcher stays the only path that wakes
# firstmate: the loop only records events.
#
# Each tick: sample memory, apply the gate's hysteresis when the gate lock is
# free right now (a held lock only postpones the gate update to the next tick,
# never the protection below), then
#   - job ceilings, at any memory level: stop every headless browser tree over
#     browser_ceiling_mb and every test-run or terraform job over
#     job_ceiling_mb (browser trees first, so a browser inside a test run is
#     stopped by itself), tell each worker through bin/fm-send.sh, and record
#     an event.
#   - critical line: when plain used >= critical and no stop happened in the
#     last FM_MEMORY_CRITICAL_COOLDOWN seconds (default 20, shared machine-wide),
#     stop the single largest heavy job under a recorded task worktree
#     (bin/fm-memory-lib.sh owns what counts), tell its worker through
#     bin/fm-send.sh what was stopped and why, and record an event. It never
#     signals a worker agent or anything outside a recorded task's process
#     tree. With nothing stoppable it records one event per critical episode.
#   - room: when deferred work exists and one more worker fits, record a room
#     event, repeating at most every FM_MEMORY_ROOM_RENOTIFY seconds (default
#     600) while the work stays deferred.
# Job sizes are the summed Pss that bin/fm-memory-lib.sh's header defines, and
# every worker notice and event names that figure as PSS.
#
# Records (bin/fm-memory-lib.sh's header owns which directory the shared ones
# live in): shared .memory-gate, .memory-reservations, .memory-gate.lock,
# .memory-critical-last; per home .memory-deferred, .memory-room-notified,
# .memory-critical-episode, memory-watchdog.events (appended and trimmed only
# under .memory-watchdog.events.lock), .memory-watchdog.cursor, and the
# .memory-watchdog.lock loop singleton.
#
# FM_MEMORY_SEND_CMD replaces bin/fm-send.sh for the worker notice (tests only).
# FM_MEMORY_WATCHDOG_DISABLE=1 turns admit, poll, ensure, loop, and tick into
# no-ops that admit, and status into a one-line notice; queue and flagship work;
# the behavior test library sets it so unrelated suites never gate or start a
# loop against the real machine's memory. config/memory-gate `enabled=off` is
# the operator's switch (docs/configuration.md "Memory gate").
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  '' | -h | --help)
    usage
    [ -n "${1:-}" ] || exit 2
    exit 0
    ;;
esac

# The test-library switch short-circuits before any sourcing or state access,
# so a disabled poll costs one process start.
if [ "${FM_MEMORY_WATCHDOG_DISABLE:-0}" = 1 ]; then
  case "$1" in
    admit | poll | ensure | loop | tick) exit 0 ;;
    status)
      echo "memory gate: disabled by FM_MEMORY_WATCHDOG_DISABLE=1 (every spawn is admitted)"
      exit 0
      ;;
  esac
fi

# shellcheck source=bin/fm-memory-lib.sh
. "$SCRIPT_DIR/fm-memory-lib.sh"

POLL=${FM_MEMORY_WATCHDOG_POLL:-3}
IDLE_EXIT=${FM_MEMORY_WATCHDOG_IDLE_EXIT:-60}
CRITICAL_COOLDOWN=${FM_MEMORY_CRITICAL_COOLDOWN:-20}
ROOM_RENOTIFY=${FM_MEMORY_ROOM_RENOTIFY:-600}
for v in POLL IDLE_EXIT CRITICAL_COOLDOWN ROOM_RENOTIFY; do
  case "${!v}" in '' | *[!0-9]* | 0) echo "error: FM_MEMORY_* tuning values must be positive whole numbers ($v='${!v}')" >&2; exit 1 ;; esac
done

now_epoch() {
  date +%s
}

SHARED=$(fm_memory_shared_state "$FM_HOME" "$STATE")
GATE_LOCK="$SHARED/.memory-gate.lock"

# Every gate read-modify-write is short; a bounded wait means a wedged holder
# or a vanished state directory can never hang a spawn or the loop.
gate_lock() {
  [ -d "$SHARED" ] || return 1
  fm_lock_acquire_wait_bounded "$GATE_LOCK" 10 >/dev/null 2>&1
}
LOOP_LOCK="$STATE/.memory-watchdog.lock"
EVENTS_LOCK="$STATE/.memory-watchdog.events.lock"

config_or_die() {
  if ! fm_memory_load_config "$CONFIG"; then
    echo "error: $FM_MEMORY_CONFIG_ERROR (docs/configuration.md \"Memory gate\")" >&2
    exit 1
  fi
}

gate_line() {  # after fm_memory_sample + fm_memory_gate_update
  local swap=
  if [ "$FM_SWAP_TOTAL_KB" -gt 0 ]; then
    swap=", swap $(fm_memory_gb $((FM_SWAP_TOTAL_KB - FM_SWAP_FREE_KB)))/$(fm_memory_gb "$FM_SWAP_TOTAL_KB") GB used"
    [ "$FM_MEM_SWAP_EXHAUSTED" = 0 ] || swap="$swap (nearly exhausted)"
  fi
  printf 'memory gate: %s - %s%% of %s GB RAM in use%s; %s just-started worker(s) reserved, counted %s%%\n' \
    "$FM_MEM_GATE" "$FM_MEM_USED_PCT" "$(fm_memory_gb "$FM_MEM_TOTAL_KB")" "$swap" \
    "$FM_MEM_RESERVED_N" "$FM_MEM_COUNTED_PCT"
}

# --- status ------------------------------------------------------------------

cmd_status() {
  local now flagship deferred pid
  now=$(now_epoch)
  config_or_die
  if [ "$FM_MEMORY_ENABLED" = 0 ]; then
    echo "memory gate: off (config/memory-gate enabled=off; every spawn is admitted, no critical stop)"
  elif fm_memory_sample "$SHARED" "$now"; then
    if gate_lock; then
      fm_memory_gate_update "$SHARED" "$now"
      fm_lock_release "$GATE_LOCK"
    else
      FM_MEM_GATE=$(fm_memory_gate_state "$SHARED")
    fi
    gate_line
    if fm_memory_room_for_one; then
      echo "room: yes - a new worker would be admitted now"
    else
      echo "room: no - a new worker would be deferred and started when memory frees"
    fi
  else
    echo "memory gate: unavailable - no readable $(fm_memory_proc_root)/meminfo on this platform, so spawns are admitted with a warning"
  fi
  printf 'lines: closes at %s%%, reopens below %s%%, critical stop at %s%%; each new worker reserves %s MB for %ss\n' \
    "$FM_MEMORY_CLOSE" "$FM_MEMORY_REOPEN" "$FM_MEMORY_CRITICAL" "$FM_MEMORY_RESERVE_MB" "$FM_MEMORY_RESERVE_SECS"
  printf 'job ceilings: one headless browser tree %s MB, one test or terraform job %s MB\n' \
    "$FM_MEMORY_BROWSER_CEILING_MB" "$FM_MEMORY_JOB_CEILING_MB"
  flagship=$(fm_memory_flagship "$CONFIG")
  printf 'flagship: %s\n' "${flagship:-none (set with bin/fm-memory-watchdog.sh flagship <project>)}"
  fm_memory_deferred_prune "$STATE" "$now"
  deferred=$(fm_memory_deferred_ids "$STATE")
  printf 'deferred work: %s\n' "${deferred:-none}"
  pid=$(cat "$LOOP_LOCK/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && fm_pid_alive "$pid"; then
    printf 'watchdog loop: running (pid %s, every %ss)\n' "$pid" "$POLL"
  else
    echo "watchdog loop: not running (started by the watcher or the next spawn while work exists)"
  fi
  if [ -s "$STATE/memory-watchdog.events" ]; then
    echo "recent events:"
    tail -n 5 "$STATE/memory-watchdog.events" | while IFS="$(printf '\t')" read -r epoch text; do
      printf '  %s  %s\n' "$(date -d "@$epoch" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$epoch" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$epoch")" "$text"
    done
  fi
}

# --- flagship ----------------------------------------------------------------

cmd_flagship() {
  local value=${1:-}
  if [ -z "$value" ]; then
    value=$(fm_memory_flagship "$CONFIG")
    printf '%s\n' "${value:-none}"
    return 0
  fi
  mkdir -p "$CONFIG" || return 1
  if [ "$value" = --clear ]; then
    rm -f "$CONFIG/flagship"
    echo "flagship: cleared"
    return 0
  fi
  case "$value" in
    -* | *[!A-Za-z0-9._-]*)
      echo "error: a flagship is one project name (letters, digits, dot, dash, underscore); got '$value'" >&2
      return 1
      ;;
  esac
  if [ ! -d "$FM_HOME/projects/$value" ]; then
    echo "warning: no clone at projects/$value in this home; the flagship matches the backlog's repo name, so check the spelling" >&2
  fi
  printf '%s\n' "$value" >"$CONFIG/flagship.tmp.$$" && mv -f "$CONFIG/flagship.tmp.$$" "$CONFIG/flagship"
  printf 'flagship: %s\n' "$value"
}

# --- queue -------------------------------------------------------------------

cmd_queue() {
  local ready flagship deferred gate_note=
  flagship=$(fm_memory_flagship "$CONFIG")
  if ! ready=$("$SCRIPT_DIR/fm-tasks-axi.sh" ready 2>&1); then
    printf 'error: could not read the backlog: %s\n' "$ready" >&2
    return 1
  fi
  fm_memory_deferred_prune "$STATE" "$(now_epoch)"
  deferred=$(fm_memory_deferred_ids "$STATE")
  if [ "${FM_MEMORY_WATCHDOG_DISABLE:-0}" != 1 ] && fm_memory_load_config "$CONFIG" && [ "$FM_MEMORY_ENABLED" = 1 ] &&
    fm_memory_sample "$SHARED" "$(now_epoch)"; then
    FM_MEM_GATE=$(fm_memory_gate_state "$SHARED")
    if fm_memory_room_for_one; then
      gate_note="memory gate open: room for another worker now"
    else
      gate_note="memory gate: no room right now; spawns will be deferred until memory frees"
    fi
  fi
  if [ -n "$flagship" ]; then
    printf 'dispatch order (flagship %s first, then the backlog'"'"'s request order)\n' "$flagship"
  else
    printf 'dispatch order (no flagship set, so the backlog'"'"'s request order)\n'
  fi
  [ -z "$gate_note" ] || printf '%s\n' "$gate_note"
  printf '%s\n' "$ready" | awk -v flagship="$flagship" -v deferred=" $deferred " '
    /^help\[/ { exit }
    /^ready\[/ { rows = 1; next }
    rows && /^[[:space:]]/ {
      line = $0; sub(/^[[:space:]]+/, "", line)
      n = split(line, f, ",")
      if (n < 4) next
      id = f[1]; kind = f[3]; repo = f[4]
      title = substr(line, length(f[1] f[2] f[3] f[4]) + 5)
      sub(/(\\n)?\.\.\. \(truncated.*$/, "...", title)
      gsub(/^"|"$/, "", title)
      tag = ""
      if (flagship != "" && repo == flagship) tag = " [flagship]"
      if (index(deferred, " " id " ")) tag = tag " [deferred]"
      row = sprintf("%s  (%s, %s)%s  %s", id, repo, kind, tag, title)
      if (flagship != "" && repo == flagship) first[++a] = row; else rest[++b] = row
      next
    }
    { rows = 0 }
    END {
      for (i = 1; i <= a; i++) printf "%d. %s\n", ++k, first[i]
      for (i = 1; i <= b; i++) printf "%d. %s\n", ++k, rest[i]
      if (k == 0) print "(no dispatchable queued work)"
    }
  '
}

# --- admission -----------------------------------------------------------------

cmd_admit() {
  local task=${1:-} override=0 kind=fresh now arg
  [ -n "$task" ] || {
    echo "error: admit needs a task id" >&2
    return 1
  }
  shift
  for arg in "$@"; do
    case "$arg" in
      --override) override=1 ;;
      --relaunch) kind=relaunch ;;
      *)
        echo "error: unknown admit option '$arg'" >&2
        return 1
        ;;
    esac
  done
  config_or_die
  [ "$FM_MEMORY_ENABLED" = 1 ] || return 0
  now=$(now_epoch)
  if ! gate_lock; then
    echo "error: the memory gate's lock at $GATE_LOCK could not be taken within 10s" >&2
    return 1
  fi
  fm_memory_prune_reservations "$SHARED" "$now"
  if ! fm_memory_sample "$SHARED" "$now"; then
    fm_lock_release "$GATE_LOCK"
    echo "warning: memory gate unavailable (no readable $(fm_memory_proc_root)/meminfo); admitting $task without a memory check" >&2
    return 0
  fi
  fm_memory_gate_update "$SHARED" "$now"
  if [ "$override" = 1 ] || fm_memory_room_for_one; then
    printf '%s\t%s\n' "$now" "$task" >>"$SHARED/.memory-reservations"
    fm_lock_release "$GATE_LOCK"
    fm_memory_deferred_remove "$STATE" "$task"
    if [ "$override" = 1 ] && ! fm_memory_room_for_one; then
      printf 'memory gate: admitting %s by explicit override although %s%% is counted (closes at %s%%)\n' \
        "$task" "$FM_MEM_COUNTED_PCT" "$FM_MEMORY_CLOSE" >&2
    fi
    return 0
  fi
  fm_lock_release "$GATE_LOCK"
  fm_memory_deferred_add "$STATE" "$task" "$now" "$kind"
  # Deferred work needs the loop to notice room freeing, even in an empty fleet.
  cmd_ensure >/dev/null 2>&1 || true
  if [ "$FM_MEM_GATE" = closed ]; then
    printf 'deferred: %s stays queued - the memory gate is closed (%s%% of RAM in use, %s just-started worker(s) reserved, counted %s%%; it closed at %s%% and reopens below %s%%). The memory watchdog notifies firstmate when room frees; bin/fm-memory-watchdog.sh status shows the gate. Pass --memory-override only for a spawn the captain explicitly directed.\n' \
      "$task" "$FM_MEM_USED_PCT" "$FM_MEM_RESERVED_N" "$FM_MEM_COUNTED_PCT" "$FM_MEMORY_CLOSE" "$FM_MEMORY_REOPEN" >&2
  else
    printf 'deferred: %s stays queued - one more worker would take counted memory from %s%% to %s%%, past the %s%% close line (%s just-started worker(s) are still reserved). The memory watchdog notifies firstmate when room frees; bin/fm-memory-watchdog.sh status shows the gate. Pass --memory-override only for a spawn the captain explicitly directed.\n' \
      "$task" "$FM_MEM_COUNTED_PCT" "$((FM_MEM_COUNTED_PCT + FM_MEM_RESERVE_PCT))" "$FM_MEMORY_CLOSE" "$FM_MEM_RESERVED_N" >&2
  fi
  return "$FM_MEMORY_DEFERRED_EXIT"
}

# --- the loop ----------------------------------------------------------------

describe_job() {  # <root-pid>: a short human label from the job's own argv
  local label
  fm_memory_argv "$1" || {
    printf 'process %s' "$1"
    return 0
  }
  label=${FM_MEM_A0##*/}
  [ -z "$FM_MEM_A1" ] || label="$label ${FM_MEM_A1##*/}"
  [ -z "$FM_MEM_A2" ] || label="$label ${FM_MEM_A2##*/}"
  printf '%s' "$label" | cut -c1-80
}

notify_worker() {  # <task> <label> <now> <message>
  FM_HOME="$FM_HOME" "${FM_MEMORY_SEND_CMD:-$SCRIPT_DIR/fm-send.sh}" "$1" "$4" </dev/null >/dev/null 2>&1 ||
    fm_memory_event "$STATE" "$3" "could not deliver the job-stop notice to $1's worker - tell it that '$2' was stopped for memory"
}

# ceiling_check <now> <jobs-file>: stop every job over its ceiling (header),
# browser trees first so a ballooning browser inside a test run is stopped by
# itself rather than taking the whole run with it. Sets CEILING_STOPPED=1.
ceiling_check() {
  local now=$1 jobs=$2 row rss task root class top btop members limit_mb label gb cgb msg pass stopped=' ' pid overlap
  CEILING_STOPPED=0
  for pass in browser runner; do
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      IFS=$'\t' read -r rss task root class top btop members <<EOF_ROW
$row
EOF_ROW
      if [ "$pass" = browser ]; then
        [ "$class" = browser ] && [ "$btop" = 1 ] || continue
        limit_mb=$FM_MEMORY_BROWSER_CEILING_MB
      else
        [ "$class" = runner ] && [ "$top" = 1 ] || continue
        limit_mb=$FM_MEMORY_JOB_CEILING_MB
      fi
      [ "$rss" -gt $((limit_mb * 1024)) ] || continue
      overlap=0
      for pid in $members; do
        case "$stopped" in *" $pid "*) overlap=1 ;; esac
      done
      [ "$overlap" = 0 ] || continue
      fm_memory_subtree_has_agent "$members" && continue
      label=$(describe_job "$root")
      gb=$(fm_memory_gb "$rss")
      cgb=$(fm_memory_gb $((limit_mb * 1024)))
      fm_memory_stop_job "$members"
      stopped="$stopped$members "
      CEILING_STOPPED=1
      if [ "$pass" = browser ]; then
        msg="Memory watchdog: your headless browser grew to about $gb GB PSS ('$label', process $root and its children, shared pages split between them), past the $cgb GB ceiling for one browser, so I stopped it before it could freeze the machine. Nothing else of yours was touched. Keep one headless browser at a time, close it between screenshots, and use a small viewport (for example 1280x800), then carry on."
        fm_memory_event "$STATE" "$now" "job ceiling: stopped $task's headless browser '$label' at about $gb GB PSS (ceiling $cgb GB) and told its worker"
      else
        msg="Memory watchdog: your job '$label' (process $root and its children) grew to about $gb GB PSS (shared pages split between its processes), past the $cgb GB ceiling for one test or terraform job, so I stopped it before it could freeze the machine. Nothing else of yours was touched. Re-run it smaller - fewer workers (for example --maxWorkers=2) or a narrower selection - and report through your status line if it cannot run smaller."
        fm_memory_event "$STATE" "$now" "job ceiling: stopped $task's job '$label' at about $gb GB PSS (ceiling $cgb GB) and told its worker"
      fi
      notify_worker "$task" "$label" "$now" "$msg"
    done <"$jobs"
  done
}

critical_stop() {  # <now> <jobs-file>
  local now=$1 jobs=$2 last row rss task root class top btop members label gb msg chosen=
  last=$(cat "$SHARED/.memory-critical-last" 2>/dev/null || echo 0)
  case "$last" in '' | *[!0-9]*) last=0 ;; esac
  [ $((now - last)) -ge "$CRITICAL_COOLDOWN" ] || return 0
  # Largest whole job first; the first whose subtree holds no worker agent is it.
  while IFS= read -r row; do
    IFS=$'\t' read -r rss task root class top btop members <<EOF_ROW
$row
EOF_ROW
    [ "$top" = 1 ] || continue
    fm_memory_subtree_has_agent "$members" && continue
    chosen=$row
    break
  done <"$jobs"
  if [ -z "$chosen" ]; then
    if [ ! -e "$STATE/.memory-critical-episode" ]; then
      printf '%s\n' "$now" >"$STATE/.memory-critical-episode"
      fm_memory_event "$STATE" "$now" "critical line: memory reached ${FM_MEM_USED_PCT}% (critical ${FM_MEMORY_CRITICAL}%) but no test suite, browser, or terraform job under a task's local copy could be stopped - memory is held by something else (worker agents or processes outside firstmate's tasks)"
    fi
    return 0
  fi
  IFS=$'\t' read -r rss task root class top btop members <<EOF_JOB
$chosen
EOF_JOB
  label=$(describe_job "$root")
  gb=$(fm_memory_gb "$rss")
  printf '%s\n' "$now" >"$SHARED/.memory-critical-last"
  fm_memory_stop_job "$members"
  msg="Memory watchdog: this machine reached ${FM_MEM_USED_PCT}% memory in use, past the ${FM_MEMORY_CRITICAL}% critical line, so I stopped your heaviest job to keep the machine from freezing: '$label' (process $root and its children, about $gb GB PSS). Nothing else of yours was touched. Do not immediately re-run it at full size: re-run it with less parallelism (fewer test or browser workers) or once memory has freed, and report through your status line if it cannot wait."
  notify_worker "$task" "$label" "$now" "$msg"
  fm_memory_event "$STATE" "$now" "critical line: memory reached ${FM_MEM_USED_PCT}% (critical ${FM_MEMORY_CRITICAL}%), so the watchdog stopped $task's heaviest job '$label' (about $gb GB PSS) and told its worker"
}

room_check() {  # <now>
  local now=$1 deferred last
  fm_memory_deferred_prune "$STATE" "$now"
  deferred=$(fm_memory_deferred_ids "$STATE")
  [ -n "$deferred" ] || return 0
  fm_memory_room_for_one || return 0
  last=$(cat "$STATE/.memory-room-notified" 2>/dev/null || echo 0)
  case "$last" in '' | *[!0-9]*) last=0 ;; esac
  [ $((now - last)) -ge "$ROOM_RENOTIFY" ] || return 0
  printf '%s\n' "$now" >"$STATE/.memory-room-notified"
  fm_memory_event "$STATE" "$now" "room for queued work: memory gate open at ${FM_MEM_COUNTED_PCT}% counted (closes at ${FM_MEMORY_CLOSE}%), deferred: $deferred - dispatch in bin/fm-memory-watchdog.sh queue order and relaunch each <id>(relaunch) with bin/fm-control.sh <id> relaunch, until one is deferred again"
}

cmd_tick() {
  local now jobs
  if ! fm_memory_load_config "$CONFIG"; then
    # Keep protecting on the defaults, and say once per bad config why.
    if [ ! -e "$STATE/.memory-config-error" ]; then
      : >"$STATE/.memory-config-error"
      fm_memory_event "$STATE" "$(now_epoch)" "$FM_MEMORY_CONFIG_ERROR - the watchdog is running on its defaults until it is fixed"
    fi
  else
    rm -f "$STATE/.memory-config-error"
  fi
  [ "$FM_MEMORY_ENABLED" = 1 ] || return 0
  now=$(now_epoch)
  fm_memory_sample "$SHARED" "$now" || return 0
  FM_MEM_GATE=$(fm_memory_gate_state "$SHARED")
  if [ -d "$SHARED" ] && fm_lock_try_acquire "$GATE_LOCK" >/dev/null 2>&1; then
    fm_memory_prune_reservations "$SHARED" "$now"
    ! fm_memory_sample "$SHARED" "$now" || fm_memory_gate_update "$SHARED" "$now"
    fm_lock_release "$GATE_LOCK"
  fi
  jobs=$(mktemp "${TMPDIR:-/tmp}/fm-memory-jobs.XXXXXX") || jobs=
  if [ -n "$jobs" ]; then
    fm_memory_heavy_jobs "$STATE" "$jobs" || : >"$jobs"
    ceiling_check "$now" "$jobs"
  fi
  if [ "$FM_MEM_USED_PCT" -ge "$FM_MEMORY_CRITICAL" ]; then
    # A ceiling stop this tick may already have freed enough; the next tick
    # re-reads memory before the critical line picks another job.
    if [ -n "$jobs" ] && [ "${CEILING_STOPPED:-0}" = 0 ]; then
      critical_stop "$now" "$jobs"
    fi
  else
    rm -f "$STATE/.memory-critical-episode"
  fi
  [ -z "$jobs" ] || rm -f "$jobs"
  room_check "$now"
}

home_needs_watchdog() {
  local meta
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && return 0
  done
  [ -s "$STATE/.memory-deferred" ]
}

state_identity() {
  # shellcheck disable=SC2012 # ls -di is the portable inode read of our own path.
  ls -di "$STATE" 2>/dev/null | awk '{ print $1 }'
}

cmd_loop() {
  local idle=0 identity
  fm_lock_try_acquire "$LOOP_LOCK" || return 0
  trap 'fm_lock_release "$LOOP_LOCK"' EXIT
  trap 'exit 0' TERM INT HUP
  identity=$(state_identity)
  while :; do
    # A home whose state directory is gone has nothing left to protect. The
    # identity check also catches a directory recreated under the same path
    # (the shared lock helpers create missing parents), which is not this home.
    [ -n "$identity" ] && [ "$(state_identity)" = "$identity" ] || break
    cmd_tick || true
    [ "${FM_MEMORY_ENABLED:-1}" = 1 ] || break
    if home_needs_watchdog; then
      idle=0
    else
      idle=$((idle + POLL))
      [ "$idle" -lt "$IDLE_EXIT" ] || break
    fi
    sleep "$POLL"
  done
}

cmd_ensure() {
  local pid
  fm_memory_load_config "$CONFIG" || true
  [ "$FM_MEMORY_ENABLED" = 1 ] || return 0
  [ -r "$(fm_memory_proc_root)/meminfo" ] || return 0
  home_needs_watchdog || return 0
  pid=$(cat "$LOOP_LOCK/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && fm_pid_alive "$pid"; then
    return 0
  fi
  if command -v setsid >/dev/null 2>&1; then
    setsid "$SCRIPT_DIR/fm-memory-watchdog.sh" loop </dev/null >/dev/null 2>&1 &
  else
    nohup "$SCRIPT_DIR/fm-memory-watchdog.sh" loop </dev/null >/dev/null 2>&1 &
  fi
  return 0
}

cmd_poll() {
  local rc=0
  cmd_ensure
  [ -f "$STATE/memory-watchdog.events" ] || return 0
  fm_lock_acquire_wait_bounded "$EVENTS_LOCK" 5 >/dev/null 2>&1 || return 0
  poll_locked || rc=$?
  fm_lock_release "$EVENTS_LOCK"
  return "$rc"
}

poll_locked() {  # the events lock is held
  local events="$STATE/memory-watchdog.events" cursor size text
  cursor=$(cat "$STATE/.memory-watchdog.cursor" 2>/dev/null || echo 0)
  case "$cursor" in '' | *[!0-9]*) cursor=0 ;; esac
  size=$(wc -c <"$events" | tr -d '[:space:]')
  [ "$cursor" -le "$size" ] || cursor=0
  [ "$cursor" -lt "$size" ] || return 0
  text=$(tail -c +"$((cursor + 1))" "$events" | head -c "$((size - cursor))" |
    awk -F '\t' 'NF >= 2 { printf "%s%s", sep, $2; sep = "; " }')
  if [ "$size" -gt 65536 ]; then
    # Everything is surfaced, so keep only a short tail for status.
    tail -n 20 "$events" >"$events.tmp.$$" && mv -f "$events.tmp.$$" "$events"
    rm -f "$events.tmp.$$"
    size=$(wc -c <"$events" | tr -d '[:space:]')
  fi
  printf '%s\n' "$size" >"$STATE/.memory-watchdog.cursor"
  [ -n "$text" ] || return 0
  printf 'memory-watchdog: %s\n' "$text"
}

cmd=$1
shift
case "$cmd" in
  status) cmd_status ;;
  queue) cmd_queue ;;
  flagship) cmd_flagship "$@" ;;
  admit) cmd_admit "$@" ;;
  poll) cmd_poll ;;
  ensure) cmd_ensure ;;
  loop) cmd_loop ;;
  tick) cmd_tick ;;
  *)
    echo "error: unknown subcommand '$cmd' (see --help)" >&2
    exit 2
    ;;
esac
