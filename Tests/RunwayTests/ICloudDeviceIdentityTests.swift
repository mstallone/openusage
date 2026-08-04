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

    func testProvisionalIdentityRecoversFromThePollWithNoProviderActivity() async throws {
        // A Mac with every provider disabled never fires the local-state callback, so the poll is
        // the only recurring signal left. Nothing here calls scheduleWrite().
        let defaults = makeDefaults("provisional-poll-recovery")
        let recovering = RecoveringDeviceIDStore()
        let cloudStore = RecordingUsageCloudStore()
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            cloudStore: cloudStore,
            deviceIDStore: recovering,
            writeDebounce: .milliseconds(10),
            pollInterval: .milliseconds(20)
        )
        XCTAssertTrue(sync.serviceError != nil, "the identity starts provisional")

        recovering.recover(as: "aaaaaaaa-9999-8888-7777-666666666666")
        let deadline = Date().addingTimeInterval(3)
        while await cloudStore.writeCount == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        let writes = await cloudStore.writeCount
        XCTAssertGreaterThan(writes, 0, "the poll must resume publishing once the identity resolves")
        XCTAssertEqual(sync.deviceID, "aaaaaaaa-9999-8888-7777-666666666666")
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

    func testAReadableButInvalidStoredIDNeverMintsAReplacement() async throws {
        // A stored value that is readable text but not a UUID is a CORRUPT identity, not an absent
        // one. Normalizing it to nil would look identical to a fresh install, so a new id would be
        // minted and a second record published for a Mac that already has one.
        let defaults = makeDefaults("invalid-stored-device-id")
        let owned = InMemoryOwnedSecretStore()
        owned.secrets["com.mattstallone.runway.icloud-sync-device-id.v2"] = "not-a-uuid"
        let cloudStore = RecordingUsageCloudStore()
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            cloudStore: cloudStore,
            deviceIDStore: KeychainICloudDeviceIDStore(
                ownedStore: owned,
                legacyKeychain: ProbeOnlyKeychain(),
                bundleIdentifier: "com.mattstallone.runway"
            ),
            pollInterval: nil
        )

        try await Task.sleep(for: .milliseconds(120))

        XCTAssertNotNil(sync.serviceError, "a corrupt identity must be reported, not silently replaced")
        XCTAssertNil(
            defaults.string(forKey: "runway.icloudSync.deviceID.v1"),
            "no replacement identity may be persisted"
        )
        let writes = await cloudStore.writeCount
        XCTAssertEqual(writes, 0, "and nothing may be published under a minted id")
        XCTAssertEqual(owned.secrets["com.mattstallone.runway.icloud-sync-device-id.v2"], "not-a-uuid")
    }

    func testAnInvalidLegacyIdentityNeverMintsAReplacement() async throws {
        // Same rule as the v2 item, on the legacy path: a recovered value that is not a UUID is a
        // corrupt identity. Normalizing it to nil would take the fresh-install branch and publish a
        // second record for a Mac that already has one.
        let defaults = makeDefaults("invalid-legacy-device-id")
        let cloudStore = RecordingUsageCloudStore()
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            cloudStore: cloudStore,
            deviceIDStore: InvalidLegacyDeviceIDStore(),
            pollInterval: nil
        )

        try await Task.sleep(for: .milliseconds(120))

        XCTAssertNotNil(sync.serviceError, "a corrupt legacy identity must be reported")
        XCTAssertNil(
            defaults.string(forKey: "runway.icloudSync.deviceID.v1"),
            "no replacement identity may be persisted"
        )
        let writes = await cloudStore.writeCount
        XCTAssertEqual(writes, 0, "and nothing may be published under a minted id")
    }

    func testAnUndecodableOwnedValueIsAReadFailureNotAnAbsentItem() throws {
        // The owned store must surface a present-but-undecodable item as an error. Returning nil
        // would put the store on the same "fresh install" path as a genuinely missing item.
        let store = RunwayOwnedKeychainStore()
        let service = "RunwayTests.owned.invalid.\(UUID().uuidString)"
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "runway",
            kSecValueData as String: Data([0xFF, 0xFE, 0xFD]),
        ]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw XCTSkip("cannot create a login-keychain item in this environment")
        }
        defer {
            _ = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary)
        }

        XCTAssertThrowsError(try store.read(service: service)) { error in
            guard case KeychainError.readFailed = error else {
                return XCTFail("expected KeychainError.readFailed, got \(error)")
            }
        }
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

    /// Sync ON by default, matching a real install — these tests must be able to prove that an
    /// unresolved identity publishes nothing even when sync is enabled.
}

final class InMemoryOwnedSecretStore: RunwayOwnedSecretStoring, @unchecked Sendable {
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
final class TrappingKeychain: KeychainReading, @unchecked Sendable {
    func readGenericPassword(service: String) throws -> String? {
        XCTFail("the legacy Keychain path must not be consulted")
        return nil
    }

    func writeGenericPassword(service: String, value: String) throws {}
}

/// Answers the prompt-free existence probe with "absent" and fails the test if any secret read runs.
final class ProbeOnlyKeychain: KeychainReading, @unchecked Sendable {
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
final class IndeterminateProbeKeychain: KeychainReading, @unchecked Sendable {
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
/// No v2 item, and the legacy recovery hands back a value that is readable but not a UUID.
private final class InvalidLegacyDeviceIDStore: ICloudDeviceIDStoring, @unchecked Sendable {
    func readDeviceID() throws -> String? { nil }
    func writeDeviceID(_ deviceID: String) throws {}
    func migrateLegacyDeviceID() throws -> String? { "definitely-not-a-uuid" }
}

final class RecoveringDeviceIDStore: ICloudDeviceIDStoring, @unchecked Sendable {
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
