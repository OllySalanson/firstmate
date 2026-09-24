#!/usr/bin/env bash
# Print a bin script's usage: its leading header comment block.
# Usage: fm-help.sh <script-path>
# Scripts without their own help path call this on -h or --help, so the
# header comment stays the single owner of their usage text.
set -eu

case "${1:-}" in -h|--help) set -- "${BASH_SOURCE[0]}" ;; esac

[ "$#" -eq 1 ] || { echo "usage: fm-help.sh <script-path>" >&2; exit 2; }
awk 'NR == 1 && /^#!/ { next }
  /^#/ { if ($0 ~ /^# *shellcheck /) next; sub(/^# ?/, ""); print; next }
  { exit }' "$1"
