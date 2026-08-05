# Architecture

A high-level map of Runway's structure, for people who work on the code. For what the app
*does*, start with the [behavior docs](README.md).

## The shape of the app

Runway is a SwiftPM package with a shared module and two thin executables — there is no Xcode project.
The main executable is a menu-bar app: a SwiftUI interface hosted inside an AppKit status item and panel.
The code is grouped by role:

- `App/` — startup and the AppKit bridge (status item, panel, the app entry point).
- `Models/` — the small value types the rest of the app speaks in (`MetricLine`, `WidgetData`, descriptors).
- `Providers/` — one folder per provider (Claude, Codex, Cursor, Devin, Grok, OpenCode, …).
- `Stores/` — the mutable state the UI observes.
- `Services/` — shared infrastructure (HTTP, the local API, process running).
- `Support/` — small shared helpers (formatting, parsing, animations).
- `Views/` — the SwiftUI screens (dashboard, customize, settings, menu-bar strip).

## Composition root

`AppContainer` is the one place that wires everything together. At launch it builds the list of
providers, turns it into a `WidgetRegistry`, creates the stores, starts the periodic refresh loop, and
starts the local HTTP API. Everything else receives what it needs from here rather than reaching for
globals, which keeps the pieces testable in isolation.

The `runway` executable imports the same module. A normal invocation reads `ProviderSnapshotCache`
and exits; `--force` constructs the canonical `ProviderCatalog` and calls `WidgetDataStore`'s forced
refresh path before reading. Providers annotate the scalar resources they export through the stable
limits contract; the CLI and `/v1/limits` share one serializer over those same normalized snapshots.
It never launches the GUI or duplicates provider, auth, pricing, or mapping logic.

## The provider pipeline

Each provider is a small module that conforms to `ProviderRuntime`. A refresh flows through three parts:

1. **Auth store** — reads credentials that already exist on the machine (config files, keychain). Runway
   never asks the user to paste tokens.
2. **Usage client** — makes the HTTP calls to the provider's API.
3. **Mapper** — turns the provider's response into the app's own vocabulary: a `ProviderSnapshot`
   containing typed widget values (`.progress`, `.values`, `.badge`, `.chart`) plus `.text` notices that
   remain available through the local API but do not render as widgets.

Because every provider produces the same normalized `MetricLine` shapes, the UI renders them all the same
way and doesn't need to know provider-specific details. To add one, see
[Adding a provider](adding-a-provider.md).

### Credential ownership

The app that owns a credential is the only app allowed to change it. Provider credentials belong to
the provider's own tool (Claude Code, the `codex` CLI, the Cursor app, GitHub CLI, …). Runway never
writes any provider's **Keychain** item — the type system enforces that, because every credential
store holds the read-only `KeychainReading`. Runway's own private iCloud-sync device ID lives in
Application Support through `RunwayOwnedFileStore`, so it needs no Keychain write API. Grok and
Kimi remain the exception on the file side: Runway still refreshes those logins and saves them back
to their CLIs' own credential files.

For Claude, Codex, Cursor, and Copilot, Runway never calls their OAuth token endpoints either,
because two apps rotating the same login can trip the server's token-reuse protection and sign the
user out. When one of those tokens lapses, the card shows a renewal notice naming the owning app;
Runway never renews it. Antigravity is the one endpoint-side exception: Runway refreshes its access
token through Google OAuth — safe because Google refresh tokens do not rotate — and caches the
result in Runway's own file, never writing back to Antigravity's Keychain item. Grok and Kimi still
refresh their own file-based logins (no Keychain involved); moving them to the same read-only model
is the remaining ownership follow-up.

Automatic refreshes never request secret data from another app's Keychain item. They inspect only
non-secret metadata and reuse, for the rest of that process while the item is unchanged, a value
loaded by a manual refresh;
after launch or a credential change, the user connects the login again through a deliberate refresh.
That waiting state is deliberately neutral in the UI (a Connect affordance, not a warning): the
metadata-only pass defers the read, it is not denied it — only an actual denial of an attempted
manual read, an expired token, or an unreadable keychain warrants a warning. Manual **Refresh All**
queues protected providers and prompts for them one at a time, so approval dialogs never overlap.
If a refresh is cancelled while its read is still queued, that read leaves the queue without touching
Keychain. Clicking **Use** on a Codex reset credit may also prompt after every cached credential was
rejected. Both paths are user-initiated with the app in front of the user.

Claude, Codex, and pi share `IncrementalJSONLScanner` for local JSONL history. The scanner caches
per-file parsed events by path, size, and modification time in a versioned Application Support store,
partitioned by provider/home identity. Provider instances that read the same home share one scanner
actor, which avoids duplicate parsing across cards; the disk store provides the reuse across process
launches. A session log that only grew since its last parse re-reads just the appended bytes and resumes
from the recorded parser state. Scans drop source-file records as their modification dates leave the
requested history window. The scanner also memoizes aggregation and pricing: when a refresh finds no log
changes (and the pricing snapshot, history window, and calendar configuration are unchanged), it reuses
the previous aggregation instead of pricing every cached event again.

## Stores

The UI reads from a few observable stores:

- `WidgetDataStore` — the latest snapshot per provider, plus refresh and caching. It keeps machine-local
  cached snapshots separate from rendered snapshots so peer history can never be written back out and
  counted again.
- `LayoutStore` — which metrics are shown, the provider/metric order, and which metrics are starred for the
  menu bar.
- `ProviderEnablementStore` — which providers the user has turned on or off.
- `ICloudUsageSyncStore` — one CloudKit record per device in the app's private database (history plus a
  live snapshot for companion apps), a five-minute peer poll, and the visible device/error state. Cloud
  access is injected for lifecycle and failure tests.

Refresh runs on a timer in `AppContainer`; each pass respects the cache, so the app only hits the
network once a snapshot has actually expired.

Providers with spend tiles carry an explicit history scope beside their export descriptors. Machine-local
sources can be summed across device records; account-wide sources such as Cursor cannot. `WidgetDataStore`
re-renders only the spend rows from the union, leaving quota and error state local.

## The AppKit bridge

macOS menu-bar apps live in an `NSStatusItem`. Runway shows its content in a custom, key-capable
`NSPanel` rather than an `NSPopover`. A popover's window is only key while the whole app is active,
and activation of a menu-bar (accessory) app is asynchronous and unreliable on recent macOS — so a
popover cannot receive keystrokes until a second click. A non-activating `NSPanel` whose
`canBecomeKey` is `true` takes key focus the instant it opens, so keyboard navigation just works.
`App/` owns that AppKit layer and hosts the SwiftUI views inside it, so the bulk of the UI can stay
plain SwiftUI.

Settings is a separate, ordinary window (`App/SettingsWindowController.swift`) rather than a popover
screen: a preferences-style toolbar window. The controller creates it lazily on first open, mounts
only the active tab's SwiftUI pane, and tears it down entirely on close, so it costs nothing while
hidden.

## Platform support

Runway runs on macOS 15 (Sequoia) and later. It is built against the latest SDK and back-deploys:
on macOS 26 (Tahoe) it uses the system's Liquid Glass controls, and on macOS 15 it falls back to the
standard controls with the same behavior (the footer still pins, the buttons keep their states). Every
one of those version checks lives in a single file — `Support/LiquidGlassFallbacks.swift` — so the views
stay free of `#available` checks.

The release build (`script/release.sh`) ships a universal binary (arm64 + x86_64), so a single DMG runs
natively on both Apple Silicon and Intel Macs. The dev build (`script/build_and_run.sh`) stays host-arch
only — a universal dev build just doubles compile time on the maintainer's own machine for no benefit.

## Local HTTP API

A small loopback server exposes the current usage as JSON on `127.0.0.1:6736` for other local tools. See
[Local HTTP API](local-http-api.md) for the endpoints and the privacy tradeoff.
