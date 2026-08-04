# Refreshing & Caching

## When data updates

- All enabled providers refresh together: once at launch, then every 5 minutes (a fixed cadence — there's no setting for it). Opening the popover does not start a second automatic pass. Providers fetch in parallel, so fast cards update without waiting for a slow one. Results that land close together coalesce briefly (a fraction of a second), so a burst publishes as one update. The batch itself still finishes only after every provider returns; notifications, history sync, and the next five-minute wait begin after that point.
- Turning a provider on (yourself in Customize, or automatically by first-launch/new-provider detection) fetches it promptly instead of waiting out the interval — even when the change lands in the middle of a refresh that's already running.
- The dashboard footer shows a compact countdown to the next update (like `5m` or `45s`). **Clicking it (or pressing ⌘R while that footer is present)** refreshes immediately, skipping the cache.
- The one-shot `runway` command reuses this same persisted cache for five minutes, refreshes missing or stale entries without starting the app, and exits. `runway --force` runs the same forced provider refresh as ⌘R regardless of cache age — with one difference: it never opens a Keychain approval dialog, and it can't reuse the app's approval either (the command is a separately signed binary). Providers whose credentials live only in a protected Keychain item are read by the app and reach the command through the shared snapshot; see [CLI](cli.md).
- While a provider is fetching, a small spinner appears next to its name (and the footer countdown becomes one), so you can tell a refresh is in flight rather than wondering if the numbers are stale.
- With [iCloud Sync](icloud-sync.md) on, a refresh batch publishes this device's one sync record after
  the whole batch finishes. Manual provider refreshes write after that provider finishes, and adjacent
  changes are debounced into one write.

## Caching

Snapshots are cached on disk and load instantly at launch, so you see your last-known values immediately instead of placeholders — even before the first fetch finishes.

Claude and Codex cache entries also remember which account produced them. If you swap the account
signed in at the provider's default home between launches, the previous account's cached values are
discarded at the next launch (the card starts empty and fills on its first fetch) instead of briefly
showing the old account's limits and plan under the new login.

A cached value only counts as *fresh* (skip-a-refresh fresh) when it was fetched **during the current running session**. So a value cached in an earlier session always re-fetches on the first pass after launch — you still see it instantly, but the app never waits out the old interval before getting live numbers. This matters after an update: a new app version refreshes right away instead of showing the previous version's data until its interval lapses. Within a session, a freshly fetched value then counts as fresh for one refresh interval before the next pass re-fetches it.

Claude, Codex, and pi spend history has a separate local-log parse cache under
`~/Library/Application Support/Runway/log-scan-cache/`. It stores parsed usage events before Runway
applies model-rate estimates, so pricing updates take effect without re-reading unchanged JSONL. On
relaunch, an entry is reused only when its path, size, modification time, and parser version still match.
A Claude or Codex session log that only *grew* since its last parse doesn't re-read from the start.
The cache remembers how far it parsed, plus a fingerprint of the bytes just before that point, so it
still detects a rewritten file and re-parses it in full. The scanner reads only the newly appended lines.
This keeps refreshes cheap while a long agent session appends to a very large log file.
Same-home cards share parsed data, and changing one source file rewrites only that file's record. Old files
leave the cache as the history window advances, and identities unused for 35 days are removed. App writes
are debounced until after refresh; the one-shot CLI drains pending writes before it exits.

## When a fetch fails

A failed refresh **never wipes your data**: the last good values stay on screen, and a small warning triangle appears at the right edge of the provider's header — hover it for the error message (e.g. "Not logged in"). **Click the triangle to refresh that provider**, which is usually what clears the problem — a login waiting for Keychain approval, or a token you just renewed in your terminal. Like every refresh you ask for yourself, that click may show a macOS permission prompt; background refreshes never do. While the refresh runs, the triangle gives way to the header's spinner. The error clears on the next successful refresh.

When a provider stops responding, Runway cuts it off after a per-provider ceiling (2.5 minutes for most; providers with legitimately slower flows, like Copilot's multi-org billing probe, allow more). So only genuinely dead work gets cut. The attempt counts as a failed refresh — same warning triangle, message "Refresh timed out after 150s" — instead of leaving the refresh spinner running forever. Like any failure, the provider backs off briefly before the next attempt, and a new attempt never overlaps a timed-out one that is still winding down.

The last good normalized history is preserved too, so a temporary provider failure—or a successful
limit refresh whose local log scan is temporarily unavailable—does not remove this Mac's previous
contribution from an iCloud-combined spend total.

Rows that have never had data show "No data" rather than made-up numbers.

## Stale data

A failed refresh keeps the last good values on screen, so those values can persist while refreshes keep failing. Without a marker, a plan or limit that changed on the provider's side keeps showing the old figures indefinitely. To make that obvious, a small **"Outdated"** tag appears next to the provider's name once its data is more than a couple of refresh cycles old (about ten minutes); hover it for the precise age ("Last updated 3h ago"). The tag stays short so it never crowds a long plan name. When you see it, the numbers below are from that earlier time, not live — usually because the provider is failing to refresh (check the warning triangle) or the Mac was asleep. A successful refresh clears it.
