#!/usr/bin/env bash
# fm-memory-watchdog.sh - the one watchdog that owns worker admission against
# the memory, processor, and connection gates, the critical-line heavy-job
# stop, the processor and connection throttle, the sample history, and the
# flagship-first dispatch order. Its name predates the processor and
# connection gates.
#
# Usage:
#   fm-memory-watchdog.sh status
#       Human-readable gate state: memory used, reservations, the processor
#       and connection readings and gates, every gate's lines, the job
#       ceilings, any throttle, the flagship, deferred work, whether the
#       watchdog loop is running, the history's extent, and recent events.
#   fm-memory-watchdog.sh history [--since <time>] [--until <time>]
#       Explain a window of the sample history in plain words: memory,
#       processor, and connection ranges and peaks, when each gate held new
#       work back, the busiest worker, throttles, gaps, watchdog actions,
#       and a timeline. A time is epoch seconds or anything `date -d` reads
#       (17:00, "2026-10-02 17:00", "20 minutes ago"); a bare HH:MM later
#       than now means yesterday. The default window is the last 30 minutes.
#   fm-memory-watchdog.sh queue
#       This home's dispatchable queued work (bin/fm-tasks-axi.sh ready) in
#       dispatch order: the flagship project's items first, then everything
#       else, each group in the backlog's own request order.
#   fm-memory-watchdog.sh flagship [<project> | --clear]
#       Print, set, or clear config/flagship.
#   fm-memory-watchdog.sh admit <task-id> [--relaunch] [--override]
#       Admission for one ship or scout worker, called by bin/fm-spawn.sh for a
#       fresh spawn and by bin/fm-control.sh (or a direct fm-spawn --relaunch)
#       for a relaunch, which --relaunch marks. Admission needs room in the
#       memory gate and the processor and connection gates open. Exit 0
#       admits and records a reservation; exit 75 defers (the task is
#       recorded as deferred and the loop reports when room frees); exit 1 is
#       an error such as a malformed config/memory-gate. --override admits
#       regardless, still recording the reservation, for a spawn or relaunch
#       the captain explicitly directed.
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
# Each tick: sample memory, the processor, and the connection, apply every
# gate's hysteresis when the gate lock is free right now (a held lock only
# postpones the gate update to the next tick, never the protection below),
# start the next background latency probe when one is due, then
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
#   - analysis sample: every FM_WATCHDOG_SAMPLE seconds (default 15),
#     attribute processor and connection use to each recorded task's tree,
#     measure the interface rates, and append one history line
#     (bin/fm-load-lib.sh's header owns the attribution and the line).
#   - throttle (throttle_step): once the processor or the connection stays
#     critical for critical_secs, throttle the task of this home using the
#     most of it, never anything outside a recorded task's tree and never a
#     worker agent's own process: lower the processor hog's priority first,
#     then pause its commands FM_WATCHDOG_PAUSE_SECS (default 10) and run
#     them FM_WATCHDOG_RUN_SECS (default 10) in turns while still critical,
#     and release once the reading falls under the close line; tell the
#     worker through bin/fm-send.sh and record an event at each step. With
#     nothing of this home's using enough of it, record one event per
#     episode. Every exit of the loop, and every poll that finds a pause
#     overdue by 30 s, continues paused commands, so a dead loop never leaves
#     them stopped.
#   - room: when deferred work exists, one more worker fits, and the
#     processor and connection gates are open, record a room event,
#     repeating at most every FM_MEMORY_ROOM_RENOTIFY seconds (default 600)
#     while the work stays deferred.
# Job sizes are the summed Pss that bin/fm-memory-lib.sh's header defines, and
# every worker notice and event names that figure as PSS.
#
# Records (bin/fm-memory-lib.sh's header owns which directory the shared ones
# live in): shared .memory-gate, .memory-reservations, .memory-gate.lock,
# .memory-critical-last; per home .memory-deferred, .memory-room-notified,
# .memory-critical-episode, memory-watchdog.events (appended and trimmed only
# under .memory-watchdog.events.lock), .memory-watchdog.cursor, and the
# .memory-watchdog.lock loop singleton. Processor and connection records
# (same split): shared .cpu-gate, .net-gate, .net-latency, .net-probe-last,
# .net-probe.out; per home watchdog-history and watchdog-history.1,
# .watchdog-sample-last, .watchdog-top, .watchdog-cputicks,
# .watchdog-sockets, .watchdog-netdev, .watchdog-throttle-<cpu|net>
# ("task<TAB>stage<TAB>until<TAB>since<TAB>root pids<TAB>stopped pid:start
# words"), .watchdog-<cpu|net>-critical-since, and .watchdog-<cpu|net>-quiet.
#
# FM_MEMORY_SEND_CMD replaces bin/fm-send.sh for the worker notice (tests only).
# FM_WATCHDOG_PROBE_EVERY, FM_WATCHDOG_NET_GATE_STALE, FM_WATCHDOG_PING_CMD, and
# FM_WATCHDOG_SS_CMD are bin/fm-load-lib.sh's (its header).
# FM_MEMORY_WATCHDOG_DISABLE=1 turns admit, poll, ensure, loop, and tick into
# no-ops that admit, and status into a one-line notice; queue, flagship, and
# history work;
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

# shellcheck source=bin/fm-load-lib.sh
. "$SCRIPT_DIR/fm-load-lib.sh"

POLL=${FM_MEMORY_WATCHDOG_POLL:-3}
IDLE_EXIT=${FM_MEMORY_WATCHDOG_IDLE_EXIT:-60}
CRITICAL_COOLDOWN=${FM_MEMORY_CRITICAL_COOLDOWN:-20}
ROOM_RENOTIFY=${FM_MEMORY_ROOM_RENOTIFY:-600}
SAMPLE_EVERY=${FM_WATCHDOG_SAMPLE:-15}
PAUSE_SECS=${FM_WATCHDOG_PAUSE_SECS:-10}
RUN_SECS=${FM_WATCHDOG_RUN_SECS:-10}
NET_GATE_STALE=${FM_WATCHDOG_NET_GATE_STALE:-120}
for v in POLL IDLE_EXIT CRITICAL_COOLDOWN ROOM_RENOTIFY SAMPLE_EVERY PAUSE_SECS RUN_SECS NET_GATE_STALE; do
  case "${!v}" in '' | *[!0-9]* | 0) echo "error: FM_MEMORY_* and FM_WATCHDOG_* tuning values must be positive whole numbers ($v='${!v}')" >&2; exit 1 ;; esac
done
# Throttle candidates must use at least this much: half a core, or 32 KB/s.
CPU_MIN_CENTICORES=50
NET_MIN_KBS=32

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

# --- processor and connection --------------------------------------------------

# load_sample <now>: fresh processor and connection levels (bin/fm-load-lib.sh),
# "off" for a resource its config key switched off.
load_sample() {
  local now=$1
  FM_CPU_PSI='' FM_CPU_PSI_PCT='' FM_CPU_LOAD='' FM_CPU_LOAD_PCT=''
  FM_NET_RTT='' FM_NET_BASE='' FM_NET_OVER=''
  FM_CPU_CORES=$(fm_load_nproc)
  FM_CPU_LEVEL=off
  FM_NET_LEVEL=off
  [ "$FM_CPU_ENABLED" = 0 ] || fm_load_cpu_sample
  if [ "$FM_NET_ENABLED" = 1 ]; then
    fm_load_latency_harvest "$SHARED" "$now"
    fm_load_latency_read "$SHARED" "$now"
  fi
}

level_for_gate() {  # <level>: a switched-off resource never closes its gate
  case "$1" in off) printf 'unknown\n' ;; *) printf '%s\n' "$1" ;; esac
}

cpu_desc() {  # the processor reading in words
  if [ -n "$FM_CPU_PSI" ]; then
    printf 'pressure %s%%, load %s on %s cores (%s%%)' "$FM_CPU_PSI" "${FM_CPU_LOAD:-unknown}" "$FM_CPU_CORES" "${FM_CPU_LOAD_PCT:-?}"
  elif [ -n "$FM_CPU_LOAD" ]; then
    printf 'load %s on %s cores (%s%%; no pressure reading on this kernel)' "$FM_CPU_LOAD" "$FM_CPU_CORES" "$FM_CPU_LOAD_PCT"
  else
    printf 'no processor reading on this platform'
  fi
}

net_desc() {  # the connection reading in words
  if [ -n "$FM_NET_RTT" ] && [ -n "$FM_NET_BASE" ]; then
    printf 'latency to %s %s ms against a normal %s ms' "$FM_LATENCY_HOST" "$FM_NET_RTT" "$FM_NET_BASE"
  elif [ -n "$FM_NET_RTT" ]; then
    printf 'latency to %s %s ms, normal latency not learned yet' "$FM_LATENCY_HOST" "$FM_NET_RTT"
  else
    printf 'no recent latency reading from %s' "$FM_LATENCY_HOST"
  fi
}

# load_gates_locked <now>: update both gates from load_sample (the gate lock
# is held).
load_gates_locked() {
  FM_CPU_GATE=$(fm_load_gate_update "$SHARED" cpu "$1" "$(level_for_gate "$FM_CPU_LEVEL")")
  FM_NET_GATE=$(fm_load_gate_update "$SHARED" net "$1" "$(level_for_gate "$FM_NET_LEVEL")")
}

room_for_one() {  # memory room and both load gates open
  fm_memory_room_for_one && [ "$FM_CPU_GATE" = open ] && [ "$FM_NET_GATE" = open ]
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
    load_sample "$now"
    if gate_lock; then
      load_gates_locked "$now"
      fm_lock_release "$GATE_LOCK"
    else
      FM_CPU_GATE=$(fm_load_gate_state "$SHARED" cpu)
      FM_NET_GATE=$(fm_load_gate_state "$SHARED" net "$now" "$NET_GATE_STALE")
    fi
    status_load_lines
    if room_for_one; then
      echo "room: yes - a new worker would be admitted now"
    elif ! fm_memory_room_for_one; then
      echo "room: no - a new worker would be deferred and started when memory frees"
    elif [ "$FM_CPU_GATE" != open ]; then
      echo "room: no - a new worker would be deferred and started when the processor calms down"
    else
      echo "room: no - a new worker would be deferred and started when the connection calms down"
    fi
  else
    echo "memory gate: unavailable - no readable $(fm_memory_proc_root)/meminfo on this platform, so spawns are admitted with a warning"
  fi
  printf 'lines: closes at %s%%, reopens below %s%%, critical stop at %s%%; each new worker reserves %s MB for %ss\n' \
    "$FM_MEMORY_CLOSE" "$FM_MEMORY_REOPEN" "$FM_MEMORY_CRITICAL" "$FM_MEMORY_RESERVE_MB" "$FM_MEMORY_RESERVE_SECS"
  printf 'job ceilings: one headless browser tree %s MB, one test or terraform job %s MB\n' \
    "$FM_MEMORY_BROWSER_CEILING_MB" "$FM_MEMORY_JOB_CEILING_MB"
  printf 'processor lines: closes at pressure %s%% or load %s%% of cores, reopens below %s%% and %s%%, throttles after %ss at %s%% or %s%%\n' \
    "$FM_CPU_CLOSE" "$FM_LOAD_CLOSE" "$FM_CPU_REOPEN" "$FM_LOAD_REOPEN" "$FM_CRITICAL_SECS" "$FM_CPU_CRITICAL" "$FM_LOAD_CRITICAL"
  printf 'connection lines: closes at %s ms above normal latency, reopens below %s ms above, throttles after %ss at %s ms above\n' \
    "$FM_LATENCY_CLOSE_MS" "$FM_LATENCY_REOPEN_MS" "$FM_CRITICAL_SECS" "$FM_LATENCY_CRITICAL_MS"
  status_throttle_lines
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
  status_history_line "$now"
  if [ -s "$STATE/memory-watchdog.events" ]; then
    echo "recent events:"
    tail -n 5 "$STATE/memory-watchdog.events" | while IFS="$(printf '\t')" read -r epoch text; do
      printf '  %s  %s\n' "$(date -d "@$epoch" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$epoch" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$epoch")" "$text"
    done
  fi
}

status_load_lines() {  # after load_sample and the gate update
  local rates=
  if [ "$FM_CPU_ENABLED" = 0 ]; then
    echo "processor gate: off (config/memory-gate processor=off)"
  else
    printf 'processor gate: %s - %s\n' "$FM_CPU_GATE" "$(cpu_desc)"
  fi
  rates=$(last_rates)
  if [ "$FM_NET_ENABLED" = 0 ]; then
    echo "connection gate: off (config/memory-gate connection=off)${rates:+; $rates}"
  else
    printf 'connection gate: %s - %s%s\n' "$FM_NET_GATE" "$(net_desc)" "${rates:+; $rates}"
  fi
}

last_rates() {  # the newest history sample's interface rates, when recent
  local line epoch up down
  line=$(tail -n 1 "$STATE/watchdog-history" 2>/dev/null) || return 0
  epoch=${line%%$'\t'*}
  case "$epoch" in '' | *[!0-9]*) return 0 ;; esac
  [ $(($(now_epoch) - epoch)) -le $((SAMPLE_EVERY * 4)) ] || return 0
  up=$(printf '%s\n' "$line" | tr '\t' '\n' | sed -n 's/^up=//p')
  down=$(printf '%s\n' "$line" | tr '\t' '\n' | sed -n 's/^down=//p')
  [ -n "$up" ] && [ "$up" != - ] || return 0
  printf 'upload %s KB/s, download %s KB/s' "$up" "$down"
}

status_throttle_lines() {
  local res rec task stage until since _r _s any=0 what
  for res in cpu net; do
    rec="$STATE/.watchdog-throttle-$res"
    [ -f "$rec" ] || continue
    IFS=$'\t' read -r task stage until since _r _s <"$rec" || continue
    any=1
    what=processor
    [ "$res" = cpu ] || what=connection
    case "$stage" in
      reniced) printf 'throttled: %s'"'"'s work runs at lower priority for the %s since %s\n' "$task" "$what" "$(clock "$since")" ;;
      *) printf 'throttled: %s'"'"'s commands are being paused in turns for the %s since %s\n' "$task" "$what" "$(clock "$since")" ;;
    esac
  done
  [ "$any" = 1 ] || echo "throttled: nothing"
}

status_history_line() {  # <now>
  local first n
  n=$(cat "$STATE/watchdog-history.1" "$STATE/watchdog-history" 2>/dev/null | wc -l | tr -d '[:space:]')
  if [ "${n:-0}" -eq 0 ]; then
    echo "history: no samples yet (the loop writes one every ${SAMPLE_EVERY}s while it runs)"
    return 0
  fi
  first=$(cat "$STATE/watchdog-history.1" "$STATE/watchdog-history" 2>/dev/null | head -n 1)
  first=${first%%$'\t'*}
  printf 'history: %s samples since %s (bin/fm-memory-watchdog.sh history --since HH:MM --until HH:MM explains a window)\n' \
    "$n" "$(clock "$first" full)"
}

clock() {  # <epoch> [full]: local HH:MM, or a date and time with full
  local fmt='+%H:%M'
  [ "${2:-}" != full ] || fmt='+%Y-%m-%d %H:%M'
  date -d "@$1" "$fmt" 2>/dev/null || date -r "$1" "$fmt" 2>/dev/null || printf '%s' "$1"
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

# --- history -------------------------------------------------------------------

# parse_when <text> <now>: an epoch for a history bound - plain epoch seconds,
# or anything `date -d` reads; a bare HH:MM later than now means yesterday.
parse_when() {
  local text=$1 now=$2 epoch
  case "$text" in
    '' | *[!0-9]*) ;;
    ?????????*)
      printf '%s\n' "$text"
      return 0
      ;;
  esac
  epoch=$(date -d "$text" +%s 2>/dev/null) || return 1
  case "$text" in
    [0-9]:[0-9][0-9] | [0-9][0-9]:[0-9][0-9]) [ "$epoch" -le "$now" ] || epoch=$((epoch - 86400)) ;;
  esac
  printf '%s\n' "$epoch"
}

cmd_history() {
  local since='' until='' now from to offset label file files=()
  now=$(now_epoch)
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --since | --until)
        [ "$#" -ge 2 ] || {
          echo "error: $1 needs a time, for example 17:00" >&2
          return 2
        }
        if [ "$1" = --since ]; then since=$2; else until=$2; fi
        shift 2
        ;;
      *)
        echo "error: unknown history option '$1' (use --since <time> and --until <time>)" >&2
        return 2
        ;;
    esac
  done
  if [ -n "$since" ]; then
    from=$(parse_when "$since" "$now") || {
      echo "error: could not read --since '$since' as a time" >&2
      return 2
    }
  else
    from=$((now - 1800))
  fi
  if [ -n "$until" ]; then
    to=$(parse_when "$until" "$now") || {
      echo "error: could not read --until '$until' as a time" >&2
      return 2
    }
  else
    to=$now
  fi
  if [ "$to" -le "$from" ]; then
    echo "error: --until must be later than --since" >&2
    return 2
  fi
  offset=$(date -d "@$from" +%z 2>/dev/null || date -r "$from" +%z 2>/dev/null || echo +0000)
  case "$offset" in
    [+-][0-9][0-9][0-9][0-9]) ;;
    *) offset=+0000 ;;
  esac
  label="$(date -d "@$from" '+%a %-d %b %H:%M' 2>/dev/null || clock "$from" full) to $(clock "$to")"
  for file in "$STATE/watchdog-history.1" "$STATE/watchdog-history"; do
    [ -f "$file" ] && files+=("$file")
  done
  [ -f "$STATE/memory-watchdog.events" ] && files+=("$STATE/memory-watchdog.events")
  if [ "${#files[@]}" -eq 0 ]; then
    printf 'Watchdog history, %s: no samples recorded yet. The watchdog writes one every %ss while this home has workers or deferred work.\n' "$label" "$SAMPLE_EVERY"
    return 0
  fi
  awk -F '\t' -v from="$from" -v to="$to" -v label="$label" -v every="$SAMPLE_EVERY" \
    -v off="$(((${offset:1:2} * 3600 + ${offset:3:2} * 60) * (${offset:0:1}1)))" '
    function hm(t,   l) { l = (t + off) % 86400; if (l < 0) l += 86400; return sprintf("%02d:%02d", int(l / 3600), int((l % 3600) / 60)) }
    function num(v) { return v != "" && v != "-" }
    function range(a, b) { return hm(a) "-" hm(b) }
    function addspan(key, t, on,   r) {
      # Track intervals during which a condition holds, per key.
      if (on) {
        if (!(key in open_at)) { open_at[key] = t; if (!(key in keyseen)) { keyseen[key] = 1; keys[++nk] = key } }
        last_on[key] = t
      } else if (key in open_at) {
        spans[key] = spans[key] (spans[key] == "" ? "" : ", ") range(open_at[key], t)
        delete open_at[key]
      }
    }
    function closespans(   k, i) {
      for (i = 1; i <= nk; i++) { k = keys[i]; if (k in open_at) { spans[k] = spans[k] (spans[k] == "" ? "" : ", ") hm(open_at[k]) " onward" ; delete open_at[k] } }
    }
    # Event lines have exactly two fields; samples always carry more.
    NF == 2 && $1 ~ /^[0-9]+$/ { if ($1 >= from && $1 <= to) ev[++ne] = hm($1) "  " $2; next }
    $1 !~ /^[0-9]+$/ || $1 < from || $1 > to { next }
    {
      t = $1; delete v
      for (i = 2; i <= NF; i++) { k = $i; sub(/=.*/, "", k); val = $i; sub(/^[^=]*=/, "", val); v[k] = val }
      n++; ts[n] = t
      if (num(v["mem"])) { m = v["mem"] + 0; msum += m; mn++; if (mn == 1 || m < mmin) mmin = m; if (mn == 1 || m > mmax) mmax = m; bm[n] = m }
      if (num(v["psi"])) { p = v["psi"] + 0; psum += p; pn++; if (pn == 1 || p > pmax) { pmax = p; pmaxt = t }; bp[n] = p }
      if (num(v["load"])) { l = v["load"] + 0; lsum += l; ln++; if (ln == 1 || l > lmax) { lmax = l; lmaxt = t }; bl[n] = l }
      if (num(v["cores"])) cores = v["cores"] + 0
      if (num(v["up"])) { u = v["up"] + 0; usum += u; un++; if (un == 1 || u > umax) { umax = u; umaxt = t }; bu[n] = u }
      if (num(v["down"])) { d = v["down"] + 0; dsum += d; dn++; if (dn == 1 || d > dmax) { dmax = d; dmaxt = t }; bd[n] = d }
      if (num(v["rtt"])) { r = v["rtt"] + 0; rsum += r; rn++; if (rn == 1 || r > rmax) { rmax = r; rmaxt = t }; br[n] = r }
      if (num(v["base"])) { bases[++bn] = v["base"] + 0 }
      g = v["gates"]
      addspan("mem gate", t, g ~ /mem:closed/)
      addspan("processor gate", t, g ~ /cpu:closed/)
      addspan("connection gate", t, g ~ /net:closed/)
      split(v["throttle"], th, ",")
      delete thnow
      for (i in th) if (th[i] != "" && th[i] != "-") { split(th[i], tf, ":"); thnow[(tf[1] == "cpu" ? "processor" : "connection") " throttle on " tf[2]] = 1 }
      for (i = 1; i <= nk; i++) if (keys[i] ~ / throttle on /) addspan(keys[i], t, keys[i] in thnow)
      for (k in thnow) addspan(k, t, 1)
      if (num(v["topcpu"])) { split(v["topcpu"], tc, ":"); ccount[tc[1]]++; cn++; if (tc[2] + 0 > cpeak[tc[1]] + 0) cpeak[tc[1]] = tc[2] + 0; btc[n] = tc[1] }
      if (num(v["topnet"])) { split(v["topnet"], tn, ":"); ncount[tn[1]]++; nn++; if (tn[2] + 0 > npeak[tn[1]] + 0) npeak[tn[1]] = tn[2] + 0 }
    }
    function best(cnt,   k, b) { b = ""; for (k in cnt) if (b == "" || cnt[k] > cnt[b]) b = k; return b }
    function sortn(a, c,   i, j, x) { for (i = 2; i <= c; i++) { x = a[i]; for (j = i - 1; j >= 1 && a[j] > x; j--) a[j + 1] = a[j]; a[j + 1] = x } }
    END {
      if (n == 0) {
        printf "Watchdog history, %s: no samples in this window. The watchdog writes one every %ss only while this home has workers or deferred work, so it was not running then.\n", label, every
        if (ne > 0) { print "Watchdog actions:"; for (i = 1; i <= ne; i++) print "  " ev[i] }
        exit
      }
      closespans()
      for (i = 2; i <= n; i++) gaps[i - 1] = ts[i] - ts[i - 1]
      step = every
      if (n > 1) { for (i = 1; i < n; i++) gs[i] = gaps[i]; sortn(gs, n - 1); step = gs[int(n / 2)] }
      if (step < 1) step = every
      printf "Watchdog history, %s (%d samples, about one every %ds):\n", label, n, step
      if (mn) printf "Memory: %d%% to %d%% in use, %d%% on average%s.\n", mmin, mmax, msum / mn + 0.5, ("mem gate" in spans) ? "; the memory gate was closed " spans["mem gate"] : "; the memory gate stayed open"
      line = "Processor" (cores ? " (" cores " cores)" : "") ":"
      if (pn) line = line sprintf(" pressure averaged %d%%, peaking at %d%% at %s;", psum / pn + 0.5, pmax + 0.5, hm(pmaxt))
      if (ln) line = line sprintf(" load averaged %.2f, peaking at %.2f%s at %s.", lsum / ln, lmax, cores ? sprintf(" (%d%% of the cores)", lmax * 100 / cores) : "", hm(lmaxt))
      if (!pn && !ln) line = line " not measured."
      line = line (("processor gate" in spans) ? " New work was held back " spans["processor gate"] "." : " New work was never held back for it.")
      print line
      line = "Connection:"
      if (un) line = line sprintf(" upload averaged %d KB/s, peaking at %d KB/s at %s;", usum / un + 0.5, umax, hm(umaxt))
      if (dn) line = line sprintf(" download averaged %d KB/s, peaking at %d KB/s at %s.", dsum / dn + 0.5, dmax, hm(dmaxt))
      if (rn) {
        base = ""
        if (bn) { sortn(bases, bn); base = bases[int((bn + 1) / 2)] }
        line = line sprintf(" Latency averaged %d ms%s, peaking at %d ms at %s.", rsum / rn + 0.5, base != "" ? " against a normal " base " ms" : "", rmax, hm(rmaxt))
      }
      if (!un && !dn && !rn) line = line " not measured."
      line = line (("connection gate" in spans) ? " New work was held back " spans["connection gate"] "." : " New work was never held back for it.")
      print line
      if (cn || nn) {
        line = "Busiest worker:"
        b = best(ccount)
        if (b != "") line = line sprintf(" %s used the most processor in %d%% of the samples that measured it (up to %.1f cores)", b, ccount[b] * 100 / cn + 0.5, cpeak[b])
        b2 = best(ncount)
        if (b2 != "" && b2 == b) line = line sprintf(" and carried the most traffic in %d%% (up to %d KB/s)", ncount[b2] * 100 / nn + 0.5, npeak[b2])
        else if (b2 != "") line = line sprintf("%s %s carried the most traffic in %d%% (up to %d KB/s)", b != "" ? ";" : "", b2, ncount[b2] * 100 / nn + 0.5, npeak[b2])
        print line "."
      } else {
        print "Busiest worker: no worker of this home used a measurable share of the processor or connection."
      }
      for (i = 1; i <= nk; i++) if (keys[i] ~ / throttle on /) {
        split(keys[i], kp, " throttle on ")
        printf "Throttle: %s was throttled for the %s %s.\n", kp[2], kp[1], spans[keys[i]]
      }
      gapline = ""
      limit = (3 * step > 60 ? 3 * step : 60)
      if (ts[1] - from > limit) gapline = "before " hm(ts[1])
      for (i = 1; i < n; i++) if (gaps[i] > limit) gapline = gapline (gapline == "" ? "" : ", ") range(ts[i], ts[i + 1])
      if (to - ts[n] > limit) gapline = gapline (gapline == "" ? "" : ", ") "after " hm(ts[n])
      if (gapline != "") print "Gaps: no samples " gapline " - the watchdog was not running then (it runs only while this home has workers or deferred work)."
      if (ne > 0) { print "Watchdog actions:"; for (i = 1; i <= ne; i++) print "  " ev[i] }
      span = to - from
      split("60 120 300 600 900 1800 3600 7200 10800 21600 43200 86400", steps, " ")
      for (i = 1; i <= 12; i++) { bucket = steps[i] + 0; if (span / bucket <= 12) break }
      printf "Timeline (%s steps):\n", bucket >= 3600 ? bucket / 3600 " hour" : bucket / 60 " minute"
      for (i = 1; i <= n; i++) {
        b = int((ts[i] + off) / bucket) * bucket - off
        if (!(b in bseen)) { bseen[b] = 1; border[++nb] = b }
        if (i in bm) { sm[b] += bm[i]; cm[b]++ }
        if (i in bp) { sp[b] += bp[i]; cp[b]++ }
        if (i in bl) { sl[b] += bl[i]; cl[b]++ }
        if (i in bu) { su[b] += bu[i]; cu[b]++ }
        if (i in bd) { sd[b] += bd[i]; cd[b]++ }
        if (i in br) { sr[b] += br[i]; cr[b]++ }
        if (i in btc) { tcnt[b, btc[i]]++; if (tcnt[b, btc[i]] > tbest[b]) { tbest[b] = tcnt[b, btc[i]]; tname[b] = btc[i] } }
      }
      for (j = 1; j <= nb; j++) {
        b = border[j]
        line = "  " hm(b)
        line = line (cm[b] ? sprintf("  memory %d%%", sm[b] / cm[b] + 0.5) : "")
        line = line (cp[b] ? sprintf("  pressure %d%%", sp[b] / cp[b] + 0.5) : "")
        line = line (cl[b] ? sprintf("  load %.1f", sl[b] / cl[b]) : "")
        line = line (cu[b] ? sprintf("  up %d KB/s", su[b] / cu[b] + 0.5) : "")
        line = line (cd[b] ? sprintf("  down %d KB/s", sd[b] / cd[b] + 0.5) : "")
        line = line (cr[b] ? sprintf("  latency %d ms", sr[b] / cr[b] + 0.5) : "")
        line = line (tname[b] != "" ? "  busiest " tname[b] : "")
        print line
      }
    }
  ' "${files[@]}"
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
  load_sample "$now"
  FM_CPU_GATE=$(fm_load_gate_update "$SHARED" cpu "$now" "$(level_for_gate "$FM_CPU_LEVEL")")
  FM_NET_GATE=open
  [ "$FM_NET_ENABLED" = 0 ] || FM_NET_GATE=$(fm_load_gate_state "$SHARED" net "$now" "$NET_GATE_STALE")
  if [ "$override" = 1 ] || room_for_one; then
    printf '%s\t%s\n' "$now" "$task" >>"$SHARED/.memory-reservations"
    fm_lock_release "$GATE_LOCK"
    fm_memory_deferred_remove "$STATE" "$task"
    if [ "$override" = 1 ] && ! fm_memory_room_for_one; then
      printf 'memory gate: admitting %s by explicit override although %s%% is counted (closes at %s%%)\n' \
        "$task" "$FM_MEM_COUNTED_PCT" "$FM_MEMORY_CLOSE" >&2
    elif [ "$override" = 1 ] && [ "$FM_CPU_GATE" != open ]; then
      printf 'processor gate: admitting %s by explicit override although it is closed (%s)\n' "$task" "$(cpu_desc)" >&2
    elif [ "$override" = 1 ] && [ "$FM_NET_GATE" != open ]; then
      printf 'connection gate: admitting %s by explicit override although it is closed (%s)\n' "$task" "$(net_desc)" >&2
    fi
    return 0
  fi
  fm_lock_release "$GATE_LOCK"
  fm_memory_deferred_add "$STATE" "$task" "$now" "$kind"
  # Deferred work needs the loop to notice room freeing, even in an empty fleet.
  cmd_ensure >/dev/null 2>&1 || true
  if fm_memory_room_for_one && [ "$FM_CPU_GATE" != open ]; then
    printf 'deferred: %s stays queued - the processor gate is closed (%s; it closes at pressure %s%% or load %s%% of cores and reopens below %s%% and %s%%). The watchdog notifies firstmate when room frees; bin/fm-memory-watchdog.sh status shows the gates. Pass --memory-override only for a spawn the captain explicitly directed.\n' \
      "$task" "$(cpu_desc)" "$FM_CPU_CLOSE" "$FM_LOAD_CLOSE" "$FM_CPU_REOPEN" "$FM_LOAD_REOPEN" >&2
  elif fm_memory_room_for_one; then
    printf 'deferred: %s stays queued - the connection gate is closed (%s; it closes at %s ms above normal and reopens below %s ms above). The watchdog notifies firstmate when room frees; bin/fm-memory-watchdog.sh status shows the gates. Pass --memory-override only for a spawn the captain explicitly directed.\n' \
      "$task" "$(net_desc)" "$FM_LATENCY_CLOSE_MS" "$FM_LATENCY_REOPEN_MS" >&2
  elif [ "$FM_MEM_GATE" = closed ]; then
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

notify_worker() {  # <task> <what-to-tell-it> <now> <message>
  FM_HOME="$FM_HOME" "${FM_MEMORY_SEND_CMD:-$SCRIPT_DIR/fm-send.sh}" "$1" "$4" </dev/null >/dev/null 2>&1 ||
    fm_memory_event "$STATE" "$3" "could not deliver the watchdog's notice to $1's worker - tell it $2"
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
      notify_worker "$task" "that '$label' was stopped for memory" "$now" "$msg"
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
  notify_worker "$task" "that '$label' was stopped for memory" "$now" "$msg"
  fm_memory_event "$STATE" "$now" "critical line: memory reached ${FM_MEM_USED_PCT}% (critical ${FM_MEMORY_CRITICAL}%), so the watchdog stopped $task's heaviest job '$label' (about $gb GB PSS) and told its worker"
}

room_check() {  # <now>
  local now=$1 deferred last
  fm_memory_deferred_prune "$STATE" "$now"
  deferred=$(fm_memory_deferred_ids "$STATE")
  [ -n "$deferred" ] || return 0
  room_for_one || return 0
  last=$(cat "$STATE/.memory-room-notified" 2>/dev/null || echo 0)
  case "$last" in '' | *[!0-9]*) last=0 ;; esac
  [ $((now - last)) -ge "$ROOM_RENOTIFY" ] || return 0
  printf '%s\n' "$now" >"$STATE/.memory-room-notified"
  fm_memory_event "$STATE" "$now" "room for queued work: memory gate open at ${FM_MEM_COUNTED_PCT}% counted (closes at ${FM_MEMORY_CLOSE}%) and the processor and connection gates open, deferred: $deferred - dispatch in bin/fm-memory-watchdog.sh queue order and relaunch each <id>(relaunch) with bin/fm-control.sh <id> relaunch, until one is deferred again"
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
  load_sample "$now"
  FM_CPU_GATE=$(fm_load_gate_state "$SHARED" cpu)
  FM_NET_GATE=$(fm_load_gate_state "$SHARED" net)
  if [ -d "$SHARED" ] && fm_lock_try_acquire "$GATE_LOCK" >/dev/null 2>&1; then
    fm_memory_prune_reservations "$SHARED" "$now"
    ! fm_memory_sample "$SHARED" "$now" || fm_memory_gate_update "$SHARED" "$now"
    load_gates_locked "$now"
    fm_lock_release "$GATE_LOCK"
  fi
  [ "$FM_NET_ENABLED" = 0 ] || fm_load_latency_probe "$SHARED" "$now" "$FM_LATENCY_HOST"
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
  analysis_sample "$now"
  throttle_step cpu "$now" "$FM_CPU_LEVEL"
  throttle_step net "$now" "$FM_NET_LEVEL"
  room_check "$now"
}

# --- analysis samples and the throttle ------------------------------------------

# analysis_sample <now>: every SAMPLE_EVERY seconds, attribute processor and
# connection use to task trees (.watchdog-top: "task<TAB>centicores<TAB>KB/s
# <TAB>root pids"), measure the interface rates, and append one history line.
analysis_sample() {
  local now=$1 last trees cpu net top thr='' res rec task stage _u _s _r _p topcpu=- topnet=-
  last=$(cat "$STATE/.watchdog-sample-last" 2>/dev/null || echo 0)
  case "$last" in '' | *[!0-9]*) last=0 ;; esac
  [ $((now - last)) -ge "$SAMPLE_EVERY" ] || return 0
  printf '%s\n' "$now" >"$STATE/.watchdog-sample-last"
  trees=$(mktemp "${TMPDIR:-/tmp}/fm-load-trees.XXXXXX") || return 0
  cpu="$trees.cpu"
  net="$trees.net"
  top="$STATE/.watchdog-top"
  fm_load_task_trees "$STATE" "$trees" || : >"$trees"
  fm_load_task_cpu "$STATE" "$trees" "$now" >"$cpu" || : >"$cpu"
  fm_load_task_net "$STATE" "$trees" "$now" >"$net" || : >"$net"
  awk -F '\t' -v cpuf="$cpu" -v netf="$net" '
    BEGIN {
      while ((getline l < cpuf) > 0) { split(l, f, "\t"); c[f[1]] = f[2] }
      while ((getline l < netf) > 0) { split(l, f, "\t"); n[f[1]] = f[2] }
    }
    !(($1 SUBSEP $6) in seen) && $2 == $6 { seen[$1, $6] = 1; roots[$1] = roots[$1] (roots[$1] == "" ? "" : " ") $6 }
    END { for (t in roots) printf "%s\t%d\t%d\t%s\n", t, c[t] + 0, n[t] + 0, roots[t] }
  ' "$trees" >"$top.tmp.$$" && mv -f "$top.tmp.$$" "$top"
  rm -f "$top.tmp.$$" "$trees" "$cpu" "$net"
  topcpu=$(sort -t "$(printf '\t')" -k2,2nr "$top" 2>/dev/null | awk -F '\t' 'NR == 1 && $2 > 0 { printf "%s:%.2f", $1, $2 / 100 }')
  topnet=$(sort -t "$(printf '\t')" -k3,3nr "$top" 2>/dev/null | awk -F '\t' 'NR == 1 && $3 > 0 { printf "%s:%d", $1, $3 }')
  fm_load_net_rates "$STATE" "$now"
  for res in cpu net; do
    rec="$STATE/.watchdog-throttle-$res"
    [ -f "$rec" ] || continue
    IFS=$'\t' read -r task stage _u _s _r _p <"$rec" || continue
    thr="${thr:+$thr,}$res:$task:$stage"
  done
  fm_load_history_append "$STATE" "$(printf '%s\tmem=%s\tpsi=%s\tload=%s\tcores=%s\tup=%s\tdown=%s\trtt=%s\tbase=%s\tgates=mem:%s,cpu:%s,net:%s\ttopcpu=%s\ttopnet=%s\tthrottle=%s' \
    "$now" "$FM_MEM_USED_PCT" "${FM_CPU_PSI:--}" "${FM_CPU_LOAD:--}" "$FM_CPU_CORES" "${FM_NET_UP_KBS:--}" "${FM_NET_DOWN_KBS:--}" \
    "${FM_NET_RTT:--}" "${FM_NET_BASE:--}" "$FM_MEM_GATE" "$FM_CPU_GATE" "$FM_NET_GATE" "${topcpu:--}" "${topnet:--}" "${thr:--}")"
}

# throttle_pick <cpu|net> <now>: print "task<TAB>use<TAB>roots" for the task
# using the most of the resource in a fresh analysis sample, when it uses at
# least the candidate minimum.
throttle_pick() {
  local col=2 min=$CPU_MIN_CENTICORES top="$STATE/.watchdog-top" last
  [ "$1" = cpu ] || {
    col=3
    min=$NET_MIN_KBS
  }
  [ -s "$top" ] || return 0
  last=$(cat "$STATE/.watchdog-sample-last" 2>/dev/null || echo 0)
  case "$last" in '' | *[!0-9]*) return 0 ;; esac
  [ $(($2 - last)) -le $((SAMPLE_EVERY * 3)) ] || return 0
  sort -t "$(printf '\t')" -k"$col","$col"nr "$top" | awk -F '\t' -v col="$col" -v min="$min" \
    'NR == 1 && $col >= min && $4 != "" { print $1 "\t" $col "\t" $4 }'
}

throttle_write() {  # <res> <task> <stage> <until> <since> <roots> <stopped>
  local rec="$STATE/.watchdog-throttle-$1"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "$6" "$7" >"$rec.tmp.$$" && mv -f "$rec.tmp.$$" "$rec"
  rm -f "$rec.tmp.$$" 2>/dev/null || true
}

throttle_reading() {  # <res>: the resource's current reading in words
  if [ "$1" = cpu ]; then cpu_desc; else net_desc; fi
}

# throttle_step <cpu|net> <now> <level>: the throttle's state machine. After
# the resource stays critical for critical_secs, the heaviest task (by
# processor or by connection use) is throttled: for the processor its whole
# tree first drops to a lower priority, then, if still critical after
# another critical_secs, its non-agent processes are paused for PAUSE_SECS
# and run for RUN_SECS in turns; the connection goes straight to pausing,
# because priority does not slow traffic. At each window end, critical
# pauses again, high keeps waiting, and anything lower releases. The worker
# and firstmate hear about each start, escalation, and release.
throttle_step() {
  local res=$1 now=$2 level=$3 rec="$STATE/.watchdog-throttle-$1" since_f="$STATE/.watchdog-$1-critical-since"
  local task stage until since roots stopped pick use what reading msg
  what=processor
  [ "$res" = cpu ] || what=connection
  if [ "$level" = critical ]; then
    [ -f "$since_f" ] || printf '%s\n' "$now" >"$since_f"
  else
    rm -f "$since_f" "$STATE/.watchdog-$res-quiet"
  fi
  if [ -f "$rec" ]; then
    IFS=$'\t' read -r task stage until since roots stopped <"$rec" || {
      rm -f "$rec"
      return 0
    }
    case "$until" in '' | *[!0-9]*) until=0 ;; esac
    if [ ! -e "$STATE/$task.meta" ]; then
      fm_load_resume "$stopped"
      rm -f "$rec"
      return 0
    fi
    reading=$(throttle_reading "$res")
    case "$stage" in
      paused)
        if [ "$now" -ge "$until" ]; then
          fm_load_resume "$stopped"
          throttle_write "$res" "$task" running $((now + RUN_SECS)) "$since" "$roots" ""
        else
          # Commands started since the pause began are paused too.
          stopped=$(fm_load_stop_tree "$roots" "$stopped")
          throttle_write "$res" "$task" paused "$until" "$since" "$roots" "$stopped"
        fi
        ;;
      *)
        [ "$now" -ge "$until" ] || return 0
        case "$level" in
          critical)
            stopped=$(fm_load_stop_tree "$roots" "")
            throttle_write "$res" "$task" paused $((now + PAUSE_SECS)) "$since" "$roots" "$stopped"
            if [ "$stage" = reniced ]; then
              notify_worker "$task" "that its commands are now being paused in turns for the processor" "$now" "Watchdog: the processor is still overloaded ($reading) even at lower priority, so I am now pausing your running commands for ${PAUSE_SECS} seconds at a time, with ${RUN_SECS} seconds of running in between, until it recovers. Your agent itself is not paused and nothing is killed; a paused command just finishes later. Cut parallelism now - fewer subagents, fewer parallel commands and downloads, capped test workers - and the pausing stops sooner."
              fm_memory_event "$STATE" "$now" "processor critical: still overloaded ($reading), so the watchdog is now pausing $task's commands in turns and told its worker"
            fi
            ;;
          high) throttle_write "$res" "$task" "$stage" $((now + RUN_SECS)) "$since" "$roots" "" ;;
          *)
            rm -f "$rec"
            if [ "$stage" = reniced ]; then
              msg="Watchdog: the processor has recovered ($reading). Your work stays at the lower priority it was given, which only matters when the machine is busy; keep parallelism moderate."
            else
              msg="Watchdog: the $what has recovered ($reading), so I stopped pausing your commands. Carry on, but keep parallelism moderate so it does not overload again."
            fi
            notify_worker "$task" "that the $what throttle has ended" "$now" "$msg"
            fm_memory_event "$STATE" "$now" "$what recovered: the watchdog stopped throttling $task ($reading)"
            ;;
        esac
        ;;
    esac
    return 0
  fi
  [ "$level" = critical ] || return 0
  since=$(cat "$since_f" 2>/dev/null || echo "$now")
  case "$since" in '' | *[!0-9]*) since=$now ;; esac
  [ $((now - since)) -ge "$FM_CRITICAL_SECS" ] || return 0
  reading=$(throttle_reading "$res")
  pick=$(throttle_pick "$res" "$now")
  if [ -z "$pick" ]; then
    if [ ! -e "$STATE/.watchdog-$res-quiet" ]; then
      : >"$STATE/.watchdog-$res-quiet"
      fm_memory_event "$STATE" "$now" "$what critical: overloaded for ${FM_CRITICAL_SECS}s ($reading) but no worker of this home is using enough of it to throttle - the load comes from somewhere else (firstmate itself, another home, or the owner's own programs)"
    fi
    return 0
  fi
  IFS=$'\t' read -r task use roots <<EOF_PICK
$pick
EOF_PICK
  if [ "$res" = cpu ]; then
    use=$(awk -v c="$use" 'BEGIN { printf "%.1f", c / 100 }')
    fm_load_renice_tree "$roots"
    throttle_write cpu "$task" reniced $((now + FM_CRITICAL_SECS)) "$now" "$roots" ""
    notify_worker "$task" "that its work now runs at lower priority for the processor" "$now" "Watchdog: this machine's processor has been overloaded for ${FM_CRITICAL_SECS} seconds ($reading), and your work is using the most of it (about $use cores). That makes the owner's own programs lag, so I lowered the priority of your agent and its commands. If it stays overloaded I will start pausing your running commands in short turns - nothing is killed. Cut parallelism now: fewer subagents, fewer parallel commands and downloads, capped test workers."
    fm_memory_event "$STATE" "$now" "processor critical: overloaded for ${FM_CRITICAL_SECS}s ($reading), so the watchdog lowered the priority of $task's work (about $use cores) and told its worker"
  else
    stopped=$(fm_load_stop_tree "$roots" "")
    throttle_write net "$task" paused $((now + PAUSE_SECS)) "$now" "$roots" "$stopped"
    notify_worker "$task" "that its commands are being paused in turns for the connection" "$now" "Watchdog: the internet connection has been overloaded for ${FM_CRITICAL_SECS} seconds ($reading), and your work carries the most traffic (about $use KB/s). That makes the owner's games and browsing lag, so I am pausing your running commands for ${PAUSE_SECS} seconds at a time, with ${RUN_SECS} seconds of running in between, until it recovers. Your agent itself is not paused and nothing is killed. Run fewer downloads and subagents at once, and the pausing stops sooner."
    fm_memory_event "$STATE" "$now" "connection critical: overloaded for ${FM_CRITICAL_SECS}s ($reading), so the watchdog is pausing $task's commands in turns (about $use KB/s) and told its worker"
  fi
}

# resume_paused [<grace-secs>]: continue every paused throttle record of this
# home whose pause ended more than <grace-secs> ago (all of them without a
# grace), so a loop that died mid-pause never leaves commands stopped.
resume_paused() {
  local grace=${1:-} res rec task stage until since roots stopped now
  now=$(now_epoch)
  for res in cpu net; do
    rec="$STATE/.watchdog-throttle-$res"
    [ -f "$rec" ] || continue
    IFS=$'\t' read -r task stage until since roots stopped <"$rec" || continue
    [ "$stage" = paused ] || continue
    case "$until" in '' | *[!0-9]*) until=0 ;; esac
    [ -z "$grace" ] || [ $((now - until)) -gt "$grace" ] || continue
    fm_load_resume "$stopped"
    throttle_write "$res" "$task" running "$now" "$since" "$roots" ""
  done
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
  trap 'resume_paused; fm_lock_release "$LOOP_LOCK"' EXIT
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
  resume_paused 30
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
  history) cmd_history "$@" ;;
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
