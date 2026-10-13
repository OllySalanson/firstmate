#!/usr/bin/env bash
# Contract: parsed .no-mistakes.yaml must leave commands.test absent or empty.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_require_host_tool "parse .no-mistakes.yaml as YAML" ruby
NM="$ROOT/.no-mistakes.yaml"

test_nm_has_no_deterministic_test_command() {
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
cmds = doc["commands"] || {}
val = cmds.is_a?(Hash) ? cmds["test"] : nil
puts (val.nil? || val == false || val == "") ? "" : val.inspect
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  if [ -n "$val" ]; then
    fail "commands.test must be absent or empty so Test stays intent-targeted; got: $val"
  fi
  pass "no-mistakes does not configure commands.test"
}

test_nm_has_no_deterministic_test_command
