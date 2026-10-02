#!/usr/bin/env bash
# End-to-end demo of the watchdog's processor/connection gates, throttle and history.
# Usage: DEMO_PY_PID=<pid of a 3-thread python at nice 0> nice -n 15 demo.sh <repo-root>
set -u
REPO=$1
eval "$(sed -e '/^test_[a-z_]*$/d' -e '/^echo "# all/d' -e 's|\$(dirname "\${BASH_SOURCE\[0\]}")|'"$REPO"'/tests|' "$REPO/tests/fm-memory-watchdog.test.sh")"
say() { printf '\n$ %s\n' "$*"; }
new_case demo
set_mem 40
printf 'critical_secs=1\n' >"$H/config/memory-gate"
throttle_case demo fm-research
# Replace the command with a real 3-thread python so per-thread renice is real.
PY=$DEMO_PY_PID  # a sleeping 3-thread python started at nice 0 outside this niced run
fake_proc "$PY" "$AGENT" 1000 /tmp python3 worker.py
rm -rf "$P/$PY/task"; ln -s "/proc/$PY/task" "$P/$PY/task"
set_ticks "$PY" 0
echo "Threads of real worker command $PY before overload (tid nice):"; ps -L -o lwp=,ni= -p "$PY"
say "fm-memory-watchdog.sh status   # calm machine"; wd status
set_cpu 64 9.30; set_latency 38 180
say "# processor pressure 64%, load 9.30 on 8 cores, latency 180 ms vs normal 38"
say "fm-memory-watchdog.sh admit next-worker"; wd admit next-worker; echo "exit=$?"
FM_WATCHDOG_SAMPLE=1 wd tick; sleep 1.1; set_ticks "$PY" 400
FM_WATCHDOG_SAMPLE=1 FM_WATCHDOG_PAUSE_SECS=1 FM_WATCHDOG_RUN_SECS=1 wd tick
echo; echo "Threads of $PY after the processor throttle's first stage (tid nice):"; ps -L -o lwp=,ni= -p "$PY"
say "fm-memory-watchdog.sh status   # during overload"; wd status
say "fm-memory-watchdog.sh poll"; wd poll
echo; echo "Messages sent to the worker:"; cut -f2 "$H/sent.log"
say "tail -n 2 state/watchdog-history"; tail -n 2 "$H/state/watchdog-history"
say "fm-memory-watchdog.sh history --since '5 minutes ago'"; wd history --since '5 minutes ago'
