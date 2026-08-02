#!/usr/bin/env bash
set -euo pipefail

# Runs the Memory-window UI performance harness end to end and prints a stats summary.
#
# Builds and stages the dev app, relaunches it with RUNWAY_UI_PROFILE_MEMORY=1 so the in-app driver
# (see Sources/Runway/Support/UIProfiler.swift, startMemoryDriverIfEnabled) walks the Memory
# Explorer through scripted phases — cold open with the initial scan, 6 close/open cycles (each a
# full store rebuild by design), 12 file-document selection switches, 6 database-row loads, 3
# re-scans, and a 10s idle soak — then aggregates the phase timings from the app log.
#
# Usage: script/profile_memory_ui.sh [--skip-build]
# Compare the output against the baseline recorded in docs/debugging.md before shipping changes
# that touch the Memory window's render or load paths.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$HOME/Library/Logs/Runway/Runway.log"
APP_BINARY="$ROOT_DIR/dist/Runway.app/Contents/MacOS/Runway"

if [ "${1:-}" != "--skip-build" ]; then
    "$ROOT_DIR/script/build_and_run.sh" build
fi
[ -x "$APP_BINARY" ] || { echo "error: $APP_BINARY not staged; run without --skip-build" >&2; exit 1; }

pkill -x Runway >/dev/null 2>&1 || true
sleep 1

# Fresh log file so the run cannot rotate its own markers away mid-run (see profile_ui.sh).
mkdir -p "$(dirname "$LOG")"
[ -f "$LOG" ] && mv "$LOG" "$LOG.pre-profile.$(date +%Y%m%d-%H%M%S)"

START_MARKER="profile_memory_ui.sh run $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "$(date -u +%Y-%m-%dT%H:%M:%S.000Z) [INFO] [uiprofile] $START_MARKER" >> "$LOG"

# CLAUDE_CONFIG_DIR must not leak into the app's shell snapshot (it flips Claude account
# resolution and would also skew which memory homes the scan sees); `open` can't pass env vars,
# so exec the binary directly.
env -u CLAUDE_CONFIG_DIR RUNWAY_UI_PROFILE_MEMORY=1 "$APP_BINARY" >/dev/null 2>&1 &
APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null || true' EXIT
trap 'exit 130' INT TERM
echo "==> Runway (pid $APP_PID) profiling the Memory window; the script takes ~1.5 minutes"

for _ in $(seq 1 180); do
    if grep -a -A100000 "$START_MARKER" "$LOG" | grep -aq "PHASE done"; then
        break
    fi
    sleep 2
done
grep -a -A100000 "$START_MARKER" "$LOG" | grep -aq "PHASE done" || { echo "error: run never reached PHASE done" >&2; exit 1; }

RUN_LOG="$(mktemp -t runway_memory_ui_profile)"
grep -a -A100000 "$START_MARKER" "$LOG" | grep -a uiprofile > "$RUN_LOG"

# A phase that silently did no work must fail the run, not masquerade as a clean result.
if grep -aq "ERROR memory driver aborted" "$RUN_LOG"; then
    echo "error: the Memory window never produced a store — check the app log" >&2
    exit 1
fi
if grep -aq "ERROR selection phase skipped" "$RUN_LOG"; then
    echo "error: the selection phase found fewer than 2 file documents — this Mac has no memory files to profile against" >&2
    exit 1
fi
if grep -aq "ERROR scan never finished" "$RUN_LOG"; then
    echo "error: a scan never finished (or found nothing) within its 30s budget" >&2
    exit 1
fi

echo
echo "== Timings (ms), by phase =="
# One aggregate per (phase, key): the cold open's buildWindow+scan must not average into the warm
# cycles', and a file load during the selection phase must not mix with one during warm cycles.
sed -E 's/.*uiprofile\] //; s/ms$//' "$RUN_LOG" \
    | awk -F': ' '
        /^PHASE /{ phase = substr($0, 7); sub(/ \(.*/, "", phase); next }
        $1 ~ /^(memoryOpen|memory)\./ && NF == 2 && phase != "" {
            key = sprintf("%-16s %s", phase, $1)
            sum[key] += $2; n[key]++
            if ($2 + 0 > max[key]) max[key] = $2
        }
        END { for (k in sum) printf "%-44s avg %7.1f  max %7.1f  n=%d\n", k, sum[k]/n[k], max[k], n[k] }' \
    | sort
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
