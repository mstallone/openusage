import SwiftUI
import WidgetKit
import os

/// The cross-device totals the widget renders — a Codable trimming of `CombinedUsage` so the last
/// good fetch can be cached and a failed refresh degrades to slightly stale numbers instead of an
/// empty lock screen.
struct WidgetUsage: Codable {
    struct Day: Codable {
        var date: String
        var tokens: Int
        var cost: Double?
    }

    var today: Day?
    var yesterday: Day?
    var last30Cost: Double?
    var last30Tokens: Int
    var trend: [Day]
    /// Totals are known to undercount: a payload was unreadable (newer schema on some Mac) or some
    /// models couldn't be priced. Mirrors the dashboard's warning states — never shown as complete.
    var partial: Bool
    var fetchedAt: Date
}

extension WidgetUsage {
    /// `unreadableHistories` (not the app's combined unreadable notice): the widget renders only
    /// the history-derived totals, so an unreadable snapshot must not flag complete totals as
    /// undercounting.
    init(combined: CombinedUsage, unreadableHistories: Bool, fetchedAt: Date) {
        self.init(
            today: combined.today.map(Day.init),
            yesterday: combined.yesterday.map(Day.init),
            last30Cost: combined.last30Cost,
            last30Tokens: combined.last30Tokens,
            trend: combined.trend.map(Day.init),
            partial: unreadableHistories || !combined.unknownModels.isEmpty,
            fetchedAt: fetchedAt
        )
    }

    /// Day boundaries move between refreshes: a cached entry must never label an older day's
    /// spend "Today", so re-anchor the day tiles to the wire keys of the current date (letting
    /// a cached "today" become "yesterday" after midnight) and drop whatever no longer matches.
    func reanchored(to now: Date) -> WidgetUsage {
        let formatter = UsageSyncReader.dayKeyFormatter()
        let todayKey = formatter.string(from: now)
        let yesterdayKey = UsageSyncReader.wireCalendar.date(byAdding: .day, value: -1, to: now)
            .map(formatter.string(from:))
        var usage = self
        if usage.today?.date != todayKey {
            usage.today = nil
        }
        if usage.yesterday?.date != yesterdayKey {
            usage.yesterday = today?.date == yesterdayKey ? today : nil
        }
        return usage
    }
}

private extension WidgetUsage.Day {
    init(_ day: CombinedUsage.Day) {
        self.init(date: day.date, tokens: day.tokens, cost: day.cost)
    }
}

/// Last good fetch, kept in the extension's own defaults purely as a fallback for failed
/// refreshes. The envelope pins the iCloud account's ubiquity identity token, and `load` only
/// replays for the same account — a direct account switch followed by a failed first fetch must
/// never resurface the previous account's numbers on the lock screen (the widget can't observe
/// `CKAccountChanged`; each timeline load re-verifies instead). No token means no caching: when
/// the account can't be identified, showing nothing beats risking someone else's usage.
enum WidgetUsageCache {
    private static let key = "cachedWidgetUsage.v2"
    private static let log = Logger(subsystem: "com.mattstallone.runway.mobile", category: "widget")

    private struct Envelope: Codable {
        var usage: WidgetUsage
        var accountToken: Data
    }

    /// The caller passes the token captured BEFORE its fetch began (and re-verified after), so
    /// data is never filed under an account it wasn't fetched from.
    static func save(_ usage: WidgetUsage, accountToken: Data?) {
        guard let accountToken else {
            log.warning("no ubiquity identity token; skipping widget usage cache")
            clear()
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            UserDefaults.standard.set(try encoder.encode(Envelope(usage: usage, accountToken: accountToken)), forKey: key)
        } catch {
            log.error("caching widget usage failed: \(String(describing: error), privacy: .public)")
        }
    }

    static func load() -> WidgetUsage? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            let envelope = try SyncWire.decoder().decode(Envelope.self, from: data)
            guard envelope.accountToken == currentAccountToken() else {
                log.info("cached widget usage is for a different iCloud account; discarding")
                clear()
                return nil
            }
            return envelope.usage
        } catch {
            log.error("cached widget usage undecodable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// The iCloud account's local identity token, archived for comparison and storage. Nil when
    /// the system can't identify the account — callers treat that as "unverifiable: don't cache".
    static func currentAccountToken() -> Data? {
        guard let token = FileManager.default.ubiquityIdentityToken else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }
}

/// Why there's no usage to show. Semantic (rather than a plain string) so every family can keep
/// the friendly-error signal at its own size: full text where there's room, a distinct symbol
/// plus a compact label on the circular face.
enum WidgetNotice {
    case signedOut
    case restricted
    case accountChanged
    case waitingForMacs
    case noRecentUsage
    case updateApp
    case unavailable
    case unreachable

    var text: String {
        switch self {
        case .signedOut: "Sign into iCloud"
        case .restricted: "iCloud restricted"
        case .accountChanged: "iCloud account changed"
        case .waitingForMacs: "Waiting for your Macs"
        case .noRecentUsage: "No recent usage"
        case .updateApp: "Update this app"
        case .unavailable: "iCloud unavailable"
        case .unreachable: "Can’t reach iCloud"
        }
    }

    var symbol: String {
        switch self {
        case .signedOut, .accountChanged: "person.icloud"
        case .restricted: "lock.icloud"
        case .waitingForMacs, .noRecentUsage: "icloud"
        case .updateApp: "exclamationmark.icloud"
        case .unavailable, .unreachable: "icloud.slash"
        }
    }

    /// One or two words that fit under the circular face's symbol.
    var shortLabel: String {
        switch self {
        case .signedOut: "Sign In"
        case .restricted: "Restricted"
        case .accountChanged: "Account"
        case .waitingForMacs: "Waiting"
        case .noRecentUsage: "No Usage"
        case .updateApp: "Update"
        case .unavailable, .unreachable: "Offline"
        }
    }
}

struct UsageEntry: TimelineEntry {
    var date: Date
    var usage: WidgetUsage?
    /// Reason rendered when there's no usage to show (signed out, nothing synced yet).
    var notice: WidgetNotice?
    /// The instance's configured display (long-press → Edit Widget): cost or token counts.
    var mode: UsageDisplayMode = .cost
    /// `usage` came from the cache because the refresh failed — views surface the fetch age
    /// instead of passing stale numbers off as current.
    var stale: Bool = false
}

extension UsageEntry {
    /// Fabricated numbers for the widget gallery and placeholders.
    static func sample(now: Date = Date(), mode: UsageDisplayMode = .cost) -> UsageEntry {
        let trend = (0...30).map { index in
            WidgetUsage.Day(date: "sample-\(index)", tokens: 20_000 + (index * 7) % 13 * 11_000, cost: nil)
        }
        let usage = WidgetUsage(
            today: WidgetUsage.Day(date: "sample-today", tokens: 58_342, cost: 12.84),
            yesterday: WidgetUsage.Day(date: "sample-yesterday", tokens: 112_951, cost: 24.10),
            last30Cost: 412.06,
            last30Tokens: 2_310_884,
            trend: trend,
            partial: false,
            fetchedAt: now
        )
        return UsageEntry(date: now, usage: usage, notice: nil, mode: mode)
    }
}

struct UsageTimelineProvider: AppIntentTimelineProvider {
    private static let log = Logger(subsystem: "com.mattstallone.runway.mobile", category: "widget")

    func placeholder(in context: Context) -> UsageEntry {
        .sample()
    }

    func snapshot(for configuration: UsageConfigurationIntent, in context: Context) async -> UsageEntry {
        if context.isPreview {
            return .sample(mode: configuration.display)
        }
        return await Self.loadEntry(mode: configuration.display)
    }

    func timeline(for configuration: UsageConfigurationIntent, in context: Context) async -> Timeline<UsageEntry> {
        let entry = await Self.loadEntry(mode: configuration.display)
        // The Macs publish every five minutes, but WidgetKit budgets reloads — half an hour
        // stays within budget while keeping spend totals close, and the app requests an
        // immediate reload whenever it fetches fresher data in the foreground.
        return Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(30 * 60)))
    }

    private static func loadEntry(mode: UsageDisplayMode) async -> UsageEntry {
        let now = Date()
        let reader = UsageSyncReader(logCategory: "widget")
        // Captured before any CloudKit work and re-verified after: the account can change while
        // the fetch is suspended, and results fetched under the old account must be neither
        // rendered nor cached under the new one — the widget's version of the app's generation
        // guard. (A nil token can't detect a switch; those fetches display but never cache.)
        let accountToken = WidgetUsageCache.currentAccountToken()
        do {
            let status = try await reader.accountStatus()
            switch status {
            case .available:
                break
            case .noAccount, .restricted:
                // The account is definitively gone or blocked: its numbers must not linger, and
                // the guidance differs — "sign in" is wrong advice for a Screen Time restriction.
                WidgetUsageCache.clear()
                log.info("account unavailable for widget: \(String(describing: status), privacy: .public)")
                return UsageEntry(
                    date: now,
                    usage: nil,
                    notice: status == .noAccount ? .signedOut : .restricted,
                    mode: mode
                )
            default:
                // temporarilyUnavailable / couldNotDetermine (and unknown future statuses): the
                // account is probably still there — treat like an unreachable fetch, keep cache.
                log.info("iCloud status transiently unavailable for widget: \(String(describing: status), privacy: .public)")
                return fallbackEntry(now: now, notice: .unavailable, mode: mode)
            }
            let result = try await reader.fetchUsage(now: now)
            guard accountToken == WidgetUsageCache.currentAccountToken() else {
                WidgetUsageCache.clear()
                log.info("iCloud account changed during widget fetch; discarding results")
                return UsageEntry(date: now, usage: nil, notice: .accountChanged, mode: mode)
            }
            guard result.combined.hasData else {
                WidgetUsageCache.clear()
                // When history payloads were skipped as unreadable, "waiting" or "no usage"
                // would be a lie — the honest guidance is the dashboard's update notice.
                // Unreadable snapshots don't count here: they never feed the widget's totals.
                let notice: WidgetNotice = result.unreadableHistories > 0 ? .updateApp
                    : result.devices.isEmpty ? .waitingForMacs : .noRecentUsage
                return UsageEntry(date: now, usage: nil, notice: notice, mode: mode)
            }
            let usage = WidgetUsage(
                combined: result.combined,
                unreadableHistories: result.unreadableHistories > 0,
                fetchedAt: now
            )
            WidgetUsageCache.save(usage, accountToken: accountToken)
            return UsageEntry(date: now, usage: usage, notice: nil, mode: mode)
        } catch {
            log.error("widget refresh failed: \(String(describing: error), privacy: .public)")
            return fallbackEntry(now: now, notice: .unreachable, mode: mode)
        }
    }

    /// Stale beats blank when a refresh fails — but never silently: cached entries are flagged so
    /// views show the fetch age, and the cache only replays for the same iCloud account.
    private static func fallbackEntry(now: Date, notice: WidgetNotice, mode: UsageDisplayMode) -> UsageEntry {
        if let cached = WidgetUsageCache.load() {
            return UsageEntry(date: now, usage: cached.reanchored(to: now), notice: nil, mode: mode, stale: true)
        }
        return UsageEntry(date: now, usage: nil, notice: notice, mode: mode)
    }
}

struct CombinedUsageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "CombinedUsage",
            intent: UsageConfigurationIntent.self,
            provider: UsageTimelineProvider()
        ) { entry in
            UsageWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Across Your Macs")
        .description("Combined AI usage synced from Runway on your Macs.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}
