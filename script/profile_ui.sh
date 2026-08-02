#!/usr/bin/env bash
set -euo pipefail

# Runs the UI performance harness end to end and prints a stats summary.
#
# Builds and stages the dev app, relaunches it with RUNWAY_UI_PROFILE=1 so the in-app driver
# (see Sources/Runway/Support/UIProfiler.swift) walks the popover through scripted phases —
# cold open, 12 warm open/close cycles, 10 screen switches, 10 caret toggles, a forced refresh
# with the panel open, and a 40s idle soak — then aggregates the phase timings from the app log.
#
# Usage: script/profile_ui.sh [--skip-build]
# Compare the output against the baseline recorded in docs/debugging.md before shipping
# changes that touch the popover render path.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$HOME/Library/Logs/Runway/Runway.log"
APP_BINARY="$ROOT_DIR/dist/Runway.app/Contents/MacOS/Runway"

if [ "${1:-}" != "--skip-build" ]; then
    "$ROOT_DIR/script/build_and_run.sh" build
fi
[ -x "$APP_BINARY" ] || { echo "error: $APP_BINARY not staged; run without --skip-build" >&2; exit 1; }

pkill -x Runway >/dev/null 2>&1 || true
sleep 1

# Start the run on a fresh log file: a Runway.log near its 10 MB rotation cap could rotate the
# marker (or the run itself) into Runway.1.log mid-run, and the polls below only read the active
# file. The app is down at this point, so the move is safe; the prior log stays inspectable.
mkdir -p "$(dirname "$LOG")"
[ -f "$LOG" ] && mv -f "$LOG" "$LOG.pre-profile"

# Marker so the stats only cover this run.
START_MARKER="profile_ui.sh run $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "$(date -u +%Y-%m-%dT%H:%M:%S.000Z) [INFO] [uiprofile] $START_MARKER" >> "$LOG"

# CLAUDE_CONFIG_DIR must not leak into the app's shell snapshot (it flips Claude account
# resolution); `open` can't pass env vars, so exec the binary directly.
env -u CLAUDE_CONFIG_DIR RUNWAY_UI_PROFILE=1 "$APP_BINARY" >/dev/null 2>&1 &
APP_PID=$!
echo "==> Runway (pid $APP_PID) profiling; the script takes ~2 minutes"

for _ in $(seq 1 240); do
    if grep -a -A100000 "$START_MARKER" "$LOG" | grep -aq "PHASE done"; then
        break
    fi
    sleep 2
done
grep -a -A100000 "$START_MARKER" "$LOG" | grep -aq "PHASE done" || { echo "error: run never reached PHASE done" >&2; exit 1; }

RUN_LOG="$(mktemp -t runway_ui_profile)"
grep -a -A100000 "$START_MARKER" "$LOG" | grep -a uiprofile > "$RUN_LOG"

echo
echo "== Open path (ms) =="
grep -a -E "open\.(layoutSubtree|orderFront|syncTotal|toFirstFrame)" "$RUN_LOG" \
    | sed -E 's/.*uiprofile\] //' \
    | awk -F'[:m]' '{sum[$1]+=$2; n[$1]++; if($2>max[$1])max[$1]=$2}
        END {for(k in sum) printf "%-24s avg %6.1f  max %6.1f  n=%d\n", k, sum[k]/n[k], max[k], n[k]}' \
    | sort
echo
echo "== Close path (ms) =="
grep -a "close.syncTotal" "$RUN_LOG" | sed -E 's/.*: //; s/ms//' \
    | awk '{s+=$1;n++; if($1>m)m=$1} END {if (n) printf "close.syncTotal          avg %6.1f  max %6.1f  n=%d\n", s/n, m, n}'
echo
echo "== Main-queue stalls (>50ms) per phase =="
awk '/PHASE/{p=$0; sub(/.*uiprofile\] /,"",p)} /STALL/{c[p]++; ms=$NF; sub(/ms/,"",ms); s[p]+=ms}
    END {for(k in c) printf "%-42s %3d stalls %7dms total\n", k, c[k], s[k]}' "$RUN_LOG" | sort
echo
echo "== Process at end of run =="
ps -o cputime=,rss= -p "$APP_PID" | awk '{printf "cpu %s  rss %.0fMB\n", $1, $2/1024}'

pkill -x Runway >/dev/null 2>&1 || true
echo
echo "full phase log: $RUN_LOG"
