# Claude

Tracks your Claude subscription limits using the login you already have from Claude Code or Claude Desktop.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour rolling window usage |
| Weekly | 7-day window usage |
| Sonnet | Separate weekly Sonnet limit (plan-dependent) |
| Fable | Separate weekly Fable limit (model-scoped window from the `limits` array) |
| Extra Usage | Extra-usage credits spent against your monthly cap |
| Today / Yesterday / Last 30 Days | Local spend, as cost, tokens, or both (see below) |

When Claude reports your plan name, Runway shows it beside the provider name. The badge follows your
current plan: Runway prefers the up-to-date plan and tier Claude Code keeps in its state file over the
copies stored at sign-in, so upgrading or downgrading shows up without signing in again.

## Where credentials come from

Sign in with Claude Code or Claude Desktop; Runway reads the existing login. It checks these sources and prefers one that can read your subscription usage:

1. The macOS keychain entry Claude Code maintains (its source of truth on macOS)
2. `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR/.credentials.json`)
3. Claude Desktop's encrypted login cache, when no working Claude Code login is available
4. `CLAUDE_CODE_OAUTH_TOKEN` environment variable

Claude Desktop support is read-only. Runway decrypts its currently valid access token using the
`Claude Safe Storage` item in your macOS Keychain. It never reads or uses Desktop's refresh token, and
never changes Desktop's config, cookies, or Keychain entry. This prevents Runway from invalidating
Claude Desktop's session.

macOS can ask once before Runway can access a Claude Code or Claude Desktop Keychain item. Launch-time
and background refreshes never open the password dialog: Runway first asks you to refresh manually, and
choosing **Always Allow** makes later reads silent. If Desktop's short-lived token expires, open Claude
Desktop so it can renew the login, then refresh Runway.

A Claude Code Keychain item remains higher priority than a home-file or Desktop login even before access
is approved. Runway reports that approval is needed instead of silently showing usage from a potentially
stale home file or a different Desktop account. If macOS cannot even determine whether the item exists
(for example, while the login keychain is locked), Runway asks you to unlock the keychain instead of
guessing or prompting in the background.

First-run detection validates Claude Desktop's cache with Keychain interaction disabled. Leftover or
corrupt Desktop files—and readable but malformed Claude Code Keychain entries—do not enable Claude by
themselves.

If you cancel or deny a Claude Code approval prompt during a manual refresh, Runway stops there. It does
not repeat the same Code prompt through a broader lookup or open an unrelated Claude Desktop prompt.

A `CLAUDE_CODE_OAUTH_TOKEN` — usually a long-lived `claude setup-token` — can run the model but can't read your Session and Weekly limits, and it often lingers in your shell environment. So when a real keychain or file login is present, Runway uses that login for the live meters and keeps the environment token only as a fallback; the Session/Weekly meters no longer go blank just because that token is set. If the environment token is your *only* credential (a headless setup), it's used on its own and the spend tiles still load from local logs.

If one source holds an expired or "locked out" token, Runway falls back to the others — so signing in again with `claude` outside the app is picked up on the next refresh, without restarting Runway.

All Claude credentials are strictly read-only to Runway. Runway never refreshes an OAuth token and never writes to Claude's Keychain items or `.credentials.json` — Claude Code and Claude Desktop own their logins and their token rotation. Two apps rotating the same login can trip the server's token-reuse protection and sign you out everywhere, so Runway stays a pure reader. When every stored login has lapsed, the live Session and Weekly meters pause and the Claude header shows **"Claude login needs renewal"**: open Claude Code (or Claude Desktop) so it renews its own login, then refresh Runway. The local spend tiles keep working the whole time.

## The spend tiles

Today / Yesterday / Last 30 Days are computed **locally**: Runway reads the Claude Code session logs under `~/.claude/projects/` (or `$CLAUDE_CONFIG_DIR`) itself — no external tools needed. Symlinks are followed, so a projects folder linked into a synced location (say, a Dropbox folder) is read all the same. Claude usage from the [pi](https://github.com/earendil-works/pi) coding agent counts too. Runway reads pi's session logs under `~/.pi/agent/sessions/` (or `$PI_CODING_AGENT_SESSION_DIR`) and folds any Claude usage there into the same tiles and trend. pi records its own per-message cost, so those dollars come straight from pi; Runway does not re-estimate them. Cowork (the Claude desktop app's agent mode) counts too: it writes the same logs into per-session folders under `~/Library/Application Support/Claude/local-agent-mode-sessions/`, and Runway scans those as well. Desktop agent sessions show up in the tiles alongside terminal ones. Persisted `claude -p` runs count as well. Runs made with `--no-session-persistence` cannot appear because Claude deliberately writes no session log for Runway to read. Advisor work recorded inside a message is counted once under the advisor's own model; the parent's main-model totals are kept separate, and ordinary iteration details are not counted again. A log's recorded fast or standard speed controls its price; Runway does not infer speed from the event date. Days are grouped in your Mac's local time zone, so they line up with your own calendar. Each period is one tile showing cost and tokens together (`$4.08 · 1.2M tokens`); a day with no usage reads **No data** rather than a misleading `$0.00 · 0 tokens` — the same as every other spend-tracking provider. The live Session and Weekly meters are unaffected. The dollars are estimated from token counts at API rates (that's the ⓘ) using the shared [model pricing](../pricing.md); the token counts themselves are measured. No log data leaves your Mac.

## Multiple accounts

If you keep more than one Claude login on this Mac using custom config dirs (separate `CLAUDE_CONFIG_DIR`
homes, each with its own sign-in), Runway finds them at launch and gives each **account** its own
card, with its own limits, plan, and spend tiles read from that home. A custom dir signed into the same
account as your main login doesn't become a second card — its session logs simply count into the main
card's spend tiles.

With one discovered account, the default name is simply "Claude." With multiple accounts, every card
includes its account email (for example, "Claude — dev@example.com"), including the first/default card.
An organization name appears after the email when available. If two active accounts still have the
same label, Runway adds a short stable account code. If the only login lives in a custom config dir,
it is the sole Claude card; Runway does not add an empty default-home card beside it. Right-click
a card and choose **Rename…**
(or use the Name field in Customize) to call it whatever you like. A card only shows while its login is
still found on this Mac — log it out or delete the dir and the card disappears, keeping its customization
and history for if it returns. Turn a card off like any provider in Customize.

An ambient `CLAUDE_CODE_OAUTH_TOKEN` cannot identify its account. When a separate account card is also
discovered, default-home local spend remains available under a clearly labeled
"Claude — Environment Token" card. A leftover Claude state file—or a malformed or tokenless stored
credential beside it—does not lend an old account name to that token-only card.

In the [CLI](../cli.md) and [local API](../local-http-api.md), extra cards appear under ids like
`claude@ab12cd34`; requesting `claude` returns every Claude card.

## Troubleshooting

- **"Not logged in"** — run `claude` and sign in, then refresh.
- **"Claude Code login found"** — refresh manually and choose **Always Allow** when macOS asks for access to `Claude Code-credentials`.
- **"Claude Code credentials couldn't be checked"** — unlock your login keychain, then refresh Runway.
- **"Claude Desktop login found"** — refresh manually and choose **Always Allow** when macOS asks for access to `Claude Safe Storage`.
- **"Claude Desktop login is stale"** (an amber warning on the Claude header) — open Claude Desktop so it can renew the login, then refresh Runway.
- **"Claude login needs renewal"** (an amber warning on the Claude header) — every stored login has an expired or revoked token. Runway never renews Claude's tokens itself, so open Claude Code (it refreshes its login on launch), then refresh Runway. The spend tiles keep working in the meantime.
- **"Re-login for live usage"** (an amber warning on the Claude header) — your saved login can authenticate for inference but can't read your subscription limits, because it lacks the `user:profile` access (this is what an inference-only token from `claude setup-token` carries). Run `claude` and sign in again with your Claude account, then refresh; the spend tiles keep working in the meantime.
- **"Updates blocked by Anthropic"** (an amber warning on the Claude header) — the usage API is throttling Runway. It keeps the last values from the same login, shows when it will retry, and backs off in the meantime. A different login starts with a fresh cache and cooldown.
- **Spend tiles show "No data"** — Runway found no Claude Code logs in the last 30 days. If your logs live somewhere custom, set `CLAUDE_CONFIG_DIR` so both Claude Code and Runway look in the same place.

## Under the hood

`GET https://api.anthropic.com/api/oauth/usage` with the selected OAuth token. All Claude tokens are read-only to Runway and must be renewed by the Claude app that owns them; Runway never calls the OAuth token endpoint. If a token is expired or revoked, Runway tries the next credential source, and when none is left it shows the renewal notice over the local spend tiles.

When the 5-hour session window has no usage yet, the Session row shows **Not started** on the trailing label; hover explains that the session begins after your first message.
