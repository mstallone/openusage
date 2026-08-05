# Antigravity

Tracks pool quotas for Antigravity (Google's AI IDE) using credentials the app or the `agy` CLI already stored on your Mac.

## What it tracks

Antigravity has two shared quota pools, and each pool has two windows — a rolling 5-hour window and a weekly window:

| Metric | Meaning |
|---|---|
| Session | The shared Gemini pool (Pro and Flash draw from the same quota), rolling 5-hour window |
| Weekly | The same Gemini pool's weekly window |
| Claude | The shared non-Gemini pool (Claude, GPT-OSS, …), rolling 5-hour window |
| Claude Weekly | The same non-Gemini pool's weekly window |

When Antigravity reports your subscription tier (such as `Pro` or `Ultra`), Runway shows it beside the provider name.

Gemini Pro and Gemini Flash are one pool: using either model drains the same quota, so Runway shows one meter per window instead of separate Pro and Flash meters. That pair is named Session and Weekly to match the other providers' rows. Every non-Gemini model shares the second pool, shown under the Claude name (like Codex's Spark pair). Quotas are reported as a fraction (full = 0% used), so there are no token or dollar spend tiles.

When a pool's rolling 5-hour window has no usage yet, that meter reads **Not started** on the trailing label instead of a reset countdown; hover explains that the session begins after your first message. The weekly meters always show a normal reset countdown.

## Where credentials come from

Runway never asks for a token — it reads what Antigravity already has:

- **Antigravity running** — Runway talks to the app's local language server (the richest source, and where the plan name comes from).
- **App closed** — it falls back to the OAuth token Antigravity / `agy` store in your macOS Keychain and queries Google's Cloud Code API. Runway refreshes an expired token automatically (it never writes back to Antigravity's own keychain item). Runway reuses its short-lived cache only while the same Keychain login is present and readable.

If neither is available you'll see *Start Antigravity or run `agy` and try again.*

## Troubleshooting

- **"Start Antigravity or run `agy`…"** — sign in to the Antigravity app (or run `agy`) so a usable token exists, then refresh. A manual refresh (⌘R) looks for the local server immediately; the automatic 5-minute passes check for it again within about 15 minutes of it starting.
- **"Antigravity login found in Keychain"** (a neutral key glyph, not a warning) — the item is present, but automatic refreshes do not request its secret. Connect to load it; choose **Always Allow** to avoid a dialog on future manual reads.
- **"Keychain access to the Antigravity login was declined"** — a manual read was denied. Refresh and choose **Always Allow** when macOS asks.
- **"Couldn't read Antigravity credentials from Keychain"** — the keychain itself couldn't be read (usually locked). Unlock it, then refresh; there's nothing to approve in this state.
- **"Couldn't read Antigravity credentials…"** — unlock Keychain, or sign in to Antigravity again. Runway will not use its cached access token until the current login can be verified.
- **The weekly meters show "No data"** — your Antigravity build doesn't expose the quota-summary endpoint yet (only newer builds do). The 5-hour meters still work from the older endpoints; updating Antigravity brings the weekly meters back.
- **A meter shows "No data"** — that pool/window wasn't in the latest response (some tiers only report certain windows). The other meters still update.
- **Where did the Gemini Pro and Flash meters go?** — merged: both models draw from the one shared Gemini pool, which is now the single Session meter.
- **Quotas look full after heavy use** — the 5-hour windows reset on a rolling basis and the weekly windows once a week; the reset time is shown on each meter.

## Under the hood

Best source first: the local language server discovered by scanning for the `language_server` / `agy` process and reading its CSRF token and listening ports; then Google Cloud Code using the Keychain token, refreshed via Google OAuth when needed. Runway binds its short-lived refreshed-token cache to a one-way fingerprint of the current Keychain refresh credential. Logout, account changes, legacy caches, and expired or malformed entries cannot reuse a previous account's access token. On each source Runway asks the quota-summary endpoint first (`RetrieveUserQuotaSummary` on the language server, `v1internal:retrieveUserQuotaSummary` on Cloud Code) — the only endpoint that reports the merged pools and the weekly windows. Builds without it fall back to the legacy per-model endpoints (`GetUserStatus` / `GetCommandModelConfigs` locally, `fetchAvailableModels` / `retrieveUserQuota` remotely), whose per-model quotas are merged into the two pools by keeping each pool's worst remaining fraction; those endpoints only know the 5-hour windows. The plan name prefers Antigravity's own `userTier` over the inherited Windsurf plan field.

> Reverse-engineered from the app and language-server binary; endpoints and storage can change without notice.
