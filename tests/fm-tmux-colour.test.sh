#!/usr/bin/env bash
# tests/fm-tmux-colour.test.sh - worker window colours from config/tmux-colours
# (bin/fm-tmux-colour-lib.sh).
#
# The rule cases drive the library against a REAL tmux server, isolated by
# tests/lib.sh, and read the window options back from tmux. The spawn cases
# drive bin/fm-spawn.sh end to end with the shared fake tmux and assert what it
# asked tmux to set. Relaunch colouring is pinned in
# tests/fm-control-relaunch.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-colour-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tmux-colour)
mkdir -p "$TMP_ROOT"

# --- rule cases against real tmux ---------------------------------------------

HAVE_TMUX=0
if command -v tmux >/dev/null 2>&1; then
  HAVE_TMUX=1
  tmux -f /dev/null new-session -d -s colours -n base || fail "could not start the isolated tmux server"
fi

# new_window <name>: a fresh window, printing its stable id.
new_window() {
  tmux new-window -dP -F '#{window_id}' -t colours: -n "$1"
}

window_style() {  # <window-id> <option>
  tmux show-window-options -v -t "$1" "$2" 2>/dev/null
}

# apply_case <name> <task-id> <project> <config-lines...>: apply the rules to a
# fresh window; sets CASE_WID, CASE_ERR (stderr), and CASE_RC.
apply_case() {
  local name=$1 id=$2 project=$3 cfg="$TMP_ROOT/$1/config"
  shift 3
  mkdir -p "$cfg"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$cfg/tmux-colours"
  fi
  CASE_WID=$(new_window "fm-$id") || fail "could not create a window for $name"
  CASE_RC=0
  CASE_ERR=$(fm_tmux_colour_apply "$CASE_WID" "$id" "$project" "$cfg" 2>&1 >/dev/null) || CASE_RC=$?
}

test_absent_file_changes_nothing() {
  apply_case absent rr-a ready-reckoner
  expect_code 0 "$CASE_RC" "an absent file"
  assert_equals "" "$CASE_ERR" "an absent file must be silent"
  assert_equals "" "$(window_style "$CASE_WID" window-status-style)" "an absent file must not colour the window"
  pass "an absent config/tmux-colours leaves the window uncoloured and silent"
}

test_prefix_rule_beats_project_rule() {
  apply_case prefix clerk-reader ready-reckoner \
    '# project colours' 'project ready-reckoner colour28' 'prefix clerk- colour130' 'prefix rr-clerk- colour130'
  expect_code 0 "$CASE_RC" "a prefix rule"
  assert_equals "" "$CASE_ERR" "valid rules must be silent"
  assert_equals "fg=colour130,bold" "$(window_style "$CASE_WID" window-status-style)" \
    "a prefix rule must win over a project rule listed earlier"
  assert_equals "bg=colour130,fg=colour231,bold" "$(window_style "$CASE_WID" window-status-current-style)" \
    "the selected tab must carry the colour as its background"
  pass "a matching prefix rule beats an earlier project rule"
}

test_project_rule_applies_without_prefix_match() {
  apply_case project rr-quote-fix ready-reckoner \
    'prefix rr-clerk- colour130' 'project ready-reckoner colour28'
  assert_equals "fg=colour28,bold" "$(window_style "$CASE_WID" window-status-style)" \
    "a project rule must apply when no prefix matches"
  pass "a project rule colours a task no prefix rule matches"
}

test_unmatched_task_stays_uncoloured() {
  apply_case unmatched cc-x customer-care 'project ready-reckoner colour28'
  assert_equals "" "$CASE_ERR" "no match must be silent"
  assert_equals "" "$(window_style "$CASE_WID" window-status-style)" "an unmatched task must stay uncoloured"
  pass "a task no rule matches stays uncoloured"
}

test_hex_colour_is_accepted() {
  apply_case hex fm-x firstmate 'project firstmate #8a8a8a'
  assert_equals "" "$CASE_ERR" "a hex colour must be accepted"
  assert_contains "$(window_style "$CASE_WID" window-status-style)" "fg=#8a8a8a" "a hex colour must apply"
  pass "a #rrggbb colour is accepted"
}

test_bad_colour_on_matching_rule_launches_uncoloured() {
  apply_case badcolour clerk-y ready-reckoner 'prefix clerk- colour256' 'project ready-reckoner colour28'
  expect_code 0 "$CASE_RC" "a bad colour must never fail"
  assert_contains "$CASE_ERR" "line 1: 'colour256' is not a tmux colour" "a bad colour must be reported"
  assert_equals 1 "$(printf '%s\n' "$CASE_ERR" | grep -c .)" "a bad colour must be reported exactly once"
  assert_equals "" "$(window_style "$CASE_WID" window-status-style)" \
    "a matching rule with a bad colour must leave the window uncoloured, not fall through"
  pass "a matching rule with a bad colour reports once and stays uncoloured"
}

test_malformed_lines_are_reported_and_skipped() {
  apply_case malformed rr-z ready-reckoner 'colour ready-reckoner colour28' 'project ready-reckoner' 'project ready-reckoner colour28'
  expect_code 0 "$CASE_RC" "malformed lines must never fail"
  assert_contains "$CASE_ERR" "line 1: unknown rule 'colour'" "an unknown rule must be reported"
  assert_contains "$CASE_ERR" "line 2: expected" "a short line must be reported"
  assert_equals 2 "$(printf '%s\n' "$CASE_ERR" | grep -c .)" "each malformed line must be reported once"
  assert_equals "fg=colour28,bold" "$(window_style "$CASE_WID" window-status-style)" \
    "a valid rule must still apply past malformed lines"
  pass "malformed lines are reported once each and skipped"
}

test_style_injection_is_refused() {
  apply_case inject rr-i ready-reckoner 'project ready-reckoner red,blink'
  assert_contains "$CASE_ERR" "is not a tmux colour" "a style fragment must be refused as a colour"
  assert_equals "" "$(window_style "$CASE_WID" window-status-style)" "a refused colour must not reach tmux"
  pass "a colour carrying extra style syntax is refused"
}

if [ "$HAVE_TMUX" = 1 ]; then
  test_absent_file_changes_nothing
  test_prefix_rule_beats_project_rule
  test_project_rule_applies_without_prefix_match
  test_unmatched_task_stays_uncoloured
  test_hex_colour_is_accepted
  test_bad_colour_on_matching_rule_launches_uncoloured
  test_malformed_lines_are_reported_and_skipped
  test_style_injection_is_refused
  tmux kill-server >/dev/null 2>&1 || true
else
  echo "skip: tmux not found; rule cases need a real tmux server"
fi

# --- end to end through fm-spawn ----------------------------------------------

# spawn_case <name> <id> [config-lines...]: a fresh ship spawn of <id> from a
# project directory named ready-reckoner; sets SPAWN_OUT, SPAWN_RC, OPT_LOG.
spawn_case() {
  local name=$1 id=$2 dir home proj wt fakebin
  shift 2
  dir="$TMP_ROOT/spawn-$name"
  home="$dir/home"
  proj="$dir/ready-reckoner"
  wt="$dir/wt"
  OPT_LOG="$dir/window-options"
  fakebin=$(make_spawn_fakebin "$dir/fake")
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$home/config/tmux-colours"
  fi
  : > "$OPT_LOG"
  SPAWN_RC=0
  SPAWN_OUT=$(FM_FAKE_WINDOW_OPTION_LOG="$OPT_LOG" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off) || SPAWN_RC=$?
}

test_spawn_colours_the_new_window() {
  spawn_case colour clerk-e2e 'project ready-reckoner colour28' 'prefix clerk- colour130'
  expect_code 0 "$SPAWN_RC" "a spawn with a colour rule"$'\n'"$SPAWN_OUT"
  assert_grep "window-status-style fg=colour130,bold" "$OPT_LOG" "a fresh spawn should colour its window"
  assert_grep "window-status-current-style bg=colour130,fg=colour231,bold" "$OPT_LOG" \
    "a fresh spawn should colour its selected tab"
  pass "fm-spawn colours a fresh tmux window from config/tmux-colours"
}

test_spawn_without_config_sets_no_colour() {
  spawn_case none rr-e2e
  expect_code 0 "$SPAWN_RC" "a spawn without a colour file"$'\n'"$SPAWN_OUT"
  assert_no_grep "window-status" "$OPT_LOG" "an absent file must not colour the window"
  assert_not_contains "$SPAWN_OUT" "tmux-colours" "an absent file must be silent"
  pass "fm-spawn without config/tmux-colours behaves as before"
}

test_spawn_with_bad_colour_still_launches() {
  spawn_case bad rr-bad 'project ready-reckoner irishgreen'
  expect_code 0 "$SPAWN_RC" "a bad colour must not fail the spawn"$'\n'"$SPAWN_OUT"
  assert_equals 1 "$(printf '%s\n' "$SPAWN_OUT" | grep -c "'irishgreen' is not a tmux colour")" \
    "a bad colour must be reported exactly once"
  assert_no_grep "window-status" "$OPT_LOG" "a bad colour must launch uncoloured"
  [ -f "$TMP_ROOT/spawn-bad/home/state/rr-bad.meta" ] || fail "the spawn should still record the task"
  pass "fm-spawn reports a bad colour once and launches uncoloured"
}

test_spawn_colours_the_new_window
test_spawn_without_config_sets_no_colour
test_spawn_with_bad_colour_still_launches
