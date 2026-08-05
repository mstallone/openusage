# Cursor

Tracks your Cursor plan usage using the login from the Cursor app.

## What it tracks

| Metric | Meaning |
|---|---|
| Credits | Credit balance left from grants and prepaid account balance |
| Total Usage | Plan usage for the billing cycle (percent or dollars; included request count vs. cap on request-based Enterprise accounts) |
| Requests | Optional copy of the included request count vs. cap for custom layouts |
| Auto Usage | Auto-model usage percent |
| API Usage | API usage percent |
| Extra Usage | On-demand spend; user-scoped when available, otherwise the team aggregate; shown as a meter when Cursor returns a limit |

When Cursor reports your plan name, Runway shows it beside the provider name.

## Where credentials come from

Just be signed into the Cursor app. Runway reads Cursor's local state database (and its keychain entries) for the session tokens. All Cursor credentials are strictly read-only to Runway: it never refreshes a token and never writes the state database or keychain — the Cursor app owns the login and its rotation. When the token lapses, the card shows **"Cursor login needs renewal"**: sign in again where that login lives — open the Cursor app, or run `agent login` if you use the Cursor CLI — then refresh Runway. Nothing extra to install or configure.

Automatic refreshes never request the keychain secrets. After launch or a credential change, the card
offers a neutral **Connect** action (not a warning); that deliberate read is cached in memory for the running app session while the items'
non-secret metadata remains unchanged. Choose **Always Allow** to avoid a dialog on future manual reads. If the
login keychain itself can't be inspected (it's locked, say), the card asks you to unlock it instead.

## The spend tiles

Today, Yesterday, Last 30 Days, and Usage Trend come from Cursor's usage export. Runway uses the exported token counts and shared model pricing to estimate the cost locally. Cursor's export can arrive late, so the newest figures can lag behind current activity. Runway leaves isolated malformed rows out instead of silently counting broken values as zero. A failed download, invalid export schema, or broken CSV structure leaves spend history unavailable for that refresh. Each failure is recorded in the diagnostic log without including the exported usage data.

## Troubleshooting

- **"Not logged in" / token errors** — open Cursor and make sure you're signed in, then refresh.
- **Some metrics missing** — Cursor omits fields depending on plan type; missing metrics simply show "No data".
- **Optional lookup failed** — plan, credit-grant, prepaid-balance, and request-fallback failures stay nonfatal when primary usage is available. Runway records fixed, credential-free reasons in the diagnostic log.

## Under the hood

Connect RPC on `api2.cursor.sh` (dashboard usage), combined REST fallback at `cursor.com/api/usage` and `cursor.com/api/usage-summary` for Enterprise/team accounts, Stripe balance at `cursor.com/api/auth/stripe`, and the usage-events CSV export at `cursor.com/api/dashboard/export-usage-events-csv`. The fallback combines the included request allowance with structured percentages and user-scoped on-demand spend; neither REST response is treated as the whole account snapshot by itself. All requests are read-only against the stored token — a 401/403 shows the renewal notice instead of refreshing and retrying; optional endpoint failures stay nonfatal when the other fallback response is usable and are recorded in the diagnostic log. Per-day spend imputation uses exported token counts priced through the shared [model pricing](../pricing.md); Cursor-native models (`auto`, `composer-*`, …) come from its supplement layer, which maintainers sync from [Cursor models & pricing](https://cursor.com/docs/models-and-pricing.md).
