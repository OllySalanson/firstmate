#!/usr/bin/env bash
# E2E against the REAL /proc: a real process named headless_shell running in a
# recorded task worktree balloons to ~400 MB; the watchdog tick (browser ceiling
# 200 MB) must stop it and notify its worker, while total memory is fine.
set -u
WT=${WT:?}
REPO=${REPO:?}
S=$(mktemp -d /tmp/fm-mem-e2e.XXXXXX)
H=$S/home; mkdir -p "$H/state" "$H/config" "$H/data" "$S/wt"
printf 'window=fm:e2e1\nworktree=%s\nkind=ship\nharness=claude\n' "$S/wt" > "$H/state/e2e1.meta"
printf 'browser_ceiling_mb=200\njob_ceiling_mb=3072\n' > "$H/config/memory-gate"
cat > "$S/send" <<'SH'
#!/usr/bin/env bash
printf 'NOTICE to %s: %s\n' "$1" "$2" >>"$FM_HOME/sent.log"
SH
chmod +x "$S/send"
wd() { FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_CONFIG_OVERRIDE="$H/config" FM_DATA_OVERRIDE="$H/data" \
  FM_MEMORY_SEND_CMD="$S/send" FM_MEMORY_STOP_GRACE=2 "$REPO/bin/fm-memory-watchdog.sh" "$@"; }
( cd "$S/wt" && exec -a headless_shell python3 -c 'import time; b=bytearray(400*1024*1024); b[::4096]=b"x"*len(b[::4096]); time.sleep(600)' --headless ) &
BR=$!
( cd "$S/wt" && exec -a headless_shell python3 -c 'import time; b=bytearray(50*1024*1024); b[::4096]=b"x"*len(b[::4096]); time.sleep(600)' --headless ) &
SMALL=$!
sleep 3
echo "\$ ps (before tick)"; ps -o pid,rss,args -p $BR,$SMALL
echo; echo "\$ fm-memory-watchdog.sh status"; wd status
echo; echo "\$ fm-memory-watchdog.sh tick"; wd tick; echo "(exit $?)"
sleep 3
echo; echo "\$ ps (after tick)"; ps -o pid,rss,args -p $BR,$SMALL || true
kill -0 $BR 2>/dev/null && echo "FAIL: ballooning browser survived" || echo "OK: ballooning browser ($BR) stopped"
kill -0 $SMALL 2>/dev/null && echo "OK: small browser ($SMALL) under ceiling left running" || echo "FAIL: small browser stopped"
echo; echo "\$ worker notice sent:"; cat "$H/sent.log"
echo; echo "\$ fm-memory-watchdog.sh poll   (what firstmate's watcher surfaces)"; mkdir -p "$H/state/.memory-watchdog.lock"; echo $$ > "$H/state/.memory-watchdog.lock/pid"; wd poll
echo; echo "--- admission against real meminfo ---"
echo "\$ admit w1"; wd admit w1; echo "(exit $?)"
printf 'close=2\nreopen=1\ncritical=99\n' > "$H/config/memory-gate"
echo "\$ admit w2 with close line forced to 2%"; wd admit w2; echo "(exit $?)"
echo "\$ admit w3 --override"; wd admit w3 --override; echo "(exit $?)"
echo; echo "\$ status"; wd status
kill -KILL $SMALL $BR 2>/dev/null; rm -rf "$S"
