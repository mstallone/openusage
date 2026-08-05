# Codex

Tracks your ChatGPT/Codex subscription limits using the login from the Codex CLI.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour rolling window usage |
| Weekly | 7-day window usage |
| Spark / Spark Weekly | GPT-5.3-Codex-Spark model limits — a 5-hour and a weekly window. Shown only when your account has the limit (otherwise "No data"), and off by default |
| Rate Limit Resets | On-demand rate-limit reset credits, shown as a count (e.g. `2 available`) with a colored dot for the soonest expiry; hover the value for a timeline of each credit's expiry |
| Extra Usage | Flex credits, shown verbatim as dollars + credits (e.g. `$31.84 · 796 credits`) |
| Today / Yesterday / Last 30 Days | Local spend, as cost, tokens, or both (see below) |

When Codex reports your plan name, Runway shows it beside the provider name.

## Where credentials come from

Sign in with the Codex CLI (`codex`); Runway reads the same `auth.json` file or home-scoped OS keyring item (`$CODEX_HOME` respected). All Codex credentials are strictly read-only to Runway: it never refreshes a token and never writes `auth.json` or the keyring — the `codex` CLI owns the login and its rotation. When the token lapses, the card shows **"Codex login needs renewal"**: run `codex` (it renews its own login), then refresh Runway. The local spend tiles keep working the whole time.

Automatic refreshes never request the keyring secret. After launch or a credential change, the card
offers a neutral **Connect** action (not a warning); that deliberate read is cached in memory for the running app session while the item's
non-secret metadata remains unchanged. Choose **Always Allow** to avoid a dialog on future manual reads. If the
login keychain itself can't be inspected (it's locked, say), the card asks you to unlock it instead.

## Multiple accounts

Runway discovers Codex homes at launch and gives every distinct ChatGPT account its own card. Each card has isolated limits, plan, spend logs, cached data, and reset-credit actions. If the same account is signed in under more than one home, Runway keeps one card and combines those homes' session logs instead of duplicating it. Pi's Codex usage identifies only the provider family, so Runway assigns that slice to the account currently occupying the default Codex home; when no account holds that badge, it leaves the ambiguous pi slice unattributed.

Discovery checks the normal `~/.codex` and `~/.config/codex` homes, dot-directories in your home folder, directories directly under `~/.config`, and every explicit entry in `CODEX_HOME`. Runway accepts a comma-separated `CODEX_HOME` list for discovery; an individual Codex CLI process must still use one home at a time. For example:

```sh
CODEX_HOME="$HOME/.codex-work" codex
CODEX_HOME="$HOME/.codex-personal" codex
```

A discovered home must contain a usable OAuth login that names its account through Codex's own account id. For file storage, that identity comes directly from `auth.json`. For keyring storage, a user-attended **Refresh All** reads the exact home-scoped item and binds the account identity to that item's non-secret fingerprint; the card appears on the next launch. Replacing the keyring item invalidates the binding, so the home stays hidden until the new login is safely rebound.

Runway never treats a directory name as identity. Every card is pinned to one credential home and reads only that home's original file or keyring item. That keeps a token, session log, cached snapshot, or reset claim from crossing between accounts when homes are added, removed, or swapped.

With one discovered account, the default name is simply "Codex." With multiple accounts, every card
includes its account email, including the first/default card. An organization name appears after the
email when available. If two active accounts still have the same label, Runway adds a short stable
account code. If the only login lives in a custom home, it is the sole Codex card; Runway does not add
an unscoped card beside it.

Additional cards use stable ids such as `codex@ab12cd34`. You can rename any Codex card from its context menu or Customize. CLI and local API queries for `codex` return every active Codex account card; querying the full card id selects one.

## The spend tiles

Today / Yesterday / Last 30 Days are computed **locally**: Runway reads the Codex CLI's session rollouts under `~/.codex/sessions/` and `archived_sessions/` (or `$CODEX_HOME`) itself — no external tools needed. Symlinks are followed, so a Codex home linked into a synced location (say, a Dropbox folder) is read all the same. Codex usage from the [pi](https://github.com/earendil-works/pi) coding agent counts too: Runway reads pi's session logs under `~/.pi/agent/sessions/` (or `$PI_CODING_AGENT_SESSION_DIR`) and folds any Codex usage there into the same tiles and trend. pi records its own per-message cost, so those dollars come straight from pi; Runway does not re-estimate them. Days are grouped in your Mac's local time zone, so they line up with your own calendar. Each period is one tile showing cost and tokens together (`$4.08 · 1.2M tokens`); a day with no usage reads **No data** rather than a misleading `$0.00 · 0 tokens` — the same as every other spend-tracking provider. The live Session and Weekly meters are unaffected. The dollars are estimated from token counts at API rates (that's the ⓘ) using the shared [model pricing](../pricing.md); sessions that ran on the fast/priority service tier — as recorded in each session's own log — use the fast rates for exactly those turns. Older logs without tier metadata, and everything else, price at standard rates; Runway does not consult the current `config.toml` setting, so a tier change never reprices past days. The token counts themselves are measured. Subagent and forked sessions copy their parent session's token history into their own log; Runway recognizes those copies and counts each token once, no matter how many subagents a session spawns. No log data leaves your Mac.

For supported GPT-5.4, GPT-5.5, and GPT-5.6 models, requests above 272k input tokens use OpenAI's long-context rates for the whole request. Cached input uses the published cache-read discount when the pricing source provides one; otherwise it is estimated at the full input rate. Fast/priority estimates use each model's published Codex multiplier (for example, GPT-5.5 uses 2.5×); model names ending in `-fast` are normalized to their unscaled base rate before that multiplier is applied once.

## Troubleshooting

- **"Not logged in"** — run `codex` and sign in, then refresh.
- **"Codex login needs renewal"** — the stored token has expired or was revoked. Runway never renews Codex's tokens itself, so run `codex` (it refreshes its login when it starts), then refresh Runway. The spend tiles keep working in the meantime.
- **"Codex login found in Keychain"** (a neutral key glyph, not a warning) — the login hasn't been loaded this app session. Connect, and choose **Always Allow** when macOS asks for access to `Codex Auth`.
- **"Keychain access to the Codex login was declined"** — a manual read was denied. Refresh and choose **Always Allow** when macOS asks.
- **API-key-only setups** can't read subscription usage — sign in with your ChatGPT account instead.
- **Spend tiles show "No data"** — Runway found no Codex session logs in the last 30 days. If your Codex home lives somewhere custom, set `CODEX_HOME` so both the Codex CLI and Runway look in the same place.
- **A custom home doesn't become a separate card** — confirm it has a ChatGPT OAuth login and either an `auth.json`, `config.toml`, or sessions directory that lets discovery recognize the home. API-key-only, tokenless, and nameless file credentials are skipped rather than guessed. For a keyring-only home, choose **Refresh All** and approve its exact `Codex Auth` item if macOS asks, then relaunch Runway so the bound account can become a card.

## Under the hood

`GET https://chatgpt.com/backend-api/wham/usage` with the Codex OAuth token, read-only: Runway never calls the token endpoint, and a 401/403 shows the renewal notice instead of retrying. Session and Weekly are classified by each usage window's duration rather than by its primary/secondary slot. This matters when Codex temporarily removes one limit and moves the remaining weekly window into the primary slot. Payloads without a recognized duration retain the primary-as-Session and secondary-as-Weekly compatibility fallback; response headers fill percentages missing from the corresponding window.

Spark and Spark Weekly come from the same response's `additional_rate_limits` array — model-specific limits that reuse the duration-based Session/Weekly classification. Runway surfaces the entry whose name identifies GPT-5.3-Codex-Spark as those two meters; accounts without the limit simply omit the entry, so the rows read "No data". Other model limits in that array aren't shown.

Runway preserves Codex's reported `used_percent` verbatim. If the API reports 1% used for an untouched window, the app shows 99% left; if it reports 0%, the app shows 100% left. Codex rows use the normal reset label rather than inferring a special "Not started" state. Burn-rate pacing still waits until enough of the window has elapsed — and until something has actually been used — to make a useful projection.

The "Rate Limit Resets" row shows the on-demand reset-credit count, e.g. `2 available`, with a colored dot for the soonest credit's expiry — blue beyond a week, yellow within a week, red within 48 hours. Runway also makes a best-effort `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` call — the dedicated endpoint that lists each credit's expiry. Hover the value and a popover shows those as a timeline of each reset, soonest-first — a numbered color dot, the exact expiry time (`Jul 12 at 5:30 PM`), and the countdown to it (`12d 18h`) on the trailing edge. When no credits are available it reads `0 available` and the popover shows `You have no rate limit resets`. If the dedicated call fails, the row falls back to the count embedded in the usage body (`rate_limit_reset_credits.available_count`); since that body carries no per-credit expiries, the popover states the count (`N available`) and notes that expiry times are unavailable rather than implying there are none.

### Using a reset from the popover

You can also spend a reset credit right from that popover — the same claim the Codex CLI's "Usage limit resets" picker performs. Hover a credit in the timeline and a **Use** button appears; clicking it expands that credit into an inline confirmation ("Immediately reset your usage limits. This can't be undone.") with **Reset** / **Cancel**. Confirming claims that exact credit from that card's account and immediately resets its 5-hour and weekly windows; the app then refreshes only that Codex card so the meters and the remaining count reflect it before the success line ("Reset claimed. Enjoy!") appears.

Safeguards, because a claim is irreversible:

- Claiming is always a deliberate two-click flow behind the hover popover — nothing is ever claimed automatically.
- Each claim targets one explicit credit (re-matched against a fresh credit list at claim time) and carries an idempotency key, so a retry after a network error can never spend a second credit.
- If the credit was meanwhile used elsewhere (CLI or web) the popover says it's no longer available and refreshes; if your usage doesn't need a reset, Codex refuses without spending the credit and the popover says so. After a claim resets usage, the remaining Use buttons disable ("nothing to reset") until the popover is reopened.
