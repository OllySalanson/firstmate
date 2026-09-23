#!/usr/bin/env bash
# fm-memory-lib.sh - the memory gate's shared mechanics, sourced by
# bin/fm-memory-watchdog.sh (the command surface) and nothing else.
#
# docs/configuration.md "Memory gate" owns the operator contract: what the
# gate, the critical line, and the flagship mean, and the config/ files that
# tune them. This header owns the mechanics.
#
# Reading memory. The only source is <proc>/meminfo, where <proc> is
# FM_MEMORY_PROC_ROOT (default /proc; tests point it at a fake tree), read for
# MemTotal, MemAvailable, SwapTotal, and SwapFree. "Used" is RAM the kernel
# cannot hand out without swapping, MemTotal - MemAvailable, as a whole-number
# percentage of MemTotal. A platform without a readable meminfo
# (macOS) is "unavailable": the gate admits with a warning instead of blocking
# every spawn, and the watchdog loop does nothing.
#
# Counted memory. Just-admitted workers have not shown their memory yet, so
# each admission within reserve_secs adds reserve_mb to "used" as a
# reservation. counted = used + reservations. The reservation ledger, the
# hysteresis state, and the critical-stop cooldown live in the LOCAL ROOT
# home's state directory (bin/fm-wake-lib.sh's fm_firstmate_root_home), so
# every home on this machine shares one gate; FM_STATE_OVERRIDE pins them to
# that override instead, which is what tests use.
#
# The gate (hysteresis). An open gate closes when counted >= close, or when
# swap is nearly exhausted (SwapFree under 10% of a non-zero SwapTotal). A
# closed gate reopens only when counted < reopen and swap is not exhausted.
# Between the two lines the gate keeps its previous state. An admission also
# needs room for itself: counted + one reservation must stay under close.
#
# The critical line compares plain used (no reservations) with critical,
# because it acts on memory that is really in use. The job ceilings apply at
# any memory level: one browser tree above browser_ceiling_mb, or one test-run
# or terraform job above job_ceiling_mb, is ballooning.
#
# Heavy jobs (fm_memory_heavy_jobs). A heavy job is a process whose own argv
# names a test runner (vitest, jest, playwright, mocha, `node --test`), a
# browser (chrome, chromium, headless_shell, msedge), or terraform, whose
# working directory is inside a recorded ship or scout task worktree, and
# whose parent is not itself heavy (so a job is its topmost heavy process).
# Its size is the proportional set size (Pss, from <proc>/<pid>/smaps_rollup)
# summed over its whole process subtree, browser renderers included, so pages
# a multi-process browser or test pool shares (the binary, libraries, shmem)
# are split between its processes rather than counted once per process. A
# member whose smaps_rollup is unreadable counts its VmRSS instead. Ship and
# scout workers each drive their own chrome-devtools-axi session
# (bin/fm-spawn.sh exports CHROME_DEVTOOLS_AXI_SESSION=fm-<task-id>), so a
# worker's browser runs from its own worktree and is attributed to it alone.
# Only argv[0] and the first two arguments are read, so a worker
# agent whose brief merely mentions "vitest" is never mistaken for a job, and
# a subtree that contains any worker-agent process is skipped outright.
# Nothing outside a recorded worktree's process tree is ever a candidate.
# shellcheck disable=SC2034 # FM_MEM*/FM_MEMORY_* output globals are read by the sourcing caller.
set -u

FM_MEMORY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_MEMORY_LIB_DIR/fm-wake-lib.sh"

FM_MEMORY_DEFERRED_EXIT=75

# --- configuration ---------------------------------------------------------

# fm_memory_load_config <config-dir>
# Sets FM_MEMORY_ENABLED (1/0), FM_MEMORY_CLOSE, FM_MEMORY_REOPEN,
# FM_MEMORY_CRITICAL, FM_MEMORY_RESERVE_MB, FM_MEMORY_RESERVE_SECS,
# FM_MEMORY_BROWSER_CEILING_MB, FM_MEMORY_JOB_CEILING_MB.
# Returns 1 with FM_MEMORY_CONFIG_ERROR set for a malformed config/memory-gate;
# the defaults stay loaded so a caller that must keep protecting can use them.
fm_memory_load_config() {
  local dir=$1 file line key value
  FM_MEMORY_ENABLED=1
  FM_MEMORY_CLOSE=85
  FM_MEMORY_REOPEN=70
  FM_MEMORY_CRITICAL=95
  FM_MEMORY_RESERVE_MB=1024
  FM_MEMORY_RESERVE_SECS=180
  FM_MEMORY_BROWSER_CEILING_MB=1536
  FM_MEMORY_JOB_CEILING_MB=3072
  FM_MEMORY_CONFIG_ERROR=
  file="$dir/memory-gate"
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    FM_MEMORY_CONFIG_ERROR="config/memory-gate must be a readable regular file"
    return 1
  fi
  local close=$FM_MEMORY_CLOSE reopen=$FM_MEMORY_REOPEN critical=$FM_MEMORY_CRITICAL
  local reserve_mb=$FM_MEMORY_RESERVE_MB reserve_secs=$FM_MEMORY_RESERVE_SECS enabled=1
  local browser_ceiling_mb=$FM_MEMORY_BROWSER_CEILING_MB job_ceiling_mb=$FM_MEMORY_JOB_CEILING_MB
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=$(printf '%s' "$line" | tr -d '[:space:]')
    [ -n "$line" ] || continue
    case "$line" in
      *=*) key=${line%%=*} value=${line#*=} ;;
      *)
        FM_MEMORY_CONFIG_ERROR="config/memory-gate line '$line' is not key=value"
        return 1
        ;;
    esac
    case "$key" in
      enabled)
        case "$value" in
          on) enabled=1 ;;
          off) enabled=0 ;;
          *)
            FM_MEMORY_CONFIG_ERROR="config/memory-gate enabled must be on or off (got '$value')"
            return 1
            ;;
        esac
        continue
        ;;
      close | reopen | critical | reserve_mb | reserve_secs | browser_ceiling_mb | job_ceiling_mb) ;;
      *)
        FM_MEMORY_CONFIG_ERROR="config/memory-gate has unknown key '$key' (known: enabled, close, reopen, critical, reserve_mb, reserve_secs, browser_ceiling_mb, job_ceiling_mb)"
        return 1
        ;;
    esac
    case "$value" in
      '' | *[!0-9]* | 0*)
        FM_MEMORY_CONFIG_ERROR="config/memory-gate $key must be a positive whole number (got '$value')"
        return 1
        ;;
    esac
    case "$key" in
      close) close=$value ;;
      reopen) reopen=$value ;;
      critical) critical=$value ;;
      reserve_mb) reserve_mb=$value ;;
      reserve_secs) reserve_secs=$value ;;
      browser_ceiling_mb) browser_ceiling_mb=$value ;;
      job_ceiling_mb) job_ceiling_mb=$value ;;
    esac
  done <"$file"
  if [ "$reopen" -ge "$close" ] || [ "$close" -ge "$critical" ] || [ "$critical" -gt 100 ]; then
    FM_MEMORY_CONFIG_ERROR="config/memory-gate needs reopen < close < critical <= 100 (got reopen=$reopen close=$close critical=$critical)"
    return 1
  fi
  FM_MEMORY_ENABLED=$enabled
  FM_MEMORY_CLOSE=$close
  FM_MEMORY_REOPEN=$reopen
  FM_MEMORY_CRITICAL=$critical
  FM_MEMORY_RESERVE_MB=$reserve_mb
  FM_MEMORY_RESERVE_SECS=$reserve_secs
  FM_MEMORY_BROWSER_CEILING_MB=$browser_ceiling_mb
  FM_MEMORY_JOB_CEILING_MB=$job_ceiling_mb
  return 0
}

# fm_memory_flagship <config-dir>: print the configured flagship project, or
# nothing when none is set.
fm_memory_flagship() {
  local file="$1/flagship" value=
  [ -f "$file" ] && [ -r "$file" ] || return 0
  value=$(tr -d '[:space:]' <"$file" 2>/dev/null || true)
  printf '%s' "$value"
}

# fm_memory_shared_state <home> <state-dir>: the directory holding the
# machine-shared gate records (header).
fm_memory_shared_state() {
  local home=$1 state=$2 root
  if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
    printf '%s\n' "$state"
    return 0
  fi
  root=$(fm_firstmate_root_home "$home" 2>/dev/null) || root=
  if [ -n "$root" ] && [ -d "$root/state" ]; then
    printf '%s\n' "$root/state"
  else
    printf '%s\n' "$state"
  fi
}

# --- sampling --------------------------------------------------------------

fm_memory_proc_root() {
  printf '%s\n' "${FM_MEMORY_PROC_ROOT:-/proc}"
}

# fm_memory_read_meminfo: set FM_MEM_TOTAL_KB, FM_MEM_AVAIL_KB,
# FM_SWAP_TOTAL_KB, FM_SWAP_FREE_KB. Returns 1 when meminfo is unavailable.
fm_memory_read_meminfo() {
  local file key value rest
  file="$(fm_memory_proc_root)/meminfo"
  FM_MEM_TOTAL_KB=
  FM_MEM_AVAIL_KB=
  FM_SWAP_TOTAL_KB=0
  FM_SWAP_FREE_KB=0
  [ -r "$file" ] || return 1
  while read -r key value _; do
    case "$key" in
      MemTotal:) FM_MEM_TOTAL_KB=$value ;;
      MemAvailable:) FM_MEM_AVAIL_KB=$value ;;
      SwapTotal:) FM_SWAP_TOTAL_KB=$value ;;
      SwapFree:) FM_SWAP_FREE_KB=$value ;;
    esac
  done <"$file"
  case "$FM_MEM_TOTAL_KB$FM_MEM_AVAIL_KB" in '' | *[!0-9]*) return 1 ;; esac
  [ "$FM_MEM_TOTAL_KB" -gt 0 ] || return 1
  case "$FM_SWAP_TOTAL_KB$FM_SWAP_FREE_KB" in '' | *[!0-9]*) FM_SWAP_TOTAL_KB=0 FM_SWAP_FREE_KB=0 ;; esac
  return 0
}

# fm_memory_prune_reservations <shared-state> <now>: drop expired lines.
# Caller holds the gate lock.
fm_memory_prune_reservations() {
  local ledger="$1/.memory-reservations" now=$2 tmp
  [ -f "$ledger" ] || return 0
  tmp="$ledger.tmp.$$"
  awk -F '\t' -v now="$now" -v win="$FM_MEMORY_RESERVE_SECS" \
    '$1 ~ /^[0-9]+$/ && now - $1 < win { print }' "$ledger" >"$tmp" 2>/dev/null &&
    mv -f "$tmp" "$ledger"
  rm -f "$tmp" 2>/dev/null || true
}

# fm_memory_reservation_count <shared-state> <now>
fm_memory_reservation_count() {
  local ledger="$1/.memory-reservations" now=$2
  [ -f "$ledger" ] || {
    printf '0\n'
    return 0
  }
  awk -F '\t' -v now="$now" -v win="$FM_MEMORY_RESERVE_SECS" \
    '$1 ~ /^[0-9]+$/ && now - $1 < win { n++ } END { print n + 0 }' "$ledger"
}

# fm_memory_sample <shared-state> <now>: read meminfo and reservations, set
# FM_MEM_USED_PCT, FM_MEM_RESERVED_N, FM_MEM_RESERVE_PCT (one reservation),
# FM_MEM_COUNTED_PCT, FM_MEM_SWAP_EXHAUSTED (1/0). Returns 1 when unavailable.
fm_memory_sample() {
  local shared=$1 now=$2 used_kb
  fm_memory_read_meminfo || return 1
  used_kb=$((FM_MEM_TOTAL_KB - FM_MEM_AVAIL_KB))
  [ "$used_kb" -ge 0 ] || used_kb=0
  FM_MEM_USED_PCT=$(((used_kb * 100 + FM_MEM_TOTAL_KB / 2) / FM_MEM_TOTAL_KB))
  FM_MEM_RESERVED_N=$(fm_memory_reservation_count "$shared" "$now")
  FM_MEM_RESERVE_PCT=$(((FM_MEMORY_RESERVE_MB * 1024 * 100 + FM_MEM_TOTAL_KB - 1) / FM_MEM_TOTAL_KB))
  FM_MEM_COUNTED_PCT=$((FM_MEM_USED_PCT + FM_MEM_RESERVED_N * FM_MEM_RESERVE_PCT))
  FM_MEM_SWAP_EXHAUSTED=0
  if [ "$FM_SWAP_TOTAL_KB" -gt 0 ] && [ $((FM_SWAP_FREE_KB * 100)) -lt $((FM_SWAP_TOTAL_KB * 10)) ]; then
    FM_MEM_SWAP_EXHAUSTED=1
  fi
  return 0
}

# fm_memory_gate_state <shared-state>: print the recorded gate state, open or
# closed (open when never recorded or unreadable).
fm_memory_gate_state() {
  local file="$1/.memory-gate" state=
  [ -f "$file" ] && read -r state _ <"$file" 2>/dev/null
  case "$state" in
    closed) printf 'closed\n' ;;
    *) printf 'open\n' ;;
  esac
}

# fm_memory_gate_update <shared-state> <now>: apply hysteresis to the current
# sample (fm_memory_sample must have run) and persist a transition. Sets
# FM_MEM_GATE (open/closed) and FM_MEM_GATE_CHANGED (1/0). Caller holds the lock.
fm_memory_gate_update() {
  local shared=$1 now=$2 prev next
  prev=$(fm_memory_gate_state "$shared")
  next=$prev
  if [ "$prev" = open ]; then
    if [ "$FM_MEM_COUNTED_PCT" -ge "$FM_MEMORY_CLOSE" ] || [ "$FM_MEM_SWAP_EXHAUSTED" = 1 ]; then
      next=closed
    fi
  elif [ "$FM_MEM_COUNTED_PCT" -lt "$FM_MEMORY_REOPEN" ] && [ "$FM_MEM_SWAP_EXHAUSTED" = 0 ]; then
    next=open
  fi
  FM_MEM_GATE=$next
  FM_MEM_GATE_CHANGED=0
  if [ "$next" != "$prev" ] || [ ! -f "$shared/.memory-gate" ]; then
    printf '%s %s\n' "$next" "$now" >"$shared/.memory-gate.tmp.$$" &&
      mv -f "$shared/.memory-gate.tmp.$$" "$shared/.memory-gate"
    rm -f "$shared/.memory-gate.tmp.$$" 2>/dev/null || true
    [ "$next" = "$prev" ] || FM_MEM_GATE_CHANGED=1
  fi
}

# fm_memory_room_for_one: true when the gate is open and one more reservation
# still stays under the close line (after fm_memory_gate_update).
fm_memory_room_for_one() {
  [ "$FM_MEM_GATE" = open ] &&
    [ $((FM_MEM_COUNTED_PCT + FM_MEM_RESERVE_PCT)) -lt "$FM_MEMORY_CLOSE" ]
}

# fm_memory_gb <kb>: one-decimal gigabytes.
fm_memory_gb() {
  awk -v kb="$1" 'BEGIN { printf "%.1f", kb / 1048576 }'
}

# --- deferred work -----------------------------------------------------------

# The deferral ledger holds "epoch<TAB>task<TAB>kind" lines, kind fresh or
# relaunch. Admission removes a task's deferral; pruning also drops a fresh
# deferral whose task has been spawned since (state/<id>.meta exists) and a
# relaunch deferral whose task record is gone (torn down).

# fm_memory_deferred_prune <state-dir> <now>: keep deferrals that are younger
# than a day and still waiting (above).
fm_memory_deferred_prune() {
  local state=$1 now=$2 file="$1/.memory-deferred" tmp epoch task kind
  [ -f "$file" ] || return 0
  tmp="$file.tmp.$$"
  : >"$tmp" || return 0
  while IFS="$(printf '\t')" read -r epoch task kind; do
    case "$epoch" in '' | *[!0-9]*) continue ;; esac
    [ -n "$task" ] || continue
    [ $((now - epoch)) -lt 86400 ] || continue
    if [ "$kind" = relaunch ]; then
      [ -e "$state/$task.meta" ] || continue
    else
      kind=fresh
      [ ! -e "$state/$task.meta" ] || continue
    fi
    printf '%s\t%s\t%s\n' "$epoch" "$task" "$kind" >>"$tmp"
  done <"$file"
  if [ -s "$tmp" ]; then
    mv -f "$tmp" "$file"
  else
    rm -f "$tmp" "$file"
  fi
}

# fm_memory_deferred_ids <state-dir>: space-separated deferred task ids, a
# deferred relaunch written as <id>(relaunch).
fm_memory_deferred_ids() {
  local file="$1/.memory-deferred"
  [ -f "$file" ] || return 0
  awk -F '\t' 'NF >= 2 && !seen[$2]++ { printf "%s%s%s", sep, $2, ($3 == "relaunch" ? "(relaunch)" : ""); sep = " " }' "$file"
}

fm_memory_deferred_add() {  # <state-dir> <task> <now> <fresh|relaunch>
  local file="$1/.memory-deferred"
  if [ -f "$file" ] && awk -F '\t' -v t="$2" '$2 == t { found = 1 } END { exit !found }' "$file"; then
    return 0
  fi
  printf '%s\t%s\t%s\n' "$3" "$2" "$4" >>"$file"
  # A new deferral wants prompt notice the next time room frees.
  rm -f "$1/.memory-room-notified"
}

fm_memory_deferred_remove() {  # <state-dir> <task>
  local file="$1/.memory-deferred" tmp
  [ -f "$file" ] || return 0
  tmp="$file.tmp.$$"
  awk -F '\t' -v t="$2" '$2 != t { print }' "$file" >"$tmp" 2>/dev/null || {
    rm -f "$tmp"
    return 0
  }
  if [ -s "$tmp" ]; then
    mv -f "$tmp" "$file"
  else
    rm -f "$tmp" "$file"
  fi
}

# --- events ------------------------------------------------------------------

# fm_memory_event <state-dir> <now> <text>: record one captain-relevant event
# for the watcher to surface (bin/fm-memory-watchdog.sh poll). The append holds
# the events lock that poll's trim also holds, so a trim never drops or skips
# an event; a lock that cannot be taken in time still appends, since losing a
# stop notice outright is worse than the narrow race.
fm_memory_event() {
  local text lock="$1/.memory-watchdog.events.lock" held=0
  text=$(printf '%s' "$3" | tr '\t\n\r' '   ')
  fm_lock_acquire_wait_bounded "$lock" 5 >/dev/null 2>&1 && held=1
  printf '%s\t%s\n' "$2" "$text" >>"$1/memory-watchdog.events"
  [ "$held" = 0 ] || fm_lock_release "$lock"
}

# --- heavy jobs ----------------------------------------------------------------

# fm_memory_argv <pid>: set FM_MEM_A0, FM_MEM_A1, FM_MEM_A2 from the process's
# own argv without forking. Returns 1 when the process is gone.
fm_memory_argv() {
  local file arg i=0
  file="$(fm_memory_proc_root)/$1/cmdline"
  FM_MEM_A0=
  FM_MEM_A1=
  FM_MEM_A2=
  [ -r "$file" ] || return 1
  while IFS= read -r -d '' arg; do
    case "$i" in
      0) FM_MEM_A0=$arg ;;
      1) FM_MEM_A1=$arg ;;
      2)
        FM_MEM_A2=$arg
        break
        ;;
    esac
    i=$((i + 1))
  done <"$file" 2>/dev/null
  [ -n "$FM_MEM_A0" ]
}

# fm_memory_argv_is_agent: true when the last-read argv is a worker agent.
fm_memory_argv_is_agent() {
  local a0=${FM_MEM_A0##*/} a1=${FM_MEM_A1##*/}
  case "$a0" in
    claude | codex | opencode | pi | pi-signed | grok | kimi | cursor-agent | gemini | muse | rovodev | acli | omp | agy | devin) return 0 ;;
  esac
  case "$a1" in
    claude | codex | opencode | pi | grok | kimi | cursor-agent | gemini | omp | devin) return 0 ;;
  esac
  case "$FM_MEM_A1" in
    */@anthropic-ai/claude-code/* | */@openai/codex/* | */opencode-ai/* | */@google/gemini-cli/*) return 0 ;;
  esac
  return 1
}

# fm_memory_argv_is_heavy: true when the last-read argv is a heavy job
# (header), setting FM_MEM_CLASS to browser or runner (test runners and
# terraform). Only argv[0..2] are read.
fm_memory_argv_is_heavy() {
  local a0=${FM_MEM_A0##*/} arg base
  FM_MEM_CLASS=runner
  case "$a0" in
    chrome | chromium | chromium-browser | google-chrome* | chrome-headless-shell | headless_shell | msedge | microsoft-edge*)
      FM_MEM_CLASS=browser
      return 0
      ;;
    terraform) return 0 ;;
    vitest | jest | playwright | mocha) return 0 ;;
    node | nodejs | bun | deno)
      [ "$FM_MEM_A1" != --test ] || return 0
      for arg in "$FM_MEM_A1" "$FM_MEM_A2"; do
        case "$arg" in
          */vitest/* | */jest/* | */jest-*/* | */playwright/* | */@playwright/* | */mocha/*) return 0 ;;
        esac
        base=${arg##*/}
        case "$base" in
          vitest | vitest.* | jest | jest.* | playwright | playwright.* | mocha | mocha.*) return 0 ;;
        esac
      done
      ;;
  esac
  return 1
}

# fm_memory_task_worktrees <state-dir>: "task<TAB>worktree" for every recorded
# ship or scout task whose worktree is a real absolute directory other than /.
fm_memory_task_worktrees() {
  local state=$1 meta task kind wt line
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    task=${meta##*/}
    task=${task%.meta}
    kind=
    wt=
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        kind=*) kind=${line#kind=} ;;
        worktree=*) wt=${line#worktree=} ;;
      esac
    done <"$meta"
    case "${kind:-ship}" in ship | scout) ;; *) continue ;; esac
    case "$wt" in /?*) ;; *) continue ;; esac
    wt=${wt%/}
    [ -n "$wt" ] && [ -d "$wt" ] || continue
    printf '%s\t%s\n' "$task" "$wt"
  done
}

# fm_memory_heavy_jobs <state-dir> <out-file>: write one line per heavy job,
# largest first: "size_kb<TAB>task<TAB>root_pid<TAB>class<TAB>top<TAB>btop<TAB>
# member_pids(space-separated)". class is browser or runner; top is 1 for a
# job's topmost heavy process (the critical line's candidates); btop is 1 for a
# topmost browser process, whose tree the browser ceiling measures alone.
# size_kb is the subtree's summed Pss with the VmRSS fallback (header).
fm_memory_heavy_jobs() {
  local state=$1 out=$2 proc tmpd pid task
  proc=$(fm_memory_proc_root)
  tmpd=$(mktemp -d "${TMPDIR:-/tmp}/fm-memory.XXXXXX") || return 1
  fm_memory_task_worktrees "$state" >"$tmpd/worktrees"
  : >"$out"
  if [ ! -s "$tmpd/worktrees" ]; then
    rm -rf "$tmpd"
    return 0
  fi
  # pid, ppid, rss for every process, in one pass over concatenated status
  # files (a vanished process just drops out).
  cat "$proc"/[0-9]*/status 2>/dev/null | awk '
    /^Pid:/ { if (pid != "") print pid, ppid, rss + 0; pid = $2; ppid = 0; rss = 0; next }
    /^PPid:/ { ppid = $2; next }
    /^VmRSS:/ { rss = $2; next }
    END { if (pid != "") print pid, ppid, rss + 0 }
  ' >"$tmpd/table"
  # Processes whose working directory is inside a recorded worktree.
  find "$proc" -mindepth 2 -maxdepth 2 -name cwd -printf '%h\t%l\n' 2>/dev/null |
    awk -F '\t' -v wts="$tmpd/worktrees" '
      BEGIN { while ((getline l < wts) > 0) { split(l, f, "\t"); n++; task[n] = f[1]; wt[n] = f[2] } }
      {
        pid = $1; sub(/.*\//, "", pid)
        if (pid !~ /^[0-9]+$/) next
        for (i = 1; i <= n; i++)
          if ($2 == wt[i] || index($2, wt[i] "/") == 1) { print pid "\t" task[i]; next }
      }
    ' >"$tmpd/owned"
  : >"$tmpd/heavy"
  while IFS="$(printf '\t')" read -r pid task; do
    fm_memory_argv "$pid" || continue
    fm_memory_argv_is_heavy || continue
    fm_memory_argv_is_agent && continue
    printf '%s\t%s\t%s\n' "$pid" "$task" "$FM_MEM_CLASS" >>"$tmpd/heavy"
  done <"$tmpd/owned"
  if [ -s "$tmpd/heavy" ]; then
    awk -F '\t' -v tbl="$tmpd/table" -v proc="$proc" '
      BEGIN {
        while ((getline l < tbl) > 0) {
          split(l, f, " "); parent[f[1]] = f[2]; rss[f[1]] = f[3]
          kids[f[2]] = kids[f[2]] " " f[1]
        }
      }
      { heavy[$1] = $2; class[$1] = $3; order[++h] = $1 }
      function size(p,   f, l, a, got) {
        if (p in sz) return sz[p]
        f = proc "/" p "/smaps_rollup"; got = 0
        while ((getline l < f) > 0)
          if (l ~ /^Pss:/) { split(l, a, " "); sz[p] = a[2] + 0; got = 1; break }
        close(f)
        if (!got) sz[p] = rss[p] + 0
        return sz[p]
      }
      function walk(p,   i, c, parts) {
        members = members " " p; total += size(p)
        c = split(kids[p], parts, " ")
        for (i = 1; i <= c; i++) if (parts[i] != "") walk(parts[i])
      }
      END {
        for (i = 1; i <= h; i++) {
          p = order[i]
          if (!(p in rss)) continue
          # A job is its topmost heavy process (top); a browser tree is also
          # measured on its own from its topmost browser process (btop), so a
          # browser inside a test run meets the browser ceiling by itself.
          top = 1; btop = (class[p] == "browser"); q = parent[p]; depth = 0
          while (q != "" && q != "0" && depth++ < 256) {
            if ((q in heavy) && heavy[q] == heavy[p]) {
              top = 0
              if (class[q] == "browser") btop = 0
            }
            if (!(q in parent)) break
            q = parent[q]
          }
          if (!top && !btop) continue
          members = ""; total = 0
          walk(p)
          sub(/^ /, "", members)
          printf "%d\t%s\t%s\t%s\t%d\t%d\t%s\n", total, heavy[p], p, class[p], top, btop, members
        }
      }
    ' "$tmpd/heavy" | sort -t "$(printf '\t')" -k1,1nr >"$out"
  fi
  rm -rf "$tmpd"
}

# fm_memory_subtree_has_agent <members>: true when any member is a worker agent.
fm_memory_subtree_has_agent() {
  local pid
  for pid in $1; do
    fm_memory_argv "$pid" || continue
    fm_memory_argv_is_agent && return 0
  done
  return 1
}

# fm_memory_starttime <pid>: the process start time from <proc>/<pid>/stat,
# used to refuse a follow-up signal to a recycled pid.
fm_memory_starttime() {
  local line rest
  line=$(cat "$(fm_memory_proc_root)/$1/stat" 2>/dev/null) || return 1
  rest=${line##*) }
  # shellcheck disable=SC2086 # Split the stat fields after the comm field.
  set -- $rest
  [ "$#" -ge 20 ] || return 1
  printf '%s\n' "${20}"
}

# fm_memory_stop_job <members>: TERM every member, give them FM_MEMORY_STOP_GRACE
# seconds, then KILL any member still alive with an unchanged start time.
fm_memory_stop_job() {
  local members=$1 pid starts='' st waited=0 grace=${FM_MEMORY_STOP_GRACE:-3} alive
  for pid in $members; do
    st=$(fm_memory_starttime "$pid" 2>/dev/null || true)
    starts="$starts $pid:$st"
  done
  for pid in $members; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  while [ "$waited" -lt "$grace" ]; do
    alive=0
    for pid in $members; do
      kill -0 "$pid" 2>/dev/null && alive=1
    done
    [ "$alive" = 1 ] || return 0
    sleep 1
    waited=$((waited + 1))
  done
  for pid in $members; do
    kill -0 "$pid" 2>/dev/null || continue
    st=$(fm_memory_starttime "$pid" 2>/dev/null || true)
    case " $starts " in
      *" $pid:$st "*) kill -KILL "$pid" 2>/dev/null || true ;;
    esac
  done
  return 0
}
