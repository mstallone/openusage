# Runway

Fast, observable AI usage across every provider and account, right from the macOS menu bar.

**Website:** [mstallone.github.io/runway](https://mstallone.github.io/runway/)

Runway brings multiple accounts across Claude, Codex, Cursor, Grok, Devin, and more into one focused view of limits, credits, and spend. Cached data appears instantly, live refreshes stay out of the way, and the metrics you care about can sit directly in the menu bar.

<p align="center">
  <img src="assets/hero.png" alt="Runway hero: menu bar pins and the dashboard popover with the Total Spend ring plus Claude and Codex meters in normal, warning, and critical states" width="900">
</p>

## Installation

**Direct download:** download the latest universal DMG from the [releases page](https://github.com/mstallone/runway/releases/latest). Open it. Drag Runway to your Applications folder.

The app updates itself in place via signed, notarized [Sparkle](docs/updates.md) updates. Requires macOS 15 (Sequoia) or later.

## Performance

Runway is a rebuilt-for-speed fork. We measured it against upstream OpenUsage on the same machine,
with the same providers and the same session-log corpus. It is faster on every axis we track — see
the details and methodology in [docs/performance.md](docs/performance.md).

| | OpenUsage | Runway |
|---|---|---|
| Launch → menu bar icon | 5.4 s | **0.29 s** |
| Popup open → first frame | 61 ms | **23 ms** |
| First open after launch | 2.59 s | **44 ms** |
| One refresh pass | 8.6 s | **2.3 s** |
| Memory (steady / peak) | 1.09 GB / 2.6 GB | **238 MB / 322 MB** |
| First-launch scan | 165 s CPU, 12.9 GB peak | **12.7 s CPU, 1.7 GB peak** |

## Supported Providers

- **[Antigravity](docs/providers/antigravity.md)** — shared Gemini and Claude pool quotas, 5-hour and weekly windows
- **[Claude](docs/providers/claude.md)** — session, weekly, model-specific limits, extra usage, local daily spend
- **[Codex](docs/providers/codex.md)** — session, weekly, credits, local daily spend
- **[Copilot](docs/providers/copilot.md)** — AI credits, extra usage, organization billing, chat and completions
- **[Cursor](docs/providers/cursor.md)** — credits, total/auto/API usage, requests, on-demand, per-day spend
- **[Devin](docs/providers/devin.md)** — weekly and daily quota, extra usage balance
- **[Grok](docs/providers/grok.md)** — weekly shared pool, pay-as-you-go, local daily spend
- **[Kimi](docs/providers/kimi.md)** — five-hour and weekly Kimi Code quota, Extra Usage balance and monthly spend
- **[OpenCode](docs/providers/opencode.md)** — Go session/weekly/monthly caps, Zen spend, local daily spend
- **[OpenRouter](docs/providers/openrouter.md)** — credit balance, daily/weekly/monthly spend (API key)
- **[Sakana Fugu](docs/providers/sakana.md)** — subscription quota plus local Fugu Ultra usage trend and estimated API-rate value
- **[Z.ai](docs/providers/zai.md)** — session, weekly, web-search quotas (GLM Coding Plan, API key)

Most providers read the credentials already on your machine (keychain, auth files, app state) — no extra login. OpenRouter and Z.ai are the exceptions: they have no local credential to reuse, so you supply an API key (see [OpenRouter setup](docs/providers/openrouter.md) or [Z.ai setup](docs/providers/zai.md)). Runway uses credentials only for the corresponding provider requests. Runway collects no product analytics or usage statistics. The [Privacy](docs/privacy.md) page documents public pricing downloads and optional iCloud sync.

## Features

- **Menu bar pins.** Pin metrics to the menu bar (up to 2 per provider); render as compact text or mini bars. The strip hides metrics with no data instead of showing placeholders.
- **Dashboard popover.** Provider-grouped meters with live reset countdowns and pace indicators. Click usage or reset values to flip their display everywhere; right-click a row to hide or star it, refresh its provider, or open Customize.
- **Global shortcut.** Toggle the popover from anywhere — record any combo in Settings.
- **Customize.** Turn providers and metrics on or off, choose which rows stay Always Visible or On Demand, and drag-reorder both.
- **Stale-while-revalidate.** Cached values display instantly at launch; refresh runs every 5 minutes.
- **[One-shot CLI](docs/cli.md).** Agents can read stable limit JSON through the same five-minute cache with `runway`, or bypass freshness with `runway --force`; the menu-bar app does not need to be running.
- **[Local HTTP API](docs/local-http-api.md).** Other apps can read machine-friendly limits from `127.0.0.1:6736/v1/limits`; the legacy `/v1/usage` UI contract remains supported. It is loopback-only and never serves credentials; note that browser pages can read it too — see the [privacy note](docs/local-http-api.md#cors-and-privacy).
- **[Proxy support](docs/proxy.md).** Route provider requests through SOCKS5 or HTTP(S) via `~/.runway/config.json`.
- **Native settings.** Launch at login, global shortcut, icon style, theme, 12/24-hour time — see [Settings](docs/settings.md).
- **[Automatic updates](docs/updates.md).** Signed, notarized stable updates via Sparkle.

## iPhone Companion

Runway for iOS mirrors combined usage from every Mac you run — spend today, yesterday, and over the
last 30 days. The data syncs privately over iCloud. The app adds lock screen and home screen
widgets. Each widget can show cost or tokens; see the [iOS app](docs/ios-app.md) for what it shows
and how syncing works.

<p align="center">
  <img src="assets/ios-lockscreen.png" width="270" alt="Runway lock screen widgets showing today's AI spend synced from your Macs">
  &nbsp;&nbsp;
  <img src="assets/ios-home-widgets.png" width="510" alt="Runway home screen widgets with today, yesterday, and 30-day spend plus a usage trend chart">
</p>

## Documentation

Behavior docs live in [docs/](docs/README.md): the [dashboard](docs/dashboard.md), [menu bar pins](docs/menu-bar.md), [settings](docs/settings.md), [refresh & caching](docs/refreshing.md), the [CLI](docs/cli.md), the [local HTTP API](docs/local-http-api.md), the [proxy](docs/proxy.md), and one page per provider.

For working on the code, see the developer docs: [architecture](docs/architecture.md), [adding a provider](docs/adding-a-provider.md), and [debugging & capturing logs](docs/debugging.md).

## Requirements

- macOS 15 (Sequoia) or later
- Universal binary — runs natively on both Apple Silicon and Intel Macs

Runway computes the Today / Yesterday / Last 30 Days spend tiles natively from local CLI logs
(Claude, Codex, Grok, and Sakana Fugu) or Cursor's usage export — no Node.js or other runtime
needed. It estimates dollars with [model pricing](docs/pricing.md).



## Development

```sh
swift build            # debug build
swift test             # run the test suite
./script/build_and_run.sh   # build and launch the dev app from dist/ (no install)
```

SwiftPM package, SwiftUI content hosted in an AppKit-owned `NSStatusItem` + custom key-capable `NSPanel`, Swift 6 strict concurrency. The app and CLI share one module: providers implement a small `ProviderRuntime` protocol (auth store → usage client → mapper → `ProviderSnapshot`), and both surfaces read the same normalized data. See the [architecture overview](docs/architecture.md) for how the pieces fit together, and [AGENTS.md](AGENTS.md) for the engineering conventions.

Releases are automated: when you push a stable tag on `main`, the pipeline tests, builds, signs, notarizes, and publishes the release. The pipeline and its one-time setup are documented in [Releasing](docs/releasing.md).

## Contributing

Issues are welcome. Pull requests are **strict and issue-first**: external PRs must link an issue a maintainer has approved with the `approved` label — **most external PRs without one are closed by design**. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening one. Report security issues privately per [SECURITY.md](SECURITY.md). The Runway name and logo are covered by the [trademark policy](TRADEMARK.md).

## License

[MIT](LICENSE)
