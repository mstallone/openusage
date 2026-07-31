# iCloud Sync

**Sync Across Macs** is on by default and can be turned off in Settings. While it is on, each
device keeps one versioned record in
Runway's private CloudKit database — part of your own iCloud account — and reads the records written
by your other devices. A random device ID is kept in the login Keychain so the same Mac continues
updating its existing record after app preferences are reset or the app is reinstalled. There is no
folder picker, pairing code, or separate account.

Each device's record has two parts:

- **History** — normalized daily tokens and spend, model totals, and unknown-model names for sources
  that are local to one Mac: Claude, Codex, Grok, Sakana, and OpenCode. Macs merge these into the
  combined view. Cursor's history is already account-wide, so it is never added across Macs.
- **Snapshot** — that device's latest rendered usage state for every enabled provider (current
  quotas, plans, balances, reset times, and refresh errors). Macs never display other Macs'
  snapshots; this part exists for companion apps (such as the iOS app) that show live usage without
  holding any provider credentials.

Records never contain credentials, raw logs, or raw provider responses. Disabling a provider
immediately removes its peer contributions from the combined view and omits it from this device's
next record, while its local cached snapshot remains.

Runway combines the valid history payloads in memory and rebuilds Today, Yesterday, Last 30 Days,
Usage Trend, unknown-model warnings, and model breakdowns. The same combined spend rows feed the
dashboard, Total Spend, menu-bar pins, share cards, and the local HTTP API. Both `/v1/usage` and
`/v1/limits` read the same rendered snapshots; the former is the deprecated UI-oriented format and
the latter is the normalized format. Quotas, plans, balances, and provider errors on a Mac remain
that Mac's own values inside those snapshots. Rows retained in an older peer record are ignored once
they fall outside the same calendar window used by the local history scanners.

Because every device only ever writes and deletes its own record, records cannot conflict: a save is
always the same device replacing its previous value. Readers fetch the whole zone and rebuild the
peer set from scratch, so a device that stops syncing simply disappears on the next load.

This Mac updates its record after a five-minute refresh batch, a manual refresh, or a provider
enablement change, and checks for peer updates at the same moments plus on a five-minute poll.
CloudKit delivery is usually a matter of seconds, but it is eventually consistent — an offline Mac
catches up when it comes back.

## Multiple accounts across Macs

Histories match by **account**, not by card name. Each device's record notes which account every
card belongs to (an opaque account/organization identifier — never an email), so the same account
merges into the same card everywhere, even when one Mac shows it as the main card and another as an
extra account card.

An account you use on another Mac but have no login for here doesn't become a card: it appears as
its own slice in **Total Spend**, named by its account code ("claude@ab12cd34") — so the number at
the top is the whole truth across your Macs, and several such accounts stay tellable apart. That
code is the same id the account's card carries on any Mac it's signed in on (the synced record holds
no emails or names to label it with). The moment you log that account in locally, its card appears —
under that same id — with the full cross-machine history already attached.

If a synced record cannot identify the account behind a main Claude or Codex card, Runway keeps its
spend in one remote family slice instead of attaching it to a different local account or dropping it
from Total Spend.

Devices running an older Runway read their own format but report this device's newer record as
"update Runway" — update both sides to sync multi-account machines.

Settings lists each valid device record with the time that device generated it. To remove a device
from the combined summary, turn sync off on that device; this deletes its record from iCloud.
Turning sync off also stops that device from reading peers and immediately returns every surface
there to local-only spend. Malformed records are ignored and reported in Settings and the app log.

## Development and release setup

Apple requires the iCloud container assignment to be present in the provisioning profile embedded in
the app, and the App ID must have the CloudKit capability. Runway uses separate containers so
development builds cannot write production data:

- `com.mattstallone.runway.dev` uses `iCloud.com.mattstallone.runway.dev`.
- `com.mattstallone.runway` uses `iCloud.com.mattstallone.runway`.

Development-signed builds additionally run against the container's **Development** CloudKit
environment (release builds use **Production**), so a dev build can never touch shipped data even
inside the same container.

CloudKit creates the `UsageHistory` zone, the `DeviceUsage` record type, and its `history` and
`snapshot` fields automatically the first time a development build writes — but only in the
Development environment. Production schemas are never auto-created: before the first release that
ships sync, and again after any schema change (a new record type or field), open the CloudKit
Console for the production container and use **Deploy Schema Changes** to promote the Development
schema to Production. A release build pointed at an undeployed Production container fails its first
write with the real CloudKit error in Settings and the app log.

Create a `MAC_APP_DEVELOPMENT` profile that includes every registered development Mac and a
`MAC_APP_DIRECT` profile for releases. Install the development profile on each included Mac. The
development build automatically selects the newest non-expired profile matching the development
bundle and iCloud container from Xcode's current profile directory or the legacy MobileDevice
directory:

```bash
./script/build_and_run.sh
```

Set `ICLOUD_PROVISIONING_PROFILE=/path/to/profile.mobileprovision` only when you need to override
that automatic selection. An explicit missing path fails the build instead of silently producing an
app without iCloud access.

The release workflow reads the base64-encoded `MAC_APP_DIRECT` profile from the repository Actions
secret `APPLE_DEVELOPER_ID_ICLOUD_PROFILE`. Keep the original provisioning profiles and signing `.p12`
in a password manager, never in the repository. A provisioning profile contains certificates and
entitlements rather than private keys, but treating it as a signing asset keeps rotation predictable.

To inspect the records written by a running build, use the CloudKit Console
(<https://icloud.developer.apple.com>) — pick the container, then **Data → Private Database → zone
`UsageHistory` → record type `DeviceUsage`**, in the **Development** environment for dev builds.
The same query works from the command line once `xcrun cktool save-token` has stored a token:

```bash
xcrun cktool query-records \
  --container-id iCloud.com.mattstallone.runway.dev \
  --environment development --database-type private \
  --zone-name UsageHistory --record-type DeviceUsage
```

No record is expected when sync is off, the app is signed without the matching profile, or the first
write has not completed. The Settings error and app log distinguish those cases (including a Mac not
signed into iCloud); the spinner only appears while a read or write is actually in progress.
