#!/usr/bin/env bash
# usage: scenario.sh <repo-root> <label>
# Real worker flow: fm-brief.sh renders the status-append command, a zsh worker runs
# it with a Windows path, then firstmate runs the real wake drain.
R=$1; LABEL=$2
. "$R/tests/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot nul-e2e-$LABEL)
dir=$(make_case e2e); state="$dir/state"; home="$dir/home"
FM_HOME="$home" "$R/bin/fm-brief.sh" winpath some-proj --mode no-mistakes >/dev/null
append=$(grep -o '`\(echo\|printf\) [^`]*"{state}[^`]*`' "$home/data/winpath/brief.md" | head -1 | tr -d '`')
echo "\$ brief status command: $append"
status="$state/winpath.status"
printf 'note: bootstrap cursor line\n' > "$status"
FM_STATE_OVERRIDE="$state" "$R/bin/fm-wake-drain.sh" >/dev/null 2>&1
cmd=${append//\{state\}/needs-decision}; cmd=${cmd//<epoch>/1790000000}
cmd=${cmd//\{one short line\}/'save report to C:\Users\ollys\0work\new\report.txt?'}
cmd=${cmd//$(printf '%q' "$home/state/winpath.status")/$status}; cmd=${cmd//"'$home/state/winpath.status'"/$status}; cmd=${cmd//"$home/state/winpath.status"/$status}
echo "\$ zsh -c <status command>   (worker writes a Windows path)"
zsh -c "$cmd"
echo "\$ od -c winpath.status (last line)"; tail -1 "$status" | od -c | head -6
append_wake "$state" signal winpath.status "signal: winpath.status"
echo "\$ fm-wake-drain.sh   (stderr shown inline)"
FM_STATE_OVERRIDE="$state" "$R/bin/fm-wake-drain.sh" 2>&1 | grep -E 'null byte|winpath|warning' 
echo "\$ fm-wake-drain.sh (second drain, stderr)"
FM_STATE_OVERRIDE="$state" "$R/bin/fm-wake-drain.sh" 2>&1 >/dev/null | grep -E 'null byte|warning' || echo "(no warnings)"
