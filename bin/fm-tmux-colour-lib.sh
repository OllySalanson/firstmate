#!/usr/bin/env bash
# bin/fm-tmux-colour-lib.sh - colour a tmux worker window by task or project.
#
# Sourced by bin/fm-spawn.sh, which calls fm_tmux_colour_apply once a tmux
# endpoint for a crewmate, scout, or secondmate exists: on a fresh spawn and on
# every relaunch (adopted or re-created window). Other backends never call it.
# The caller must already have sourced bin/fm-tmux-lib.sh (the tmux backend
# adapter does), whose fm_tmux_exact_pane resolves the window to colour.
#
# The optional, captain-private config/tmux-colours file holds one rule per
# line; blank lines and lines starting with `#` are ignored:
#
#   prefix <task-id-prefix> <colour>
#   project <project-name> <colour>
#
# Every `prefix` rule is checked before any `project` rule, in file order, and
# the first rule that matches decides. A prefix rule matches a task id that
# starts with its value; a project rule matches the basename of the spawn's
# project directory exactly (for a secondmate, the basename of its home). So
# `prefix clerk- colour130` beats `project ready-reckoner colour28` for a
# clerk-* task cloned from the ready-reckoner repo.
#
# <colour> is a tmux colour: colour0-colour255 (or color0-color255), #rrggbb,
# or one of default, black, red, green, yellow, blue, magenta, cyan, white and
# their bright* forms. A matched window gets
#   window-status-style          fg=<colour>,bold
#   window-status-current-style  bg=<colour>,fg=colour231,bold
# so the tab carries the colour whether or not it is the selected window.
#
# An absent file changes nothing. A colour setting never fails a spawn: a
# malformed line, an unknown colour, or a failed tmux call prints one warning
# per problem to stderr and the window launches uncoloured. A matching rule
# whose colour is invalid ends the lookup uncoloured rather than falling
# through to a later rule. The file is inherited into secondmate homes from the
# primary (bin/fm-config-inherit-lib.sh), so a secondmate's own crewmates are
# coloured by the same rules.

# fm_tmux_colour_valid <colour>: 0 when tmux accepts <colour> as a colour that
# is safe to splice into a style string (no comma, space, or other syntax).
fm_tmux_colour_valid() {  # <colour>
  local c=${1-} n
  case "$c" in
    colour[0-9]|colour[0-9][0-9]|colour[0-9][0-9][0-9]|color[0-9]|color[0-9][0-9]|color[0-9][0-9][0-9])
      n=${c#colour}
      n=${n#color}
      [ "$((10#$n))" -le 255 ]
      return
      ;;
    '#'[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) return 0 ;;
    default|black|red|green|yellow|blue|magenta|cyan|white) return 0 ;;
    brightblack|brightred|brightgreen|brightyellow|brightblue|brightmagenta|brightcyan|brightwhite) return 0 ;;
  esac
  return 1
}

# fm_tmux_colour_resolve <file> <task-id> <project-name>: print the colour the
# rules give this task, or nothing. Warns on stderr once per malformed line and
# once for a matching rule whose colour is invalid. Always returns 0.
fm_tmux_colour_resolve() {  # <file> <task-id> <project-name>
  local file=$1 id=$2 project=$3 line kind value colour extra n=0
  local prefix_hit='' prefix_colour='' prefix_line='' project_hit='' project_colour='' project_line=''
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    kind='' value='' colour='' extra=''
    read -r kind value colour extra <<EOF
$line
EOF
    case "$kind" in ''|'#'*) continue ;; esac
    if [ -z "$colour" ] || [ -n "$extra" ]; then
      echo "warning: config/tmux-colours line $n: expected '<prefix|project> <value> <colour>'; line ignored" >&2
      continue
    fi
    case "$kind" in
      prefix)
        if [ -z "$prefix_hit" ] && [ "${id#"$value"}" != "$id" ]; then
          prefix_hit=1 prefix_colour=$colour prefix_line=$n
        fi
        ;;
      project)
        if [ -z "$project_hit" ] && [ "$project" = "$value" ]; then
          project_hit=1 project_colour=$colour project_line=$n
        fi
        ;;
      *)
        echo "warning: config/tmux-colours line $n: unknown rule '$kind' (use prefix or project); line ignored" >&2
        continue
        ;;
    esac
    fm_tmux_colour_valid "$colour" ||
      echo "warning: config/tmux-colours line $n: '$colour' is not a tmux colour (use colour0-colour255, #rrggbb, or a colour name)" >&2
  done < "$file"
  if [ -n "$prefix_hit" ]; then
    colour=$prefix_colour n=$prefix_line
  elif [ -n "$project_hit" ]; then
    colour=$project_colour n=$project_line
  else
    return 0
  fi
  # The invalid colour was already reported when its line was read.
  fm_tmux_colour_valid "$colour" && printf '%s\n' "$colour"
  return 0
}

# fm_tmux_colour_apply <target> <task-id> <project-name> <config-dir>: colour
# the exact tmux window holding <target> when <config-dir>/tmux-colours has a
# rule for this task. Always returns 0; see the header for the warning contract.
fm_tmux_colour_apply() {  # <target> <task-id> <project-name> <config-dir>
  local target=$1 id=$2 project=$3 file=$4/tmux-colours colour pane
  [ -e "$file" ] || return 0
  colour=$(fm_tmux_colour_resolve "$file" "$id" "$project")
  [ -n "$colour" ] || return 0
  if ! pane=$(fm_tmux_exact_pane "$target"); then
    echo "warning: could not colour window for $id: no tmux pane for $target" >&2
    return 0
  fi
  if ! tmux set-window-option -t "$pane" window-status-style "fg=$colour,bold" >/dev/null 2>&1 ||
    ! tmux set-window-option -t "$pane" window-status-current-style "bg=$colour,fg=colour231,bold" >/dev/null 2>&1; then
    echo "warning: could not colour window for $id: tmux refused colour '$colour'" >&2
  fi
  return 0
}
