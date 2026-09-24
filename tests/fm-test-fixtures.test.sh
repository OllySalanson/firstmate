#!/usr/bin/env bash
# Behavior tests for tests/lib.sh primitives and tests/fixtures.sh builders.
#
# Cases call shared primitives directly or write stubs into a fakebin and exec
# them as a test would. Assertions are on observable output, exit status, and
# filesystem effects - never on helper source text. Migrated spawn suites cover
# fm_test_run_spawn through the real fm-spawn.sh; this file pins the shared
# primitives and stubs those suites use.
#
# It is also the fixture Git-config isolation regression, with host signing
# armed on a scratch config file: it drives every entry point that must reach
# tests/git-config-helpers.sh - the shared helpers, bin/fm-test-run.sh's
# per-suite wrapper, and the standalone scripts runnable without a live vendor.
# That helper's header owns the contract and the layers it leaves in force.
# It is likewise the tmux server isolation regression for
# tests/tmux-isolation-helpers.sh, through the runner and tests/lib.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-test-fixtures)

test_git_config_isolation() (
  local dir="$TMP_ROOT/git-config" helper jobs timeout fakebin rc
  mkdir -p "$dir/runner/bin" "$dir/runner/tests"
  git init -q "$dir/caller"
  git -C "$dir/caller" config commit.gpgsign false
  cd "$dir/caller" || exit 1
  cp "$ROOT/bin/fm-test-run.sh" "$ROOT/bin/fm-timeout-lib.sh" "$dir/runner/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$dir/runner/tests/"
  cp "$ROOT/tests/tmux-isolation-helpers.sh" "$dir/runner/tests/"
  fakebin=$(fm_fakebin "$dir/standalone")
  fm_fake_exit0 "$fakebin" pi
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${1:-}" != list-panes ] || exec "$FM_TEST_FAKE_TMUX_LIST_PANES" "$0" "$@"
while [ "$#" -gt 0 ]; do
  if [ "$1" = -c ]; then
    git -C "$2" log -1 --format=%s > "${FM_TEST_STANDALONE_COMMIT:?}"
    exit 1
  fi
  shift
done
SH
  chmod +x "$fakebin/tmux"
  cat > "$dir/runner/tests/fm-test-run.test.sh" <<'SH'
#!/usr/bin/env bash
set -eu
repo=$(mktemp -d "${TMPDIR:-/tmp}/fm-git-runner.XXXXXX")
trap 'rm -rf "$repo"' EXIT
git init -q "$repo"
git -C "$repo" config user.name 'Runner Fixture'
git -C "$repo" config user.email runner@example.invalid
git -C "$repo" commit -q --allow-empty -m initial
[ "$(git -C "$repo" log -1 --format='%s:%an:%ae')" = 'initial:Runner Fixture:runner@example.invalid' ]
[ "$(git -C "$repo" config --get fixture.input)" = preserved ]
[ "$(GIT_CONFIG_GLOBAL="$FM_TEST_GIT_CONFIG" git config --global --get commit.gpgsign)" = true ]
SH
  chmod +x "$dir/runner/tests/fm-test-run.test.sh"
  export GIT_CONFIG_GLOBAL="$dir/global" GIT_CONFIG_SYSTEM="$dir/system"
  export GIT_CONFIG_NOSYSTEM=0
  unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS

  # A failing signer exposes inherited config without requiring GPG or keys.
  arm_host_signing() {  # <scope>: only this layer carries the failing signer
    : > "$dir/global"
    : > "$dir/system"
    git config --file "$dir/$1" commit.gpgsign true
    git config --file "$dir/$1" gpg.format openpgp
    git config --file "$dir/$1" gpg.program /usr/bin/false
    cp "$dir/$1" "$dir/expected"
  }

  assert_helper_isolates() {  # <helper> <scope>
    bash -eus -- "$ROOT/tests/$1.sh" "$dir/$2-$1" "$dir/$2" <<'SH' || exit 1
. "$1"
fm_git_init_commit "$2"
[ "$(git -C "$2" log -1 --format=%s)" = initial ] || fail "fixture has no initial commit"
fm_git_identity
# Child Git processes and direct commits inherit the same isolation.
bash -eu -c 'git -C "$1" commit -q --allow-empty -m child' _ "$2"
# Repository-local config and explicit command inputs remain authoritative.
git -C "$2" config commit.gpgsign true
git -C "$2" config gpg.program /usr/bin/false
if git -C "$2" commit -q --allow-empty -m signed > "$2/signing.log" 2>&1; then
  fail "repository-local signing config was ignored"
fi
assert_grep 'gpg failed to sign' "$2/signing.log" "local signing was not attempted"
git -C "$2" -c commit.gpgsign=false commit -q --allow-empty -m explicit
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
  git -C "$2" commit -q --allow-empty -m environment
# A config test can deliberately supply its own global file after sourcing.
[ "$(GIT_CONFIG_GLOBAL="$3" git config --global --get commit.gpgsign)" = true ] || fail "explicit global config was ignored"
SH
  }

  assert_host_config_still_governs() {  # <scope>
    # Sourcing in test subprocesses cannot change the caller or its config files.
    [ "$(git config --"$1" --get commit.gpgsign)" = true ] || fail "caller lost signing preference"
    cmp -s "$dir/$1" "$dir/expected" || fail "host config file was changed"
    git init -q "$dir/$1-outside"
    if git -C "$dir/$1-outside" -c user.name=test -c user.email=test@example.invalid \
      commit -q --allow-empty -m outside > "$dir/outside.log" 2>&1; then
      fail "commit outside fixtures bypassed signing"
    fi
    assert_grep 'gpg failed to sign' "$dir/outside.log" "outside commit did not attempt signing"
  }

  # Every fixture entry point, once. Each only has to reach the shared helper;
  # which layers that helper neutralizes is the helper's own property, settled
  # by the system-layer case below.
  arm_host_signing global
  for helper in lib fixtures secondmate-helpers wake-helpers; do
    assert_helper_isolates "$helper" global
  done
  bash -eus -- "$ROOT/tests/herdr-test-safety.sh" "$dir/global-herdr" <<'SH' || exit 1
. "$1"
git init -q "$2"
git -C "$2" -c user.name=test -c user.email=test@example.invalid \
  commit -q --allow-empty -m initial
[ "$(git -C "$2" log -1 --format=%s)" = initial ]
SH
  for jobs in 1 2; do
    for timeout in 0 30; do
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=fixture.input GIT_CONFIG_VALUE_0=preserved \
        FM_TEST_GIT_CONFIG="$dir/global" \
        "$dir/runner/bin/fm-test-run.sh" --jobs "$jobs" --per-script-timeout-secs "$timeout" \
        tests/fm-test-run.test.sh > "$dir/runner.log" 2>&1 \
        || fail "runner inherited global config (jobs=$jobs, timeout=$timeout): $(cat "$dir/runner.log")"
      assert_grep 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0' "$dir/runner.log" \
        "runner did not execute the Git fixture"
    done
  done
  rc=0
  FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 FM_SESSIONSTART_INSTRUCTION_REFRESH_REF=HEAD \
    FM_SESSIONSTART_INSTRUCTION_REFRESH_EXPECT=updated \
    FM_TEST_STANDALONE_COMMIT="$dir/global-standalone-commit" PATH="$fakebin:$PATH" \
    bash "$ROOT/tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh" \
    > "$dir/standalone.log" 2>&1 || rc=$?
  [ "$rc" = 1 ] || fail "standalone fixture did not stop at the tmux launch"
  assert_grep 'could not start isolated Pi session' "$dir/standalone.log" \
    "standalone fixture failed before the tmux launch: $(cat "$dir/standalone.log")"
  [ "$(cat "$dir/global-standalone-commit")" = 'test: initial instruction contract' ] \
    || fail "standalone fixture did not create its initial commit"
  bash "$ROOT/tests/fm-gitignore-config.test.sh" > "$dir/gitignore.log" 2>&1 \
    || fail "standalone gitignore fixture inherited global config: $(cat "$dir/gitignore.log")"
  assert_host_config_still_governs global

  # The system layer is the shared helper's other half: one entry point settles
  # it, and the caller still signing proves the layer was genuinely armed.
  arm_host_signing system
  assert_helper_isolates lib system
  assert_host_config_still_governs system

  pass "runner and shared helpers isolate host Git config and preserve explicit config and outside commits"
)

# A suite started from inside a tmux pane must not reach that pane's server, even
# with a bare `tmux kill-server`. The "host" server here is a private stand-in
# placed where an inherited TMUX and TMUX_TMPDIR would both lead a bare tmux, so
# a broken guard kills the stand-in rather than anything real.
test_tmux_server_isolation() (
  local dir="$TMP_ROOT/tmux-isolation" real host_dir host_sock host_pid probe private leftover
  real=$(command -v tmux) || { echo "# tmux not installed; host-server isolation not exercised"; return 0; }
  host_dir=$(mktemp -d /tmp/fm-host.XXXXXX) || fail "could not create the host stand-in directory"
  host_sock="$host_dir/tmux-$(id -u)/default"
  trap 'env -u TMUX -u TMUX_PANE "$real" -S "$host_sock" kill-server >/dev/null 2>&1; rm -rf "$host_dir"' EXIT
  mkdir -m 700 "$host_dir/tmux-$(id -u)"
  env -u TMUX -u TMUX_PANE "$real" -S "$host_sock" -f /dev/null new-session -d -s host 'sleep 600' \
    || fail "could not start the host stand-in server"
  host_pid=$(env -u TMUX -u TMUX_PANE "$real" -S "$host_sock" display-message -p '#{pid}')
  host_alive() { env -u TMUX -u TMUX_PANE "$real" -S "$host_sock" has-session -t =host 2>/dev/null; }

  mkdir -p "$dir/runner/bin" "$dir/runner/tests"
  git init -q "$dir/caller"
  cd "$dir/caller" || exit 1
  cp "$ROOT/bin/fm-test-run.sh" "$ROOT/bin/fm-timeout-lib.sh" "$dir/runner/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$ROOT/tests/tmux-isolation-helpers.sh" "$dir/runner/tests/"
  cat > "$dir/runner/tests/fm-tmux-probe.test.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n%s\n' "${TMUX-unset}" "${TMUX_TMPDIR-unset}" > "$FM_TEST_TMUX_PROBE"
tmux kill-server >/dev/null 2>&1
tmux -L default kill-server >/dev/null 2>&1
tmux -L leftover -f /dev/null new-session -d -s left 'sleep 600' || exit 1
tmux -L leftover display-message -p '#{pid}' >> "$FM_TEST_TMUX_PROBE"
SH
  probe="$dir/probe"
  TMUX="$host_sock,$host_pid,0" TMUX_PANE=%0 TMUX_TMPDIR="$host_dir" FM_TEST_TMUX_PROBE="$probe" \
    "$dir/runner/bin/fm-test-run.sh" tests/fm-tmux-probe.test.sh > "$dir/runner.log" 2>&1 \
    || fail "runner did not run the tmux probe: $(cat "$dir/runner.log")"
  host_alive || fail "a suite run by the runner killed the tmux server it was started under"
  [ "$(sed -n 1p "$probe")" = unset ] || fail "the runner passed TMUX to its suite"
  private=$(sed -n 2p "$probe")
  case "$private" in
    unset|"$host_dir") fail "the runner did not give its suite a private TMUX_TMPDIR (got '$private')" ;;
  esac
  [ ! -e "$private" ] || fail "the runner left its private tmux directory behind: $private"
  leftover=$(sed -n 3p "$probe")
  case "$leftover" in ''|*[!0-9]*) fail "the probe did not start its leftover server" ;; esac
  ! kill -0 "$leftover" 2>/dev/null || fail "the runner left a suite's tmux server running (pid $leftover)"

  # Expansion is intentionally deferred to the child bash.
  # shellcheck disable=SC2016
  TMUX="$host_sock,$host_pid,0" TMUX_PANE=%0 TMUX_TMPDIR="$host_dir" \
    env -u FM_TEST_TMUX_TMPDIR -u FM_TEST_LIB_SOURCED bash -c '
      . "$1"
      [ -z "${TMUX+x}" ] || fail "tests/lib.sh kept TMUX"
      [ "$TMUX_TMPDIR" != "$2" ] || fail "tests/lib.sh kept the inherited TMUX_TMPDIR"
      tmux kill-server >/dev/null 2>&1
      true' _ "$ROOT/tests/lib.sh" "$host_dir" \
    || fail "tests/lib.sh did not isolate tmux"
  host_alive || fail "a suite sourcing tests/lib.sh killed the tmux server it was started under"
  pass "runner and tests/lib.sh keep every suite's tmux off the server it was started under"
)

test_touch_epoch_preserves_repeated_dst_hour() {
  local TZ=Europe/Paris epoch path actual
  export TZ
  for epoch in 1761438600 1761442200; do
    fm_touch_epoch "$epoch" "$TMP_ROOT/epoch-one" "$TMP_ROOT/epoch two"
    for path in "$TMP_ROOT/epoch-one" "$TMP_ROOT/epoch two"; do
      actual=$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null) \
        || fail "could not read fixture mtime for $path"
      [ "$actual" = "$epoch" ] \
        || fail "fm_touch_epoch should preserve epoch $epoch, got $actual"
    done
  done
  pass "fm_touch_epoch preserves both epochs in the repeated DST hour"
}

test_no_mistakes_version_constant() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/nm")
  fm_test_fake_no_mistakes "$fakebin"
  out=$("$fakebin/no-mistakes" --version)
  [ "$out" = "$FM_TEST_NO_MISTAKES_FAKE_VERSION" ] || \
    fail "fake no-mistakes --version should be the shared constant, got '$out'"
  out=$(FM_FAKE_NO_MISTAKES_VERSION="$FM_TEST_NO_MISTAKES_FAKE_VERSION_TS" \
    "$fakebin/no-mistakes" --version)
  [ "$out" = "$FM_TEST_NO_MISTAKES_FAKE_VERSION_TS" ] || \
    fail "timestamped banner override should round-trip, got '$out'"
  case "$out" in
    "$FM_TEST_NO_MISTAKES_FAKE_VERSION "*) ;;
    *) fail "timestamped banner '$out' is not the shared constant plus a suffix" ;;
  esac
  out=$(FM_FAKE_NO_MISTAKES_VERSION='no-mistakes version v9.9.9 (fake)' \
    "$fakebin/no-mistakes" --version)
  [ "$out" = 'no-mistakes version v9.9.9 (fake)' ] || \
    fail "FM_FAKE_NO_MISTAKES_VERSION should override the default banner, got '$out'"
  "$fakebin/no-mistakes" doctor
  expect_code 0 $? "fake no-mistakes non-version verbs should exit 0"
  pass "fake no-mistakes --version is the shared constant and overridable"
}

test_no_mistakes_init_doctor_markers() {
  local fakebin dir rc
  dir="$TMP_ROOT/nm-init"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_no_mistakes_init_doctor "$fakebin"
  ( cd "$dir" && "$fakebin/no-mistakes" init )
  assert_present "$dir/.no-mistakes-init" "init did not touch the marker"
  ( cd "$dir" && "$fakebin/no-mistakes" doctor )
  assert_present "$dir/.no-mistakes-doctor" "doctor did not touch the marker"
  rc=0
  ( cd "$dir" && "$fakebin/no-mistakes" axi ) || rc=$?
  expect_code 2 "$rc" "unknown no-mistakes verb should exit 2"
  pass "init/doctor no-mistakes stub touches markers and refuses other verbs"
}

test_fake_gh_and_gh_axi() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/gh")
  fm_test_fake_gh "$fakebin"
  fm_test_fake_gh_axi "$fakebin"
  "$fakebin/gh" auth status
  expect_code 0 $? "fake gh auth status should succeed"
  "$fakebin/gh" pr list
  expect_code 0 $? "fake gh other verbs should exit 0"
  out=$("$fakebin/gh-axi" --version)
  [ "$out" = "$FM_TEST_GH_AXI_VERSION" ] || \
    fail "fake gh-axi --version should be $FM_TEST_GH_AXI_VERSION, got '$out'"
  out=$(FM_FAKE_GH_AXI_VERSION=0.9.9 "$fakebin/gh-axi" --version)
  [ "$out" = 0.9.9 ] || fail "FM_FAKE_GH_AXI_VERSION should override, got '$out'"
  pass "fake gh authenticates and fake gh-axi reports the shared version"
}

test_spawn_tmux_and_fakebin() {
  local fakebin out log
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn" gh-axi)
  log="$TMP_ROOT/spawn/launch.log"
  : > "$log"
  out=$(FM_FAKE_PANE_PATH=/tmp/wt "$fakebin/tmux" display-message -p '#{pane_current_path}')
  [ "$out" = /tmp/wt ] || fail "spawn tmux pane path should be FM_FAKE_PANE_PATH, got '$out'"
  out=$(unset FM_FAKE_PANE_PATH; "$fakebin/tmux" display-message -p '#{pane_current_path}')
  [ -z "$out" ] || fail "spawn tmux pane path should default to empty, got '$out'"
  out=$("$fakebin/tmux" display-message -p '#S')
  [ "$out" = firstmate ] || fail "spawn tmux session name should be firstmate, got '$out'"
  FM_FAKE_LAUNCH_LOG="$log" "$fakebin/tmux" send-keys -t @w -l 'codex --yolo'
  assert_grep 'codex --yolo' "$log" "send-keys -l payload was not logged"
  [ -x "$fakebin/treehouse" ] || fail "spawn fakebin should include treehouse"
  [ -x "$fakebin/gh-axi" ] || fail "extra exit-0 tools should land in the spawn fakebin"
  "$fakebin/treehouse" get
  expect_code 0 $? "fake treehouse should exit 0"
  pass "spawn fakebin answers pane path, logs -l payloads, and installs extra tools"
}

test_send_stubs_and_ssh() {
  local fakebin log ssh_log out
  fakebin=$(make_stubs "$TMP_ROOT/send")
  log="$TMP_ROOT/send/send.log"
  ssh_log="$TMP_ROOT/send/ssh.log"
  : > "$log"
  fm_test_fake_ssh "$fakebin"
  FM_SEND_LOG="$log" "$fakebin/tmux" send-keys -t sess:w -l 'hello steer'
  assert_grep 'hello steer' "$log" "send stubs did not log the -l payload"
  out=$("$fakebin/tmux" display-message -p '#{cursor_y}')
  [ "$out" = 1 ] || fail "send tmux cursor_y should be 1, got '$out'"
  out=$("$fakebin/tmux" capture-pane -p)
  case "$out" in
    *'╭────╮'*) ;;
    *) fail "send tmux capture-pane should render an empty composer, got '$out'" ;;
  esac
  printf 'ignored\n' | FM_SSH_LOG="$ssh_log" "$fakebin/fake-ssh" host -- cmd
  assert_grep 'host -- cmd' "$ssh_log" "fake ssh did not record argv"
  FM_FAKE_SSH_RC=7 "$fakebin/fake-ssh" x < /dev/null
  expect_code 7 $? "fake ssh should honor FM_FAKE_SSH_RC"
  pass "send stubs log typed text and fake ssh records argv with a controllable exit"
}

test_spawn_home_layout() {
  local home="$TMP_ROOT/home"
  fm_test_spawn_home "$home" claude
  fm_test_spawn_brief "$home" t1 'do the thing'
  assert_present "$home/data" "spawn home missing data/"
  assert_present "$home/state/.last-watcher-beat" "spawn home missing watcher beat"
  assert_grep claude "$home/config/crew-harness" "crew-harness was not pinned"
  assert_grep 'do the thing' "$home/data/t1/brief.md" "brief text was not written"
  pass "spawn-home layout writes harness pin, beat, and brief"
}

test_git_config_isolation || fail "Git fixture config isolation"
test_tmux_server_isolation || fail "tmux server isolation"
test_touch_epoch_preserves_repeated_dst_hour
test_no_mistakes_version_constant
test_no_mistakes_init_doctor_markers
test_fake_gh_and_gh_axi
test_spawn_tmux_and_fakebin
test_send_stubs_and_ssh
test_spawn_home_layout
