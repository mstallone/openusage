# Settings

Settings opens in its own window — separate from the popover, so the dashboard stays a quick glance and Settings gets room to breathe. Open it from the popover footer's **gear** menu, with ⌘, while the popover is showing, or by right-clicking the menu bar icon and choosing Settings. Opening Settings closes the popover; close the window with the red close button, Esc, or ⌘W.

The window is organized into four tabs — **General**, **Appearance**, **Notifications**, and **Advanced** — using the classic macOS preferences toolbar. It remembers the tab you were on, its size, and its position, and it only exists while it's open: a closed Settings window uses no memory or CPU at all, and reopening it is instant.

While Settings is open, Runway briefly appears in the Dock (the same as during an [update session](updates.md)) — that's what reliably brings the window to the front of a menu-bar-only app. It leaves the Dock again when you close the window.

## General

| Setting | Options | What it does |
|---|---|---|
| Show Total Spend | on/off | Whether the cross-provider [Total Spend](dashboard.md#total-spend) card shows at the top of the dashboard. On by default; the card appears whenever at least one enabled provider tracks spend (Claude, Codex, Cursor, Grok, OpenCode, Sakana Fugu). |
| Launch at Login | on/off | Registers the app as a login item (the system's login-item registry is the source of truth). |
| Global Shortcut | record a shortcut | Global shortcut that toggles the popover from anywhere. Click the field and press a combo; the ⓧ clears it and disables the shortcut. |

### iCloud Sync

**Sync Across Macs** is on by default (turn it off here to keep this Mac local-only). It shares
normalized Runway history and each
device's latest usage snapshot through the app's private CloudKit database, and combines
machine-local tokens and spend across Macs signed into the same iCloud account. Settings shows the
five-minute write cadence and each device's relative **Updated** time; it also reports unavailable
iCloud, loading, write, and malformed-record states. See [iCloud Sync](icloud-sync.md) for what is
included and which surfaces use the combined values.

### Privacy

| Setting | Options | What it does |
|---|---|---|
| Hide From Screen Share | On / Off | Off (default). On replaces the menu bar strip with the Runway icon and wordmark while your screen is being shared or recorded, and restores your starred metrics the moment the capture ends. See [Menu bar](menu-bar.md#hiding-usage-while-screen-sharing). |

## Appearance

| Setting | Options | What it does |
|---|---|---|
| Icon Style | Text / Bars | How starred metrics render in the menu bar. See [Menu bar](menu-bar.md). |
| Theme | System / Light / Dark | App-wide appearance override for the popover and the Settings window. |
| Time Format | Auto / 12-hour / 24-hour | How exact times read (e.g. "Resets today at 6:38 PM" vs "18:38"). Auto follows the system. |
| Increase Transparency | Off / On | Off (default) keeps the popover a solid panel. On makes it translucent so your desktop shows through, while keeping the numbers and footer controls legible with adaptive frosted surfaces. It pauses automatically when you have the macOS **Reduce Transparency** or **Increase Contrast** accessibility setting turned on (a note explains why), so it never works against those preferences. |

### Usage Display

| Setting | Options | What it does |
|---|---|---|
| Show Usage As | Used / Left | Whether bounded metrics read "48% used" or "52% left" — same toggle as clicking a headline. |
| Reset Times | Countdown / Exact time | "Resets in 3h 25m" vs "Resets today at 6:38 PM" — same toggle as clicking a reset label. |
| Always Show Pacing | Off / On | Off (default) shows pacing only when a metric is close to or over its limit. On surfaces it on every metric with a reset window: on-track rows gain their projection ("~33% left at reset") and an even-pace tick that marks where steady use puts you right now. Metrics without a reset window have no pace to show. |

## Notifications

Runway can alert you with a macOS notification when a metric runs low or its pace gets worse, so you don't have to keep the popover open to catch a quota creeping toward its limit. Alerts work while the app runs in the menu bar, even with the popover closed.

| Setting | Options | What it does |
|---|---|---|
| Almost Out | On / Off | Alerts when a metric crosses under 10% remaining, including balances without a reset window. |
| Cutting It Close | On / Off | Alerts when a metric is projected to finish the period with little left — close to its limit. |
| Will Run Out | On / Off | Alerts when a metric is projected to run out before it resets. |

Alerts fire on a new crossing or pace worsening, then stay deduplicated while that condition is unchanged, so you do not get repeats on every refresh. A quota already in a bad state when Runway launches establishes the baseline without alerting. If it recovers and later worsens again, the alert re-arms; a new reset period also clears the reset-based history. **Almost Out** is based only on the remaining share, so it also works for bounded balances without a reset window. **Cutting It Close** and **Will Run Out** require reset-window pace context. Metrics whose data cannot be read never alert. Turn all three triggers off to silence everything. When several alerts fire at once, they stack into a single grouped banner.

All three alerts default off. The first time you turn one on, Runway asks for notification permission. If you decline (or turn notifications off for Runway in System Settings later), a warning mark appears on the Notifications header, and an "Open System Settings" button shows under the toggles so you can re-enable them. A notification's title is the alert name, its subtitle names the provider and metric, and its body is the plain-language verdict. Tapping an alert opens the popover on the dashboard.

## Advanced

### Command Line

| Setting | Options | What it does |
|---|---|---|
| Terminal Helper | Install / Uninstall | Adds a global `runway` command agents can use to monitor limits. See [CLI](cli.md). |

### Logging

| Setting | Options | What it does |
|---|---|---|
| Log Level | Error / Warning / Info / Debug | How much detail the app writes to its log file. Defaults to Info and persists across launches; raise to Debug while reproducing a problem. Applies immediately. |
| Copy Log Path | button | Copies the log file path (`~/Library/Logs/Runway/Runway.log`) to the clipboard. |
| Reveal in Finder | button | Opens a Finder window with the log file selected. |

See [Logging](logging.md) for the full behavior: subsystem tags, the file size cap, and the guarantee that secrets are never written.

### Updates

The Updates section appears in official packaged builds that include the signed update feed. Local
developer builds do not show it.

| Setting | Options | What it does |
|---|---|---|
| Update Automatically | On / Off | Whether Sparkle checks for updates in the background. You can still check manually when this is off. |
| Check for Updates… | button | Starts a manual update check and opens Sparkle's update window. |

See [Updates](updates.md) for the dashboard banner and signature verification.

## Version

The app version shows in the popover footer.

Your settings carry across updates — layout, stars, preferences, and the menu-bar shortcut all stay put. When an update changes how a setting is stored, the app upgrades it in place on launch, stepping through any in-between versions if you skipped a few. Nothing is reset.

Which providers you have on also carries across updates — your choices are never overridden. A brand-new install picks its starting set by detecting the AI tools on your Mac (see [Dashboard § First launch](dashboard.md#first-launch)). When an update ships a provider you've never seen, the same local detection runs once for just that provider and turns it on only if you actually have the tool; everything you've already decided about stays exactly as you set it. See [Which Providers Are On](provider-enablement.md).
