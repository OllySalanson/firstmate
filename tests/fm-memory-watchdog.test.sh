#!/usr/bin/env bash
# bin/fm-memory-watchdog.sh owns worker admission against a memory gate with
# hysteresis and reservations, the critical-line stop of the single largest
# heavy job under a recorded task worktree, the flagship-first dispatch order,
# and the watcher-surfaced events. Every case fakes /proc (meminfo plus process
# entries); the process entries for the critical line are bound to real `sleep`
# processes so the stop is observed, never assumed.
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
    "$WD" "$@"
}

cat >"$TMP_ROOT/fake-send" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "$2" >>"$FM_HOME/sent.log"
SH
chmod +x "$TMP_ROOT/fake-send"

# fake_proc <pid> <ppid> <rss-kb> <cwd> <argv...>
fake_proc() {
  local pid=$1 ppid=$2 rss=$3 cwd=$4
  shift 4
  mkdir -p "$P/$pid"
  printf '%s\0' "$@" >"$P/$pid/cmdline"
  printf 'Name:\t%s\nState:\tS (sleeping)\nPid:\t%s\nPPid:\t%s\nVmRSS:\t%s kB\n' \
    "${1##*/}" "$pid" "$ppid" "$rss" >"$P/$pid/status"
  printf '%s (%s) S %s 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 4242 0 0\n' \
    "$pid" "${1##*/}" "$ppid" >"$P/$pid/stat"
  ln -sfn "$cwd" "$P/$pid/cwd"
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
  assert_contains "$out" "memory-watchdog: critical line: memory reached 96% (critical 95%), so the watchdog stopped t1's heaviest job 'node vitest.mjs run' (about 3.0 GB)" "firstmate was not given the stop"
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
  out=$(FM_MEMORY_PROC_ROOT="$P" FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" FM_MEMORY_WATCHDOG_IDLE_EXIT=1 \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off --memory-override)
  rc=$?
  expect_code 0 "$rc" "an overridden spawn"$'\n'"$out"
  assert_contains "$out" "spawned $id" "the override did not launch"
  assert_contains "$(cat "$case_dir/launch.log")" "plugin:pdf-viewer:pdf" "the worker launch does not deny the PDF viewer helper"
  pid=$(cat "$home/state/.memory-watchdog.lock/pid" 2>/dev/null || true)
  [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null
  out=$(FM_MEMORY_PROC_ROOT="$P" fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" --relaunch --memory-override)
  assert_contains "$out" "--memory-override applies only to fresh ship and scout spawns" "a relaunch accepted the override"
  pass "fm-spawn defers a fresh spawn over the gate, admits it on --memory-override, and never gates relaunch"
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
  assert_contains "$out" "job ceiling: stopped t4's headless browser 'headless_shell --headless' at about 2.0 GB (ceiling 1.5 GB)" "firstmate was not told of the ceiling stop"
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
echo "# all fm-memory-watchdog tests passed"
