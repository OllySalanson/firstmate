#!/usr/bin/env bash
# tests/tmux-isolation-helpers.sh - keep every test's tmux off the host's real
# tmux server.
#
# Source this before a suite's first tmux command:
#   # shellcheck source=tests/tmux-isolation-helpers.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/tmux-isolation-helpers.sh"
#
# A suite launched from inside a tmux pane inherits TMUX, and a bare `tmux`
# command then talks to that pane's server: one stray `tmux kill-server` in a
# test once killed the operator's firstmate and every live worker with it.
# Sourcing this unsets TMUX and TMUX_PANE and points TMUX_TMPDIR at a private
# directory, so a bare `tmux`, and a `tmux -L <name>`, can only reach a server
# on a socket inside that directory. An explicit `tmux -S <path>` still goes
# exactly where the suite says, which is what a suite that builds its own socket
# path relies on.
#
# The directory lives directly under /tmp rather than under TMPDIR because a
# Unix socket path is limited to about 104 bytes on macOS, and tmux appends
# tmux-<uid>/<socket-name> to it.
#
# bin/fm-test-run.sh sources this per suite in run_script_bounded, and
# tests/lib.sh sources it for every suite that uses it, so a hand-run suite is
# isolated too. A source that finds the directory an outer source already
# exported reuses it; the source that created the directory owns its cleanup
# through fm_test_tmux_isolation_cleanup, which stops any server a suite left on
# a socket there, addressing each socket by its explicit path, then removes the
# directory. tests/fm-test-fixtures.test.sh is the regression.

unset TMUX TMUX_PANE
if [ -n "${FM_TEST_TMUX_TMPDIR:-}" ] && [ "${TMUX_TMPDIR:-}" = "$FM_TEST_TMUX_TMPDIR" ] \
  && [ -d "$FM_TEST_TMUX_TMPDIR" ] && [ ! -L "$FM_TEST_TMUX_TMPDIR" ]; then
  FM_TEST_TMUX_TMPDIR_OWNER=
else
  FM_TEST_TMUX_TMPDIR=$(mktemp -d /tmp/fm-tmux.XXXXXX) || return 1
  FM_TEST_TMUX_TMPDIR_OWNER=$$
fi
TMUX_TMPDIR=$FM_TEST_TMUX_TMPDIR
export TMUX_TMPDIR FM_TEST_TMUX_TMPDIR

# fm_test_tmux_isolation_cleanup: stop and remove the private tmux directory,
# only from the shell whose source created it.
fm_test_tmux_isolation_cleanup() {
  local sock
  [ "${FM_TEST_TMUX_TMPDIR_OWNER:-}" = "$$" ] || return 0
  [ -d "$FM_TEST_TMUX_TMPDIR" ] || return 0
  if command -v tmux >/dev/null 2>&1; then
    for sock in "$FM_TEST_TMUX_TMPDIR"/tmux-*/*; do
      [ -S "$sock" ] || continue
      env -u TMUX -u TMUX_PANE tmux -S "$sock" kill-server >/dev/null 2>&1 || true
    done
  fi
  rm -rf "$FM_TEST_TMUX_TMPDIR"
}
