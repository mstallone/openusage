# Sakana Fugu

Tracks Fugu subscription quota from Sakana AI Console, plus local Fugu Ultra token history and
estimated API-rate value from Codex rollouts.

## What it tracks

| Metric | Meaning |
| --- | --- |
| Five-Hour Usage | Usage percentage in the rolling five-hour window |
| Weekly Usage | Usage percentage in the shared weekly window |
| Usage Trend | Daily fixed-rate Fugu tokens saved by Codex on this Mac |
| Today | Today's local tokens and estimated API-rate value |
| Yesterday | Yesterday's local tokens and estimated API-rate value |
| Last 30 Days | Local tokens and estimated API-rate value over the history window |

The five-hour window begins with the account's first request. Weekly usage resets every Monday at
00:00 UTC. These are account-wide subscription pools, not usage from only this Mac.

Before a subscription window has any usage, Sakana Console returns that quota row as explicitly
empty. Runway treats that state as 0% used and keeps showing both meters. A missing quota field or
malformed value still produces an unsupported-response error so a real console format change is not
mistaken for zero usage.

The graph and spend rows are different: they come from local Codex logs and include only usage saved
on this Mac. If private iCloud sync is enabled, Runway can combine that machine-local history with
history from your other Macs without double-counting the account-wide subscription meters.

## Local Fugu history

Runway finds Sakana-configured Codex homes from `CODEX_HOME`, `~/.codex*`, and direct directories
under `~/.config`. This includes launcher-specific homes such as `~/.codex-fugu`. It parses the same
`sessions/` and `archived_sessions/` rollout files as the Codex provider, filters the events to Fugu,
and avoids copied-session and subagent-replay double counting.

Only models with a fixed published price are included:

| Model | Input | Cached Input | Output |
| --- | ---: | ---: | ---: |
| Fugu Ultra v1.0 / v1.1 | $5 / 1M | $0.50 / 1M | $30 / 1M |
| Fugu Cyber v1.0 | $6 / 1M | $0.60 / 1M | $36 / 1M |

For requests above 272,000 input tokens, the whole request uses the published long-context rates:
Ultra uses $10 input, $1 cached input, and $45 output per million; Cyber uses $12, $1.20, and $54.
Plain `fugu` is deliberately left unpriced because its charge depends on the routed underlying model.

These dollars are estimates of API-rate value, not an invoice or an extra subscription charge. Codex
saves input, cached-input, output, and total counts, but not Sakana's separate orchestration-detail
fields. The graph and estimate can therefore undercount orchestration tokens. Runway never invents
the missing fields or adds reasoning tokens a second time.

## Where credentials come from

Runway looks for a signed-in `console.sakana.ai` session in Chrome, Arc, Brave, and Microsoft Edge
profiles. It reads the browser's cookie database in read-only mode, decrypts the Sakana session in
memory with that browser's Safe Storage key, and sends the cookie only to Sakana Console. Runway
does not copy the cookie into its own configuration, refresh it, or change the browser database.

After launch, the card offers a neutral **Connect** action to load the browser's Safe Storage key.
That read can show a macOS Keychain prompt; choosing **Always Allow** avoids the dialog on future
manual reads. Runway caches the derived key for the rest of the process, so scheduled refreshes do
not request the Keychain secret. If you deny the request, the browser session stays untouched and
the provider shows a permission warning.

Safari is not currently supported because it uses a different cookie store and security model.

## Setup

1. Open [Sakana AI Console](https://console.sakana.ai/) in Chrome, Arc, Brave, or Microsoft Edge.
2. Sign in to the Sakana account that owns the Fugu subscription.
3. If you want local spend estimates and the usage graph, use Fugu through a Sakana-configured
   Codex home, such as the official `codex-fugu` launcher.
4. Refresh Runway and approve the browser Safe Storage Keychain request if macOS shows one.

Runway detects either the local Sakana cookie or a Sakana Codex home without contacting the
network during first-run and new-provider detection.

## Why the API key is not used

`SAKANA_API_KEY` authenticates model requests at `api.sakana.ai`, but Sakana does not expose the
five-hour or weekly subscription pools, or account-wide request history, through a documented API-key
endpoint. A model response contains only that request's token counts, not the remaining account quota.
Direct use of responses also requires Runway to proxy every future request.

The provider uses the signed-in console session for subscription usage and reads the resulting local
Codex records for history. Your `SAKANA_API_KEY` remains available to Codex and other tools that make
model calls; Runway neither reads nor sends it.

## Under the hood

- `GET https://console.sakana.ai/api/auth/session` verifies that the borrowed browser session is
  current.
- `GET https://console.sakana.ai/billing` reads the five-hour and weekly values rendered by Sakana
  Console.

The billing data is embedded in the console's authenticated page payload rather than exposed by a
public quota API. Runway validates the known shape strictly and reports a decoding error if Sakana
changes it, instead of silently displaying zero. Local history scanning makes no network requests.

## Troubleshooting

- **"Sign in to Sakana AI Console"** — sign in through a supported Chromium browser, then refresh.
- **"Sakana browser session found"** (a neutral key glyph / **Connect** button, not a warning) — the
  Safe Storage key hasn't been loaded this app session. Connect and approve the macOS Keychain
  prompt; choose **Always Allow** to avoid a dialog on future manual reads.
- **"Keychain access to your browser's Safe Storage key was declined"** — a manual read was denied.
  Refresh and choose **Always Allow** when macOS asks.
- **"The Sakana browser session expired"** — sign out and back in at Sakana AI Console, then refresh.
- **"The Sakana browser session couldn't be decoded"** — update or restart the browser, sign in again,
  and retry. A change to the browser's cookie encryption can cause this.
- **"Unsupported billing response"** — Sakana changed its private console page format. Update
  Runway; your browser login and API key are not modified.
- **Graph or spend rows show "No data"** — use Fugu through a detected Codex home. Plain `fugu` cannot
  be assigned a fixed estimate; use Fugu Ultra or Cyber for priced history.
