# Runway

Fast, observable AI usage across every provider and account, right from the macOS menu bar.

Runway brings multiple accounts across Claude, Codex, Cursor, Grok, Devin, and more into one focused view of limits, credits, and spend. Cached data appears instantly, live refreshes stay out of the way, and the metrics you care about can sit directly in the menu bar.

<p align="center">
  <img src="assets/screenshot.jpg?v=20260706" alt="Runway menu bar tracker showing Claude and Codex session, weekly, and spend usage" width="900">
</p>

## Installation

**Direct download:** grab the latest universal DMG from the [releases page](https://github.com/mstallone/runway/releases/latest), open it, and drag Runway to your Applications folder.

The app updates itself in place via signed, notarized [Sparkle](docs/updates.md) updates. Requires macOS 15 (Sequoia) or later.

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

Most providers read the credentials already on your machine (keychain, auth files, app state) — no extra login. OpenRouter and Z.ai are the exceptions: they have no local credential to reuse, so you supply an API key (see [OpenRouter setup](docs/providers/openrouter.md) or [Z.ai setup](docs/providers/zai.md)). Credentials are used only for the corresponding provider requests. Runway collects no product analytics or usage statistics; public pricing downloads and optional iCloud sync are documented under [Privacy](docs/privacy.md).

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



## Documentation

Behavior docs live in [docs/](docs/README.md): the [dashboard](docs/dashboard.md), [menu bar pins](docs/menu-bar.md), [settings](docs/settings.md), [refresh & caching](docs/refreshing.md), the [CLI](docs/cli.md), the [local HTTP API](docs/local-http-api.md), the [proxy](docs/proxy.md), and one page per provider.

For working on the code, see the developer docs: [architecture](docs/architecture.md), [adding a provider](docs/adding-a-provider.md), and [debugging & capturing logs](docs/debugging.md).

## Requirements

- macOS 15 (Sequoia) or later
- Universal binary — runs natively on both Apple Silicon and Intel Macs

The Today / Yesterday / Last 30 Days spend tiles are computed natively from local CLI logs (Claude,
Codex, Grok, and Sakana Fugu) or Cursor's usage export — no Node.js or other runtime needed. Dollars
are estimated with [model pricing](docs/pricing.md).



## Building

```sh
swift build            # debug build
swift test             # run the test suite
./script/build_and_run.sh   # build and launch the dev app from dist/ (no install)
```



## Architecture

SwiftPM package, SwiftUI content hosted in an AppKit-owned `NSStatusItem` + custom key-capable `NSPanel`, Swift 6 strict concurrency. The app and CLI share one module: providers implement a small `ProviderRuntime` protocol (auth store → usage client → mapper → `ProviderSnapshot`), and both surfaces read the same normalized data — see the [architecture overview](docs/architecture.md) for how the pieces fit together and [AGENTS.md](AGENTS.md) for engineering conventions.

## Releasing

Releases are automated: pushing a stable tag such as `v0.7.1` on `main` tests, builds, signs, notarizes, and publishes a new version with its SHA-256 checksum. Prerelease suffixes are rejected. The pipeline lives in [.github/workflows/release.yml](.github/workflows/release.yml), and the step-by-step is in the `release-swift` skill.

### Release setup (one-time)

The release workflow needs these repository secrets (Settings → Secrets and variables → Actions):


| Secret                       | What it is                                                            |
| ---------------------------- | --------------------------------------------------------------------- |
| `DEVELOPER_ID_CERTIFICATE_BASE64` | base64 of the Runway Developer ID Application `.p12`          |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | the password set when exporting that `.p12`                     |
| `APPLE_NOTARY_PRIVATE_KEY_BASE64` | base64 of an App Store Connect API private key (`.p8`)            |
| `APPLE_NOTARY_KEY_ID`        | the App Store Connect API key ID                                      |
| `APPLE_NOTARY_ISSUER_ID`     | the App Store Connect API issuer ID                                   |
| `APPLE_DEVELOPER_ID_ICLOUD_PROFILE` | base64 Developer ID provisioning profile for the production iCloud container |
| `SPARKLE_PUBLIC_KEY`         | base64 EdDSA public key, baked into the build as `SUPublicEDKey`      |
| `SPARKLE_PRIVATE_KEY`        | base64 EdDSA private key used to sign the DMG                         |


Export the NextByte Developer ID Application cert (with its private key) from Keychain Access as a `.p12`, then `base64 -i DeveloperID.p12 | pbcopy`. Create an App Store Connect API key with the **App Manager** role (it both notarizes the Mac app and cloud-signs/uploads the iOS app), download its `.p8` file once, and base64-encode it the same way. The certificate, API key, and iCloud profile must all belong to NextByte team `8KZBNZJBAX`. Generate the Sparkle EdDSA key pair once with Sparkle's `generate_keys` tool; the public and private values must be a matching pair or signing is silently skipped.

The iOS TestFlight jobs reuse the three `APPLE_NOTARY_*` secrets — no extra secrets — but need one-time App Store Connect setup: create the app record (My Apps → New App, iOS, bundle ID `com.mattstallone.runway.mobile`, any unique SKU), and add an internal TestFlight tester group with **automatic distribution** so every uploaded build reaches internal testers without a manual step. The App ID must already carry the CloudKit capability with both Runway containers (see [iOS app](docs/ios-app.md)); the workflow's cloud signing then creates and refreshes the App Store provisioning profile on its own.

For external testers, the workflow's TestFlight External job submits every release for Beta App Review and testers receive it when Apple approves. Its one-time setup: create an external group named `External` under TestFlight → External Testing (add testers by email or enable a public link; the workflow's `TESTFLIGHT_EXTERNAL_GROUPS` env lists the group names it ships to), and fill in the app's TestFlight **Test Information** — beta app description, feedback email, and the review contact/sign-in details the first submission asks for. The app needs no demo account: it reads the tester's own iCloud data, so mark it as not requiring sign-in and say so in the review notes.

For iCloud Sync, store the original development and Developer ID provisioning profiles in 1Password as secure documents. Install the development profile on each registered Mac; base64-encode the Developer ID profile and store it only in the `APPLE_DEVELOPER_ID_ICLOUD_PROFILE` Actions secret. See [iCloud Sync](docs/icloud-sync.md#development-and-release-setup) for the container identifiers, build command, and file-inspection command.

The repository must be public (Sparkle fetches the DMG and appcast anonymously), and the update feed is served through GitHub Pages. Set Settings → Pages → Build and deployment → Source to **GitHub Actions**; the publishing workflows create and maintain the `update-feed` branch and deploy through the **Update Feed** environment.

## Contributing

Issues are welcome. Pull requests are **strict and issue-first**: external PRs must link an issue a maintainer has approved with the `approved` label — **most external PRs without one are closed by design**. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening one. Report security issues privately per [SECURITY.md](SECURITY.md). The Runway name and logo are covered by the [trademark policy](TRADEMARK.md).

## License

[MIT](LICENSE)
