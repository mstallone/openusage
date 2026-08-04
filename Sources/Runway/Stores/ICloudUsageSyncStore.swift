import Foundation
import Observation

struct UsageHistoryLoadResult: Sendable {
    var documents: [UsageHistoryDocument]
    var invalidRecordMessages: [String]
}

/// One device's complete published payload: the history document Macs merge, plus the rendered
/// snapshot document the iOS companion reads. Written together, deleted together.
struct DeviceSyncRecord: Sendable {
    var history: UsageHistoryDocument
    var snapshot: DeviceSnapshotDocument
}

protocol UsageCloudStoring: Sendable {
    func loadDocuments() async throws -> UsageHistoryLoadResult
    func write(_ deviceRecord: DeviceSyncRecord) async throws
    func delete(deviceID: String) async throws
}

protocol ICloudDeviceIDStoring: Sendable {
    func readDeviceID() throws -> String?
    func writeDeviceID(_ deviceID: String) throws
    /// Recover the device id from the store's legacy (pre-v2) location and persist it in the
    /// current one, or return nil when there is nothing to migrate. Callers reach for this LAST —
    /// only when both the current store and the saved preference are empty — because the legacy
    /// location may sit behind a prompt-capable Keychain path.
    func migrateLegacyDeviceID() throws -> String?
}

extension ICloudDeviceIDStoring {
    func migrateLegacyDeviceID() throws -> String? {
        nil
    }
}

struct KeychainICloudDeviceIDStore: ICloudDeviceIDStoring {
    private let service: String
    private let legacyService: String
    private let ownedStore: any RunwayOwnedSecretStoring
    private let legacyKeychain: any KeychainReading

    init(
        ownedStore: any RunwayOwnedSecretStoring = RunwayOwnedKeychainStore(),
        legacyKeychain: any KeychainReading = SecurityKeychainAccessor(),
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.mattstallone.runway"
    ) {
        self.ownedStore = ownedStore
        self.legacyKeychain = legacyKeychain
        self.service = "\(bundleIdentifier).icloud-sync-device-id.v2"
        self.legacyService = "\(bundleIdentifier).icloud-sync-device-id.v1"
    }

    func readDeviceID() throws -> String? {
        try ownedStore.read(service: service)
    }

    func writeDeviceID(_ deviceID: String) throws {
        try ownedStore.write(service: service, value: deviceID)
    }

    /// One-time recovery from the v1 item the `/usr/bin/security` subprocess created, for upgrades
    /// where the saved preference is also gone (a preferences reset). Copying it keeps this device's
    /// iCloud record instead of minting a duplicate. The subprocess read can raise a Keychain prompt
    /// when the login keychain is locked, which is why `resolveDeviceID` reaches here last — and why
    /// the prompt-free existence probe gates it: a fresh install has no v1 item and must not spawn
    /// the subprocess at all. The v1 item's ACL belongs to the subprocess, so Runway cannot silently
    /// delete it; it stays behind, orphaned and never read again once the v2 item exists.
    func migrateLegacyDeviceID() throws -> String? {
        // Tri-state on purpose. `false` is a confirmed fresh install — nothing to migrate, and the
        // subprocess never runs. `nil` means the probe could not answer (locked keychain, suppressed
        // UI, a stuck flight): treating that as "absent" would mint a NEW id for a Mac that already
        // has one and publish a duplicate device to iCloud, so fail instead and let the caller
        // surface its existing warning.
        switch legacyKeychain.genericPasswordForCurrentUserExists(service: legacyService) {
        case false:
            return nil
        case nil:
            throw KeychainError.readFailed("Keychain could not be checked for this Mac's previous sync identity.")
        case true?:
            break
        }
        guard let legacy = try legacyKeychain.readGenericPasswordForCurrentUser(service: legacyService) else {
            return nil
        }
        try ownedStore.write(service: service, value: legacy)
        return legacy
    }
}

@MainActor
@Observable
final class ICloudUsageSyncStore {
    private static let enabledKey = "runway.icloudSync.enabled.v1"
    private static let deviceIDKey = "runway.icloudSync.deviceID.v1"

    private let defaults: UserDefaults
    private let cloudStore: any UsageCloudStoring
    private var identityError: String?
    /// True when this Mac's durable sync identity could not be established — the legacy lookup was
    /// indeterminate and no saved id existed, so `deviceID` is a freshly minted UUID that may
    /// duplicate a record this Mac already published under its real id. Reads and the UI carry on;
    /// only publishing is withheld, because a publish is what creates the duplicate.
    private var identityIsProvisional: Bool
    /// The store used to resolve this Mac's identity, kept so a provisional identity can be retried
    /// once Keychain access comes back rather than staying stuck until relaunch.
    private let deviceIDStore: any ICloudDeviceIDStoring
    private let dataStore: WidgetDataStore
    private let writeDebounce: Duration
    /// How often to check the private database for peer updates while sync is on. CloudKit has no
    /// push channel in this always-running menu-bar app (no APNs entitlement), so a simple poll —
    /// matched to the five-minute refresh cadence — is the delivery mechanism. `nil` disables
    /// polling (tests drive reloads directly).
    private let pollInterval: Duration?
    private var writeTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var syncActivityCount = 0
    private var writeInProgress = false
    private var writeQueued = false
    private var reloadGeneration = 0

    private(set) var deviceID: String
    let deviceName: String
    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.enabledKey)
            Task { await applyEnabledChange() }
        }
    }
    private(set) var isSyncing = false
    /// Read and write failures are tracked separately so a healthy five-minute poll read can never
    /// hide a failed save: this device's record stays stale until a write succeeds, and Settings
    /// must keep saying so.
    private var readError: String?
    private var writeError: String?
    var serviceError: String? { writeError ?? readError ?? identityError }
    /// The subset of `serviceError` that still matters once sync is switched OFF: an unresolved
    /// identity means this Mac's existing iCloud record could not be removed, and nothing retries
    /// while sync is disabled — so Settings keeps showing it instead of appearing cleanly off.
    var disabledStateWarning: String? { identityIsProvisional ? identityError : nil }
    private(set) var invalidRecordMessages: [String] = []
    private(set) var documents: [UsageHistoryDocument] = []

    init(
        dataStore: WidgetDataStore,
        defaults: UserDefaults = .standard,
        cloudStore: any UsageCloudStoring = CloudKitUsageHistoryStore(),
        deviceIDStore: any ICloudDeviceIDStoring = KeychainICloudDeviceIDStore(),
        writeDebounce: Duration = .seconds(3),
        pollInterval: Duration? = .seconds(300)
    ) {
        self.dataStore = dataStore
        self.defaults = defaults
        self.cloudStore = cloudStore
        self.writeDebounce = writeDebounce
        self.pollInterval = pollInterval
        let identity = Self.resolveDeviceID(defaults: defaults, store: deviceIDStore)
        self.deviceID = identity.id
        self.identityError = identity.error
        self.identityIsProvisional = identity.isProvisional
        self.deviceIDStore = deviceIDStore
        self.deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        // On by default: a fresh install starts syncing; only a user's explicit choice is stored.
        self.enabled = (defaults.object(forKey: Self.enabledKey) as? Bool) ?? true
        dataStore.onLocalStateChanged = { [weak self] in self?.scheduleWrite() }
        if enabled {
            Task { await applyEnabledChange() }
        }
    }

    var displayedDocuments: [UsageHistoryDocument] {
        documents.sorted { lhs, rhs in
            if lhs.deviceID == deviceID { return true }
            if rhs.deviceID == deviceID { return false }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func scheduleWrite() {
        guard enabled else { return }
        writeTask?.cancel()
        writeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: writeDebounce)
            guard !Task.isCancelled else { return }
            await writeNow()
        }
    }

    private func applyEnabledChange() async {
        if enabled {
            startPolling()
            await reload()
            await writeNow()
        } else {
            writeTask?.cancel()
            stopPolling()
            dataStore.clearPeerHistoryDocuments()
            documents = []
            invalidRecordMessages = []
            // A provisional id is not the id this Mac published under, so deleting it would remove
            // nothing and quietly strand the real record — and turning sync off also stops the
            // retries that would have resolved it. Try once more, and say so if it still can't.
            resolveProvisionalIdentityIfNeeded()
            guard !identityIsProvisional else {
                AppLog.warn(.config, "iCloud opt-out could not remove this Mac's record: its sync identity is unresolved")
                identityError = "Runway couldn’t identify this Mac, so its existing iCloud record "
                    + "wasn’t removed. Unlock your login keychain and turn Sync Across Macs off again."
                return
            }
            do {
                try await cloudStore.delete(deviceID: deviceID)
                // Re-enabling can race this deletion: if the toggle came back on while the delete
                // was in flight, publish again so a late-landing delete cannot leave an enabled
                // Mac's record missing until the next refresh batch.
                if enabled {
                    await writeNow()
                } else {
                    readError = nil
                    writeError = nil
                }
            } catch {
                report(error, .disable)
            }
        }
    }

    /// Serializes saves. The store and CloudKit suspend at network awaits, so a second state change
    /// could otherwise start an overlapping save whose OLDER payload lands last at the server and
    /// wins. Overlapping requests instead fold into one queued rerun that publishes the latest
    /// state after the in-flight save finishes.
    private func writeNow() async {
        guard enabled else { return }
        if writeInProgress {
            writeQueued = true
            return
        }
        writeInProgress = true
        repeat {
            writeQueued = false
            await performWrite()
        } while writeQueued && enabled
        writeInProgress = false
    }

    private func performWrite() async {
        guard enabled else { return }
        // A provisional identity would publish a SECOND record for a Mac that already has one.
        // Retry the lookup first — Keychain access usually comes back within a session (an unlock),
        // and the error text promises publishing resumes when it does.
        resolveProvisionalIdentityIfNeeded()
        guard !identityIsProvisional else {
            AppLog.warn(.config, "iCloud publish skipped: this Mac's sync identity is unresolved")
            return
        }
        await withSyncActivity {
            let updatedAt = Date()
            let deviceRecord = DeviceSyncRecord(
                history: dataStore.localHistoryDocument(
                    deviceID: deviceID,
                    deviceName: deviceName,
                    updatedAt: updatedAt
                ),
                snapshot: dataStore.localSnapshotDocument(
                    deviceID: deviceID,
                    deviceName: deviceName,
                    updatedAt: updatedAt
                )
            )
            do {
                try await cloudStore.write(deviceRecord)
                // Disabling can run while the write is in flight. If it did, remove the
                // just-finished record as well so this Mac cannot reappear in peers after opting out.
                guard enabled else {
                    try await cloudStore.delete(deviceID: deviceID)
                    return
                }
                writeError = nil
                AppLog.info(.config, "iCloud history write ok (device \(deviceID))")
                await reload()
            } catch {
                report(error, .write)
            }
        }
    }

    /// The poll and the post-write reload can overlap at their network awaits; the generation
    /// check lets only the newest-started read publish, so a slow stale response can never
    /// replace fresher peer state (or report an outdated error). Internal for the staleness test.
    func reload() async {
        guard enabled else { return }
        await withSyncActivity {
            reloadGeneration += 1
            let generation = reloadGeneration
            do {
                let result = try await cloudStore.loadDocuments()
                // A read that began while enabled must not restore peer state after sync was
                // disabled, and a superseded read must not publish over a newer one.
                guard enabled, generation == reloadGeneration else { return }
                documents = UsageHistoryDocument.newestByDevice(result.documents)
                invalidRecordMessages = result.invalidRecordMessages
                // While the identity is provisional, this Mac's OWN previous record cannot be
                // recognized — merging would count its local usage a second time, as if another
                // device had produced it. Show the peer list, contribute nothing.
                dataStore.setPeerHistoryDocuments(
                    identityIsProvisional ? [] : result.documents,
                    ownDeviceID: deviceID
                )
                readError = result.invalidRecordMessages.isEmpty
                    ? nil
                    : "Runway couldn’t read some synced usage data. Check the log for details."
                AppLog.info(
                    .config,
                    "iCloud history loaded \(documents.count) device record(s), \(invalidRecordMessages.count) invalid"
                )
            } catch {
                guard generation == reloadGeneration else { return }
                report(error, .read)
            }
        }
    }

    private func withSyncActivity(_ operation: () async -> Void) async {
        syncActivityCount += 1
        isSyncing = true
        await operation()
        syncActivityCount -= 1
        isSyncing = syncActivityCount > 0
    }

    private enum SyncOperation: String { case read, write, disable }

    private func report(_ error: Error, _ operation: SyncOperation) {
        switch operation {
        case .read: readError = error.localizedDescription
        case .write, .disable: writeError = error.localizedDescription
        }
        AppLog.warn(.config, "iCloud history \(operation.rawValue) failed: \(error.localizedDescription)")
    }

    /// Re-run identity resolution while it is provisional. A success adopts the real id (and
    /// clears the notice) so publishing resumes without a relaunch; a failure leaves the state as
    /// it was and the next attempt tries again.
    private func resolveProvisionalIdentityIfNeeded() {
        guard identityIsProvisional else { return }
        let identity = Self.resolveDeviceID(defaults: defaults, store: deviceIDStore)
        guard !identity.isProvisional else { return }
        AppLog.info(.config, "iCloud sync identity resolved; publishing resumes")
        deviceID = identity.id
        identityError = identity.error
        identityIsProvisional = false
    }

    private static func resolveDeviceID(
        defaults: UserDefaults,
        store: any ICloudDeviceIDStoring
    ) -> (id: String, error: String?, isProvisional: Bool) {
        let saved = normalizedDeviceID(defaults.string(forKey: deviceIDKey))
        do {
            if let stored = normalizedDeviceID(try store.readDeviceID()) {
                defaults.set(stored, forKey: deviceIDKey)
                return (stored, nil, false)
            }

            // The saved preference is the same id the Keychain held, so on upgrades it seeds the
            // store without touching any legacy Keychain path. Legacy recovery — which can raise a
            // prompt when the login keychain is locked — runs only when BOTH are gone (a
            // preferences reset), and at most once: after it, either the store holds the id or a
            // freshly minted one is saved, so no later launch reaches it again.
            if let saved {
                try store.writeDeviceID(saved)
                return (saved, nil, false)
            }
            if let migrated = normalizedDeviceID(try store.migrateLegacyDeviceID()) {
                defaults.set(migrated, forKey: deviceIDKey)
                return (migrated, nil, false)
            }

            let id = UUID().uuidString.lowercased()
            try store.writeDeviceID(id)
            defaults.set(id, forKey: deviceIDKey)
            return (id, nil, false)
        } catch {
            AppLog.warn(.keychain, "iCloud device identity failed: \(error.localizedDescription)")
            if let saved {
                // A known id: publishing under it is still correct, it just isn't durable against a
                // preferences reset.
                defaults.set(saved, forKey: deviceIDKey)
                return (
                    saved,
                    "Runway couldn’t save this Mac’s sync identity in Keychain. "
                        + "Sync can create a duplicate device if you reset app preferences.",
                    false
                )
            }
            // Nothing to go on: any id minted here can duplicate a record this Mac already
            // published. Keep it out of the defaults and out of the cloud until the lookup works.
            return (
                UUID().uuidString.lowercased(),
                "Runway couldn’t identify this Mac for iCloud Sync. It won’t publish usage until "
                    + "Keychain access is available again.",
                true
            )
        }
    }

    private static func normalizedDeviceID(_ value: String?) -> String? {
        guard let value, UUID(uuidString: value) != nil else { return nil }
        return value.lowercased()
    }

    private func startPolling() {
        guard let pollInterval, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled, let self else { return }
                await self.reload()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
