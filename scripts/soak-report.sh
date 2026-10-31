#!/bin/bash
# Read-only soak report for the live GhostTrace recorder. Usage: scripts/soak-report.sh [path/to/ghosttrace]
# Only reads: launchctl print, ps, stat, and the ghosttrace CLI (status, events). Never signals or restarts anything.
# shortcut: parses the CLI's text output (no jq), so a changed `status`/`events` format breaks it; switch to --json then.
LABEL=com.amoghkhairate.GhostTrace.recorder
HOME_DIR="$HOME/Library/Application Support/GhostTrace"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GT="${1:-}"
if [ -z "$GT" ]; then
  for c in "$ROOT/.build/release/ghosttrace" "$ROOT/.build/debug/ghosttrace"; do [ -x "$c" ] && GT="$c" && break; done
fi
[ -x "$GT" ] || { echo "ghosttrace CLI not found; pass its path or run: swift build -c release --product ghosttrace" >&2; exit 1; }

# [[dd-]hh:]mm:ss[.ss] -> seconds
secs() { awk -v t="$1" 'BEGIN { d = 0; if (t ~ /-/) { split(t, a, "-"); d = a[1]; t = a[2] }
  n = split(t, p, ":"); s = p[n] + 0; if (n > 1) s += p[n-1] * 60; if (n > 2) s += p[n-2] * 3600; printf "%.2f", s + d * 86400 }'; }
size() { stat -f %z "$1" 2>/dev/null | awk '{ printf "%.1f MB (%d B)", $1 / 1048576, $1 }'; }

echo "== GhostTrace soak report  $(date '+%Y-%m-%d %H:%M:%S %z')  (cli: $GT)"

LD="$(launchctl print "gui/$(id -u)/$LABEL" 2>&1)"
STATUS="$("$GT" status 2>&1)"
PID="$(printf '%s\n' "$LD" | awk '/^\tpid = / { print $3 }')"
[ -n "$PID" ] || PID="$(printf '%s\n' "$STATUS" | sed -n 's/.*(pid \([0-9]*\),.*/\1/p')"

echo "-- launchd"
printf '%s\n' "$LD" | awk -F' = ' '/^\t(state|runs|pid|last exit code|last terminating signal) = / { sub(/^\t/, "", $1); printf "  %s: %s\n", $1, $2 }'
[ -n "$PID" ] || { echo "  recorder not running"; printf '%s\n' "$STATUS" | sed 's/^/  /'; exit 1; }
echo "  cli pid: $(printf '%s\n' "$STATUS" | sed -n 's/.*(pid \([0-9]*\),.*/\1/p')"

echo "-- process $PID"
read -r ETIME CPUT RSS < <(ps -o etime=,time=,rss= -p "$PID")
START="$(ps -o lstart= -p "$PID")"
EL="$(secs "$ETIME")"; CP="$(secs "$CPUT")"
echo "  started: $START   elapsed: $ETIME ($EL s)"
awk -v cp="$CP" -v el="$EL" -v rss="$RSS" 'BEGIN {
  pct = el > 0 ? cp / el * 100 : 0; mb = rss / 1024
  printf "  cpu time: %s s   lifetime avg: %.3f%% of one core   [target <1%%: %s]\n", cp, pct, (pct < 1 ? "PASS" : "FAIL")
  printf "  rss: %.1f MB   [target <50 MB: %s]\n", mb, (mb < 50 ? "PASS" : "FAIL") }'

echo "-- database"
for f in events.sqlite events.sqlite-wal events.sqlite-shm; do printf '  %-18s %s\n' "$f" "$(size "$HOME_DIR/$f")"; done
printf '%s\n' "$STATUS" | grep -E ' events, oldest ' | sed 's/^ */  /'
OLDEST="$(printf '%s\n' "$STATUS" | sed -n 's/.*oldest \([0-9-]* [0-9:]* [+-][0-9:]*\),.*/\1/p' | sed 's/\([+-][0-9][0-9]\):\([0-9][0-9]\)$/\1\2/')"
OLD_EPOCH="$(date -j -f '%Y-%m-%d %H:%M:%S %z' "$OLDEST" +%s 2>/dev/null)"
if [ -n "$OLD_EPOCH" ]; then
  DBSZ="$(stat -f %z "$HOME_DIR/events.sqlite")"
  awk -v b="$DBSZ" -v s="$OLD_EPOCH" -v n="$(date +%s)" 'BEGIN { d = (n - s) / 86400; printf "  growth: %.0f KB/day over %.2f days since oldest event (oldest may be imported power log, not recorded)\n", b / d / 1024, d }'
fi

echo "-- events, last 24h, by kind"
OUT="" ; CUR=()
while :; do
  PAGE="$("$GT" events --last 24h --limit 1000 ${CUR[@]+"${CUR[@]}"} 2>&1)" || { echo "  events failed: $PAGE"; break; }
  OUT="$OUT"$'\n'"$PAGE"
  N="$(printf '%s\n' "$PAGE" | sed -n 's/^More events: add --cursor //p')"
  [ -n "$N" ] || break
  CUR=(--cursor "$N")
done
printf '%s\n' "$OUT" | awk '$1 ~ /^20[0-9][0-9]-/ { c[$4]++; t++ } END { for (k in c) printf "  %-17s %d\n", k, c[k]; printf "  %-17s %d\n", "TOTAL", t }' | sort
