#!/usr/bin/env bash
# fm-load-lib.sh - the watchdog's processor, connection, and history
# mechanics, sourced by bin/fm-memory-watchdog.sh (the command surface) and
# nothing else. bin/fm-memory-lib.sh owns the memory mechanics and parses the
# whole of config/memory-gate, including the settings named here.
#
# docs/configuration.md "Memory gate" owns the operator contract: what the
# processor and connection gates and the throttle mean, and the config keys
# that tune them. This header owns the mechanics.
#
# Every <proc> path below is FM_MEMORY_PROC_ROOT (default /proc), so tests
# point the whole watchdog at one fake tree.
#
# Processor (fm_load_cpu_sample). Two signals, each against its own lines:
# pressure is the "some avg10" figure of <proc>/pressure/cpu, the percent of
# the last ten seconds in which at least one runnable task waited for a
# processor; load is the one-minute load average of <proc>/loadavg as a
# percent of the processor count (<proc>/cpuinfo "processor" lines, else
# getconf). Pressure only rises once WSL itself is oversubscribed, while load
# per core shows how much of the machine WSL asks for before that, which is
# what starves Windows programs sharing the same cores, so either signal can
# close the gate or reach critical. Without a readable pressure file, load
# alone decides.
#
# Connection (fm_load_latency_*). A background probe pings latency_host once
# every FM_WATCHDOG_PROBE_EVERY seconds (default 6), one packet with a 2 s
# timeout, through FM_WATCHDOG_PING_CMD (default ping; tests replace it); the
# next tick harvests its result into the shared ring .net-latency
# ("epoch<TAB>ms", or "epoch<TAB>timeout"), trimmed to its last 600 lines.
# Each analysis sample of every home (bin/fm-memory-watchdog.sh) appends to
# the shared ring .net-traffic ("epoch<TAB>home state<TAB>secs<TAB>worker
# KB/s<TAB>up KB/s<TAB>down KB/s": the traffic this home's workers carried,
# by the attribution below, and this machine's interface rates, over the
# secs before epoch), trimmed the same way. A reading covers the last
# FM_LOAD_NET_WINDOW (60) seconds: its latency is the median of their
# probes, a timeout counting as 2000 ms, and its traffic is the samples
# ending in them, weighted by the seconds each covers, which need to cover
# at least half the window: this machine's rate, and the workers' rate,
# each home's averaged on its own and then summed. Every home records under
# the gate lock, so a trim never drops another home's sample. Normal latency is the
# 20th percentile of the successful probes in the last hour, and needs at
# least five of them. Without a normal figure the connection is "unknown",
# which never closes the gate.
# The connection lines compare current latency minus normal latency, because
# a saturated link shows first as queueing delay, but that delay counts only
# while firstmate's workers carry at least net_worker_kbs and most of this
# machine's traffic: otherwise raised latency is the connection itself (a
# phone hotspot or busy mobile cell, Wi-Fi, other devices) or other programs
# on this machine, neither an overload holding back work can ease, so the
# level reads low. Once a counted reading reaches the close line, the level
# reads at least high until no counted reading has reached it for
# net_calm_secs, recomputed from the rings at every read, so one overload is
# one episode.
#
# Gates. .cpu-gate and .net-gate in the shared state directory hold
# "open|closed epoch" with the memory gate's hysteresis: closed when a close
# line is crossed, reopened only once every signal is under its reopen line.
# The loop and admission update the processor gate from a fresh sample; only
# the loop updates the connection gate, so admission treats a connection gate
# record older than FM_WATCHDOG_NET_GATE_STALE seconds (default 120) as open.
#
# Attribution (fm_load_task_trees). A task's tree is each worker agent
# process (bin/fm-memory-lib.sh fm_memory_argv_is_agent) whose working
# directory is inside a recorded ship or scout worktree and whose parent is
# not such an agent, plus every descendant of it; a worktree two records name
# belongs to one of them (bin/fm-memory-lib.sh fm_memory_task_worktrees).
# Nothing outside those trees - firstmate, a secondmate, the terminal
# multiplexer, the no-mistakes daemon, or the owner's own programs - is ever
# attributed, throttled, or signaled.
# Processor use is the summed utime+stime+cutime+cstime of a tree between two
# samples, so commands that already exited still count through the parent
# that reaped them. Connection use is the TCP bytes acknowledged plus received
# per socket from `ss -tinpH state established` (FM_WATCHDOG_SS_CMD replaces
# it in tests), between two samples, credited to the tree owning the socket's
# first listed process. Only internet traffic counts: an IPv4 peer whose most
# specific route in <proc>/net/route is on the measured interface and either
# leaves through a gateway or is the default route (a VPN or point-to-point
# link has none), or a global unicast IPv6 peer (2000::/3), so traffic to
# loopback, a container on a bridge network, or any other directly connected
# subnet is never attributed. UDP traffic (QUIC) is not attributed.
# Interface rates come from <proc>/net/dev for net_interface, else
# the default route's interface in <proc>/net/route, else every non-loopback
# interface summed.
#
# Throttle (owned by bin/fm-memory-watchdog.sh's throttle_step). Pausing
# stops (SIGSTOP) every non-agent process in a tree and later continues it
# (SIGCONT), checking the recorded start time so a recycled pid is never
# signaled. A worker agent itself is never stopped: a shell-launched agent
# that stops is taken over by its shell's job control and would stay frozen
# after SIGCONT. Lowering priority sets every thread (<proc>/<pid>/task/*) of
# every tree member, agent included, to niceness FM_LOAD_NICE (10) when it is
# lower, so running threads slow down and new commands and threads inherit it;
# an unprivileged process cannot raise it back.
#
# History (fm_load_history_append). Each analysis sample appends one line of
# tab-separated key=value fields after the epoch to state/watchdog-history:
# mem, psi, load, cores, up and down (KB/s), rtt and base (ms), gates
# (mem:..,cpu:..,net:..), topcpu (task:cores), topnet (task:KB/s), and
# throttle (resource:task:stage, or -); "-" marks a value not measured. When
# the file passes history_kb it is renamed to watchdog-history.1, replacing
# the previous one, so the history never holds more than twice history_kb.
# shellcheck disable=SC2034 # FM_CPU_*/FM_NET_* output globals are read by the sourcing caller.
set -u

FM_LOAD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-memory-lib.sh
. "$FM_LOAD_LIB_DIR/fm-memory-lib.sh"

FM_LOAD_NICE=10
FM_LOAD_NET_WINDOW=60

# --- processor ---------------------------------------------------------------

fm_load_nproc() {
  local n
  n=$(grep -c '^processor' "$(fm_memory_proc_root)/cpuinfo" 2>/dev/null) || n=
  case "$n" in '' | *[!0-9]* | 0) n=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1) ;; esac
  case "$n" in '' | *[!0-9]* | 0) n=1 ;; esac
  printf '%s\n' "$n"
}

# fm_load_cpu_sample: set FM_CPU_PSI (one decimal, or empty without a
# pressure file), FM_CPU_PSI_PCT (whole percent, rounded down), FM_CPU_LOAD
# (two decimals, or empty), FM_CPU_LOAD_PCT (load as percent of cores),
# FM_CPU_CORES, and FM_CPU_LEVEL: critical, high (at or past a close line),
# mid, low (under every reopen line), or unknown (no signal at all).
fm_load_cpu_sample() {
  local proc line
  proc=$(fm_memory_proc_root)
  FM_CPU_PSI=
  FM_CPU_PSI_PCT=
  FM_CPU_LOAD=
  FM_CPU_LOAD_PCT=
  FM_CPU_CORES=$(fm_load_nproc)
  if [ -r "$proc/pressure/cpu" ]; then
    line=$(awk '$1 == "some" { for (i = 2; i <= NF; i++) if ($i ~ /^avg10=/) { sub(/^avg10=/, "", $i); print $i; exit } }' "$proc/pressure/cpu" 2>/dev/null)
    case "$line" in
      [0-9]*)
        FM_CPU_PSI=$(awk -v v="$line" 'BEGIN { printf "%.1f", v }')
        FM_CPU_PSI_PCT=${FM_CPU_PSI%.*}
        ;;
    esac
  fi
  if [ -r "$proc/loadavg" ]; then
    read -r line _ <"$proc/loadavg" 2>/dev/null || line=
    case "$line" in
      [0-9]*)
        FM_CPU_LOAD=$(awk -v v="$line" 'BEGIN { printf "%.2f", v }')
        FM_CPU_LOAD_PCT=$(awk -v v="$line" -v c="$FM_CPU_CORES" 'BEGIN { printf "%d", v * 100 / c }')
        ;;
    esac
  fi
  FM_CPU_LEVEL=$(fm_load_level "$FM_CPU_PSI_PCT" "$FM_CPU_REOPEN" "$FM_CPU_CLOSE" "$FM_CPU_CRITICAL" \
    "$FM_CPU_LOAD_PCT" "$FM_LOAD_REOPEN" "$FM_LOAD_CLOSE" "$FM_LOAD_CRITICAL")
}

# fm_load_level <value> <reopen> <close> <critical> [<value> <reopen> <close>
# <critical> ...]: the highest level any measured value reaches; low only
# when every measured value is under its reopen line; unknown when none was
# measured.
fm_load_level() {
  local level=unknown v r c k rank=0 r2
  while [ "$#" -ge 4 ]; do
    v=$1 r=$2 c=$3 k=$4
    shift 4
    [ -n "$v" ] || continue
    if [ "$v" -ge "$k" ]; then
      r2=4
    elif [ "$v" -ge "$c" ]; then
      r2=3
    elif [ "$v" -ge "$r" ]; then
      r2=2
    else
      r2=1
    fi
    [ "$r2" -le "$rank" ] || rank=$r2
  done
  case "$rank" in
    4) level=critical ;;
    3) level=high ;;
    2) level=mid ;;
    1) level=low ;;
  esac
  printf '%s\n' "$level"
}

# --- gates -------------------------------------------------------------------

# fm_load_gate_state <shared-state> <cpu|net> [<now> <stale-secs>]: print the
# recorded gate, open or closed; with <now> and <stale-secs>, a record older
# than that reads as open.
fm_load_gate_state() {
  local file="$1/.$2-gate" state='' epoch=''
  [ -f "$file" ] && read -r state epoch _ <"$file" 2>/dev/null
  if [ "$state" = closed ] && [ "$#" -ge 4 ]; then
    case "$epoch" in '' | *[!0-9]*) epoch=0 ;; esac
    [ $(($3 - epoch)) -lt "$4" ] || state=open
  fi
  case "$state" in
    closed) printf 'closed\n' ;;
    *) printf 'open\n' ;;
  esac
}

# fm_load_gate_update <shared-state> <cpu|net> <now> <level>: apply the
# hysteresis (header) and persist; prints the resulting state. A closed gate
# refreshes its epoch on every update, so the staleness rule only ever reads
# a record the loop stopped maintaining. Caller holds the gate lock.
fm_load_gate_update() {
  local shared=$1 name=$2 now=$3 level=$4 prev next file
  file="$shared/.$name-gate"
  prev=$(fm_load_gate_state "$shared" "$name")
  next=$prev
  case "$level" in
    high | critical) next=closed ;;
    low | unknown) next=open ;;
  esac
  if [ "$next" != "$prev" ] || [ "$next" = closed ] || [ ! -f "$file" ]; then
    printf '%s %s\n' "$next" "$now" >"$file.tmp.$$" && mv -f "$file.tmp.$$" "$file"
    rm -f "$file.tmp.$$" 2>/dev/null || true
  fi
  printf '%s\n' "$next"
}

# --- connection --------------------------------------------------------------

# fm_load_latency_harvest <shared-state> <now>: move a finished probe's result
# into the latency ring.
fm_load_latency_harvest() {
  local shared=$1 now=$2 out="$1/.net-probe.out" ms ring="$1/.net-latency"
  [ -f "$out" ] || return 0
  ms=$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^time[=<]/) { v = $i; sub(/^time[=<]/, "", v); if (v == "" && i < NF) v = $(i + 1); printf "%d", v + 0.5; exit } }' "$out" 2>/dev/null)
  rm -f "$out"
  case "$ms" in '' | *[!0-9]*) ms=timeout ;; esac
  printf '%s\t%s\n' "$now" "$ms" >>"$ring"
  fm_load_ring_trim "$ring"
}

# fm_load_ring_trim <ring>: keep a shared ring to its last 600 lines.
fm_load_ring_trim() {
  local ring=$1
  if [ "$(wc -l <"$ring" | tr -d '[:space:]')" -gt 700 ]; then
    tail -n 600 "$ring" >"$ring.tmp.$$" && mv -f "$ring.tmp.$$" "$ring"
    rm -f "$ring.tmp.$$" 2>/dev/null || true
  fi
}

# fm_load_traffic_record <shared-state> <now> <home-state> <secs>
# <worker-kbs> <up-kbs> <down-kbs>: append one sample to the traffic ring.
fm_load_traffic_record() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "$6" "$7" >>"$1/.net-traffic"
  fm_load_ring_trim "$1/.net-traffic"
}

# fm_load_latency_probe <shared-state> <now> <host>: start one background
# probe when the last one is FM_WATCHDOG_PROBE_EVERY seconds old.
fm_load_latency_probe() {
  local shared=$1 now=$2 host=$3 last every=${FM_WATCHDOG_PROBE_EVERY:-6} tmp
  last=$(cat "$shared/.net-probe-last" 2>/dev/null || echo 0)
  case "$last" in '' | *[!0-9]*) last=0 ;; esac
  [ $((now - last)) -ge "$every" ] || return 0
  [ ! -f "$shared/.net-probe.out" ] || return 0
  printf '%s\n' "$now" >"$shared/.net-probe-last"
  tmp="$shared/.net-probe.out.tmp.$$"
  (
    # One packet with a 2 s timeout, so a probe never outlives its interval.
    "${FM_WATCHDOG_PING_CMD:-ping}" -n -c 1 -W 2 "$host" >"$tmp" 2>&1 </dev/null
    mv -f "$tmp" "$shared/.net-probe.out" 2>/dev/null || rm -f "$tmp"
  ) >/dev/null 2>&1 &
}

# fm_load_latency_read <shared-state> <now>: set FM_NET_RTT and FM_NET_BASE
# (whole ms, or empty), FM_NET_OVER (rtt - base, or empty), FM_NET_WORK_KBS
# and FM_NET_ALL_KBS (the workers' and this machine's traffic over the
# reading, both or neither empty), FM_NET_QUIET (1 when the latency alone
# would reach the close line but the workers do not carry enough of the
# traffic for it to count), FM_NET_SETTLING (1 when only the calm hold keeps
# the level high), and FM_NET_LEVEL (header), from the two rings.
fm_load_latency_read() {
  local shared=$1 now=$2 result sticky counted
  FM_NET_RTT=
  FM_NET_BASE=
  FM_NET_OVER=
  FM_NET_WORK_KBS=
  FM_NET_ALL_KBS=
  FM_NET_QUIET=0
  FM_NET_SETTLING=0
  result=$(awk -F '\t' -v now="$now" -v win="$FM_LOAD_NET_WINDOW" -v calm="$FM_NET_CALM_SECS" \
    -v closems="$FM_LATENCY_CLOSE_MS" -v floor="$FM_NET_WORKER_KBS" -v traffic="$shared/.net-traffic" '
    BEGIN {
      while ((getline l < traffic) > 0) {
        if (split(l, f, "\t") < 6 || f[1] !~ /^[0-9]+$/ || f[3] !~ /^[1-9][0-9]*$/) continue
        if (f[1] > now || now - f[1] >= calm + win) continue
        s++; st[s] = f[1] + 0; sh[s] = f[2]; sd[s] = f[3] + 0; sw[s] = f[4] + 0; sa[s] = f[5] + f[6]
      }
    }
    $1 !~ /^[0-9]+$/ || $1 > now { next }
    now - $1 <= 3600 && $2 ~ /^[0-9]+$/ { ok[++n] = $2 + 0 }
    now - $1 < calm + win { m++; t[m] = $1 + 0; ms[m] = ($2 ~ /^[0-9]+$/ ? $2 + 0 : 2000) }
    function sortn(a, c,   i, j, x) { for (i = 2; i <= c; i++) { x = a[i]; for (j = i - 1; j >= 1 && a[j] > x; j--) a[j + 1] = a[j]; a[j + 1] = x } }
    # reading <end>: W_RTT (median ms), W_WORK and W_ALL (KB/s) of the
    # reading ending at <end>, each empty when unmeasured.
    function reading(end,   i, c, v, h, all, cover, wsum, wcover, w) {
      W_RTT = ""; W_WORK = ""; W_ALL = ""; c = 0; all = 0; cover = 0; w = 0
      for (i = 1; i <= m; i++) if (t[i] > end - win && t[i] <= end) v[++c] = ms[i]
      if (c > 0) { sortn(v, c); W_RTT = v[int((c + 1) / 2)] }
      for (i = 1; i <= s; i++) {
        if (st[i] <= end - win || st[i] > end) continue
        all += sa[i] * sd[i]; cover += sd[i]
        wsum[sh[i]] += sw[i] * sd[i]; wcover[sh[i]] += sd[i]
      }
      if (cover < win / 2) return
      for (h in wsum) w += wsum[h] / wcover[h]
      W_WORK = int(w); W_ALL = int(all / cover)
    }
    function counted() { return W_WORK != "" && W_WORK >= floor && W_WORK * 2 > W_ALL }
    function overloaded() { return W_RTT != "" && W_RTT - base >= closems && counted() }
    END {
      base = ""; sticky = 0
      if (n >= 5) { sortn(ok, n); base = ok[int((n - 1) * 0.2) + 1] }
      if (base != "") for (i = 1; i <= m; i++) if (now - t[i] < calm) { reading(t[i]); if (overloaded()) sticky = 1 }
      reading(now)
      print base "|" W_RTT "|" W_WORK "|" W_ALL "|" sticky "|" counted()
    }
  ' "$shared/.net-latency" 2>/dev/null)
  IFS='|' read -r FM_NET_BASE FM_NET_RTT FM_NET_WORK_KBS FM_NET_ALL_KBS sticky counted <<EOF_READING
$result
EOF_READING
  if [ -n "$FM_NET_BASE" ] && [ -n "$FM_NET_RTT" ]; then
    FM_NET_OVER=$((FM_NET_RTT - FM_NET_BASE))
    [ "$FM_NET_OVER" -ge 0 ] || FM_NET_OVER=0
  fi
  FM_NET_LEVEL=$(fm_load_level "$FM_NET_OVER" "$FM_LATENCY_REOPEN_MS" "$FM_LATENCY_CLOSE_MS" "$FM_LATENCY_CRITICAL_MS")
  [ "$FM_NET_LEVEL" != unknown ] || return 0
  if [ "${counted:-0}" != 1 ]; then
    case "$FM_NET_LEVEL" in high | critical) FM_NET_QUIET=1 ;; esac
    FM_NET_LEVEL=low
  fi
  case "$FM_NET_LEVEL" in
    low | mid)
      if [ "${sticky:-0}" = 1 ]; then
        FM_NET_LEVEL=high
        FM_NET_SETTLING=1
      fi
      ;;
  esac
}

# fm_load_net_interface: print the measured interface (header).
fm_load_net_interface() {
  local proc
  proc=$(fm_memory_proc_root)
  if [ -n "${FM_NET_INTERFACE:-}" ]; then
    printf '%s\n' "$FM_NET_INTERFACE"
    return 0
  fi
  awk 'NR > 1 && $2 == "00000000" { print $1; exit }' "$proc/net/route" 2>/dev/null
}

# fm_load_net_rates <state-dir> <now>: set FM_NET_IFACE, FM_NET_UP_KBS, and
# FM_NET_DOWN_KBS (whole KB/s since the previous call, or empty on the
# first), and FM_NET_RATE_SECS (the seconds they cover), remembering the
# counters in .watchdog-netdev.
fm_load_net_rates() {
  local state=$1 now=$2 proc counters rx tx pepoch prx ptx piface elapsed
  proc=$(fm_memory_proc_root)
  FM_NET_UP_KBS=
  FM_NET_DOWN_KBS=
  FM_NET_RATE_SECS=
  FM_NET_IFACE=$(fm_load_net_interface)
  counters=$(awk -v want="$FM_NET_IFACE" '
    NR > 2 {
      line = $0; sub(/^[[:space:]]+/, "", line)
      name = line; sub(/:.*/, "", name); sub(/^[^:]*:[[:space:]]*/, "", line)
      split(line, f, " ")
      if (want != "" ? name == want : name != "lo") { rx += f[1]; tx += f[9]; seen = 1 }
    }
    END { if (seen) printf "%.0f %.0f\n", rx, tx }
  ' "$proc/net/dev" 2>/dev/null)
  [ -n "$counters" ] || return 0
  rx=${counters% *}
  tx=${counters#* }
  [ -n "$FM_NET_IFACE" ] || FM_NET_IFACE=all
  if [ -f "$state/.watchdog-netdev" ] && read -r pepoch prx ptx piface <"$state/.watchdog-netdev" &&
    [ "$piface" = "$FM_NET_IFACE" ]; then
    elapsed=$((now - pepoch))
    if [ "$elapsed" -gt 0 ] && [ "$rx" -ge "$prx" ] && [ "$tx" -ge "$ptx" ]; then
      FM_NET_DOWN_KBS=$(((rx - prx) / 1024 / elapsed))
      FM_NET_UP_KBS=$(((tx - ptx) / 1024 / elapsed))
      FM_NET_RATE_SECS=$elapsed
    fi
  fi
  printf '%s %s %s %s\n' "$now" "$rx" "$tx" "$FM_NET_IFACE" >"$state/.watchdog-netdev"
}

# --- attribution -------------------------------------------------------------

# fm_load_stat_table <out>: "pid ppid ticks starttime nice" for every process,
# in one pass over concatenated stat files (a vanished process drops out).
fm_load_stat_table() {
  cat "$(fm_memory_proc_root)"/[0-9]*/stat 2>/dev/null | awk '
    {
      i = length($0)
      while (i > 0 && substr($0, i, 1) != ")") i--
      if (i == 0) next
      pid = $1
      n = split(substr($0, i + 2), f, " ")
      if (n < 20) next
      print pid, f[2], f[12] + f[13] + f[14] + f[15], f[20], f[17]
    }
  ' >"$1"
}

# fm_load_tree_walk <stat-table> <roots-file> <out>: for every "pid<TAB>task"
# root, write "task<TAB>pid<TAB>ticks<TAB>starttime<TAB>nice<TAB>root" for the
# root and each descendant.
fm_load_tree_walk() {
  awk -v tbl="$1" -F '\t' '
    BEGIN {
      while ((getline l < tbl) > 0) {
        split(l, f, " "); ppid[f[1]] = f[2]; ticks[f[1]] = f[3]; start[f[1]] = f[4]; nice[f[1]] = f[5]
        kids[f[2]] = kids[f[2]] " " f[1]
      }
    }
    function walk(p, task, root,   c, parts, i) {
      if (p in seen) return
      seen[p] = 1
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", task, p, ticks[p], start[p], nice[p], root
      c = split(kids[p], parts, " ")
      for (i = 1; i <= c; i++) if (parts[i] != "") walk(parts[i], task, root)
    }
    ($1 in ppid) { walk($1, $2, $1) }
  ' "$2" >"$3"
}

# fm_load_task_trees <state-dir> <out>: every process in every recorded task's
# tree (header), as fm_load_tree_walk lines.
fm_load_task_trees() {
  local state=$1 out=$2 proc tmpd pid task
  proc=$(fm_memory_proc_root)
  : >"$out"
  tmpd=$(mktemp -d "${TMPDIR:-/tmp}/fm-load.XXXXXX") || return 1
  fm_memory_task_worktrees "$state" >"$tmpd/worktrees"
  if [ ! -s "$tmpd/worktrees" ]; then
    rm -rf "$tmpd"
    return 0
  fi
  fm_load_stat_table "$tmpd/table"
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
  : >"$tmpd/agents"
  while IFS="$(printf '\t')" read -r pid task; do
    fm_memory_argv "$pid" || continue
    fm_memory_argv_is_agent || continue
    printf '%s\t%s\n' "$pid" "$task" >>"$tmpd/agents"
  done <"$tmpd/owned"
  # Topmost agents only: a nested agent is already inside its parent's tree.
  awk -F '\t' -v tbl="$tmpd/table" '
    BEGIN { while ((getline l < tbl) > 0) { split(l, f, " "); ppid[f[1]] = f[2] } }
    { agent[$1] = $2; order[++n] = $1 }
    END {
      for (i = 1; i <= n; i++) {
        p = order[i]; q = ppid[p]; nested = 0; depth = 0
        while (q != "" && q != "0" && depth++ < 256) {
          if ((q in agent) && agent[q] == agent[p]) { nested = 1; break }
          q = ppid[q]
        }
        if (!nested) print p "\t" agent[p]
      }
    }
  ' "$tmpd/agents" >"$tmpd/roots"
  fm_load_tree_walk "$tmpd/table" "$tmpd/roots" "$out"
  rm -rf "$tmpd"
}

# fm_load_task_cpu <state-dir> <trees> <now>: print "task<TAB>centicores" per
# task (processor use since the previous call, 100 = one whole core), and
# remember the tick totals in .watchdog-cputicks.
fm_load_task_cpu() {
  local state=$1 trees=$2 now=$3 clk prev="$1/.watchdog-cputicks"
  clk=$(getconf CLK_TCK 2>/dev/null || echo 100)
  case "$clk" in '' | *[!0-9]* | 0) clk=100 ;; esac
  awk -F '\t' -v prev="$prev" -v now="$now" -v clk="$clk" -v out="$prev.tmp.$$" '
    BEGIN {
      if ((getline l < prev) > 0) pepoch = l + 0
      while ((getline l < prev) > 0) { split(l, f, "\t"); pt[f[1]] = f[2] }
    }
    { t[$1] += $3 }
    END {
      print now > out
      for (k in t) {
        print k "\t" t[k] > out
        el = now - pepoch
        if ((k in pt) && el > 0) { d = t[k] - pt[k]; if (d < 0) d = 0; printf "%s\t%d\n", k, d * 100 / clk / el }
      }
    }
  ' "$trees" && mv -f "$prev.tmp.$$" "$prev"
  rm -f "$prev.tmp.$$" 2>/dev/null || true
}

# fm_load_task_net <state-dir> <trees> <now>: print "task<TAB>KB/s" per task
# (internet use since the previous call, header), remembering per-socket
# byte counts in .watchdog-sockets.
fm_load_task_net() {
  local state=$1 trees=$2 now=$3 prev="$1/.watchdog-sockets" ss_out want
  # shellcheck disable=SC2086 # FM_WATCHDOG_SS_CMD is a command line.
  ss_out=$(${FM_WATCHDOG_SS_CMD:-ss -tinpH state established} 2>/dev/null) || ss_out=
  [ -n "$ss_out" ] || return 0
  want=$(fm_load_net_interface)
  printf '%s\n' "$ss_out" | awk -v trees="$trees" -v prev="$prev" -v now="$now" -v out="$prev.tmp.$$" \
    -v routes="$(fm_memory_proc_root)/net/route" -v want="$want" '
    function hex(s,   i, v) { v = 0; for (i = 1; i <= length(s); i++) v = v * 16 + index("0123456789abcdef", tolower(substr(s, i, 1))) - 1; return v }
    # internet <peer>: 1 when traffic to the ss peer address:port leaves
    # through the measured interface toward the internet (header).
    function internet(peer,   a, o, r, i, ok, best) {
      a = peer; sub(/:[^:]*$/, "", a); gsub(/[][]/, "", a); sub(/^::ffff:/, "", a)
      if (a ~ /:/) return a ~ /^[23]/
      if (a ~ /^127\./ || split(a, o, ".") != 4) return 0
      best = 0
      for (r = 1; r <= nr; r++) {
        ok = 1
        for (i = 1; i <= 4; i++) if (o[i] - o[i] % (256 - rm[r, i]) != rd[r, i]) ok = 0
        if (ok && (!best || rmask[r] > rmask[best])) best = r
      }
      return best && routed[best] && (want != "" ? rif[best] == want : rif[best] != "lo")
    }
    BEGIN {
      while ((getline l < routes) > 0) {
        if (split(l, f, " ") < 8 || f[2] !~ /^[0-9A-Fa-f]+$/ || length(f[2]) != 8 || f[8] !~ /^[0-9A-Fa-f]+$/ || length(f[8]) != 8) continue
        nr++; rif[nr] = f[1]; routed[nr] = (hex(f[3]) != 0 || hex(f[8]) == 0); rmask[nr] = 0
        for (i = 1; i <= 4; i++) {
          rd[nr, i] = hex(substr(f[2], 9 - 2 * i, 2)); rm[nr, i] = hex(substr(f[8], 9 - 2 * i, 2))
          rmask[nr] = rmask[nr] * 256 + rm[nr, i]
        }
      }
      while ((getline l < trees) > 0) { split(l, f, "\t"); owner[f[2]] = f[1] }
      if ((getline l < prev) > 0) { pepoch = l + 0; have = 1 }
      while ((getline l < prev) > 0) { n = split(l, f, "\t"); pb[f[1]] = f[2] }
      print now > out
    }
    /^[^[:space:]]/ {
      key = ""; pid = ""
      if (!internet($4)) next
      key = $3 " " $4
      if (match($0, /pid=[0-9]+/)) pid = substr($0, RSTART + 4, RLENGTH - 4)
      next
    }
    key != "" {
      a = 0; r = 0
      if (match($0, /bytes_acked:[0-9]+/)) a = substr($0, RSTART + 12, RLENGTH - 12) + 0
      if (match($0, /bytes_received:[0-9]+/)) r = substr($0, RSTART + 15, RLENGTH - 15) + 0
      b = a + r
      printf "%s\t%.0f\n", key, b > out
      d = 0
      if (key in pb) d = b - pb[key]; else if (have) d = b
      if (d < 0) d = 0
      if (pid in owner) used[owner[pid]] += d
      key = ""
    }
    END {
      el = now - pepoch
      if (have && el > 0) for (k in used) printf "%s\t%d\n", k, used[k] / 1024 / el
    }
  ' && mv -f "$prev.tmp.$$" "$prev"
  rm -f "$prev.tmp.$$" 2>/dev/null || true
}

# --- throttle mechanics ------------------------------------------------------

# fm_load_tree_of <roots> <out>: the current tree under the given root pids
# (space-separated), as fm_load_tree_walk lines with task "-".
fm_load_tree_of() {
  local roots=$1 out=$2 tmpd pid
  tmpd=$(mktemp -d "${TMPDIR:-/tmp}/fm-load.XXXXXX") || return 1
  fm_load_stat_table "$tmpd/table"
  : >"$tmpd/roots"
  for pid in $roots; do printf '%s\t-\n' "$pid" >>"$tmpd/roots"; done
  fm_load_tree_walk "$tmpd/table" "$tmpd/roots" "$out"
  rm -rf "$tmpd"
}

# fm_load_self_chain: this process and its ancestors (from the real /proc,
# since they are real processes even under a fake proc root).
fm_load_self_chain() {
  local p=$BASHPID chain='' line rest depth=0
  while [ -n "$p" ] && [ "$p" -gt 1 ] && [ "$depth" -lt 64 ]; do
    chain="$chain $p"
    line=$(cat "/proc/$p/stat" 2>/dev/null) || break
    rest=${line##*) }
    # shellcheck disable=SC2086 # Split the stat fields after the comm field.
    set -- $rest
    p=${2:-}
    depth=$((depth + 1))
  done
  printf '%s \n' "$chain"
}

# fm_load_stop_tree <roots> <already-stopped>: SIGSTOP every non-agent member
# of the roots' current trees not already in <already-stopped> ("pid:start"
# words), never this process or an ancestor of it; prints the full stopped
# list afterwards.
fm_load_stop_tree() {
  local roots=$1 stopped=$2 tree pid start self _t _k _n _r
  tree=$(mktemp "${TMPDIR:-/tmp}/fm-load-tree.XXXXXX") || {
    printf '%s\n' "$stopped"
    return 0
  }
  self=$(fm_load_self_chain)
  fm_load_tree_of "$roots" "$tree"
  while IFS="$(printf '\t')" read -r _t pid _k start _n _r; do
    [ -n "$pid" ] || continue
    case "$self" in *" $pid "*) continue ;; esac
    case " $stopped " in *" $pid:$start "*) continue ;; esac
    fm_memory_argv "$pid" || continue
    fm_memory_argv_is_agent && continue
    kill -STOP "$pid" 2>/dev/null && stopped="$stopped $pid:$start"
  done <"$tree"
  rm -f "$tree"
  printf '%s\n' "${stopped# }"
}

# fm_load_resume <stopped>: SIGCONT every "pid:start" whose start time still
# matches.
fm_load_resume() {
  local word pid start
  for word in $1; do
    pid=${word%%:*}
    start=${word#*:}
    [ "$(fm_memory_starttime "$pid" 2>/dev/null)" = "$start" ] || continue
    kill -CONT "$pid" 2>/dev/null || true
  done
}

# fm_load_renice_tree <roots>: lower every thread of every member of the
# roots' trees to FM_LOAD_NICE when its niceness is lower; Linux sets the
# niceness of one thread at a time.
fm_load_renice_tree() {
  local tree proc pid _t _r
  tree=$(mktemp "${TMPDIR:-/tmp}/fm-load-tree.XXXXXX") || return 0
  fm_load_tree_of "$1" "$tree"
  proc=$(fm_memory_proc_root)
  while IFS="$(printf '\t')" read -r _t pid _r; do
    cat "$proc/$pid"/task/[0-9]*/stat 2>/dev/null
  done <"$tree" | awk -v floor="$FM_LOAD_NICE" '
    {
      i = length($0)
      while (i > 0 && substr($0, i, 1) != ")") i--
      if (i == 0 || split(substr($0, i + 2), f, " ") < 20) next
      if (f[17] ~ /^-?[0-9]+$/ && f[17] + 0 < floor) print $1
    }
  ' | xargs -r renice -n "$FM_LOAD_NICE" -p >/dev/null 2>&1 || true
  rm -f "$tree"
}

# --- history -----------------------------------------------------------------

# fm_load_history_append <state-dir> <line>: append one sample (header).
fm_load_history_append() {
  local file="$1/watchdog-history" size
  printf '%s\n' "$2" >>"$file"
  size=$(wc -c <"$file" 2>/dev/null | tr -d '[:space:]')
  case "$size" in '' | *[!0-9]*) return 0 ;; esac
  [ "$size" -le $((FM_HISTORY_KB * 1024)) ] || mv -f "$file" "$file.1"
}
