# Performance

Runway forked from [OpenUsage](https://github.com/robinebers/openusage) and then rebuilt its hot
paths: incremental JSONL parsing, off-main launch discovery, coalesced refresh batches, a settled
popover render path, and launch pre-warming. This page records what those changes are worth,
measured head-to-head against the fork point.

## Results

Steady state (caches warm — normal daily use), measured 2026-08-02:

| Metric | OpenUsage (fork tip) | Runway | Ratio |
|---|---|---|---|
| Launch → menu bar icon visible | 5.4 s | 0.29 s | 18× faster |
| CPU spent in the first 30 s after launch | 21.3 s | 3.8 s | 5.6× less |
| Open the popup (warm) → first frame | 61 ms | 23 ms | 2.7× faster |
| First popup open after launch → first frame | 2.59 s | 44 ms | 59× faster |
| One refresh pass (all providers, wall time) | 8.6 s | 2.3 s | 3.7× faster |
| Main-thread stall time, 10 screen switches | 2.0 s | 0.7 s | 2.9× less |
| Main-thread stall time, 10 card expands | 6.6 s | 4.1 s | 1.6× less |
| Memory, steady state | 1.09 GB | 238 MB | 4.6× less |
| Memory, peak during the run | 2.6 GB | 322 MB | 8× less |

First launch on this machine's corpus (caches cold — what a new install pays once):

| Metric | OpenUsage (fork tip) | Runway | Ratio |
|---|---|---|---|
| CPU spent in the first 30 s | 165 s | 12.7 s | 13× less |
| Peak memory during the initial scan | 12.9 GB | 1.7 GB | 7.5× less |

## CodexBar (best effort)

[CodexBar](https://github.com/steipete/CodexBar) 0.46.0 (build 110, `7760f349`), installed via its
Homebrew cask and measured **as shipped** on the same machine and day — a different footing from
the OpenUsage comparison, so its column is deliberately partial:

- **No shared harness.** CodexBar's popup, refresh internals, and first-launch scan aren't
  externally measurable without instrumenting its source, so those rows are marked —.
- **Measured rows.** Launch → menu bar is the interval between two lines in its debug-level
  unified log (`log stream --level debug --predicate 'subsystem == "com.steipete.codexbar"'`):
  "CodexBar starting" and the first "[perf] refresh cycle: updateIcons()" entry — the earliest
  icon-render evidence its logs expose, so an upper-bound proxy rather than a first-frame
  measurement; 0.9–1.4 s across runs. Memory comes from `ps` sampling: ~250–365 MB steady
  depending on what its adaptive refresh has done recently, ~365 MB peak observed.
- **CPU rows are omitted, not hidden.** CodexBar gates work behind an adaptive refresh (it backs
  off to 30-minute cycles when idle), so its launch-window CPU swung 1.3–6.8 s between runs purely
  on which work the gate admitted — and Runway's swung similarly in the same windows because live
  agent sessions were actively growing the log corpus during measurement. Neither side's number
  would be honest.
- **Different scope.** CodexBar tracked its 3 enabled providers (Codex, Claude, Gemini) in its
  default configuration — it does offer usage/spend views of its own; Runway tracked 7 providers
  plus Total Spend over the same corpus. Where Runway still leads (launch, peak memory), it does
  so while watching more providers.

## Methodology

Both apps ran the same scripted workload on the same machine (Apple Silicon MacBook Pro,
macOS 26.5), against the same local data, minutes apart:

- **Same code lineage, fixed points.** Runway at `f752361` (the `main` tip after PRs #54–#59,
  2026-08-02) vs OpenUsage at its `main` tip (`9d2bf09`, 2026-07-19 — also the fork point), built
  with the same Swift toolchain in release configuration, with the same measurement harness
  compiled into both.
- **Matched content.** Both apps were configured with the identical provider set (claude, codex,
  copilot, grok, sakana plus the same two account cards), reading the same credentials and the same
  local session-log corpus (~27 GB of Codex JSONL, ~400 MB of Claude logs).
- **Same workload.** The in-app driver (`RUNWAY_UI_PROFILE=1`, see `docs/debugging.md`) ran the
  identical phases in both apps: a cold popup open, 12 warm open/close cycles, 10 screen switches,
  10 card expand/collapse toggles, and an idle soak, with an 8 ms main-thread stall watchdog
  running throughout. Launch and refresh figures come from process accounting (`ps`) and each
  app's own batch logs.
- **Steady state vs first launch.** Each app ran twice; the first run populated its log-scan
  caches (reported as "first launch"), the second is the steady-state table.

Caveats, so the numbers stay honest:

- Figures are machine- and corpus-specific; ratios travel better than absolute numbers.
- The forced-refresh phase was excluded from the refresh row for both apps: the dev build's
  keychain ACL turns a forced Claude refresh into an interactive prompt no headless run can
  answer (Runway's refresh deadline cut it off exactly as designed; the scheduled batches above
  are the non-interactive path both apps take in normal use).
- Stall-time totals for the expand phase vary meaningfully between runs on both apps; the table
  reports the same single steady-state run for each side, and Runway was lower in every paired run.

## Reproducing

The UI rows (popup opens, stall totals) come straight from the built-in harness:

```
script/profile_ui.sh
```

builds, drives the scripted phases, and prints the per-phase stats. See the "Profile the UI"
section of [docs/debugging.md](debugging.md) for what each number means and for the
`RUNWAY_UI_PROFILE_COLD=1` true-cold variant.

The cross-app rows need the two-build procedure the tables came from — the harness alone measures
only the current Runway tree:

1. Check out OpenUsage at `9d2bf09` in a separate worktree, compile the same `UIProfiler` +
   `StatusItemController` instrumentation into it, and stage both dev bundles.
2. Match both apps' enabled-provider defaults (`runway.enabledProviders.v1` /
   `openusage.enabledProviders.v1`) to the identical list.
3. Launch each with `RUNWAY_UI_PROFILE=1` and sample around the run: launch latency is the delta
   from exec to the "Status item ready" log line, CPU/RSS via `ps` at +30 s / end of run / after a
   60 s idle window (with a poller recording peak RSS), and refresh wall time from each app's own
   "batch end" log lines.
4. Run each app twice: the first run measures the cold caches ("first launch" table), the second
   the steady state. For the first run to actually be cold, delete each app's persisted scan cache
   beforehand — `~/Library/Application Support/Runway/log-scan-cache/` (upstream:
   `OpenUsage/log-scan-cache/`) — while leaving the matched provider/account defaults in place; a
   revision that has ever been profiled on the machine otherwise starts warm and silently reports
   another steady-state run.
