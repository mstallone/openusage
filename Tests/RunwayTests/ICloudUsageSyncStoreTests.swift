import XCTest
@testable import Runway

@MainActor
final class ICloudUsageSyncStoreTests: XCTestCase {
    func testSyncDefaultsOnForFreshInstallAndRespectsSavedOptOut() async throws {
        let freshDefaults = makeFreshDefaults("default-on")
        let fresh = ICloudUsageSyncStore(
            dataStore: makeDataStore(freshDefaults),
            defaults: freshDefaults,
            cloudStore: RecordingUsageCloudStore(),
            deviceIDStore: MemoryDeviceIDStore(),
            pollInterval: nil
        )
        XCTAssertTrue(fresh.enabled, "a fresh install starts syncing")

        let optedOutDefaults = makeFreshDefaults("saved-opt-out")
        optedOutDefaults.set(false, forKey: "runway.icloudSync.enabled.v1")
        let optedOut = ICloudUsageSyncStore(
            dataStore: makeDataStore(optedOutDefaults),
            defaults: optedOutDefaults,
            cloudStore: RecordingUsageCloudStore(),
            deviceIDStore: MemoryDeviceIDStore(),
            pollInterval: nil
        )
        XCTAssertFalse(optedOut.enabled, "a stored opt-out wins over the default")
    }

    func testEnableWritesLoadsAndDisableDeletesThisMac() async throws {
        let defaults = makeDefaults("enable-disable")
        let cloudStore = RecordingUsageCloudStore()
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            cloudStore: cloudStore,
            deviceIDStore: MemoryDeviceIDStore(),
            writeDebounce: .milliseconds(10),
            pollInterval: nil
        )

        sync.enabled = true
        try await waitUntil { await cloudStore.writeCount == 1 && sync.displayedDocuments.count == 1 }

        XCTAssertEqual(sync.displayedDocuments.first?.deviceID, sync.deviceID)
        XCTAssertNil(sync.serviceError)

        sync.enabled = false
        try await waitUntil { await cloudStore.deletedDeviceIDs.contains(sync.deviceID) }
        XCTAssertTrue(sync.documents.isEmpty)
    }

    func testWrittenRecordCarriesMatchingSnapshotPayload() async throws {
        let defaults = makeDefaults("snapshot-payload")
        let cloudStore = RecordingUsageCloudStore()
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            cloudStore: cloudStore,
            deviceIDStore: MemoryDeviceIDStore(),
            writeDebounce: .milliseconds(10),
            pollInterval: nil
        )

        sync.enabled = true
        try await waitUntil { await cloudStore.writeCount == 1 }

        let record = await cloudStore.lastWrittenRecord
        XCTAssertEqual(record?.snapshot.deviceID, sync.deviceID)
        XCTAssertEqual(record?.snapshot.deviceID, record?.history.deviceID)
        XCTAssertEqual(record?.snapshot.updatedAt, record?.history.updatedAt)
        XCTAssertEqual(record?.snapshot.schema, DeviceSnapshotDocument.currentSchema)
    }

    func testAdjacentHistoryChangesDebounceToOneWrite() async throws {
        let defaults = makeDefaults("debounce")
        let cloudStore = RecordingUsageCloudStore()
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            cloudStore: cloudStore,
            deviceIDStore: MemoryDeviceIDStore(),
            writeDebounce: .milliseconds(20),
            pollInterval: nil
        )
        sync.enabled = true
        try await waitUntil { await cloudStore.writeCount == 1 }

        sync.scheduleWrite()
        sync.scheduleWrite()
        sync.scheduleWrite()
        try await waitUntil { await cloudStore.writeCount == 2 }
        try await Task.sleep(for: .milliseconds(40))

        let writeCount = await cloudStore.writeCount
        XCTAssertEqual(writeCount, 2)
    }

    func testDisableDeletesWriteThatWasAlreadyInFlight() async throws {
        let defaults = makeDefaults("disable-in-flight-write")
        let cloudStore = RecordingUsageCloudStore()
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            cloudStore: cloudStore,
            deviceIDStore: MemoryDeviceIDStore(),
            pollInterval: nil
        )

        // Hold the enable write open so disable can race it deliberately, instead of hoping an
        // 80ms sleep is still in flight when the test flips the toggle on a loaded CI runner.
        await cloudStore.holdNextWrite()
        sync.enabled = true
        try await waitUntil { await cloudStore.writeInFlight }

        sync.enabled = false
        try await waitUntil {
            await cloudStore.deletedDeviceIDs.contains(sync.deviceID)
        }

        await cloudStore.releaseWrite()
        try await waitUntil {
            let deletedCount = await cloudStore.deletedDeviceIDs.filter { $0 == sync.deviceID }.count
            let writeInFlight = await cloudStore.writeInFlight
            return deletedCount >= 2 && !writeInFlight && !sync.isSyncing
        }

        let documents = await cloudStore.documents
        XCTAssertFalse(documents.contains { $0.deviceID == sync.deviceID })
    }

    func testUnavailableStoreSurfacesFriendlyError() async throws {
        let defaults = makeDefaults("unavailable")
        let cloudStore = RecordingUsageCloudStore(unavailable: true)
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            cloudStore: cloudStore,
            deviceIDStore: MemoryDeviceIDStore(),
            pollInterval: nil
        )

        sync.enabled = true
        try await waitUntil { sync.serviceError != nil && !sync.isSyncing }

        XCTAssertEqual(sync.serviceError, CloudKitUsageSyncError.accountUnavailable.localizedDescription)
        XCTAssertFalse(sync.isSyncing)
    }

    func testMalformedPeerMessageIsVisibleAndValidDocumentsStillLoad() async throws {
        let defaults = makeDefaults("malformed")
        let peer = UsageHistoryDocument(
            deviceID: "peer",
            deviceName: "Peer Mac",
            updatedAt: .now,
            providers: [:]
        )
        let cloudStore = RecordingUsageCloudStore(
            seedDocuments: [peer],
            invalidRecordMessages: ["broken-device: invalid value"]
        )
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            cloudStore: cloudStore,
            deviceIDStore: MemoryDeviceIDStore(),
            pollInterval: nil
        )

        sync.enabled = true
        try await waitUntil { sync.invalidRecordMessages.count == 1 }

        XCTAssertTrue(sync.displayedDocuments.contains { $0.deviceID == "peer" })
        XCTAssertNotNil(sync.serviceError)
    }

    func testPollingPicksUpPeerRecordsWithoutALocalWrite() async throws {
        let defaults = makeDefaults("polling")
        let cloudStore = RecordingUsageCloudStore()
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            cloudStore: cloudStore,
            deviceIDStore: MemoryDeviceIDStore(),
            writeDebounce: .milliseconds(10),
            pollInterval: .milliseconds(25)
        )

        sync.enabled = true
        try await waitUntil { await cloudStore.writeCount == 1 }

        // A peer publishes after this Mac's write+reload cycle; only the poll can surface it.
        await cloudStore.seed(UsageHistoryDocument(
            deviceID: "peer",
            deviceName: "Peer Mac",
            updatedAt: .now,
            providers: [:]
        ))
        try await waitUntil { sync.displayedDocuments.contains { $0.deviceID == "peer" } }
    }

    func testReEnableDuringSlowDisableDeletionRepublishesThisMac() async throws {
        let defaults = makeDefaults("re-enable-during-delete")
        let cloudStore = RecordingUsageCloudStore()
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            cloudStore: cloudStore,
            deviceIDStore: MemoryDeviceIDStore(),
            writeDebounce: .milliseconds(10),
            pollInterval: nil
        )

        sync.enabled = true
        try await waitUntil { await cloudStore.writeCount == 1 }

        // Turn sync off (deletion hangs on the network), then back on before it finishes: the
        // late-landing delete must trigger a republish instead of leaving this Mac unpublished.
        await cloudStore.holdNextDelete()
        sync.enabled = false
        try await waitUntil { await cloudStore.deleteInFlight }
        sync.enabled = true
        try await waitUntil { await cloudStore.writeCount == 2 }

        await cloudStore.releaseDelete()
        try await waitUntil { await cloudStore.writeCount >= 3 && !sync.isSyncing }
        let documents = await cloudStore.documents
        XCTAssertTrue(documents.contains { $0.deviceID == sync.deviceID })
    }

    func testOverlappingWriteRequestsSerializeIntoAFollowUpWrite() async throws {
        let defaults = makeDefaults("serialized-writes")
        let cloudStore = RecordingUsageCloudStore()
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            cloudStore: cloudStore,
            deviceIDStore: MemoryDeviceIDStore(),
            writeDebounce: .milliseconds(10),
            pollInterval: nil
        )

        // Hold the enable write open, then let a second state change pass its debounce while the
        // first save is still in flight: it must queue behind it, not race it.
        await cloudStore.holdNextWrite()
        sync.enabled = true
        try await waitUntil { await cloudStore.writeInFlight }
        sync.scheduleWrite()
        try await Task.sleep(for: .milliseconds(40))
        let writeCountWhileHeld = await cloudStore.writeCount
        XCTAssertEqual(writeCountWhileHeld, 1, "an overlapping save must wait for the in-flight one")

        await cloudStore.releaseWrite()
        try await waitUntil { await cloudStore.writeCount == 2 && !sync.isSyncing }
    }

    func testPollingReadSuccessDoesNotClearAWriteFailure() async throws {
        let defaults = makeDefaults("write-failure-sticks")
        let cloudStore = RecordingUsageCloudStore(failWrites: true)
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            cloudStore: cloudStore,
            deviceIDStore: MemoryDeviceIDStore(),
            writeDebounce: .milliseconds(10),
            pollInterval: .milliseconds(20)
        )

        sync.enabled = true
        try await waitUntil { sync.serviceError != nil }

        // Several healthy poll reads must not hide the failed save — this device's record is stale.
        try await Task.sleep(for: .milliseconds(80))
        try await waitUntil { await cloudStore.loadCount >= 2 }
        XCTAssertEqual(sync.serviceError, CloudKitUsageSyncError.accountUnavailable.localizedDescription)
    }

    func testStaleReloadCannotReplaceNewerPeerState() async throws {
        let defaults = makeDefaults("stale-reload")
        let cloudStore = RecordingUsageCloudStore()
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            cloudStore: cloudStore,
            deviceIDStore: MemoryDeviceIDStore(),
            writeDebounce: .milliseconds(10),
            pollInterval: nil
        )
        sync.enabled = true
        try await waitUntil { await cloudStore.writeCount == 1 && !sync.isSyncing }

        // A slow read starts before the peer publishes, then a fresh read lands first: the slow
        // stale response must be discarded, not published over the newer peer set.
        await cloudStore.holdNextLoad()
        let staleReload = Task { await sync.reload() }
        try await waitUntil { await cloudStore.loadInFlight }
        await cloudStore.seed(UsageHistoryDocument(
            deviceID: "peer",
            deviceName: "Peer Mac",
            updatedAt: .now,
            providers: [:]
        ))
        await sync.reload()
        XCTAssertTrue(sync.displayedDocuments.contains { $0.deviceID == "peer" })

        await cloudStore.releaseLoad()
        await staleReload.value
        XCTAssertTrue(sync.displayedDocuments.contains { $0.deviceID == "peer" })
    }

    func testBackgroundReloadShowsSyncActivity() async throws {
        let defaults = makeDefaults("background-sync-activity")
        let cloudStore = RecordingUsageCloudStore()
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            cloudStore: cloudStore,
            deviceIDStore: MemoryDeviceIDStore(),
            writeDebounce: .milliseconds(10),
            pollInterval: nil
        )

        sync.enabled = true
        try await waitUntil {
            await cloudStore.writeCount == 1 && !sync.isSyncing
        }

        // Gate only the post-write reload so isSyncing stays true long enough to observe.
        await cloudStore.holdNextLoad()
        sync.scheduleWrite()
        try await waitUntil {
            let writeCount = await cloudStore.writeCount
            let loadInFlight = await cloudStore.loadInFlight
            return writeCount == 2 && loadInFlight && sync.isSyncing
        }

        await cloudStore.releaseLoad()
        try await waitUntil { !sync.isSyncing }
    }

    func testDeviceIdentitySurvivesPreferencesResetThroughKeychainStore() {
        let expectedID = UUID().uuidString.lowercased()
        let firstDefaults = makeDefaults("identity-first")
        firstDefaults.set(expectedID, forKey: "runway.icloudSync.deviceID.v1")
        let deviceIDStore = MemoryDeviceIDStore()

        let first = ICloudUsageSyncStore(
            dataStore: makeDataStore(firstDefaults),
            defaults: firstDefaults,
            cloudStore: RecordingUsageCloudStore(),
            deviceIDStore: deviceIDStore,
            pollInterval: nil
        )
        let resetDefaults = makeDefaults("identity-after-reset")
        let afterReset = ICloudUsageSyncStore(
            dataStore: makeDataStore(resetDefaults),
            defaults: resetDefaults,
            cloudStore: RecordingUsageCloudStore(),
            deviceIDStore: deviceIDStore,
            pollInterval: nil
        )

        XCTAssertEqual(first.deviceID, expectedID)
        XCTAssertEqual(afterReset.deviceID, expectedID)
        XCTAssertEqual(resetDefaults.string(forKey: "runway.icloudSync.deviceID.v1"), expectedID)
    }

    func testKeychainIdentityIsScopedToDevelopmentAndProductionBundles() throws {
        let owned = InMemoryOwnedSecretStore()
        let development = KeychainICloudDeviceIDStore(
            ownedStore: owned,
            legacyKeychain: ServiceKeychain(),
            bundleIdentifier: "com.mattstallone.runway.dev"
        )
        let production = KeychainICloudDeviceIDStore(
            ownedStore: owned,
            legacyKeychain: ServiceKeychain(),
            bundleIdentifier: "com.mattstallone.runway"
        )

        try development.writeDeviceID("development-id")
        try production.writeDeviceID("production-id")

        XCTAssertEqual(try development.readDeviceID(), "development-id")
        XCTAssertEqual(try production.readDeviceID(), "production-id")
    }

    func testLegacyDeviceIDMigratesIntoTheRunwayOwnedItemOnce() throws {
        // Existing installs keep their iCloud device record: the v1 item the subprocess created is
        // copied into the Runway-owned v2 item on first read, and the legacy item is never consulted
        // again once the v2 item exists.
        let owned = InMemoryOwnedSecretStore()
        let legacy = ServiceKeychain()
        legacy.currentUserValues["com.mattstallone.runway.icloud-sync-device-id.v1"] = "legacy-device-id"
        let store = KeychainICloudDeviceIDStore(
            ownedStore: owned,
            legacyKeychain: legacy,
            bundleIdentifier: "com.mattstallone.runway"
        )

        XCTAssertEqual(try store.readDeviceID(), "legacy-device-id")
        XCTAssertEqual(
            owned.secrets["com.mattstallone.runway.icloud-sync-device-id.v2"],
            "legacy-device-id"
        )

        // The legacy item changing afterwards is irrelevant — v2 is authoritative.
        legacy.currentUserValues["com.mattstallone.runway.icloud-sync-device-id.v1"] = "changed-later"
        XCTAssertEqual(try store.readDeviceID(), "legacy-device-id")
    }

    func testMissingDeviceIDReadsNilWithoutInventingAnIdentity() throws {
        let store = KeychainICloudDeviceIDStore(
            ownedStore: InMemoryOwnedSecretStore(),
            legacyKeychain: ServiceKeychain(),
            bundleIdentifier: "com.mattstallone.runway"
        )
        XCTAssertNil(try store.readDeviceID())
    }

    private func makeDataStore(_ defaults: UserDefaults) -> WidgetDataStore {
        WidgetDataStore(
            registry: WidgetRegistry(providers: [], descriptors: []),
            providers: [],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults
        )
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let defaults = makeFreshDefaults(name)
        // Sync is on by default; these tests exercise the enable transition, so start disabled.
        defaults.set(false, forKey: "runway.icloudSync.enabled.v1")
        return defaults
    }

    private func makeFreshDefaults(_ name: String) -> UserDefaults {
        let suite = "RunwayTests.ICloudSync.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met before timeout")
    }
}

private final class MemoryDeviceIDStore: ICloudDeviceIDStoring, @unchecked Sendable {
    private var deviceID: String?

    func readDeviceID() throws -> String? {
        deviceID
    }

    func writeDeviceID(_ deviceID: String) throws {
        self.deviceID = deviceID
    }
}

private final class InMemoryOwnedSecretStore: RunwayOwnedSecretStoring, @unchecked Sendable {
    var secrets: [String: String] = [:]

    func read(service: String) throws -> String? {
        secrets[service]
    }

    func write(service: String, value: String) throws {
        secrets[service] = value
    }
}

private actor RecordingUsageCloudStore: UsageCloudStoring {
    private(set) var documents: [UsageHistoryDocument]
    private(set) var invalidRecordMessages: [String]
    private(set) var writeCount = 0
    private(set) var loadCount = 0
    private(set) var lastWrittenRecord: DeviceSyncRecord?
    private(set) var deletedDeviceIDs: [String] = []
    private let unavailable: Bool
    private let failWrites: Bool
    private(set) var loadInFlight = false
    private(set) var writeInFlight = false
    private(set) var deleteInFlight = false
    private var shouldHoldNextLoad = false
    private var shouldHoldNextWrite = false
    private var shouldHoldNextDelete = false
    private var loadGate: CheckedContinuation<Void, Never>?
    private var writeGate: CheckedContinuation<Void, Never>?
    private var deleteGate: CheckedContinuation<Void, Never>?

    init(
        unavailable: Bool = false,
        failWrites: Bool = false,
        seedDocuments: [UsageHistoryDocument] = [],
        invalidRecordMessages: [String] = []
    ) {
        self.unavailable = unavailable
        self.failWrites = failWrites
        self.documents = seedDocuments
        self.invalidRecordMessages = invalidRecordMessages
    }

    func loadDocuments() async throws -> UsageHistoryLoadResult {
        if unavailable { throw CloudKitUsageSyncError.accountUnavailable }
        loadCount += 1
        loadInFlight = true
        defer { loadInFlight = false }
        // Capture before gating: a held load answers with the state from when it started, like a
        // real CloudKit response that was slow on the network — what the staleness guard handles.
        let result = UsageHistoryLoadResult(documents: documents, invalidRecordMessages: invalidRecordMessages)
        if shouldHoldNextLoad {
            shouldHoldNextLoad = false
            await withCheckedContinuation { continuation in
                loadGate = continuation
            }
        }
        return result
    }

    func write(_ deviceRecord: DeviceSyncRecord) async throws {
        if unavailable || failWrites { throw CloudKitUsageSyncError.accountUnavailable }
        writeCount += 1
        writeInFlight = true
        defer { writeInFlight = false }
        if shouldHoldNextWrite {
            shouldHoldNextWrite = false
            await withCheckedContinuation { continuation in
                writeGate = continuation
            }
        }
        lastWrittenRecord = deviceRecord
        documents.removeAll { $0.deviceID == deviceRecord.history.deviceID }
        documents.append(deviceRecord.history)
    }

    func delete(deviceID: String) async throws {
        if unavailable { throw CloudKitUsageSyncError.accountUnavailable }
        deleteInFlight = true
        defer { deleteInFlight = false }
        if shouldHoldNextDelete {
            shouldHoldNextDelete = false
            await withCheckedContinuation { continuation in
                deleteGate = continuation
            }
        }
        deletedDeviceIDs.append(deviceID)
        documents.removeAll { $0.deviceID == deviceID }
    }

    func seed(_ document: UsageHistoryDocument) {
        documents.removeAll { $0.deviceID == document.deviceID }
        documents.append(document)
    }

    func holdNextLoad() {
        shouldHoldNextLoad = true
    }

    func holdNextWrite() {
        shouldHoldNextWrite = true
    }

    func holdNextDelete() {
        shouldHoldNextDelete = true
    }

    func releaseDelete() {
        deleteGate?.resume()
        deleteGate = nil
    }

    func releaseLoad() {
        loadGate?.resume()
        loadGate = nil
    }

    func releaseWrite() {
        writeGate?.resume()
        writeGate = nil
    }
}
