import CloudKit
import Foundation
import Security

enum CloudKitUsageSyncError: Error, LocalizedError, Equatable {
    case missingEntitlement
    case accountUnavailable

    var errorDescription: String? {
        switch self {
        case .missingEntitlement:
            "This Runway build was signed without iCloud access, so sync is unavailable."
        case .accountUnavailable:
            "iCloud isn’t available. Check that this Mac is signed into iCloud."
        }
    }
}

/// Runway's private CloudKit database: one `DeviceUsage` record per device, all in one custom zone.
///
/// Each device writes and deletes only the record named after its own device ID, so records never
/// conflict — a save is always last-writer-wins with the same device. Readers fetch the whole zone
/// from a nil change token and rebuild the peer set from scratch, so there are no change tokens to
/// persist and a peer's deleted record disappears on the next load.
actor CloudKitUsageHistoryStore: UsageCloudStoring {
    static let zoneName = "UsageHistory"
    static let recordType = "DeviceUsage"
    static let historyKey = "history"
    static let snapshotKey = "snapshot"

    private let zoneID = CKRecordZone.ID(zoneName: CloudKitUsageHistoryStore.zoneName, ownerName: CKCurrentUserDefaultName)
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var container: CKContainer?
    private var zoneReady = false

    init() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func loadDocuments() async throws -> UsageHistoryLoadResult {
        let database = try await database()
        var documents: [UsageHistoryDocument] = []
        var invalid: [String] = []
        var token: CKServerChangeToken?
        while true {
            let changes: (
                modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, any Error>],
                deletions: [CKDatabase.RecordZoneChange.Deletion],
                changeToken: CKServerChangeToken,
                moreComing: Bool
            )
            do {
                changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                // No device has written yet (or the user erased Runway's iCloud data): nothing to
                // merge, and the next write must recreate the zone rather than assume it exists.
                zoneReady = false
                return UsageHistoryLoadResult(documents: [], invalidRecordMessages: [])
            }
            for (recordID, result) in changes.modificationResultsByID {
                // A per-record fetch failure is a SERVICE problem, not bad data: fail the whole
                // load so the caller keeps the previous peer set and shows the real error, instead
                // of misreporting the record as malformed and silently dropping that device.
                let record = try result.get().record
                do {
                    guard let data = record[Self.historyKey] as? Data else {
                        throw UsageHistoryDocumentError.unsupportedSchema
                    }
                    let document = try decoder.decode(UsageHistoryDocument.self, from: data)
                    try document.validate()
                    documents.append(document)
                } catch {
                    invalid.append("\(recordID.recordName): \(error.localizedDescription)")
                    AppLog.warn(.config, "iCloud history ignored record \(recordID.recordName): \(error.localizedDescription)")
                }
            }
            token = changes.changeToken
            if !changes.moreComing { break }
        }
        // A complete fetch proves the zone exists, so the next write can skip the zone save.
        zoneReady = true
        return UsageHistoryLoadResult(documents: documents, invalidRecordMessages: invalid)
    }

    func write(_ deviceRecord: DeviceSyncRecord) async throws {
        try deviceRecord.history.validate()
        let database = try await database()
        try await ensureZone(in: database)
        let recordID = CKRecord.ID(recordName: deviceRecord.history.deviceID, zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record[Self.historyKey] = try encoder.encode(deviceRecord.history)
        record[Self.snapshotKey] = try encoder.encode(deviceRecord.snapshot)
        do {
            // `.allKeys` skips the oplock: only this device writes this record, so overwriting
            // unconditionally is last-writer-wins with itself, never a lost peer update.
            let (saveResults, _) = try await database.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .allKeys
            )
            for (_, result) in saveResults { _ = try result.get() }
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            // The zone vanished mid-run (the user erased Runway's iCloud data). Fail this write
            // loudly, but forget the cached zone so the next write recreates it instead of failing
            // until relaunch.
            zoneReady = false
            throw error
        }
    }

    func delete(deviceID: String) async throws {
        let database = try await database()
        let recordID = CKRecord.ID(recordName: deviceID, zoneID: zoneID)
        do {
            let (_, deleteResults) = try await database.modifyRecords(saving: [], deleting: [recordID])
            for (_, result) in deleteResults {
                do { try result.get() } catch let error as CKError where error.code == .unknownItem {
                    // Deleting a record this device never published is the desired end state.
                }
            }
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone || error.code == .unknownItem {
            // Same: nothing published means nothing to remove.
        }
    }

    /// The private database, gated on the two states a user can actually fix: a build signed
    /// without the iCloud entitlement, and a Mac not signed into iCloud.
    private func database() async throws -> CKDatabase {
        let container = try resolvedContainer()
        let status = try await container.accountStatus()
        guard status == .available else { throw CloudKitUsageSyncError.accountUnavailable }
        return container.privateCloudDatabase
    }

    /// Resolves the container from the signed entitlement instead of hardcoding an identifier, so
    /// development and release bundles land in their own containers. Constructing `CKContainer`
    /// without the entitlement raises an Objective-C exception Swift cannot catch, so probe the
    /// entitlement first and fail with a friendly error for unsigned local builds.
    private func resolvedContainer() throws -> CKContainer {
        if let container { return container }
        let task = SecTaskCreateFromSelf(nil)
        guard let task,
              let value = SecTaskCopyValueForEntitlement(
                  task,
                  "com.apple.developer.icloud-container-identifiers" as CFString,
                  nil
              ),
              let identifier = (value as? [String])?.first
        else { throw CloudKitUsageSyncError.missingEntitlement }
        let resolved = CKContainer(identifier: identifier)
        container = resolved
        return resolved
    }

    private func ensureZone(in database: CKDatabase) async throws {
        guard !zoneReady else { return }
        _ = try await database.save(CKRecordZone(zoneID: zoneID))
        zoneReady = true
    }
}
