# OpenCode

Tracks your OpenCode-hosted usage — the **Go** subscription and the **Zen** pay-as-you-go gateway — from
OpenCode's own logs already on your Mac. Nothing is sent anywhere.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | Go spend in the rolling 5-hour window, against the $12 cap, with the reset countdown |
| Weekly | Go spend this week, against the $30 cap (resets Monday) |
| Monthly | Go spend this cycle, against the $60 cap |
| Today / Yesterday / Last 30 Days | Local cost and tokens across all your OpenCode-hosted usage (Go + Zen) |
| Usage Trend | A day-by-day sparkline of tokens over the last month |

When you have the Go subscription, Runway shows "Go" beside the provider name.

The Session / Weekly / Monthly meters show **observed local spend** — the usage recorded on *this* Mac. If
you also use OpenCode Go on another machine, or OpenCode hasn't finished writing a session locally, the
local figure can be lower than your true account usage. Treat the caps as a guide rather than the last
word. (When OpenCode ships an official usage API, Runway can switch to authoritative numbers without any
change on your side.) If you only use the Zen pay-as-you-go gateway (no Go subscription), the cap meters are
hidden and you'll just see the spend tiles.

## Where credentials come from

Use OpenCode as usual. Runway reads OpenCode's local data directory
(`~/.local/share/opencode`, or `$OPENCODE_DATA_DIR` / `$XDG_DATA_HOME` if you've set them): the
`auth.json` Go key to detect that you use it, and the local SQLite logs for the numbers. There's no login
prompt and no token to paste.

## The meters and spend tiles

The dollar figures come straight from the per-message cost OpenCode records for its own hosted gateways, so
they're OpenCode's own accounting — not an estimate imputed from token counts. Each spend tile shows cost
and tokens together (`$4.08 · 1.2M tokens`), the same as Claude / Codex / Cursor. A period with no recorded
usage reads "No data" rather than a misleading `$0.00`. No log data leaves your Mac.

The Go caps Runway draws against are the published plan limits: **$12 per rolling 5 hours**, **$30 per
week** (UTC Monday), and **$60 per month** (the monthly cycle is anchored to the day of the month you first
used Go). Zen usage is pay-as-you-go credits with no cap, so it appears only in the spend tiles.

## Troubleshooting

- **Everything shows "No data"** — Runway needs OpenCode's local database at
  `~/.local/share/opencode/opencode*.db`. Run an OpenCode session, then refresh. (If you're logged into
  Go, the cap meters show at $0 even before your first local message.)
- **No Session / Weekly / Monthly meters** — those are Go-plan caps; you'll see them when you're logged
  into OpenCode Go or have used it recently on this Mac. Zen-only (or lapsed) users see the spend tiles
  instead — old Go history alone won't bring the caps back.
- **"Couldn't read OpenCode's local database"** — the database (or data directory) exists but couldn't be
  read this refresh. Quit OpenCode and refresh; if it persists, check the permissions on
  `~/.local/share/opencode`.
- **"Couldn't read OpenCode's auth.json"** — the file exists but is unreadable or not valid JSON. Check
  its permissions, or log into OpenCode Go again to rewrite it.
- **Numbers look lower than your dashboard** — the meters are local-observed spend (this Mac only); see the
  note above.

## Under the hood

Runway reads the assistant-message `cost` and token fields from every `opencode*.db` in the data
directory (OpenCode partitions its database by release channel — stable is `opencode.db`, the preview line
is `opencode-next.db` — so all channels are unioned). The Go caps sum the `opencode-go` messages; the spend
tiles and trend sum both `opencode-go` (Go) and `opencode` (Zen). Read-only, no network. If OpenCode's
proposed `/zen/go/v1/usage` API ships, the same Go key becomes the bearer token for authoritative windows.
