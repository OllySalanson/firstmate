#!/usr/bin/env bash
# tests/fake-tmux-list-panes.sh - the `list-panes` answer for a fake tmux.
#
# bin/fm-tmux-lib.sh's fm_tmux_pane_read turns every recorded tmux target into
# an exact pane with one `tmux list-panes` read, and later commands address that
# pane by its `%<id>`. A fake tmux that answers the pane reads a suite cares
# about through its own `display-message` arm hands `list-panes` to this script
# instead of re-deriving that row format, as the first line of the fake:
#
#   [ "${1:-}" != list-panes ] || exec "$FM_TEST_FAKE_TMUX_LIST_PANES" "$0" "$@"
#
# tests/lib.sh exports FM_TEST_FAKE_TMUX_LIST_PANES. The first argument is the
# fake itself; the rest are the `list-panes` arguments as the fake received them.
# A fake written as a shell function passes `-` instead, and then every named
# pane exists and reads empty.
# The pane exists exactly when the fake's own `display-message -p -t <target>
# <format>` succeeds, and that call's output is the value, so a fake keeps one
# source of truth for both whether a pane is alive and what it reads; only a
# `#{pane_id}` read is answered from the listing's own pane id.
#
# A window target is echoed back as `<session>:<window>`. A whole-session
# listing reports the windows the fake's `list-windows` names, or one active
# window named `fake` when it names none. Each pane id is `%` followed by the
# octal bytes of its `<session>:<window>`, so a pane id always leads back to the
# window it was resolved from and the fake sees that window again when the id
# is read. A bare `@<window-id>` target is encoded and read back the same way. Two lookup modes let a suite and a fake use the same encoding:
#   fake-tmux-list-panes.sh --pane-id <session>:<window>   the pane id
#   fake-tmux-list-panes.sh --target-of %<id>              the window target
set -u

encode() {  # <session:window>
  local text=$1 out='' byte i
  local LC_ALL=C
  for ((i = 0; i < ${#text}; i++)); do
    printf -v byte '%03o' "'${text:i:1}"
    out=$out$byte
  done
  printf '%%%s\n' "$out"
}

decode() {  # %<id>
  local digits=${1#%} out='' byte
  case "$digits" in ''|*[!0-7]*) return 1 ;; esac
  [ $(( ${#digits} % 3 )) -eq 0 ] || return 1
  while [ -n "$digits" ]; do
    byte=${digits%"${digits#???}"}
    digits=${digits#???}
    # shellcheck disable=SC2059
    printf -v byte "\\$byte"
    out=$out$byte
  done
  printf '%s\n' "$out"
}

case "${1:-}" in
  --pane-id) encode "${2:?}"; exit 0 ;;
  --target-of) decode "${2:?}"; exit ;;
esac

fake=${1:?fake-tmux-list-panes: the fake tmux path is required}
shift
[ "${1:-}" = list-panes ] && shift
session_scope=0 target='' format=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -s) session_scope=1 ;;
    -t) target=${2-}; shift ;;
    -F) format=${2-}; shift ;;
  esac
  shift
done
tab=$(printf '\t')
# The caller's own format is the last field of the row format.
value_format=${format##*"$tab"=}

row() {  # <session> <window> <index> <window-active> <read-target> [window-id]
  local pane value wid=${6:-@$3}
  case "$5" in
    @*) pane=$(encode "$5") ;;
    *) pane=$(encode "$1:$2") ;;
  esac
  if [ "$fake" = - ]; then
    value=
  else
    value=$("$fake" display-message -p -t "$5" "$value_format" 2>/dev/null) || return 1
  fi
  [ "$value_format" != '#{pane_id}' ] || value=$pane
  # `$0` is the literal session id tmux would print.
  # shellcheck disable=SC2016
  printf '$0\t=%s\t%s\t%s\t%s\t=%s\t%s\t1\t0\t=%s\n' "$1" "$pane" "$wid" "$3" "$2" "$4" "$value"
}

case "$target" in
  %*)
    window_target=$(decode "$target") || { echo "can't find pane: $target" >&2; exit 1; }
    case "$window_target" in
      @*) row fake fake 0 1 "$window_target" "$window_target" ;;
      *) row "${window_target%%:*}" "${window_target#*:}" 0 1 "$window_target" ;;
    esac || { echo "can't find pane: $target" >&2; exit 1; }
    ;;
  @*)
    row fake fake 0 1 "$target" "$target" || { echo "can't find window: $target" >&2; exit 1; }
    ;;
  *:=*)
    session=${target%%:*}
    session=${session#=}
    window=${target#*:=}
    row "$session" "$window" 0 1 "$session:$window" \
      || { echo "can't find window: $window" >&2; exit 1; }
    ;;
  *:)
    [ "$session_scope" -eq 1 ] || exit 1
    session=${target%:}
    session=${session#=}
    windows=
    [ "$fake" = - ] \
      || windows=$("$fake" list-windows -t "=$session" -F '#{window_name}' 2>/dev/null) || windows=
    [ -n "$windows" ] || windows=fake
    index=0 found=0
    while IFS= read -r window; do
      # A fake that always prints the `-a` form names its windows session-first.
      window=${window#"$session":}
      [ -n "$window" ] || continue
      active=0
      [ "$index" -ne 0 ] || active=1
      if row "$session" "$window" "$index" "$active" "$session:$window"; then
        found=1
      fi
      index=$((index + 1))
    done <<EOF
$windows
EOF
    [ "$found" -eq 1 ] || { echo "can't find session: $session" >&2; exit 1; }
    ;;
  *) echo "can't find window: $target" >&2; exit 1 ;;
esac
