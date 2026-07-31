import CloudKit
import Foundation
import Observation

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
    var last30Cost: Double
    var last30Tokens: Int
    var trend: [Day]
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
    private(set) var combined = CombinedUsage(today: nil, yesterday: nil, last30Cost: 0, last30Tokens: 0, trend: [])
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var lastRefreshAt: Date?

    private let zoneID = CKRecordZone.ID(zoneName: UsageCloudModel.zoneName, ownerName: CKCurrentUserDefaultName)
    private let decoder = SyncWire.decoder()

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let container = CKContainer(identifier: Self.containerID)
            guard try await container.accountStatus() == .available else {
                lastError = "Sign into iCloud on this device to see your usage."
                return
            }
            let records = try await fetchAllRecords(in: container.privateCloudDatabase)
            lastError = apply(records)
            lastRefreshAt = Date()
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            // No Mac has published yet: an empty dashboard with guidance, not an error.
            devices = []
            combined = CombinedUsage(today: nil, yesterday: nil, last30Cost: 0, last30Tokens: 0, trend: [])
            lastError = nil
            lastRefreshAt = Date()
        } catch {
            lastError = error.localizedDescription
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
        var unreadable = 0
        for record in records {
            guard let snapshotData = record[Self.snapshotKey] as? Data,
                  let snapshot = try? decoder.decode(SnapshotDocument.self, from: snapshotData),
                  SyncWire.snapshotSchemas.contains(snapshot.schema)
            else {
                unreadable += 1
                continue
            }
            var history: HistoryDocument?
            if let historyData = record[Self.historyKey] as? Data,
               let decoded = try? decoder.decode(HistoryDocument.self, from: historyData),
               SyncWire.historySchemas.contains(decoded.schema) {
                history = decoded
            } else {
                // Macs always write the history payload (even when empty), so a readable snapshot
                // with no readable history means the device is silently absent from the combined
                // totals — keep showing its snapshot, but say so.
                unreadable += 1
            }
            loaded.append(DeviceUsage(snapshot: snapshot, history: history))
        }
        devices = loaded.sorted { $0.snapshot.updatedAt > $1.snapshot.updatedAt }
        combined = Self.combine(devices)
        guard unreadable > 0 else { return nil }
        return "Some synced usage couldn’t be read here (\(unreadable) newer or unreadable payload\(unreadable == 1 ? "" : "s")). Update Runway on your Macs and this app."
    }

    /// Day-sums every device's series inside the Mac's 30-day window (today + 30 previous days).
    private static func combine(_ devices: [DeviceUsage], now: Date = Date()) -> CombinedUsage {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = calendar
        let todayKey = formatter.string(from: now)
        let yesterdayKey = calendar.date(byAdding: .day, value: -1, to: now).map(formatter.string(from:))
        let orderedWindow: [String] = (0...30).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: now).map(formatter.string(from:))
        }
        let window = Set(orderedWindow)

        var tokens: [String: Int] = [:]
        var cost: [String: Double] = [:]
        var sawCost: Set<String> = []
        for device in devices {
            for history in (device.history?.providers ?? [:]).values {
                for day in history.series.daily where window.contains(day.date) {
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
        // spacing — otherwise nonconsecutive usage days would render adjacent.
        let trend = tokens.isEmpty ? [] : orderedWindow.map { key in
            CombinedUsage.Day(date: key, tokens: tokens[key] ?? 0, cost: sawCost.contains(key) ? cost[key] : nil)
        }
        return CombinedUsage(
            today: day(todayKey),
            yesterday: day(yesterdayKey),
            last30Cost: cost.values.reduce(0, +),
            last30Tokens: tokens.values.reduce(0, +),
            trend: trend
        )
    }
}
