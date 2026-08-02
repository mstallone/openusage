# AGENTS.md

Runway is a SwiftPM-based SwiftUI menu-bar app for macOS that shows AI provider usage widgets (Claude, Codex, Cursor, Grok, Devin, and more).

This file documents the engineering conventions for the project. Read it before you contribute.

## Agent Instructions

AGENTS.md is the source of truth for agent instructions in this repository. CLAUDE.md files must only point to the nearest AGENTS.md file with `@AGENTS.md`. Do not add guidance, duplicate instructions, or project rules to CLAUDE.md.

> **Repository note:** This is the native Swift edition of Runway. Active development happens on the `main` branch. (NOT the legacy Tauri version which now sits in the `tauri-legacy` branch)

## Releases

`main` is the active development line. The NextByte-owned `mstallone/runway` fork ships via `.github/workflows/release.yml` (Sparkle appcast on `update-feed`). Cut releases with the release-swift skill. `docs/releasing.md` documents the secrets and the one-time setup.

### Guardrails (do not break)
- Versions are `0.7.x` and up. Never reuse a `0.6.x` number — those are the original edition's released tags, now frozen on the `tauri-legacy` branch (final release `v0.6.28`).
- **Never increase the version number on your own initiative — always ask for explicit approval first.** The version is a deliberate owner decision: propose the number and wait for explicit sign-off before tagging or cutting a release.
- Releases use plain `vMAJOR.MINOR.PATCH` tags and become GitHub "Latest". Prerelease suffixes and Sparkle beta channels are not supported.
- The NextByte fork starts a fresh GitHub Release and Sparkle history. Do not carry forward the upstream fork's Tauri `latest.json`, GitHub Release assets, appcast entries, or signing identity.
- Never leave a release in Draft, and never ship blank notes: the release-swift skill generates the changelog and verifies the published release after every cut.

## Architecture

- SwiftPM executable target; SwiftUI content hosted in an AppKit-owned `NSStatusItem` + custom key-capable `NSPanel`.
- Swift 6 with strict concurrency.
- Providers implement the small `ProviderRuntime` protocol: an auth store reads credentials already on the user's machine, a usage client calls the provider's API, and a mapper normalizes the response into `MetricLine` values. The UI renders those normalized values.
- See `docs/` for behavior docs and the developer docs (architecture overview, adding a provider).

## Providers

Conventions for the per-provider modules under `Sources/Runway/Providers/<Name>/`.

- **Structure:** one folder per provider with an auth store (reads credentials already on the user's machine), a usage client (calls the provider API), and a mapper (normalizes to `MetricLine`). The module conforms to `ProviderRuntime`: `refresh()` plus `hasLocalCredentials()`. `hasLocalCredentials()` is the local-only credential probe. First-run detection (`FirstRunSeeder`) uses it, and new-provider detection (`NewProviderSeeder`) uses it on the first launch after the provider ships. Mirror the same local credential sources and usability filters that `refresh()` starts with. Reuse the auth-store loaders; do not add a second credential-reading path. See `docs/adding-a-provider.md` and `docs/provider-enablement.md`.
- **Model pricing:** all spend imputation (Claude, Codex, Cursor, Grok) prices through the shared engine in `Sources/Runway/Pricing/` (see `docs/pricing.md`). Cursor-native model rates and alias rules live in `Sources/Runway/Resources/pricing_supplement.json`. Sync new or changed models from [Cursor models & pricing](https://cursor.com/docs/models-and-pricing.md): update `updated_at`, the pricing entries, and the `alias_rules` for CSV model slugs. A merge to `main` publishes the file to `update-feed`, so installed apps pick it up without a release. The bundled LiteLLM/models.dev snapshots regenerate with `script/update_pricing_snapshots.sh` (a release-time chore).
- **Default order:** Claude, Codex, Cursor first (the established providers, in that order), then every other provider alphabetically by display name (Antigravity, Devin, Grok, …). The order is the array order in `AppContainer`, which seeds `LayoutStore`'s default provider order (and `resetToDefault`). A new provider slots into the alphabetical tail.
- **Metric placement defaults:** when you add or change a metric, confirm its four defaults with the owner before you choose — never pick silently:
  1. enabled on/off (`DefaultLayout.metricIDs`),
  2. Always Visible vs. On Demand — above the fold vs. behind the per-provider caret (`DefaultLayout.expandedMetricIDs`). Note: a provider always keeps at least one Always Visible row. When every metric is marked On Demand, the dashboard promotes all of them, so a fully On Demand provider is not possible. Leave one metric Always Visible so the caret appears,
  3. pinned to the menu bar (`DefaultLayout.pinnedMetricIDs`),
  4. order (within a provider, the `widgetDescriptors` declaration order).

## Running / Testing Changes

- There is no hot reload. The app is a long-lived menu-bar process, so **every code change requires a full rebuild and restart of the running app** to take effect — kill the running instance, rebuild, and relaunch before you test.

## Pull Requests

Every PR description must follow this structure so reviewers can skim it quickly:

- **TL;DR** — open with a one- or two-sentence plain-English summary of the change.
- **What was happening** — plain-English bullet points describing the prior behavior, bug, or gap that motivated the change.
- **What this changes** — bullet points describing what the PR actually changes.
- **Heads-up** (optional) — noteworthy things a reviewer or future maintainer should consider (risks, follow-ups, trade-offs).
- **Tests** (optional) — how the change was verified.

## Documentation

- Logic changes must update any docs in `docs/` that describe the affected behavior.
- Keep docs simple, less-technical, and easy to skim; exclude visual design details.

## Code Conventions

- When you fix a bug, add a regression test where it fits.
- Keep files under ~500 LOC; split or refactor as needed.
- No new dependencies without justification.
- When you add a provider, follow the conventions in "## Providers".

## Error Handling

Always fail loudly into the local log file and show friendly errors to the user. Do not add silent fallbacks that hide real problems. Only validate at system boundaries (user input, external APIs); trust internal code and framework guarantees.

## UI

- Use title case for any hardcoded copy used as a title.
- Match the existing design language; Runway has a specific look and feel.
- Only add tooltips (`hoverTooltip`) when explicitly asked to. Don't add them proactively to new controls.
