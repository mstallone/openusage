import XCTest
@testable import Runway

/// This Mac's iCloud Sync identity: where the device id comes from, how it migrates off the legacy
/// subprocess-written Keychain item, and — most importantly — that Runway never publishes a second
/// CloudKit record for a Mac that already has one.
@MainActor
final class ICloudDeviceIdentityTests: XCTestCase {
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

    func testUpgradeSeedsTheOwnedItemFromSavedPreferencesWithoutTouchingLegacyKeychain() async throws {
        // The normal upgrade: UserDefaults still carries the device id, so the v2 item is seeded
        // from it directly. The legacy `/usr/bin/security` path — the only prompt-capable step —
        // must not be consulted at all.
        let defaults = makeDefaults("upgrade-from-saved")
        defaults.set("aaaaaaaa-1111-2222-3333-444444444444", forKey: "runway.icloudSync.deviceID.v1")
        let owned = InMemoryOwnedSecretStore()
        let deviceIDStore = KeychainICloudDeviceIDStore(
            ownedStore: owned,
            legacyKeychain: TrappingKeychain(),
            bundleIdentifier: "com.mattstallone.runway"
        )

        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            cloudStore: RecordingUsageCloudStore(),
            deviceIDStore: deviceIDStore,
            pollInterval: nil
        )

        XCTAssertEqual(sync.deviceID, "aaaaaaaa-1111-2222-3333-444444444444")
        XCTAssertEqual(
            owned.secrets["com.mattstallone.runway.icloud-sync-device-id.v2"],
            "aaaaaaaa-1111-2222-3333-444444444444"
        )
    }

    func testPreferencesResetUpgradeRecoversTheLegacyDeviceIDOnce() async throws {
        // Only when BOTH the v2 item and the saved preference are gone (a preferences reset on an
        // upgrade) is the legacy v1 item consulted — once. It seeds v2, and later launches never
        // reach the legacy path again.
        let defaults = makeDefaults("upgrade-after-prefs-reset")
        let owned = InMemoryOwnedSecretStore()
        let legacy = ServiceKeychain()
        legacy.currentUserValues["com.mattstallone.runway.icloud-sync-device-id.v1"] = "bbbbbbbb-1111-2222-3333-444444444444"
        legacy.values["com.mattstallone.runway.icloud-sync-device-id.v1"] = "bbbbbbbb-1111-2222-3333-444444444444"
        let deviceIDStore = KeychainICloudDeviceIDStore(
            ownedStore: owned,
            legacyKeychain: legacy,
            bundleIdentifier: "com.mattstallone.runway"
        )

        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            cloudStore: RecordingUsageCloudStore(),
            deviceIDStore: deviceIDStore,
            pollInterval: nil
        )

        XCTAssertEqual(sync.deviceID, "bbbbbbbb-1111-2222-3333-444444444444")
        XCTAssertEqual(
            owned.secrets["com.mattstallone.runway.icloud-sync-device-id.v2"],
            "bbbbbbbb-1111-2222-3333-444444444444"
        )
        XCTAssertEqual(defaults.string(forKey: "runway.icloudSync.deviceID.v1"), "bbbbbbbb-1111-2222-3333-444444444444")

        // Relaunch: v2 exists now, so the legacy path is dead even if the item changes.
        legacy.currentUserValues["com.mattstallone.runway.icloud-sync-device-id.v1"] = "cccccccc-1111-2222-3333-444444444444"
        let relaunch = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            cloudStore: RecordingUsageCloudStore(),
            deviceIDStore: deviceIDStore,
            pollInterval: nil
        )
        XCTAssertEqual(relaunch.deviceID, "bbbbbbbb-1111-2222-3333-444444444444")
    }

    func testUnknownLegacyProbeNeverPublishesAProvisionalIdentity() async throws {
        // v2 and the saved preference are both gone and the keychain can't be checked. Any id minted
        // here could duplicate a record this Mac already published under its real id — so with sync
        // ON, Runway must publish NOTHING, persist nothing, and say why.
        let defaults = makeDefaults("unknown-legacy-probe")
        let cloudStore = RecordingUsageCloudStore()
        let store = KeychainICloudDeviceIDStore(
            ownedStore: InMemoryOwnedSecretStore(),
            legacyKeychain: IndeterminateProbeKeychain(),
            bundleIdentifier: "com.mattstallone.runway"
        )
        XCTAssertThrowsError(try store.migrateLegacyDeviceID())

        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            cloudStore: cloudStore,
            deviceIDStore: store,
            writeDebounce: .milliseconds(10),
            pollInterval: nil
        )
        XCTAssertTrue(sync.enabled, "this test only means something with sync on")
        sync.scheduleWrite()
        try await Task.sleep(for: .milliseconds(120))

        let writes = await cloudStore.writeCount
        XCTAssertEqual(writes, 0, "a provisional identity must never publish a device record")
        XCTAssertNil(
            defaults.string(forKey: "runway.icloudSync.deviceID.v1"),
            "a provisional id must not be persisted as this Mac's identity"
        )
        XCTAssertNotNil(sync.serviceError, "the user must be told why usage isn't publishing")
    }

    func testProvisionalIdentityContributesNoPeerHistory() async throws {
        // This Mac's OWN earlier record can't be recognized while the identity is provisional, so
        // merging it would count local usage a second time as if a different device produced it.
        let defaults = makeDefaults("provisional-peer-merge")
        let ownPriorRecord = UsageHistoryDocument(
            deviceID: "the-real-id-this-mac-published-before",
            deviceName: "This Mac",
            updatedAt: .now,
            providers: [:]
        )
        let cloudStore = RecordingUsageCloudStore(seedDocuments: [ownPriorRecord])
        let dataStore = makeDataStore(defaults)
        let sync = ICloudUsageSyncStore(
            dataStore: dataStore,
            defaults: defaults,
            cloudStore: cloudStore,
            deviceIDStore: KeychainICloudDeviceIDStore(
                ownedStore: InMemoryOwnedSecretStore(),
                legacyKeychain: IndeterminateProbeKeychain(),
                bundleIdentifier: "com.mattstallone.runway"
            ),
            pollInterval: nil
        )

        // Poll until the record has actually been downloaded, so this proves the merge path ran
        // and still contributed nothing — not merely that the load never happened.
        let deadline = Date().addingTimeInterval(2)
        while sync.documents.isEmpty, Date() < deadline {
            await sync.reload()
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertFalse(sync.documents.isEmpty, "the prior record should have been downloaded")
        XCTAssertTrue(
            dataStore.peerHistoryDocuments.isEmpty,
            "a provisional identity must contribute no peer history"
        )
    }

    func testOptOutWithAProvisionalIdentityReportsThatNothingWasRemoved() async throws {
        // Deleting the provisional UUID would remove nothing and quietly strand the record this Mac
        // really published — and opting out also stops the retries that would resolve it.
        let defaults = makeDefaults("provisional-opt-out")
        let cloudStore = RecordingUsageCloudStore()
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            cloudStore: cloudStore,
            deviceIDStore: KeychainICloudDeviceIDStore(
                ownedStore: InMemoryOwnedSecretStore(),
                legacyKeychain: IndeterminateProbeKeychain(),
                bundleIdentifier: "com.mattstallone.runway"
            ),
            pollInterval: nil
        )

        sync.enabled = false
        let deadline = Date().addingTimeInterval(2)
        while sync.serviceError == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        let deleted = await cloudStore.deletedDeviceIDs
        XCTAssertTrue(deleted.isEmpty, "a provisional id must not be used for the opt-out delete")
        XCTAssertNotNil(sync.serviceError, "the user must be told the record wasn't removed")
        XCTAssertNotNil(
            sync.disabledStateWarning,
            "Settings renders errors only while sync is on, so this one must survive the toggle"
        )
    }

    func testPendingOptOutIsRetriedOnTheNextLaunch() async throws {
        // Sync is off after a failed opt-out, so nothing else would ever come back for it. The
        // intent is persisted and completed once the identity is knowable again.
        let defaults = makeDefaults("pending-opt-out-retry")
        defaults.set(false, forKey: "runway.icloudSync.enabled.v1")
        defaults.set(true, forKey: "runway.icloudSync.pendingOptOutDeletion.v1")
        defaults.set("cccccccc-1111-2222-3333-444444444444", forKey: "runway.icloudSync.deviceID.v1")
        let cloudStore = RecordingUsageCloudStore()

        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            cloudStore: cloudStore,
            deviceIDStore: KeychainICloudDeviceIDStore(
                ownedStore: InMemoryOwnedSecretStore(),
                legacyKeychain: ServiceKeychain(),
                bundleIdentifier: "com.mattstallone.runway"
            ),
            pollInterval: nil
        )
        XCTAssertFalse(sync.enabled)

        let deadline = Date().addingTimeInterval(2)
        while await cloudStore.deletedDeviceIDs.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        let deleted = await cloudStore.deletedDeviceIDs
        XCTAssertEqual(deleted, ["cccccccc-1111-2222-3333-444444444444"])
        XCTAssertFalse(
            defaults.bool(forKey: "runway.icloudSync.pendingOptOutDeletion.v1"),
            "a completed opt-out must clear the pending flag"
        )
    }

    func testFailedDeletionWithAResolvedIdentityIsAlsoRetriedAndVisible() async throws {
        // The other stranding path: identity is fine, but the CloudKit delete throws. Sync is off,
        // so nothing comes back for it — record and surface it like the provisional case.
        let defaults = makeDefaults("failed-delete-retry")
        let cloudStore = RecordingUsageCloudStore(unavailable: true)
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            cloudStore: cloudStore,
            deviceIDStore: MemoryDeviceIDStore(),
            pollInterval: nil
        )

        sync.enabled = false
        let deadline = Date().addingTimeInterval(2)
        while !defaults.bool(forKey: "runway.icloudSync.pendingOptOutDeletion.v1"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertTrue(
            defaults.bool(forKey: "runway.icloudSync.pendingOptOutDeletion.v1"),
            "a failed deletion must be remembered for the next launch"
        )
        XCTAssertNotNil(sync.disabledStateWarning, "and stay visible while sync is off")
    }

    func testPendingOptOutCompletesWithinTheSameSessionOnceTheKeychainRecovers() async throws {
        // With sync off there is no poll and no write loop, so a launch-time retry that finds the
        // keychain still locked used to strand the record until the next relaunch.
        let defaults = makeDefaults("pending-opt-out-in-session")
        defaults.set(false, forKey: "runway.icloudSync.enabled.v1")
        defaults.set(true, forKey: "runway.icloudSync.pendingOptOutDeletion.v1")
        let recovering = RecoveringDeviceIDStore()
        let cloudStore = RecordingUsageCloudStore()
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            cloudStore: cloudStore,
            deviceIDStore: recovering,
            pollInterval: nil
        )

        // The launch-time retry runs against a still-unreadable keychain and must delete nothing:
        // the provisional UUID is not this Mac's CloudKit record.
        try await Task.sleep(for: .milliseconds(120))
        var deleted = await cloudStore.deletedDeviceIDs
        XCTAssertTrue(deleted.isEmpty, "a provisional identity must never be used to delete")
        XCTAssertTrue(defaults.bool(forKey: "runway.icloudSync.pendingOptOutDeletion.v1"))

        // The keychain comes back and a refresh reports local state; that is the only recurring
        // signal left while sync is off, so the opt-out finishes there.
        recovering.recover(as: "eeeeeeee-1111-2222-3333-444444444444")
        sync.scheduleWrite()
        let deadline = Date().addingTimeInterval(2)
        while await cloudStore.deletedDeviceIDs.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        deleted = await cloudStore.deletedDeviceIDs
        XCTAssertEqual(deleted, ["eeeeeeee-1111-2222-3333-444444444444"])
        XCTAssertFalse(
            defaults.bool(forKey: "runway.icloudSync.pendingOptOutDeletion.v1"),
            "the opt-out completed without a relaunch"
        )
    }

    func testAStrandedOptOutRetriesWithoutAnyProviderActivity() async throws {
        // The local-state callback only fires when a provider refreshed or failed, so a Mac with
        // every provider disabled gave the retry no signal at all. The schedule must not depend on
        // it: nothing here ever calls scheduleWrite().
        let defaults = makeDefaults("pending-opt-out-independent")
        defaults.set(false, forKey: "runway.icloudSync.enabled.v1")
        defaults.set(true, forKey: "runway.icloudSync.pendingOptOutDeletion.v1")
        let recovering = RecoveringDeviceIDStore()
        let cloudStore = RecordingUsageCloudStore()
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            cloudStore: cloudStore,
            deviceIDStore: recovering,
            pollInterval: nil,
            optOutRetryDelays: [.milliseconds(20), .milliseconds(20), .milliseconds(20)]
        )

        try await Task.sleep(for: .milliseconds(10))
        let beforeRecovery = await cloudStore.deletedDeviceIDs
        XCTAssertTrue(beforeRecovery.isEmpty, "a provisional identity must never be used to delete")

        // The keychain comes back with no provider ever reporting anything.
        recovering.recover(as: "ffffffff-1111-2222-3333-444444444444")
        let deadline = Date().addingTimeInterval(3)
        while await cloudStore.deletedDeviceIDs.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        let deleted = await cloudStore.deletedDeviceIDs
        XCTAssertEqual(deleted, ["ffffffff-1111-2222-3333-444444444444"])
        XCTAssertFalse(sync.enabled, "no provider activity was ever reported")
    }

    func testProvisionalIdentityRecoversWithinTheSameSession() async throws {
        // Reviewer-requested: once the keychain becomes readable, publishing resumes without a
        // relaunch.
        let defaults = makeDefaults("provisional-recovers-in-session")
        let recovering = RecoveringDeviceIDStore()
        let cloudStore = RecordingUsageCloudStore()
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            cloudStore: cloudStore,
            deviceIDStore: recovering,
            writeDebounce: .milliseconds(10),
            pollInterval: nil
        )

        // First publish attempt is withheld: the identity is provisional.
        sync.scheduleWrite()
        try await Task.sleep(for: .milliseconds(120))
        var writes = await cloudStore.writeCount
        XCTAssertEqual(writes, 0)

        // The keychain comes back; the next attempt resolves and publishes under the real id.
        recovering.recover(as: "dddddddd-1111-2222-3333-444444444444")
        sync.scheduleWrite()
        let deadline = Date().addingTimeInterval(2)
        while await cloudStore.writeCount == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        writes = await cloudStore.writeCount
        XCTAssertGreaterThan(writes, 0, "publishing resumes without a relaunch")
        XCTAssertEqual(sync.deviceID, "dddddddd-1111-2222-3333-444444444444")
    }

    func testFreshInstallNeverSpawnsTheLegacyKeychainRead() throws {
        // A fresh install has no v1 item: the prompt-free existence probe answers "absent" and the
        // subprocess-backed legacy read must never run — not even once.
        let store = KeychainICloudDeviceIDStore(
            ownedStore: InMemoryOwnedSecretStore(),
            legacyKeychain: ProbeOnlyKeychain(),
            bundleIdentifier: "com.mattstallone.runway"
        )
        XCTAssertNil(try store.migrateLegacyDeviceID())
    }

    func testMissingDeviceIDReadsNilWithoutInventingAnIdentity() throws {
        let store = KeychainICloudDeviceIDStore(
            ownedStore: InMemoryOwnedSecretStore(),
            legacyKeychain: ServiceKeychain(),
            bundleIdentifier: "com.mattstallone.runway"
        )
        XCTAssertNil(try store.readDeviceID())
        XCTAssertNil(try store.migrateLegacyDeviceID())
    }

    private func makeDataStore(_ defaults: UserDefaults) -> WidgetDataStore {
        WidgetDataStore(
            registry: WidgetRegistry(providers: [], descriptors: []),
            providers: [],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults
        )
    }

    /// Sync ON by default, matching a real install — these tests must be able to prove that an
    /// unresolved identity publishes nothing even when sync is enabled.
    private func makeDefaults(_ name: String, syncEnabled: Bool = true) -> UserDefaults {
        let suite = "RunwayTests.ICloudIdentity.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(syncEnabled, forKey: "runway.icloudSync.enabled.v1")
        return defaults
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

/// Fails the test on ANY read: proves a code path never consults the (prompt-capable) legacy
/// Keychain.
private final class TrappingKeychain: KeychainReading, @unchecked Sendable {
    func readGenericPassword(service: String) throws -> String? {
        XCTFail("the legacy Keychain path must not be consulted")
        return nil
    }

    func writeGenericPassword(service: String, value: String) throws {}
}

/// Answers the prompt-free existence probe with "absent" and fails the test if any secret read runs.
private final class ProbeOnlyKeychain: KeychainReading, @unchecked Sendable {
    func readGenericPassword(service: String) throws -> String? {
        XCTFail("no secret read may run when the existence probe reports the item absent")
        return nil
    }

    func genericPasswordExists(service: String) -> Bool? {
        false
    }

    func writeGenericPassword(service: String, value: String) throws {}
}

/// The legacy item's existence cannot be determined (locked keychain / suppressed probe), and any
/// secret read would fail the test — the migration must stop at the probe.
private final class IndeterminateProbeKeychain: KeychainReading, @unchecked Sendable {
    func readGenericPassword(service: String) throws -> String? {
        XCTFail("no secret read may run when existence is unknown")
        return nil
    }

    func genericPasswordExists(service: String) -> Bool? {
        nil
    }

    func genericPasswordForCurrentUserExists(service: String) -> Bool? {
        nil
    }
}

/// Unresolvable until `recover` is called, then returns a real id — models a keychain that becomes
/// readable during the session.
private final class RecoveringDeviceIDStore: ICloudDeviceIDStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    func recover(as id: String) {
        lock.withLock { stored = id }
    }

    func readDeviceID() throws -> String? {
        lock.withLock { stored }
    }

    func writeDeviceID(_ deviceID: String) throws {
        lock.withLock { stored = deviceID }
    }

    func migrateLegacyDeviceID() throws -> String? {
        guard lock.withLock({ stored }) != nil else {
            throw KeychainError.readFailed("keychain unavailable")
        }
        return nil
    }
}
