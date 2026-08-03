# Privacy

Runway does not collect product analytics or usage statistics. It includes no analytics or crash-reporting service, creates no analytics identifier, and sends no app-use events, provider-refresh summaries, error categories, or crash reports.

On the first launch after upgrading from a version that included analytics, Runway deletes the retired analytics identifier and counters that version stored locally.

Provider usage stays on your Mac except for the network requests needed to read each provider's limits and the optional services you explicitly enable.

## Credentials Stored on This Mac

Runway primarily reads credentials that provider tools already keep on your Mac. When it writes a user-supplied API key or saves a refreshed credential, it replaces the file atomically and restricts it to your macOS account (owner read and write only). Antigravity's short-lived refreshed-token cache is tied to the current Keychain login using a one-way fingerprint; the refresh credential itself is not copied. The cache is never used after logout, an account change, or while Keychain access is unavailable.

All Claude access is strictly read-only. Runway never refreshes a Claude OAuth token and never writes to Claude Code's Keychain items or `.credentials.json` — Claude owns its logins and their rotation. For Claude Desktop, Runway can ask macOS for permission to use the `Claude Safe Storage` Keychain item so it can decrypt Desktop's current access token; it never uses Desktop's rotating refresh token and never modifies Desktop's config, cookies, or Keychain data.

## Other Network Requests

Besides the provider API calls that the vendor's own tools also make, Runway fetches public [model price lists](pricing.md) about once an hour from `raw.githubusercontent.com`, `models.dev`, and this project's GitHub Pages. These are plain downloads of public data and carry no usage, log, or account information. Spend tiles are computed from local CLI logs entirely on your Mac; no log data leaves it.

Runway also checks its signed update feed in release builds. See [Updates](updates.md).

## Local Usage Cache

To avoid re-reading unchanged Claude, Codex, and pi logs after every relaunch, Runway keeps parsed usage events in `~/Library/Application Support/Runway/log-scan-cache/`. These records contain the usage metadata needed for local totals, including any per-event cost already recorded by a provider, but not raw JSONL lines or conversation text.

The cache is private to your macOS account and is never sent to a provider or iCloud. Runway drops old source-file records as the scan window advances, and removes identity caches that have not been used for 35 days. Runway's pricing engine runs after the cache is read, so its computed aggregates and totals are not persisted in this cache.

## iCloud Sync

iCloud Sync is on by default; you can turn it off in Settings. With [iCloud Sync](icloud-sync.md) on, Runway writes normalized daily tokens, spend, and model totals to its private CloudKit database, plus each device's latest rendered usage snapshot (current quotas, plans, balances, and refresh errors). Your own devices use this data to show one combined summary and live usage. All of it stays inside your iCloud account and is never visible to Runway's developers or any provider. Credentials, raw provider responses, and raw logs are never written there. Turning sync off deletes this device's record from iCloud.

## Local Diagnostics

Runway writes a redacted diagnostic log on your Mac so failures remain visible and debuggable. The log is not uploaded automatically. See [Logging](logging.md).
