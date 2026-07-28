# Grok

Tracks Grok Build credit usage using the login from the Grok CLI.

## What it tracks

| Metric | Meaning |
|---|---|
| Weekly | The shared weekly pool's usage percent (the limit Grok's unified billing enforces), with the weekly reset countdown |
| Extra Usage | Pay-as-you-go cap as a status (e.g. `2500 cap` or `Disabled`) |
| Today / Yesterday / Last 30 Days | Local cost and tokens estimated from the Grok CLI log |

When Grok reports your subscription tier, Runway shows it beside the provider name.

The weekly shared pool is the limit Grok enforces for unified-billing accounts (the old monthly credits meter is legacy and no longer shown). Accounts that haven't been migrated to unified billing have no weekly pool, so the Weekly tile reads "No data" there.

## Where credentials come from

Sign in once with the Grok CLI (`grok login`); Runway reads the same `~/.grok/auth.json`. Access tokens refresh automatically before expiry, and rotated tokens are written back to the file.

## The spend tiles

Today / Yesterday / Last 30 Days are computed **locally** from the Grok CLI's log (`~/.grok/logs/unified.jsonl`, or `$GROK_HOME/logs/unified.jsonl`) — Runway reads the log directly. Each period is one tile showing cost and tokens together (`$4.08 · 1.2M tokens`), the same as Claude/Codex/Cursor. The dollars are estimated from token counts at public API rates using the shared [model pricing](../pricing.md) (that's the ⓘ); the token counts themselves are measured, and these estimates are separate from the monthly credits the billing API reports. No log data leaves your Mac. A period with no recorded usage reads "No data" rather than a misleading `$0.00 · 0 tokens` — the same as every other spend-tracking provider.

## Troubleshooting

- **"Session expired" / auth errors** — run `grok login` again, then refresh.
- **Weekly shows "No data"** — your account still reports a monthly (non-weekly) period, meaning it hasn't been migrated to Grok's unified weekly billing yet.
- **Spend tiles show "No data"** — they need the Grok CLI's log at `~/.grok/logs/unified.jsonl`; older CLI versions logged no token counts. Run a Grok CLI session to populate it, then refresh.

## Under the hood

`GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` for the weekly pool and pay-as-you-go cap — the exact call the Grok CLI itself makes — and `…/v1/settings` for the plan name; token refresh via `auth.x.ai`. A 401/403 triggers one token refresh and retry.
