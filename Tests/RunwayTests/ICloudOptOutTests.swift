import XCTest
@testable import Runway

/// Opting out has to finish even when the identity or iCloud is unavailable at the moment the
/// user flips the switch: sync is off afterwards, so nothing else comes back for it.
@MainActor
final class ICloudOptOutTests: XCTestCase {
    func testAFailedCompensatingDeletionIsRememberedRatherThanLost() async throws {
        // The race: a publish is in flight when the user opts out, so the record lands AFTER the
        // opt-out deletion already succeeded. The compensating deletion removes it — but if THAT
        // fails, the user would otherwise be told nothing and believe their record is gone when it
        // is still in iCloud. The first delete (the opt-out itself) succeeds; the compensating one
        // fails, which is the only way to exercise this path.
        let defaults = makeDefaults("compensating-delete-fails")
        let cloudStore = RecordingUsageCloudStore(deletionsBeforeFailure: 1)
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            cloudStore: cloudStore,
            deviceIDStore: MemoryDeviceIDStore(),
            writeDebounce: .milliseconds(10),
            pollInterval: nil,
            optOutRetryDelays: []
        )

        await cloudStore.holdNextWrite()
        sync.scheduleWrite()
        let deadline = Date().addingTimeInterval(2)
        while await cloudStore.writeInFlight == false, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let writeStarted = await cloudStore.writeInFlight
        XCTAssertTrue(writeStarted, "the publish must be in flight for this race")

        // Opt out while that write is still in flight, and let the opt-out's own deletion finish
        // FIRST — otherwise the compensating deletion could be the one that succeeds and this would
        // pass for the wrong reason.
        sync.enabled = false
        let optOutDeleted = Date().addingTimeInterval(2)
        while await cloudStore.deletedDeviceIDs.isEmpty, Date() < optOutDeleted {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(
            defaults.bool(forKey: "runway.icloudSync.pendingOptOutDeletion.v1"),
            "the opt-out's own deletion succeeded, so nothing is pending yet"
        )

        // Now the in-flight write lands, recreating the record, and its compensating delete fails.
        await cloudStore.releaseWrite()
        let settle = Date().addingTimeInterval(2)
        while !defaults.bool(forKey: "runway.icloudSync.pendingOptOutDeletion.v1"), Date() < settle {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(
            defaults.bool(forKey: "runway.icloudSync.pendingOptOutDeletion.v1"),
            "a failed compensating deletion must persist the unfinished opt-out"
        )
        XCTAssertNotNil(sync.disabledStateWarning, "and stay visible to the user")
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

}
