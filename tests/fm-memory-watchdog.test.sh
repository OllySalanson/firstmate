#!/usr/bin/env bash
# bin/fm-memory-watchdog.sh owns worker admission against a memory gate with
# hysteresis and reservations and against the processor and connection gates,
# the critical-line stop of the single largest heavy job under a recorded task
# worktree, the processor and connection throttle, the sample history, the
# flagship-first dispatch order, and the watcher-surfaced events. Every case
# fakes /proc (meminfo, pressure, loadavg, plus process entries), ping, and ss;
# the process entries for the critical line and the throttle are bound to real
# `sleep` processes so every stop, pause, and resume is observed, never assumed.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# tests/lib.sh disables the gate for every other suite; this one is its owner.
unset FM_MEMORY_WATCHDOG_DISABLE

WD="$ROOT/bin/fm-memory-watchdog.sh"
TMP_ROOT=$(fm_test_tmproot fm-memory-watchdog-tests)
SLEEPERS=()

cleanup_all() {
  local pid
  for pid in "${SLEEPERS[@]:-}"; do
    [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null
  done
  for pid in "$TMP_ROOT"/*/home/state/.memory-watchdog.lock/pid; do
    [ -f "$pid" ] || continue
    pid=$(cat "$pid")
    [ "$pid" = "$$" ] || kill -KILL "$pid" 2>/dev/null
  done
  fm_test_cleanup
}
trap cleanup_all EXIT

GB=1048576 # kB

# new_case <name>: a fresh home and fake proc root; sets H, P.
new_case() {
  H="$TMP_ROOT/$1/home"
  P="$TMP_ROOT/$1/proc"
  mkdir -p "$H/state" "$H/config" "$H/data" "$P"
  # Stand in as the home's live loop so `poll` never starts a real one that
  # would tick concurrently with the case; the loop case removes this.
  mkdir -p "$H/state/.memory-watchdog.lock"
  printf '%s\n' "$$" >"$H/state/.memory-watchdog.lock/pid"
}

# set_mem <used-percent> [swap-total-kb swap-free-kb]: a 10 GB machine.
set_mem() {
  local total=$((10 * GB)) avail
  avail=$((total - total * $1 / 100))
  {
    printf 'MemTotal:       %s kB\n' "$total"
    printf 'MemFree:        %s kB\n' "$avail"
    printf 'MemAvailable:   %s kB\n' "$avail"
    printf 'SwapTotal:      %s kB\n' "${2:-0}"
    printf 'SwapFree:       %s kB\n' "${3:-0}"
  } >"$P/meminfo"
}

wd() {  # <args...>: run the watchdog against the current case
  FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_CONFIG_OVERRIDE="$H/config" \
    FM_DATA_OVERRIDE="$H/data" FM_MEMORY_PROC_ROOT="$P" \
    FM_MEMORY_SEND_CMD="$TMP_ROOT/fake-send" FM_MEMORY_STOP_GRACE=2 \
    FM_WATCHDOG_PING_CMD="$TMP_ROOT/fake-ping" FM_WATCHDOG_SS_CMD="$TMP_ROOT/fake-ss" \
    FM_WATCHDOG_PROBE_EVERY="${FM_WATCHDOG_PROBE_EVERY:-100000}" \
    "$WD" "$@"
}

cat >"$TMP_ROOT/fake-send" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "$2" >>"$FM_HOME/sent.log"
SH
# The fake ping answers with $FM_HOME/ping-ms, or times out without it.
cat >"$TMP_ROOT/fake-ping" <<'SH'
#!/usr/bin/env bash
[ -f "$FM_HOME/ping-ms" ] || exit 1
printf '64 bytes from 1.1.1.1: icmp_seq=1 ttl=55 time=%s ms\n' "$(cat "$FM_HOME/ping-ms")"
SH
cat >"$TMP_ROOT/fake-ss" <<'SH'
#!/usr/bin/env bash
cat "$FM_HOME/ss.out" 2>/dev/null
SH
chmod +x "$TMP_ROOT/fake-send" "$TMP_ROOT/fake-ping" "$TMP_ROOT/fake-ss"

# fake_proc <pid> <ppid> <rss-kb> <cwd> <argv...>: Pss equals the RSS unless
# set_pss changes it.
fake_proc() {
  local pid=$1 ppid=$2 rss=$3 cwd=$4
  shift 4
  mkdir -p "$P/$pid/task"
  # Each fake process is single-threaded: its one thread is the process itself.
  ln -sfn .. "$P/$pid/task/$pid"
  printf '%s\0' "$@" >"$P/$pid/cmdline"
  printf 'Name:\t%s\nState:\tS (sleeping)\nPid:\t%s\nPPid:\t%s\nVmRSS:\t%s kB\n' \
    "${1##*/}" "$pid" "$ppid" "$rss" >"$P/$pid/status"
  printf '%s (%s) S %s 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 4242 0 0\n' \
    "$pid" "${1##*/}" "$ppid" >"$P/$pid/stat"
  set_pss "$pid" "$rss"
  ln -sfn "$cwd" "$P/$pid/cwd"
}

# set_cpu <pressure-some-avg10|-> <load1> [cores]: "-" leaves no pressure file.
set_cpu() {
  local i
  mkdir -p "$P/pressure"
  if [ "$1" = - ]; then
    rm -f "$P/pressure/cpu"
  else
    printf 'some avg10=%s avg60=0.00 avg300=0.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' "$1" >"$P/pressure/cpu"
  fi
  printf '%s 1.00 1.00 2/400 999\n' "$2" >"$P/loadavg"
  : >"$P/cpuinfo"
  for i in $(seq 0 $((${3:-8} - 1))); do printf 'processor\t: %s\n\n' "$i" >>"$P/cpuinfo"; done
}

# set_latency <normal-ms> <current-ms>: twenty probes at the normal latency
# over the last hour, then three recent ones at the current latency.
set_latency() {
  local now i
  now=$(date +%s)
  : >"$H/state/.net-latency"
  for i in $(seq 20 -1 1); do printf '%s\t%s\n' $((now - 120 * i - 60)) "$1" >>"$H/state/.net-latency"; done
  for i in 3 2 1; do printf '%s\t%s\n' $((now - i)) "$2" >>"$H/state/.net-latency"; done
}

set_ticks() {  # <pid> <cpu-ticks>: the process's utime in its fake stat
  local ppid
  ppid=$(awk '/^PPid:/ { print $2 }' "$P/$1/status")
  printf '%s (%s) S %s 0 0 0 0 0 0 0 0 0 %s 0 0 0 0 0 0 0 4242 0 0\n' "$1" "x" "$ppid" "$2" >"$P/$1/stat"
}

proc_state() {  # <pid>: the real process state letter (T while stopped)
  awk '{ i = length($0); while (substr($0, i, 1) != ")") i--; split(substr($0, i + 2), f, " "); print f[1] }' "/proc/$1/stat" 2>/dev/null
}

set_pss() {  # <pid> <pss-kb>
  printf '00400000-7ffff000 ---p 00000000 00:00 0                          [rollup]\nRss:            %s kB\nPss:            %s kB\n' \
    "$(awk '/^VmRSS:/ { print $2 }' "$P/$1/status")" "$2" >"$P/$1/smaps_rollup"
}

sleeper() {  # prints the pid of a fresh real process standing in for a job
  sleep 600 &
  LAST_SLEEPER=$!
  disown "$LAST_SLEEPER"
  SLEEPERS+=("$LAST_SLEEPER")
}

task_meta() {  # <task> <worktree> [kind]
  mkdir -p "$2"
  fm_write_meta "$H/state/$1.meta" "window=fm:$1" "worktree=$2" "kind=${3:-ship}" "harness=claude"
}

test_admission_counts_reservations() {
  local out rc
  new_case reserve
  set_mem 60
  wd admit t1 || fail "a worker was not admitted at 60% used"
  out=$(wd status)
  assert_contains "$out" "memory gate: open - 60% of 10.0 GB RAM in use" "status did not report the sample"
  assert_contains "$out" "1 just-started worker(s) reserved, counted 70%" "the admitted worker was not reserved"
  wd admit t2 || fail "a second worker was not admitted while one more still fits under 85%"
  out=$(wd admit t3 2>&1)
  rc=$?
  expect_code 75 "$rc" "a third worker that would cross the close line"
  assert_contains "$out" "deferred: t3 stays queued" "the deferral did not say the task stays queued"
  assert_contains "$out" "past the 85% close line" "the deferral did not name the close line"
  assert_contains "$(wd status)" "deferred work: t3" "the deferral was not recorded"
  pass "just-admitted workers count as reserved memory, so a burst is admitted only while it fits"
}

test_reservations_expire() {
  new_case expire
  set_mem 60
  printf 'reserve_secs=1\n' >"$H/config/memory-gate"
  wd admit t1 || fail "first admission failed"
  wd admit t2 || fail "second admission failed"
  sleep 2
  assert_contains "$(wd status)" "0 just-started worker(s) reserved" "expired reservations were still counted"
  pass "a reservation stops counting after reserve_secs"
}

test_hysteresis() {
  local rc
  new_case hysteresis
  set_mem 86
  wd admit a 2>/dev/null
  expect_code 75 "$?" "admission at 86% used"
  assert_contains "$(wd status)" "memory gate: closed" "the gate did not close at the close line"
  set_mem 72
  wd admit b 2>/dev/null
  rc=$?
  expect_code 75 "$rc" "admission at 72% while the gate is still closed"
  assert_contains "$(wd admit c 2>&1)" "the memory gate is closed" "the closed-gate deferral did not say so"
  set_mem 60
  wd admit d || fail "the gate did not reopen below 70%"
  assert_contains "$(wd status)" "memory gate: open" "the gate did not report open after reopening"
  pass "the gate closes at 85% and reopens only below 70%"
}

test_swap_exhaustion_closes_gate() {
  new_case swap
  set_mem 40 $((4 * GB)) $((GB / 4))
  wd admit a 2>/dev/null
  expect_code 75 "$?" "admission with swap nearly exhausted"
  assert_contains "$(wd status)" "(nearly exhausted)" "status did not report exhausted swap"
  pass "nearly exhausted swap closes the gate even with RAM to spare"
}

test_override_admits_and_reserves() {
  local out
  new_case override
  set_mem 90
  out=$(wd admit boss --override 2>&1) || fail "an override was refused: $out"
  assert_contains "$out" "by explicit override" "the override did not announce itself"
  assert_contains "$(wd status)" "1 just-started worker(s) reserved" "the override did not reserve its worker"
  pass "--override admits a captain-directed worker and still counts it"
}

test_unavailable_meminfo_admits_with_warning() {
  local out
  new_case nomeminfo
  out=$(wd admit t1 2>&1) || fail "a platform without meminfo blocked a spawn"
  assert_contains "$out" "memory gate unavailable" "no warning was printed"
  assert_contains "$(wd status)" "memory gate: unavailable" "status did not report unavailable"
  pass "without /proc/meminfo the gate admits with a warning instead of blocking"
}

test_config_validation() {
  local out rc
  new_case config
  set_mem 10
  printf 'close=70\nreopen=80\n' >"$H/config/memory-gate"
  out=$(wd admit t1 2>&1)
  rc=$?
  expect_code 1 "$rc" "admission under an inverted config"
  assert_contains "$out" "reopen < close < critical" "the config error did not explain itself"
  printf 'enabled=off\n' >"$H/config/memory-gate"
  set_mem 99
  wd admit t2 || fail "enabled=off still gated"
  printf 'close=60 # tighter\nreopen=40\ncritical=90\nreserve_mb=512\n' >"$H/config/memory-gate"
  set_mem 55
  out=$(wd status)
  assert_contains "$out" "closes at 60%, reopens below 40%, critical stop at 90%; each new worker reserves 512 MB" "configured lines were not applied"
  pass "config/memory-gate is validated, tunable, and can switch the gate off"
}

test_critical_stops_largest_heavy_job_only() {
  local wt="$TMP_ROOT/crit/wt" other="$TMP_ROOT/crit/elsewhere" agent vit fork chrome renderer outside out sent
  new_case crit
  mkdir -p "$other"
  task_meta t1 "$wt"
  set_mem 96
  sleeper; agent=$LAST_SLEEPER
  sleeper; vit=$LAST_SLEEPER
  sleeper; fork=$LAST_SLEEPER
  sleeper; chrome=$LAST_SLEEPER
  sleeper; renderer=$LAST_SLEEPER
  sleeper; outside=$LAST_SLEEPER
  # The agent's own argv mentions vitest in its prompt; it must never count.
  fake_proc "$agent" 1 $((GB)) "$wt" claude --dangerously-skip-permissions "run vitest and chrome"
  fake_proc "$vit" "$agent" $((2 * GB)) "$wt" node "$wt/node_modules/vitest/vitest.mjs" run
  fake_proc "$fork" "$vit" $((GB)) "$wt" node "$wt/node_modules/vitest/dist/workers/forks.js"
  fake_proc "$chrome" "$agent" $((GB / 2)) "$wt" /opt/chrome/chrome --headless=new
  fake_proc "$renderer" "$chrome" $((GB / 4)) / /opt/chrome/chrome --type=renderer
  # Bigger than anything, but not under any recorded worktree.
  fake_proc "$outside" 1 $((5 * GB)) "$other" node "$other/node_modules/vitest/vitest.mjs"
  wd tick
  sleep 0.3
  kill -0 "$vit" 2>/dev/null && fail "the largest heavy job survived the critical line"
  kill -0 "$fork" 2>/dev/null && fail "the job's own worker process survived"
  kill -0 "$agent" 2>/dev/null || fail "the worker agent was signaled"
  kill -0 "$chrome" 2>/dev/null || fail "a second, smaller job was also stopped"
  kill -0 "$renderer" 2>/dev/null || fail "the smaller job's renderer was stopped"
  kill -0 "$outside" 2>/dev/null || fail "a process outside every recorded worktree was stopped"
  sent=$(cat "$H/sent.log")
  assert_contains "$sent" "t1"$'\t'"Memory watchdog: this machine reached 96% memory" "the worker was not told"
  assert_contains "$sent" "'node vitest.mjs run'" "the notice did not name the stopped job"
  out=$(wd poll)
  assert_contains "$out" "memory-watchdog: critical line: memory reached 96% (critical 95%), so the watchdog stopped t1's heaviest job 'node vitest.mjs run' (about 3.0 GB PSS)" "firstmate was not given the stop"
  assert_equals "" "$(wd poll)" "a surfaced event was repeated"
  # The cooldown keeps a second tick from stopping another job at once.
  wd tick
  kill -0 "$chrome" 2>/dev/null || fail "a second job was stopped inside the cooldown"
  pass "the critical line stops only the single largest heavy job in a task's tree and tells its worker"
}

test_critical_skips_subtree_holding_an_agent() {
  local wt="$TMP_ROOT/agentsub/wt" runner nested small
  new_case agentsub
  task_meta t2 "$wt"
  set_mem 97
  sleeper; runner=$LAST_SLEEPER
  sleeper; nested=$LAST_SLEEPER
  sleeper; small=$LAST_SLEEPER
  fake_proc "$runner" 1 $((3 * GB)) "$wt" terraform apply
  fake_proc "$nested" "$runner" $((GB)) "$wt" claude -p hello
  fake_proc "$small" 1 $((GB / 2)) "$wt" node --test
  wd tick
  sleep 0.3
  kill -0 "$runner" 2>/dev/null || fail "a job whose subtree holds an agent was stopped"
  kill -0 "$nested" 2>/dev/null || fail "an agent was signaled"
  kill -0 "$small" 2>/dev/null && fail "the next largest job was not stopped"
  pass "a heavy job whose subtree contains a worker agent is never stopped"
}

test_critical_with_nothing_to_stop_reports_once() {
  local wt="$TMP_ROOT/nothing/wt" out
  new_case nothing
  task_meta t3 "$wt"
  set_mem 98
  wd tick
  wd tick
  out=$(wd poll)
  assert_contains "$out" "no test suite, browser, or terraform job" "the empty critical episode was not reported"
  case "$out" in *";"*) fail "the empty critical episode was reported twice: $out" ;; esac
  set_mem 50
  wd tick
  set_mem 98
  wd tick
  assert_contains "$(wd poll)" "no test suite" "a new critical episode was not reported"
  pass "a critical episode with nothing stoppable is reported once per episode"
}

test_room_event_for_deferred_work() {
  local out
  new_case room
  set_mem 90
  wd admit waiting 2>/dev/null
  expect_code 75 "$?" "admission at 90%"
  wd tick
  assert_equals "" "$(wd poll)" "room was announced while memory was still high"
  set_mem 40
  wd tick
  out=$(wd poll)
  assert_contains "$out" "memory-watchdog: room for queued work" "room was not announced"
  assert_contains "$out" "deferred: waiting" "the announcement did not name the deferred work"
  wd tick
  assert_equals "" "$(wd poll)" "room was re-announced inside the renotify window"
  wd admit waiting || fail "the deferred task was not admitted once room freed"
  assert_contains "$(wd status)" "deferred work: none" "an admitted task stayed deferred"
  pass "freed memory announces deferred work once, and admission clears it"
}

test_queue_orders_flagship_first() {
  local out fakebin="$TMP_ROOT/queue-bin"
  new_case queue
  mkdir -p "$fakebin"
  cat >"$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "$1" in
  ready)
    printf '%s\n' 'count: 4' 'ready[4]{id,state,kind,repo,title}:' \
      '  a-one,queued,ship,alpha,First alpha item' \
      '  f-one,queued,ship,flag,"Flagship, with a comma"' \
      '  a-two,queued,scout,alpha,Second alpha item' \
      '  f-two,queued,ship,flag,Second flagship item' \
      'help[1]:' '  - Run `tasks-axi start <id>` to dispatch one of these'
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tasks-axi"
  printf '# Backlog\n\n## Queued\n' >"$H/data/backlog.md"
  wd flagship flag >/dev/null 2>&1 || fail "setting the flagship failed"
  assert_equals flag "$(wd flagship)" "the flagship was not recorded"
  out=$(PATH="$fakebin:$PATH" wd queue) || fail "queue failed: $out"
  assert_contains "$out" "flagship flag first" "the order did not name the flagship"
  assert_contains "$out" "1. f-one  (flag, ship) [flagship]  Flagship, with a comma" "the first flagship item did not lead"
  assert_contains "$out" "2. f-two  (flag, ship) [flagship]" "the second flagship item was not next"
  assert_contains "$out" "3. a-one  (alpha, ship)" "request order was not kept after the flagship"
  assert_contains "$out" "4. a-two  (alpha, scout)" "request order was not kept after the flagship"
  wd flagship --clear >/dev/null
  out=$(PATH="$fakebin:$PATH" wd queue)
  assert_contains "$out" "1. a-one" "without a flagship the request order was not kept"
  pass "the dispatch queue puts the flagship project first, then keeps request order"
}

test_loop_runs_only_while_work_exists() {
  local pid
  new_case loop
  rm -rf "$H/state/.memory-watchdog.lock"
  set_mem 30
  FM_MEMORY_WATCHDOG_POLL=1 FM_MEMORY_WATCHDOG_IDLE_EXIT=1 wd ensure
  sleep 0.5
  assert_absent "$H/state/.memory-watchdog.lock/pid" "a loop started for a home with no work"
  task_meta t9 "$TMP_ROOT/loop/wt"
  FM_MEMORY_WATCHDOG_POLL=1 FM_MEMORY_WATCHDOG_IDLE_EXIT=1 wd ensure
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$H/state/.memory-watchdog.lock/pid" ] && break
    sleep 0.2
  done
  pid=$(cat "$H/state/.memory-watchdog.lock/pid" 2>/dev/null) || fail "no loop started while a task exists"
  kill -0 "$pid" 2>/dev/null || fail "the loop is not alive"
  FM_MEMORY_WATCHDOG_POLL=1 FM_MEMORY_WATCHDOG_IDLE_EXIT=1 wd ensure
  assert_equals "$pid" "$(cat "$H/state/.memory-watchdog.lock/pid")" "ensure replaced a live loop"
  rm -f "$H/state/t9.meta"
  for _ in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
  done
  kill -0 "$pid" 2>/dev/null && fail "the loop kept running after the home ran out of work"
  # A loop whose home disappears (a removed secondmate home) exits too.
  task_meta t9 "$TMP_ROOT/loop/wt"
  FM_MEMORY_WATCHDOG_POLL=1 FM_MEMORY_WATCHDOG_IDLE_EXIT=600 wd ensure
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$H/state/.memory-watchdog.lock/pid" ] && break
    sleep 0.2
  done
  pid=$(cat "$H/state/.memory-watchdog.lock/pid" 2>/dev/null) || fail "no loop started for the vanishing-home check"
  # The live loop may write into the directory during removal; retry.
  for _ in 1 2 3 4 5; do
    rm -rf "$H/state" 2>/dev/null && [ ! -e "$H/state" ] && break
  done
  for _ in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
  done
  kill -0 "$pid" 2>/dev/null && fail "the loop kept running after its home's state directory vanished"
  pass "the watchdog loop is a singleton that runs only while the home has work"
}

test_spawn_defers_and_overrides() {
  local case_dir="$TMP_ROOT/spawn" home proj wt fakebin out rc id=gate-spawn-z1 pid
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-gate"
  fm_test_spawn_brief "$home" "$id"
  P="$case_dir/proc"
  mkdir -p "$P"
  set_mem 92
  out=$(FM_MEMORY_PROC_ROOT="$P" FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off)
  rc=$?
  expect_code 75 "$rc" "a spawn over the memory gate"$'\n'"$out"
  assert_contains "$out" "deferred: $id stays queued" "the spawn did not report a deferral"
  assert_absent "$home/state/$id.meta" "a deferred spawn left a task record"
  [ ! -s "$case_dir/launch.log" ] || fail "a deferred spawn launched a worker"
  out=$(FM_MEMORY_PROC_ROOT="$P" FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" FM_FAKE_PANE_LOG="$case_dir/pane.log" \
    FM_MEMORY_WATCHDOG_IDLE_EXIT=1 fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off --memory-override)
  rc=$?
  expect_code 0 "$rc" "an overridden spawn"$'\n'"$out"
  assert_contains "$out" "spawned $id" "the override did not launch"
  assert_contains "$(cat "$case_dir/launch.log")" "plugin:pdf-viewer:pdf" "the worker launch does not deny the PDF viewer helper"
  pid=$(cat "$home/state/.memory-watchdog.lock/pid" 2>/dev/null || true)
  [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null
  assert_contains "$(cat "$case_dir/pane.log")" "export CHROME_DEVTOOLS_AXI_SESSION=fm-$id" "the worker pane does not own a per-task browser session"
  out=$(FM_MEMORY_PROC_ROOT="$P" fm_test_run_spawn "$home" "$wt" "$fakebin" sm-z3 --secondmate --memory-override)
  assert_contains "$out" "secondmate spawns are not memory-gated" "a secondmate spawn accepted the override"
  pass "fm-spawn defers a fresh spawn over the gate, admits it on --memory-override, and refuses the override for a secondmate"
}

test_room_event_names_a_deferred_relaunch() {
  local out
  new_case roomrl
  task_meta rl1 "$TMP_ROOT/roomrl/wt"
  set_mem 90
  wd admit rl1 --relaunch 2>/dev/null
  expect_code 75 "$?" "a relaunch admission at 90%"
  set_mem 40
  wd tick
  out=$(wd poll)
  assert_contains "$out" "deferred: rl1(relaunch)" "the room notice did not name the deferred relaunch"
  assert_contains "$out" "bin/fm-control.sh <id> relaunch" "the room notice did not say how to relaunch it"
  rm -f "$H/state/rl1.meta"
  assert_contains "$(wd status)" "deferred work: none" "a deferred relaunch outlived its torn-down task"
  pass "a deferred relaunch is announced as one when room frees and dropped when its task is torn down"
}

test_job_size_is_pss_with_rss_fallback() {
  local wt="$TMP_ROOT/pss/wt" browser r1 r2 r3 other orenderer
  new_case pss
  task_meta t6 "$wt"
  set_mem 40
  sleeper; browser=$LAST_SLEEPER
  sleeper; r1=$LAST_SLEEPER
  sleeper; r2=$LAST_SLEEPER
  sleeper; r3=$LAST_SLEEPER
  sleeper; other=$LAST_SLEEPER
  sleeper; orenderer=$LAST_SLEEPER
  # 4 GB of summed RSS, but most of it is the same shared pages: 1.2 GB PSS.
  fake_proc "$browser" 1 $((GB)) "$wt" chromium --headless
  fake_proc "$r1" "$browser" $((GB)) / chromium --type=renderer
  fake_proc "$r2" "$browser" $((GB)) / chromium --type=renderer
  fake_proc "$r3" "$browser" $((GB)) / chromium --type=renderer
  for pid in "$browser" "$r1" "$r2" "$r3"; do set_pss "$pid" $((3 * GB / 10)); done
  # No readable smaps_rollup: the RSS counts instead, 2 GB over the ceiling.
  fake_proc "$other" 1 $((GB)) "$wt" chrome --headless=new
  fake_proc "$orenderer" "$other" $((GB)) / chrome --type=renderer
  rm -f "$P/$other/smaps_rollup" "$P/$orenderer/smaps_rollup"
  wd tick
  sleep 0.3
  kill -0 "$browser" 2>/dev/null || fail "a browser under the ceiling by PSS was stopped for its shared pages"
  kill -0 "$r1" 2>/dev/null || fail "a renderer of a browser under the ceiling by PSS was stopped"
  kill -0 "$other" 2>/dev/null && fail "a browser without readable PSS was not measured by its RSS"
  assert_contains "$(cat "$H/sent.log")" "grew to about 2.0 GB PSS" "the notice did not name the measured figure"
  pass "a job is sized by summed PSS, falling back to RSS where PSS is unreadable"
}

test_tick_protects_while_the_gate_lock_is_held() {
  local wt="$TMP_ROOT/locked/wt" holder browser start
  new_case locked
  task_meta t7 "$wt"
  set_mem 40
  sleeper; holder=$LAST_SLEEPER
  sleeper; browser=$LAST_SLEEPER
  mkdir -p "$H/state/.memory-gate.lock"
  printf '%s\n' "$holder" >"$H/state/.memory-gate.lock/pid"
  fake_proc "$browser" 1 $((2 * GB)) "$wt" chromium --headless
  start=$(date +%s)
  wd tick
  sleep 0.3
  kill -0 "$browser" 2>/dev/null && fail "a held gate lock turned off the job ceiling"
  [ $(($(date +%s) - start)) -lt 8 ] || fail "a held gate lock blocked the tick"
  pass "a held gate lock postpones only the gate update, never the job stops"
}

test_poll_trim_keeps_later_events() {
  local line out
  new_case trim
  line=$(printf 'x%.0s' $(seq 1 200))
  for _ in $(seq 1 400); do printf '1\t%s\n' "$line"; done >"$H/state/memory-watchdog.events"
  wd poll >/dev/null
  [ "$(wc -c <"$H/state/memory-watchdog.events")" -lt 65536 ] || fail "the surfaced events were not trimmed"
  FM_STATE_OVERRIDE="$H/state" bash -c '. "$1/bin/fm-memory-lib.sh"; STATE=$2; FM_ROOT=$1; fm_memory_event "$2" 2 "after the trim"' _ "$ROOT" "$H/state"
  out=$(wd poll)
  assert_equals "memory-watchdog: after the trim" "$out" "an event appended after a trim was not surfaced exactly once"
  pass "trimming surfaced events keeps every later event for the next poll"
}

test_browser_ceiling_stops_a_ballooning_browser_alone() {
  local wt="$TMP_ROOT/ceiling/wt" runner browser renderer small out sent
  new_case ceiling
  task_meta t4 "$wt"
  set_mem 40
  sleeper; runner=$LAST_SLEEPER
  sleeper; browser=$LAST_SLEEPER
  sleeper; renderer=$LAST_SLEEPER
  sleeper; small=$LAST_SLEEPER
  # A screenshot run: a test runner whose own browser balloons.
  fake_proc "$runner" 1 $((GB / 2)) "$wt" node "$wt/node_modules/@playwright/test/cli.js" test
  fake_proc "$browser" "$runner" $((GB / 2)) "$wt" /opt/ms-playwright/chrome-linux/headless_shell --headless
  fake_proc "$renderer" "$browser" $((3 * GB / 2)) / /opt/ms-playwright/chrome-linux/headless_shell --type=renderer
  # A second, modest browser in the same local copy stays.
  fake_proc "$small" 1 $((GB / 2)) "$wt" chromium --headless
  wd tick
  sleep 0.3
  kill -0 "$browser" 2>/dev/null && fail "a browser tree over its ceiling survived at 40% memory"
  kill -0 "$renderer" 2>/dev/null && fail "the ballooning renderer survived"
  kill -0 "$runner" 2>/dev/null || fail "the test runner around the browser was stopped too"
  kill -0 "$small" 2>/dev/null || fail "a browser under the ceiling was stopped"
  sent=$(cat "$H/sent.log")
  assert_contains "$sent" "t4"$'\t'"Memory watchdog: your headless browser grew to about 2.0 GB" "the worker was not told its browser was stopped"
  assert_contains "$sent" "close it between screenshots, and use a small viewport" "the notice did not say how to stay small"
  out=$(wd poll)
  assert_contains "$out" "job ceiling: stopped t4's headless browser 'headless_shell --headless' at about 2.0 GB PSS (ceiling 1.5 GB)" "firstmate was not told of the ceiling stop"
  pass "one browser tree over its ceiling is stopped early, alone, even while total memory is fine"
}

test_job_ceiling_stops_an_oversized_test_run() {
  local wt="$TMP_ROOT/jobceiling/wt" vit ok
  new_case jobceiling
  task_meta t5 "$wt"
  set_mem 30
  printf 'job_ceiling_mb=2048\n' >"$H/config/memory-gate"
  sleeper; vit=$LAST_SLEEPER
  sleeper; ok=$LAST_SLEEPER
  fake_proc "$vit" 1 $((5 * GB / 2)) "$wt" node "$wt/node_modules/vitest/vitest.mjs" run
  fake_proc "$ok" 1 $((GB)) "$wt" terraform plan
  wd tick
  sleep 0.3
  kill -0 "$vit" 2>/dev/null && fail "a test run over the job ceiling survived"
  kill -0 "$ok" 2>/dev/null || fail "a job under the ceiling was stopped"
  assert_contains "$(cat "$H/sent.log")" "past the 2.0 GB ceiling for one test or terraform job" "the worker was not told about the job ceiling"
  assert_contains "$(wd status)" "job ceilings: one headless browser tree 1536 MB, one test or terraform job 2048 MB" "status did not show the ceilings"
  pass "one test run over the configured job ceiling is stopped and its worker told"
}

test_processor_gate_defers_and_reopens() {
  local out rc
  new_case cpugate
  set_mem 40
  set_cpu 30 2.00
  out=$(wd admit p1 2>&1)
  rc=$?
  expect_code 75 "$rc" "admission while processor pressure is 30%"
  assert_contains "$out" "the processor gate is closed (pressure 30.0%, load 2.00 on 8 cores (25%)" "the deferral did not name the processor reading"
  assert_contains "$(wd status)" "processor gate: closed - pressure 30.0%" "status did not show the closed processor gate"
  set_cpu 15 2.00
  wd admit p1 2>/dev/null
  expect_code 75 "$?" "admission between the processor reopen and close lines"
  set_cpu 5 2.00
  wd admit p1 || fail "the processor gate did not reopen under both reopen lines"
  # Without a pressure file, load per core alone decides.
  set_cpu - 7.50
  wd admit p2 2>/dev/null
  expect_code 75 "$?" "admission at load 7.5 on 8 cores"
  assert_contains "$(wd status)" "load 7.50 on 8 cores (93%; no pressure reading on this kernel)" "status did not fall back to load"
  set_cpu - 2.00
  assert_contains "$(wd status)" "room: yes" "the processor gate did not reopen on load alone"
  pass "processor pressure or load per core closes the processor gate, deferring new work until both fall under their reopen lines"
}

test_connection_gate_follows_latency_above_normal() {
  local out rc
  new_case netgate
  set_mem 40
  set_latency 40 160
  wd tick
  assert_contains "$(wd status)" "connection gate: closed - latency to 1.1.1.1 160 ms against a normal 40 ms" "status did not show the closed connection gate"
  out=$(wd admit n1 2>&1)
  rc=$?
  expect_code 75 "$rc" "admission while latency is 120 ms above normal"
  assert_contains "$out" "the connection gate is closed (latency to 1.1.1.1 160 ms against a normal 40 ms" "the deferral did not name the latency"
  set_latency 40 90
  wd tick
  assert_contains "$(wd status)" "connection gate: closed" "the connection gate reopened between its lines"
  set_latency 40 60
  wd tick
  wd admit n1 || fail "the connection gate did not reopen under its reopen line"
  # Only the loop maintains this gate, so admission ignores a record it stopped refreshing.
  printf 'closed %s\n' $(($(date +%s) - 600)) >"$H/state/.net-gate"
  : >"$H/state/.net-latency"
  wd admit n2 || fail "a stale closed connection gate blocked admission"
  # Without a learned normal latency the connection never closes the gate.
  printf '%s\t900\n' "$(date +%s)" >"$H/state/.net-latency"
  wd tick
  assert_contains "$(wd status)" "connection gate: open - latency to 1.1.1.1 900 ms, normal latency not learned yet" "an unknown normal latency closed the gate"
  pass "latency well above its normal level closes the connection gate, with hysteresis, and an unmaintained or unlearned reading never blocks work"
}

test_latency_probe_is_harvested_by_the_next_tick() {
  new_case probe
  set_mem 40
  printf '37.6\n' >"$H/ping-ms"
  FM_WATCHDOG_PROBE_EVERY=1 wd tick
  for _ in $(seq 1 25); do
    [ -f "$H/state/.net-probe.out" ] && break
    sleep 0.2
  done
  FM_WATCHDOG_PROBE_EVERY=1 wd tick
  assert_contains "$(cat "$H/state/.net-latency")" $'\t38' "a probe's latency was not recorded"
  rm -f "$H/ping-ms"
  sleep 1.1
  FM_WATCHDOG_PROBE_EVERY=1 wd tick
  for _ in $(seq 1 25); do
    [ -f "$H/state/.net-probe.out" ] && break
    sleep 0.2
  done
  FM_WATCHDOG_PROBE_EVERY=1 wd tick
  assert_contains "$(cat "$H/state/.net-latency")" $'\ttimeout' "a failed probe was not recorded as a timeout"
  pass "the background latency probe is recorded by the next tick, and a lost probe counts as a timeout"
}

# throttle_case <name> <task>: a task whose worker agent runs one command
# with a child of its own; sets AGENT, CMD, CHILD and the case's worktree WT.
throttle_case() {
  WT="$TMP_ROOT/$1/wt-$2"
  task_meta "$2" "$WT"
  sleeper; AGENT=$LAST_SLEEPER
  sleeper; CMD=$LAST_SLEEPER
  sleeper; CHILD=$LAST_SLEEPER
  fake_proc "$AGENT" 1 1000 "$WT" claude --dangerously-skip-permissions
  # A command that changed directory still belongs to the worker's tree.
  fake_proc "$CMD" "$AGENT" 1000 /tmp bash -c "curl a b"
  fake_proc "$CHILD" "$CMD" 1000 /tmp curl --parallel
}

test_processor_throttle_lowers_priority_then_pauses_then_releases() {
  local sent out want
  new_case cputhr
  set_mem 40
  printf 'critical_secs=1\n' >"$H/config/memory-gate"
  throttle_case cputhr t1
  set_ticks "$CMD" 0
  set_cpu 60 9.30
  FM_WATCHDOG_SAMPLE=1 wd tick
  sleep 1.1
  set_ticks "$CMD" 400
  FM_WATCHDOG_SAMPLE=1 FM_WATCHDOG_PAUSE_SECS=1 FM_WATCHDOG_RUN_SECS=1 wd tick
  # A suite already running nicer than 10 keeps its own niceness.
  want=$(ps -o ni= -p "$$" | tr -d ' ')
  [ "$want" -gt 10 ] || want=10
  assert_equals "$want" "$(ps -o ni= -p "$CMD" | tr -d ' ')" "the heaviest worker's command was not lowered in priority"
  assert_equals "$want" "$(ps -o ni= -p "$AGENT" | tr -d ' ')" "the worker agent was not lowered in priority, so new commands would not inherit it"
  sent=$(cat "$H/sent.log")
  assert_contains "$sent" "t1"$'\t'"Watchdog: this machine's processor has been overloaded for 1 seconds (pressure 60.0%, load 9.30 on 8 cores (116%))" "the worker was not told why"
  assert_contains "$sent" "lowered the priority of your agent and its commands" "the worker was not told its priority dropped"
  assert_contains "$(wd poll)" "processor critical: overloaded for 1s (pressure 60.0%, load 9.30 on 8 cores (116%)), so the watchdog lowered the priority of t1's work" "firstmate was not told of the throttle"
  assert_contains "$(tail -n 1 "$H/state/watchdog-history")" "topcpu=t1:" "the history did not record the busiest worker"
  sleep 1.1
  set_ticks "$CMD" 800
  FM_WATCHDOG_SAMPLE=1 FM_WATCHDOG_PAUSE_SECS=1 FM_WATCHDOG_RUN_SECS=1 wd tick
  assert_equals T "$(proc_state "$CMD")" "a command was not paused once lower priority was not enough"
  assert_equals T "$(proc_state "$CHILD")" "the command's child was not paused"
  assert_equals S "$(proc_state "$AGENT")" "the worker agent itself was paused"
  assert_contains "$(cat "$H/sent.log")" "now pausing your running commands for 1 seconds at a time" "the worker was not told about the pausing"
  assert_contains "$(wd status)" "throttled: t1's commands are being paused in turns for the processor" "status did not show the throttle"
  sleep 1.1
  FM_WATCHDOG_SAMPLE=1 FM_WATCHDOG_PAUSE_SECS=1 FM_WATCHDOG_RUN_SECS=1 wd tick
  assert_equals S "$(proc_state "$CMD")" "a paused command was not continued when its pause ended"
  assert_equals S "$(proc_state "$CHILD")" "a paused child was not continued when its pause ended"
  set_cpu 4 1.00
  sleep 1.1
  FM_WATCHDOG_SAMPLE=1 FM_WATCHDOG_PAUSE_SECS=1 FM_WATCHDOG_RUN_SECS=1 wd tick
  assert_absent "$H/state/.watchdog-throttle-cpu" "the throttle outlived the overload"
  assert_contains "$(cat "$H/sent.log")" "Watchdog: the processor has recovered" "the worker was not told the overload ended"
  out=$(wd poll)
  assert_contains "$out" "processor critical: still overloaded" "firstmate was not told of the escalation"
  assert_contains "$out" "processor recovered: the watchdog stopped throttling t1" "firstmate was not told of the release"
  kill -0 "$CMD" 2>/dev/null || fail "the throttle killed a command"
  pass "a processor overload lowers the heaviest worker's priority, then pauses its commands in turns, never its agent, and releases on recovery"
}

test_connection_throttle_pauses_the_heaviest_traffic_only() {
  local busy_cmd busy_agent light_cmd
  new_case netthr
  set_mem 40
  printf 'critical_secs=1\n' >"$H/config/memory-gate"
  throttle_case netthr busy
  busy_cmd=$CMD busy_agent=$AGENT
  throttle_case netthr light
  light_cmd=$CMD
  write_ss() {  # <busy-bytes> <light-bytes>
    {
      printf '0 0 172.17.0.2:40000 104.16.0.1:443 users:(("curl",pid=%s,fd=3))\n\t cubic bytes_acked:%s bytes_received:0\n' "$busy_cmd" "$1"
      printf '0 0 172.17.0.2:40001 104.16.0.2:443 users:(("curl",pid=%s,fd=3))\n\t cubic bytes_acked:%s bytes_received:0\n' "$light_cmd" "$2"
      printf '0 0 127.0.0.1:40002 127.0.0.1:4387 users:(("curl",pid=%s,fd=3))\n\t cubic bytes_acked:%s bytes_received:0\n' "$light_cmd" "$(($1 * 10))"
    } >"$H/ss.out"
  }
  write_ss 0 0
  set_latency 40 400
  FM_WATCHDOG_SAMPLE=1 wd tick
  sleep 1.1
  write_ss 4000000 400000
  set_latency 40 400
  FM_WATCHDOG_SAMPLE=1 FM_WATCHDOG_PAUSE_SECS=1 FM_WATCHDOG_RUN_SECS=1 wd tick
  assert_equals T "$(proc_state "$busy_cmd")" "the worker carrying the most traffic was not paused"
  assert_equals S "$(proc_state "$busy_agent")" "the busy worker's agent itself was paused"
  assert_equals S "$(proc_state "$light_cmd")" "a worker carrying less traffic was paused"
  assert_contains "$(cat "$H/sent.log")" "busy"$'\t'"Watchdog: the internet connection has been overloaded for 1 seconds (latency to 1.1.1.1 400 ms against a normal 40 ms), and your work carries the most traffic" "the busy worker was not told"
  assert_contains "$(wd poll)" "connection critical: overloaded for 1s (latency to 1.1.1.1 400 ms against a normal 40 ms), so the watchdog is pausing busy's commands" "firstmate was not told"
  assert_contains "$(tail -n 1 "$H/state/watchdog-history")" "topnet=busy:" "the history did not record the heaviest traffic"
  sleep 1.1
  set_latency 40 45
  FM_WATCHDOG_SAMPLE=1 FM_WATCHDOG_PAUSE_SECS=1 FM_WATCHDOG_RUN_SECS=1 wd tick
  assert_equals S "$(proc_state "$busy_cmd")" "a paused command was not continued"
  sleep 1.1
  FM_WATCHDOG_SAMPLE=1 FM_WATCHDOG_PAUSE_SECS=1 FM_WATCHDOG_RUN_SECS=1 wd tick
  assert_absent "$H/state/.watchdog-throttle-net" "the connection throttle outlived the overload"
  assert_contains "$(wd poll)" "connection recovered" "firstmate was not told of the release"
  pass "a connection overload pauses only the commands of the worker carrying the most traffic, loopback excluded, and releases on recovery"
}

test_overload_from_elsewhere_reports_once() {
  local out
  new_case cpuquiet
  set_mem 40
  printf 'critical_secs=1\n' >"$H/config/memory-gate"
  task_meta idle "$TMP_ROOT/cpuquiet/wt"
  set_cpu 80 12.00
  FM_WATCHDOG_SAMPLE=1 wd tick
  sleep 1.1
  FM_WATCHDOG_SAMPLE=1 wd tick
  FM_WATCHDOG_SAMPLE=1 wd tick
  out=$(wd poll)
  assert_contains "$out" "processor critical: overloaded for 1s (pressure 80.0%" "the overload was not reported"
  assert_contains "$out" "no worker of this home is using enough of it to throttle" "the report did not say the load comes from elsewhere"
  case "$out" in *";"*) fail "the overload from elsewhere was reported twice: $out" ;; esac
  pass "a processor overload no worker of this home causes is reported once per episode and throttles nothing"
}

test_poll_continues_commands_a_dead_loop_left_paused() {
  local start
  new_case orphan
  set_mem 40
  throttle_case orphan t8
  kill -STOP "$CMD"
  start=$(awk '{ print $22 }' "$P/$CMD/stat")
  printf 't8\tpaused\t%s\t%s\t%s\t%s:%s\n' $(($(date +%s) - 60)) $(($(date +%s) - 90)) "$AGENT" "$CMD" "$start" >"$H/state/.watchdog-throttle-cpu"
  wd poll >/dev/null
  assert_equals S "$(proc_state "$CMD")" "a command a dead loop left paused was not continued"
  pass "a poll continues commands whose pause a dead loop never ended"
}

test_history_explains_a_window() {
  local out base=1790960400 i t psi gate thr
  new_case history
  : >"$H/state/watchdog-history"
  for i in $(seq 0 59); do
    t=$((base + i * 15))
    # A 10-minute gap: the loop was not running.
    [ "$i" -lt 30 ] || t=$((t + 600))
    psi=5.0 gate=open thr=-
    if [ "$i" -ge 10 ] && [ "$i" -lt 40 ]; then psi=64.0 gate=closed thr=cpu:fm-research:paused; fi
    printf '%s\tmem=60\tpsi=%s\tload=9.30\tcores=8\tup=250\tdown=500\trtt=180\tbase=38\tgates=mem:open,cpu:%s,net:open\ttopcpu=fm-research:4.20\ttopnet=fm-research:300\tthrottle=%s\n' \
      "$t" "$psi" "$gate" "$thr" >>"$H/state/watchdog-history"
  done
  printf '%s\tprocessor critical: test event\n' $((base + 160)) >"$H/state/memory-watchdog.events"
  out=$(TZ=UTC wd history --since "$base" --until $((base + 1800))) || fail "history failed: $out"
  assert_contains "$out" "Watchdog history, " "no heading"
  assert_contains "$out" "(60 samples, about one every 15s)" "the sample count was wrong"
  assert_contains "$out" "Memory: 60% to 60% in use, 60% on average; the memory gate stayed open." "memory was not explained"
  assert_contains "$out" "Processor (8 cores): pressure averaged 35%, peaking at 64% at 17:02;" "processor pressure was not explained"
  assert_contains "$out" "load averaged 9.30, peaking at 9.30 (116% of the cores)" "load was not explained"
  assert_contains "$out" "New work was held back 17:02-17:20." "the processor gate's closure was not explained"
  assert_contains "$out" "Latency averaged 180 ms against a normal 38 ms" "latency was not explained"
  assert_contains "$out" "Busiest worker: fm-research used the most processor in 100% of the samples that measured it (up to 4.2 cores) and carried the most traffic in 100% (up to 300 KB/s)." "the busiest worker was not named"
  assert_contains "$out" "Throttle: fm-research was throttled for the processor 17:02-17:20." "the throttle was not explained"
  assert_contains "$out" "Gaps: no samples 17:07-17:17" "the gap was not explained"
  assert_contains "$out" "17:02  processor critical: test event" "the watchdog's actions were not listed"
  assert_contains "$out" "Timeline (5 minute steps):" "no timeline"
  assert_contains "$out" "  17:00  memory 60%  pressure 35%  load 9.3  up 250 KB/s  down 500 KB/s  latency 180 ms  busiest fm-research" "the timeline row was wrong"
  out=$(TZ=UTC wd history --since $((base - 7200)) --until $((base - 3600)))
  assert_contains "$out" "no samples in this window" "an empty window was not explained"
  wd history --since nonsense >/dev/null 2>&1
  expect_code 2 "$?" "an unreadable time"
  pass "history explains a time window in plain words: ranges, peaks, held-back work, the busiest worker, throttles, gaps, actions, and a timeline"
}

test_history_window_may_run_past_now() {
  local out now zone
  new_case histnow
  now=$(date +%s)
  # A zone where it is about noon, so the window never crosses midnight.
  zone="FMT$(($(TZ=UTC date -d "@$now" +%-H) - 12))"
  printf '%s\tmem=77\tpsi=5.0\n' $((now - 120)) >"$H/state/watchdog-history"
  out=$(TZ=$zone wd history --since "$(TZ=$zone date -d "@$((now - 600))" +%H:%M)" \
    --until "$(TZ=$zone date -d "@$((now + 900))" +%H:%M)") || fail "a window running past now was refused: $out"
  assert_contains "$out" "(1 samples" "the window running past now lost the latest sample"
  assert_not_contains "$out" "to $(TZ=$zone date -d "@$((now + 900))" +%H:%M)" "the window was not cut off at now"
  pass "a history window that runs past now, such as during a slowdown, ends at now"
}

test_history_reads_zones_whose_offset_has_a_leading_zero() {
  local out base=1790960400
  new_case histzone
  printf '%s\tmem=77\tpsi=5.0\n' $((base + 60)) >"$H/state/watchdog-history"
  # Offsets such as +0900 and -0800 must not be read as invalid octal numbers.
  out=$(TZ=FMT-9 wd history --since "$base" --until $((base + 600))) || fail "a +0900 zone was refused: $out"
  assert_contains "$out" "(1 samples" "a +0900 zone lost its sample"
  assert_contains "$out" "  02:01  memory 77%" "a +0900 zone placed the sample at the wrong time"
  out=$(TZ=FMT+8 wd history --since "$base" --until $((base + 600))) || fail "a -0800 zone was refused: $out"
  assert_contains "$out" "  09:01  memory 77%" "a -0800 zone placed the sample at the wrong time"
  pass "history reads zone offsets with a leading zero, such as +0900 and -0800"
}

test_history_window_may_cross_midnight() {
  local out now secs zone
  new_case histmidnight
  now=$(date +%s)
  # A zone where it is now about 00:20, just after the window ends.
  secs=$(((now % 86400 - 1200 + 86400) % 86400))
  zone="FMT+$((secs / 3600)):$(printf '%02d' $((secs % 3600 / 60)))"
  printf '%s\tmem=77\tpsi=5.0\n' $((now - 1200)) >"$H/state/watchdog-history"
  out=$(TZ=$zone wd history --since 23:50 --until 00:10) || fail "a window crossing midnight was refused: $out"
  assert_contains "$out" "(1 samples" "the window crossing midnight lost its sample"
  assert_contains "$out" "23:50 to 00:10" "the window crossing midnight was not read as one"
  pass "a history window from before midnight to after it reads as one window"
}

test_history_rotates_at_its_size_limit() {
  local i
  new_case rotate
  set_mem 40
  printf 'history_kb=1\n' >"$H/config/memory-gate"
  for i in $(seq 1 12); do printf '%s\tmem=1\tpadding=%s\n' "$i" "$(printf 'x%.0s' $(seq 1 80))"; done >"$H/state/watchdog-history"
  FM_WATCHDOG_SAMPLE=1 wd tick
  [ -f "$H/state/watchdog-history.1" ] || fail "the history was not rotated past history_kb"
  FM_WATCHDOG_SAMPLE=1 wd tick
  sleep 1.1
  FM_WATCHDOG_SAMPLE=1 wd tick
  [ "$(wc -c <"$H/state/watchdog-history")" -lt 1024 ] || fail "the fresh history file was not started small"
  assert_contains "$(wd status)" "history: " "status did not report the history"
  pass "the history rotates to one previous file at history_kb, so it stays bounded"
}

test_processor_and_connection_config() {
  local out rc
  new_case loadconfig
  set_mem 40
  printf 'cpu_close=20\ncpu_reopen=30\n' >"$H/config/memory-gate"
  out=$(wd admit c1 2>&1)
  rc=$?
  expect_code 1 "$rc" "admission under an inverted processor config"
  assert_contains "$out" "cpu_reopen < cpu_close < cpu_critical" "the processor config error did not explain itself"
  printf 'latency_host=bad/host\n' >"$H/config/memory-gate"
  assert_contains "$(wd admit c1 2>&1)" "latency_host must be a host or interface name" "a bad host was accepted"
  printf 'processor=off\nconnection=off\nlatency_host=9.9.9.9\nload_close=150\nload_critical=200\n' >"$H/config/memory-gate"
  set_cpu 99 40.00
  set_latency 40 900
  wd admit c1 || fail "processor=off and connection=off still gated"
  out=$(wd status)
  assert_contains "$out" "processor gate: off (config/memory-gate processor=off)" "status did not show the processor switched off"
  assert_contains "$out" "connection gate: off (config/memory-gate connection=off)" "status did not show the connection switched off"
  assert_contains "$out" "closes at pressure 25% or load 150% of cores" "configured load lines were not applied"
  pass "config/memory-gate validates and tunes the processor and connection lines and can switch each off"
}

test_admission_counts_reservations
test_reservations_expire
test_hysteresis
test_swap_exhaustion_closes_gate
test_override_admits_and_reserves
test_unavailable_meminfo_admits_with_warning
test_config_validation
test_critical_stops_largest_heavy_job_only
test_critical_skips_subtree_holding_an_agent
test_critical_with_nothing_to_stop_reports_once
test_browser_ceiling_stops_a_ballooning_browser_alone
test_job_ceiling_stops_an_oversized_test_run
test_room_event_for_deferred_work
test_queue_orders_flagship_first
test_loop_runs_only_while_work_exists
test_spawn_defers_and_overrides
test_room_event_names_a_deferred_relaunch
test_job_size_is_pss_with_rss_fallback
test_tick_protects_while_the_gate_lock_is_held
test_poll_trim_keeps_later_events
test_processor_gate_defers_and_reopens
test_connection_gate_follows_latency_above_normal
test_latency_probe_is_harvested_by_the_next_tick
test_processor_throttle_lowers_priority_then_pauses_then_releases
test_connection_throttle_pauses_the_heaviest_traffic_only
test_overload_from_elsewhere_reports_once
test_poll_continues_commands_a_dead_loop_left_paused
test_history_explains_a_window
test_history_window_may_run_past_now
test_history_reads_zones_whose_offset_has_a_leading_zero
test_history_window_may_cross_midnight
test_history_rotates_at_its_size_limit
test_processor_and_connection_config
echo "# all fm-memory-watchdog tests passed"
