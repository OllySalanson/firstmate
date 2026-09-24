#!/usr/bin/env bash
# Behavior tests for the --help contract on every executable bin/ entrypoint.
#
# The bug this pins: fm-send.sh --help refused with "target --help is not
# resolvable", and fm-bootstrap.sh --help ran a full bootstrap, so the header
# comment was reachable only by reading the source. Every executable non-library
# bin script must answer -h and --help by printing its usage to stdout and
# exiting 0 without creating anything in its home, working directory, or HOME.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-help)

entrypoints() {
  local f
  for f in "$ROOT"/bin/*.sh; do
    [ -x "$f" ] || continue
    case "$f" in *-lib.sh) continue ;; esac
    printf '%s\n' "$f"
  done
}

test_every_entrypoint_answers_help_without_side_effects() {
  local f flag scratch out code count=0
  while IFS= read -r f; do
    for flag in --help -h; do
      scratch="$TMP_ROOT/$(basename "$f" .sh)$flag"
      mkdir -p "$scratch"
      code=0
      out=$(cd "$scratch" && HOME="$scratch" FM_HOME="$scratch" timeout 20 "$f" "$flag" </dev/null 2>/dev/null) || code=$?
      expect_code 0 "$code" "$(basename "$f") $flag"
      [ -n "$out" ] || fail "$(basename "$f") $flag printed no usage on stdout"
      [ -z "$(ls -A "$scratch")" ] || fail "$(basename "$f") $flag created $(ls -A "$scratch" | tr '\n' ' ')"
    done
    count=$((count + 1))
  done < <(entrypoints)
  [ "$count" -gt 0 ] || fail "no bin entrypoints found"
  pass "all $count bin entrypoints answer --help and -h on stdout with exit 0 and no side effects"
}

test_send_help_prints_its_usage() {
  local out
  out=$("$ROOT/bin/fm-send.sh" --help) || fail "fm-send.sh --help exited nonzero"
  assert_contains "$out" "Usage: fm-send.sh <target>" "fm-send.sh --help prints its usage line"
  pass "fm-send.sh --help prints its usage instead of resolving --help as a target"
}

test_sourced_script_ignores_callers_help_argument() {
  local out
  out=$(bash -c 'root=$1; shift; . "$root/bin/fm-harness.sh"; echo sourced-continued' _ "$ROOT" --help 2>/dev/null)
  assert_contains "$out" "sourced-continued" "sourcing a script with a caller --help argument must not print help and exit"
  pass "the help path fires only when a script is executed, never when sourced"
}

test_remote_entrypoint_answers_help_through_installed_symlink() {
  local link_dir out flag
  link_dir="$TMP_ROOT/symlink-bin"
  mkdir -p "$link_dir"
  ln -s "$ROOT/bin/fm-remote-entrypoint.sh" "$link_dir/fm-remote-entrypoint.sh"
  for flag in --help -h; do
    out=$("$link_dir/fm-remote-entrypoint.sh" "$flag" 2>/dev/null) || fail "fm-remote-entrypoint.sh $flag via symlink exited nonzero"
    assert_contains "$out" "Fixed remote entrypoint for bin/fm-on.sh." "fm-remote-entrypoint.sh $flag via symlink prints its usage"
  done
  pass "fm-remote-entrypoint.sh answers --help and -h when run through its installed symlink"
}

test_every_entrypoint_answers_help_without_side_effects
test_remote_entrypoint_answers_help_through_installed_symlink
test_send_help_prints_its_usage
test_sourced_script_ignores_callers_help_argument
