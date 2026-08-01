import CloudKit
import Foundation
import Observation
import os

/// One synced device as this app displays it: the live snapshot is required (it is what the phone
/// exists to show); history rides along for the combined totals.
struct DeviceUsage: Identifiable {
    var snapshot: SnapshotDocument
    var history: HistoryDocument?

    var id: String { snapshot.deviceID }
}

/// Cross-device spend summary computed by day-summing every device's history payload — the same
/// additive model the Mac uses (each Mac's history covers only usage produced on that Mac).
struct CombinedUsage {
    struct Day: Identifiable {
        var date: String
        var tokens: Int
        var cost: Double?

        var id: String { date }
    }

    var today: Day?
    var yesterday: Day?
    var last30Cost: Double?
    var last30Tokens: Int
    var trend: [Day]
    /// Models some Mac couldn't price inside the window — their spend is missing from the totals.
    var unknownModels: [String] = []

    /// Whether anything in the window deserves the combined section: usage, cost, or a warning.
    var hasData: Bool {
        !trend.isEmpty || !unknownModels.isEmpty || last30Cost != nil || last30Tokens > 0
    }
}

/// Read-only consumer of Runway's private CloudKit database. Mirrors the Mac's transport exactly:
/// fetch every record in the `UsageHistory` zone from a nil change token and rebuild from scratch —
/// this app never writes, so the Macs' single-writer-per-record invariant is preserved.
@MainActor
@Observable
final class UsageCloudModel {
    static let zoneName = "UsageHistory"
    static let historyKey = "history"
    static let snapshotKey = "snapshot"

    #if DEBUG
    static let containerID = "iCloud.com.mattstallone.runway.dev"
    #else
    static let containerID = "iCloud.com.mattstallone.runway"
    #endif

    private(set) var devices: [DeviceUsage] = []
    private(set) var combined = CombinedUsage(today: nil, yesterday: nil, last30Cost: nil, last30Tokens: 0, trend: [])
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var lastRefreshAt: Date?

    private let zoneID = CKRecordZone.ID(zoneName: UsageCloudModel.zoneName, ownerName: CKCurrentUserDefaultName)
    private let decoder = SyncWire.decoder()
    private let log = Logger(subsystem: "com.mattstallone.runway.mobile", category: "sync")

    init() {
        // An iCloud account switch must never leave the previous account's private usage on
        // screen — clear before the new account's first fetch, which may itself fail.
        NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.clearLoadedState()
                self.lastError = nil
                await self.refresh()
            }
        }
    }

    private func clearLoadedState() {
        devices = []
        combined = CombinedUsage(today: nil, yesterday: nil, last30Cost: nil, last30Tokens: 0, trend: [])
    }

    /// Decodes one payload field, logging the concrete failure (record + error) so wire drift is
    /// diagnosable locally while the UI keeps its friendly aggregate notice.
    private func decodePayload<T: Decodable>(_ type: T.Type, record: CKRecord, key: String) -> T? {
        guard let data = record[key] as? Data else {
            log.warning("record \(record.recordID.recordName, privacy: .public) has no \(key, privacy: .public) payload")
            return nil
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            log.warning("record \(record.recordID.recordName, privacy: .public) \(key, privacy: .public) payload undecodable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let container = CKContainer(identifier: Self.containerID)
            if let message = Self.accountMessage(for: try await container.accountStatus()) {
                // The account is gone or unreachable: the prior account's private usage must not
                // keep rendering beneath the notice.
                clearLoadedState()
                lastError = message
                return
            }
            let records = try await fetchAllRecords(in: container.privateCloudDatabase)
            lastError = apply(records)
            lastRefreshAt = Date()
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            // No Mac has published yet: an empty dashboard with guidance, not an error.
            devices = []
            combined = CombinedUsage(today: nil, yesterday: nil, last30Cost: nil, last30Tokens: 0, trend: [])
            lastError = nil
            lastRefreshAt = Date()
        } catch {
            log.error("CloudKit refresh failed: \(String(describing: error), privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    /// Only `.noAccount` means "sign in" — the other statuses need their own recovery advice.
    private static func accountMessage(for status: CKAccountStatus) -> String? {
        switch status {
        case .available: nil
        case .noAccount: "Sign into iCloud on this device to see your usage."
        case .restricted: "iCloud access is restricted on this device (Screen Time or a profile)."
        case .temporarilyUnavailable: "iCloud is temporarily unavailable. Try again in a moment."
        case .couldNotDetermine: "Couldn’t determine iCloud status. Try again."
        @unknown default: "iCloud isn’t available right now."
        }
    }

    private func fetchAllRecords(in database: CKDatabase) async throws -> [CKRecord] {
        var records: [CKRecord] = []
        var token: CKServerChangeToken?
        while true {
            let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            for (_, result) in changes.modificationResultsByID {
                records.append(try result.get().record)
            }
            token = changes.changeToken
            if !changes.moreComing { break }
        }
        return records
    }

    /// Rebuilds display state and returns a user-facing notice when any payload was unreadable.
    /// A skipped payload is never silent: a newer schema on one Mac must say "update", not quietly
    /// drop that device (or undercount "Across Your Macs" when only its history payload is newer).
    private func apply(_ records: [CKRecord]) -> String? {
        var loaded: [DeviceUsage] = []
        var histories: [HistoryDocument] = []
        var unreadable = 0
        for record in records {
            // The two payloads are independent: a device whose snapshot is newer than this app
            // can read must still contribute its valid history to the combined totals (and vice
            // versa). Each unreadable half counts toward the update notice on its own — Macs
            // always write both, even when the history has no providers.
            let history = validatedHistory(from: record)
            if let history { histories.append(history) } else { unreadable += 1 }
            if let snapshot = decodePayload(SnapshotDocument.self, record: record, key: Self.snapshotKey),
               SyncWire.snapshotSchemas.contains(snapshot.schema) {
                loaded.append(DeviceUsage(snapshot: snapshot, history: history))
            } else {
                unreadable += 1
            }
        }
        devices = loaded.sorted { $0.snapshot.updatedAt > $1.snapshot.updatedAt }
        combined = Self.combine(histories)
        guard unreadable > 0 else { return nil }
        return "Some synced usage couldn’t be read here (\(unreadable) newer or unreadable payload\(unreadable == 1 ? "" : "s")). Update Runway on your Macs and this app."
    }

    /// Decodes and semantically validates a history payload. Mirrors the Mac's
    /// `UsageHistoryDocument.validate()` for the fields this app consumes: duplicate days,
    /// negative or non-finite values, and malformed day keys count as unreadable rather than
    /// feeding `combine` confident wrong totals.
    private func validatedHistory(from record: CKRecord) -> HistoryDocument? {
        guard let decoded = decodePayload(HistoryDocument.self, record: record, key: Self.historyKey),
              SyncWire.historySchemas.contains(decoded.schema)
        else { return nil }
        guard Self.isValid(decoded) else {
            log.warning("record \(record.recordID.recordName, privacy: .public) history payload semantically invalid")
            return nil
        }
        return decoded
    }

    private static func isValid(_ history: HistoryDocument) -> Bool {
        for provider in history.providers.values {
            var seenDays: Set<String> = []
            for day in provider.series.daily {
                guard isDayKey(day.date),
                      seenDays.insert(day.date).inserted,
                      day.totalTokens >= 0,
                      day.costUSD.map({ $0.isFinite && $0 >= 0 }) ?? true
                else { return false }
            }
            for day in (provider.unknownModelsByDay ?? [:]).keys where !isDayKey(day) {
                return false
            }
        }
        return true
    }

    /// Mirrors the Mac validator: shape plus real Gregorian month/day ranges, so an impossible
    /// date ("2026-99-99") counts as unreadable instead of silently missing the window.
    private static func isDayKey(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month)
        else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let monthDate = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let dayRange = calendar.range(of: .day, in: .month, for: monthDate)
        else { return false }
        return dayRange.contains(day)
    }

    /// Day-sums every device's series inside the Mac's 30-day window (today + 30 previous days).
    private static func combine(_ histories: [HistoryDocument], now: Date = Date()) -> CombinedUsage {
        // Wire day keys are Gregorian with Latin digits regardless of device settings; only the
        // time zone stays local so "today" matches the user's day boundary.
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let todayKey = formatter.string(from: now)
        let yesterdayKey = calendar.date(byAdding: .day, value: -1, to: now).map(formatter.string(from:))
        let orderedWindow: [String] = (0...30).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: now).map(formatter.string(from:))
        }
        let window = Set(orderedWindow)

        var tokens: [String: Int] = [:]
        var cost: [String: Double] = [:]
        var sawCost: Set<String> = []
        var unknownModels: Set<String> = []
        for document in histories {
            for history in document.providers.values {
                for (day, names) in history.unknownModelsByDay ?? [:] where window.contains(day) {
                    unknownModels.formUnion(names)
                }
                for day in history.series.daily where window.contains(day.date) {
                    // A zero row is "no usage", not a known $0.00 — mirror the Mac's hasUsage rule.
                    guard day.totalTokens > 0 || (day.costUSD ?? 0) > 0 else { continue }
                    tokens[day.date, default: 0] += day.totalTokens
                    if let dayCost = day.costUSD {
                        cost[day.date, default: 0] += dayCost
                        sawCost.insert(day.date)
                    }
                }
            }
        }

        func day(_ key: String?) -> CombinedUsage.Day? {
            guard let key, let dayTokens = tokens[key] else { return nil }
            return CombinedUsage.Day(date: key, tokens: dayTokens, cost: sawCost.contains(key) ? cost[key] : nil)
        }

        // Zero-fill the full window (like the Mac's trend) so the index-plotted bars keep real
        // spacing — otherwise nonconsecutive usage days would render adjacent. A cost-only window
        // (every token count zero) gets no token chart at all rather than 31 invisible bars.
        let trend = !tokens.values.contains(where: { $0 > 0 }) ? [] : orderedWindow.map { key in
            CombinedUsage.Day(date: key, tokens: tokens[key] ?? 0, cost: sawCost.contains(key) ? cost[key] : nil)
        }
        return CombinedUsage(
            today: day(todayKey),
            yesterday: day(yesterdayKey),
            last30Cost: sawCost.isEmpty ? nil : cost.values.reduce(0, +),
            last30Tokens: tokens.values.reduce(0, +),
            trend: trend,
            unknownModels: unknownModels.sorted()
        )
    }
}
