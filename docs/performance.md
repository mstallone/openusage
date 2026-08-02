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

## Methodology

Both apps ran the same scripted workload on the same machine (Apple Silicon MacBook Pro,
macOS 26.5), against the same local data, minutes apart:

- **Same code lineage, fixed points.** Runway at `main` (post-#54–#59) vs OpenUsage at its `main`
  tip (`9d2bf09`, 2026-07-19 — also the fork point), built with the same Swift toolchain in release
  configuration, with the same measurement harness compiled into both.
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

```
script/profile_ui.sh
```

builds, drives the scripted phases, and prints the per-phase stats. See the "Profile the UI"
section of [docs/debugging.md](debugging.md) for what each number means and for the
`RUNWAY_UI_PROFILE_COLD=1` true-cold variant.
