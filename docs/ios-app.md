# iOS Companion App

RunwayMobile (in `ios/`) is a read-only iPhone/iPad viewer for the usage your Macs publish through
[iCloud Sync](icloud-sync.md). It holds no provider credentials and never writes to iCloud: it
fetches every device record from Runway's private CloudKit database and renders it.

The dashboard shows:

- **Across Your Macs** — Today, Yesterday, and Last 30 Days spend/token tiles plus a usage trend,
  day-summed from every device's history payload (the same additive model the Mac uses).
- **One section per Mac** — that device's live snapshot: each provider's rendered rows (quota
  meters with reset countdowns, spend tiles, status badges, charts), its plan, warnings, and
  refresh errors, with the record's age in the header.

Data refreshes on launch, on returning to the foreground, and with pull-to-refresh. Liveness is
bounded by the Macs' five-minute publish cadence.

## Wire contract

The app decodes the versioned payloads the Mac writes (`runway.history.v2`,
`runway.snapshot.v1`) with tolerant decoders in `ios/RunwayMobile/SyncWire.swift`: unknown JSON
keys and unknown row types are ignored, so additive Mac-side changes don't break older phones. A
schema *bump* shows an "update Runway and this app" notice instead of wrong numbers. When the Mac
payloads change shape, update `SyncWire.swift` to match.

## Building

Open `ios/RunwayMobile.xcodeproj` in Xcode and run, or:

```bash
xcodebuild -project ios/RunwayMobile.xcodeproj -target RunwayMobile \
  -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

That unsigned simulator build is for compile verification only — launching it would abort at
CloudKit setup, since it carries no iCloud entitlements (iOS offers no public API to probe for
them first). Run the app from Xcode instead, which signs simulator and device builds alike.

Debug builds read the development container (`iCloud.com.mattstallone.runway.dev`, Development
environment — the same place dev Mac builds write); Release builds read the production container.
The App ID (`com.mattstallone.runway.mobile`) needs the CloudKit capability with both containers;
signing is automatic with the development team. On device, the app must be signed into the same
iCloud account as the Macs.

## Releasing (TestFlight)

The iOS app ships from the same `v*` tag as the Mac app: the release workflow's "iOS TestFlight"
job archives the app, signs it, and uploads it to App Store Connect, which serves it to TestFlight
testers once Apple finishes processing. Testers install and update through the TestFlight app —
there is no Sparkle feed on iOS, and no notarization either (the App Store Connect upload plays
that role).

- The version is the tag (`v0.7.1` → `0.7.1`) and the build number is the git commit count, both
  injected at build time — the `MARKETING_VERSION` in the Xcode project is never bumped by hand.
  TestFlight rejects a reused build number for the same version, so rerunning a tag that already
  uploaded fails at the upload step; tag a new patch version instead.
- Signing is Xcode cloud signing with the App Store Connect API key the Mac release already uses
  for notarization — no certificate or provisioning profile secrets. The key must have the App
  Manager role.
- `script/release_ios.sh` is the whole build; run it locally with `SKIP_TESTFLIGHT_UPLOAD=1` to get
  a signed `.ipa` in `dist/ios/` without uploading.

The one-time App Store Connect setup (app record, tester group, key role) is documented in the
release-swift skill under `.agents/skills/release-swift/`.
