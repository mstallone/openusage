import LocalAuthentication
import Security
import XCTest
@testable import Runway

/// Minimal lock-guarded box for cross-thread event recording in the gate tests.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.withLock { body(&value) }
    }
}

private final class ManualRefreshApprovalProbe: @unchecked Sendable {
    struct State {
        var active = 0
        var maximumActive = 0
        var readAttempts = 0
        var promptedProviderIDs: Set<String> = []
        var unavailableProviderIDs: Set<String> = []
    }

    let state = Locked(State())

    func read(providerID: String) {
        state.withLock { $0.readAttempts += 1 }
        InteractiveKeychainReadGate.withTurn { turn in
            guard case .available = turn else {
                _ = state.withLock { $0.unavailableProviderIDs.insert(providerID) }
                return
            }
            let holdFor = state.withLock {
                let isFirstPrompt = $0.promptedProviderIDs.isEmpty
                $0.active += 1
                $0.maximumActive = max($0.maximumActive, $0.active)
                $0.promptedProviderIDs.insert(providerID)
                return isFirstPrompt ? 2.2 : 0.05
            }
            Thread.sleep(forTimeInterval: holdFor)
            state.withLock { $0.active -= 1 }
        }
    }
}

@MainActor
private final class KeychainApprovalRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor] = []
    private let probe: ManualRefreshApprovalProbe

    init(provider: Provider, probe: ManualRefreshApprovalProbe) {
        self.provider = provider
        self.probe = probe
    }

    func refresh() async -> ProviderSnapshot {
        if ProviderRefreshContext.isManual {
            let providerID = provider.id
            let probe = probe
            await loadOffMainActor {
                probe.read(providerID: providerID)
            }
        }
        return ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: [])
    }
}

final class KeychainAccessorTests: XCTestCase {
    func testMissingItemReadsNilAndAnUnreadableOneThrows() throws {
        // The plain throwing read must keep "no credential stored" (nil) apart from "couldn't be
        // read" (throw) — collapsing them is how a locked keychain gets mislabeled "not signed in".
        // It is also prompt-free now: this runs with no approval dialog possible.
        let accessor = SecurityKeychainAccessor()

        XCTAssertNil(try accessor.readGenericPassword(service: "RunwayTests.absent.\(UUID().uuidString)"))
    }

    func testAutomaticReadNeverRequestsSecretData() {
        let requestedSecretData = Locked(false)
        let blockedAuthenticationUI = Locked(false)
        let accessor = SecurityKeychainAccessor(
            coordinator: KeychainReadCoordinator(),
            copyMatching: { query, _ in
                let attributes = query as NSDictionary
                if attributes[kSecReturnData] as? Bool == true {
                    requestedSecretData.withLock { $0 = true }
                }
                if let context = attributes[kSecUseAuthenticationContext] as? LAContext,
                   context.interactionNotAllowed {
                    blockedAuthenticationUI.withLock { $0 = true }
                }
                return errSecItemNotFound
            }
        )

        XCTAssertEqual(
            accessor.readGenericPasswordWithoutUserInteraction(service: "service"),
            .missing
        )
        XCTAssertFalse(
            requestedSecretData.withLock { $0 },
            "automatic reads may inspect metadata but must never request foreign secret data"
        )
        XCTAssertTrue(
            blockedAuthenticationUI.withLock { $0 },
            "metadata probes must fail instead of presenting login-keychain authentication UI"
        )
    }

    func testDeferredAutomaticReadRecordsANeutralCategoryNotADenial() {
        // "An item exists, but the automatic read intentionally didn't inspect it" is NOT
        // "keychain permission is required": nothing asked securityd for the secret, so nothing
        // can have been denied. The deferral must be remembered as `.manualReadDeferred` so
        // providers offer the neutral Connect affordance instead of a permission warning.
        let accessor = SecurityKeychainAccessor(
            coordinator: KeychainReadCoordinator(),
            copyMatching: { _, _ in errSecSuccess }
        )

        XCTAssertEqual(
            accessor.readGenericPasswordWithoutUserInteraction(service: "service"),
            .unavailable
        )
        XCTAssertEqual(accessor.lastReadFailure(service: "service"), .manualReadDeferred)
    }

    func testManualReadWaitsOutModificationDateCollisionBeforeCaching() throws {
        struct ProbeState {
            var secret = "old-secret"
            var secretReads = 0
            var waits = 0
        }

        let modificationDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let clock = Locked(Date(timeIntervalSinceReferenceDate: 1_000.25))
        let state = Locked(ProbeState())
        let coordinator = KeychainReadCoordinator()
        let accessor = SecurityKeychainAccessor(
            coordinator: coordinator,
            metadataNow: { clock.withLock { $0 } },
            waitForMetadataStability: { interval in
                // Simulate another app rotating only the secret later in the same Keychain
                // modification-date second. Its metadata fingerprint remains unchanged.
                state.withLock {
                    $0.secret = "rotated-secret"
                    $0.waits += 1
                }
                clock.withLock { $0 = $0.addingTimeInterval(interval) }
            },
            copyMatching: { query, result in
                let query = query as NSDictionary
                if query[kSecReturnAttributes] as? Bool == true {
                    result?.pointee = [
                        kSecAttrService as String: "service",
                        kSecAttrAccount as String: "account",
                        kSecAttrModificationDate as String: modificationDate,
                    ] as CFDictionary
                    return errSecSuccess
                }
                if query[kSecReturnData] as? Bool == true {
                    let secret = state.withLock { value -> String in
                        value.secretReads += 1
                        return value.secret
                    }
                    result?.pointee = Data(secret.utf8) as CFData
                    return errSecSuccess
                }
                return errSecSuccess
            }
        )

        XCTAssertEqual(
            try accessor.readGenericPasswordAllowingUserInteraction(service: "service", account: "account"),
            "rotated-secret",
            "the approved read must happen after the timestamp collision window closes"
        )
        XCTAssertEqual(
            accessor.readGenericPasswordWithoutUserInteraction(service: "service", account: "account"),
            .value("rotated-secret")
        )
        XCTAssertEqual(state.withLock { $0.waits }, 1)
        XCTAssertEqual(state.withLock { $0.secretReads }, 1, "automatic reuse must not request secret data")
    }

    func testAutomaticSafeStorageReadersRequestMetadataOnly() {
        let claudeRequestedSecretData = Locked(false)
        let claudeBlockedAuthenticationUI = Locked(false)
        let claude = ClaudeDesktopSafeStorageKeyReader(
            coordinator: KeychainReadCoordinator(),
            copyMatching: { query, _ in
                if (query as NSDictionary)[kSecReturnData] as? Bool == true {
                    claudeRequestedSecretData.withLock { $0 = true }
                }
                if let context = (query as NSDictionary)[kSecUseAuthenticationContext] as? LAContext,
                   context.interactionNotAllowed {
                    claudeBlockedAuthenticationUI.withLock { $0 = true }
                }
                return errSecSuccess
            }
        )
        XCTAssertThrowsError(try claude.readPassword(allowInteraction: false)) {
            guard case ClaudeDesktopCredentialError.manualReadDeferred = $0 else {
                return XCTFail("expected the deferred-read outcome, got \($0)")
            }
        }
        XCTAssertFalse(claudeRequestedSecretData.withLock { $0 })
        XCTAssertTrue(claudeBlockedAuthenticationUI.withLock { $0 })

        let sakanaRequestedSecretData = Locked(false)
        let sakanaBlockedAuthenticationUI = Locked(false)
        let sakana = SakanaSafeStorageKeyReader(
            coordinator: KeychainReadCoordinator(),
            copyMatching: { query, _ in
                if (query as NSDictionary)[kSecReturnData] as? Bool == true {
                    sakanaRequestedSecretData.withLock { $0 = true }
                }
                if let context = (query as NSDictionary)[kSecUseAuthenticationContext] as? LAContext,
                   context.interactionNotAllowed {
                    sakanaBlockedAuthenticationUI.withLock { $0 = true }
                }
                return errSecSuccess
            }
        )
        XCTAssertThrowsError(
            try sakana.readPassword(service: "Browser Safe Storage", allowInteraction: false)
        ) {
            guard case SakanaBrowserCredentialError.manualReadDeferred = $0 else {
                return XCTFail("expected the deferred-read outcome, got \($0)")
            }
        }
        XCTAssertFalse(sakanaRequestedSecretData.withLock { $0 })
        XCTAssertTrue(sakanaBlockedAuthenticationUI.withLock { $0 })
    }

    @MainActor
    func testManualRefreshAllQueuesThreeApprovalProvidersAndForcedAutomaticRefreshStaysPromptFree() async {
        // A manual Refresh All starts every provider at once. Whichever provider reaches the gate
        // first holds it beyond the old two-second `.peerBusy` deadline: the other two must stay
        // queued, then both receive a real turn. Then run the CLI/automatic shape (`force`, but not
        // `interactive`) and prove it makes no additional prompt-capable reads.
        let providers = ["provider-a", "provider-b", "provider-c"].map {
            Provider(id: $0, displayName: $0, icon: .providerMark("codex"))
        }
        let probe = ManualRefreshApprovalProbe()
        let runtimes = providers.map { KeychainApprovalRuntime(provider: $0, probe: probe) }
        let suiteName = "RunwayTests.keychain-refresh-all.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: providers, descriptors: []),
            providers: runtimes,
            defaults: defaults
        )

        await store.refreshAll(force: true, interactive: true)

        let afterManual = probe.state.withLock { $0 }
        XCTAssertEqual(
            afterManual.promptedProviderIDs,
            Set(providers.map(\.id)),
            "every protected provider must receive its turn in the same manual refresh"
        )
        XCTAssertTrue(afterManual.unavailableProviderIDs.isEmpty, "no provider may time out as peer-busy")
        XCTAssertEqual(afterManual.readAttempts, providers.count)
        XCTAssertEqual(afterManual.maximumActive, 1, "only one approval dialog may be open at a time")

        await store.refreshAll(force: true)

        let afterForcedNonInteractive = probe.state.withLock { $0 }
        XCTAssertEqual(afterForcedNonInteractive.promptedProviderIDs, afterManual.promptedProviderIDs)
        XCTAssertEqual(
            afterForcedNonInteractive.readAttempts,
            afterManual.readAttempts,
            "a forced automatic/CLI-style refresh must not attempt an interactive read"
        )
        XCTAssertEqual(afterForcedNonInteractive.maximumActive, 1)
    }

    func testCancelledProviderLeavesAnAbandonedDialogQueueWithoutBlockingTheNextProvider() {
        // The active Security call cannot be dismissed by cancellation, but a provider still queued
        // behind an abandoned dialog can be cancelled by its refresh watchdog. It must leave the
        // FIFO promptly, and a later provider must acquire the gate once the active dialog closes.
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let holderDone = expectation(description: "abandoned dialog released")

        let holder = Thread {
            InteractiveKeychainReadGate.withTurn { _ in
                held.signal()
                release.wait()
            }
            holderDone.fulfill()
        }
        holder.start()
        XCTAssertEqual(held.wait(timeout: .now() + 5), .success)
        var holderReleased = false
        var holderFinished = false
        defer {
            if !holderReleased { release.signal() }
            if !holderFinished { wait(for: [holderDone], timeout: 5) }
        }

        let cancelledResult = Locked<InteractiveKeychainReadGate.Turn?>(nil)
        let cancelledDone = DispatchSemaphore(value: 0)
        let queuedStarted = DispatchSemaphore(value: 0)
        let queued = Task {
            await loadOffMainActor {
                queuedStarted.signal()
                let ui = InteractiveKeychainReadGate.withTurn { $0 }
                cancelledResult.withLock { $0 = ui }
                cancelledDone.signal()
            }
        }
        XCTAssertEqual(queuedStarted.wait(timeout: .now() + 2), .success)
        Thread.sleep(forTimeInterval: 0.2)
        queued.cancel()
        XCTAssertEqual(
            cancelledDone.wait(timeout: .now() + 2),
            .success,
            "a cancelled queued provider must not remain trapped behind an abandoned dialog"
        )
        guard case .cancelled? = cancelledResult.withLock({ $0 }) else {
            return XCTFail("the cancelled provider must be told not to touch Security.framework")
        }

        let nextEntered = DispatchSemaphore(value: 0)
        let nextDone = expectation(description: "next provider completed")
        Thread {
            InteractiveKeychainReadGate.withTurn { ui in
                guard case .available = ui else { return }
                nextEntered.signal()
            }
            nextDone.fulfill()
        }.start()
        XCTAssertEqual(nextEntered.wait(timeout: .now() + 0.2), .timedOut)

        holderReleased = true
        release.signal()
        wait(for: [holderDone], timeout: 5)
        holderFinished = true
        XCTAssertEqual(nextEntered.wait(timeout: .now() + 5), .success)
        wait(for: [nextDone], timeout: 5)
    }

    func testManualReadSeedsAutomaticCacheAndDistinguishesMissingItems() throws {
        let accessor = SecurityKeychainAccessor(coordinator: KeychainReadCoordinator())
        let service = "RunwayTests.keychain-ui.\(UUID().uuidString)"
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "runway-tests",
            kSecValueData as String: Data("stored-secret".utf8),
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw XCTSkip("cannot create a login-keychain item in this environment (status \(addStatus))")
        }
        defer {
            _ = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary)
        }

        XCTAssertEqual(accessor.genericPasswordExists(service: service), true)
        XCTAssertEqual(
            accessor.readGenericPasswordWithoutUserInteraction(service: service),
            .unavailable,
            "automatic refresh must not read a foreign secret, even when its ACL already allows it"
        )
        XCTAssertEqual(
            try accessor.readGenericPasswordAllowingUserInteraction(service: service),
            "stored-secret"
        )
        XCTAssertEqual(
            accessor.readGenericPasswordWithoutUserInteraction(service: service),
            .value("stored-secret"),
            "a deliberate read should seed the in-process cache for later automatic refreshes"
        )
        XCTAssertEqual(
            accessor.readGenericPasswordWithoutUserInteraction(service: "\(service).missing"),
            .missing
        )
    }

    func testChangeGatedReadRequiresAnotherManualReadAfterAnItemUpdate() throws {
        // End-to-end over a real login-keychain item: a deliberate read seeds the cache, the
        // coordinator serves it while metadata is unchanged, and a credential rotation invalidates
        // it without letting the automatic path request the replacement secret.
        let accessor = SecurityKeychainAccessor(coordinator: KeychainReadCoordinator())
        let service = "RunwayTests.keychain-fingerprint.\(UUID().uuidString)"
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "runway-tests",
            kSecValueData as String: Data("first-secret".utf8),
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw XCTSkip("cannot create a login-keychain item in this environment (status \(addStatus))")
        }
        defer {
            _ = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary)
        }

        XCTAssertEqual(try accessor.readGenericPasswordAllowingUserInteraction(service: service), "first-secret")
        XCTAssertEqual(accessor.readGenericPasswordWithoutUserInteraction(service: service), .value("first-secret"))

        let update: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        // The label attribute changes alongside the secret, so the fingerprint must move even if the
        // modification date's resolution is coarse.
        let changes: [String: Any] = [
            kSecValueData as String: Data("second-secret".utf8),
            kSecAttrLabel as String: "rotated",
        ]
        XCTAssertEqual(SecItemUpdate(update as CFDictionary, changes as CFDictionary), errSecSuccess)

        XCTAssertEqual(
            accessor.readGenericPasswordWithoutUserInteraction(service: service),
            .unavailable,
            "an updated item must invalidate the old cache without being read automatically"
        )
        XCTAssertEqual(try accessor.readGenericPasswordAllowingUserInteraction(service: service), "second-secret")
        XCTAssertEqual(accessor.readGenericPasswordWithoutUserInteraction(service: service), .value("second-secret"))
    }

    func testRunwayOwnedStoreRoundTripsAndUpdatesPrivateFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunwayOwnedFileStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RunwayOwnedFileStore(directory: directory.path)
        let service = "RunwayTests.owned.\(UUID().uuidString)"

        XCTAssertNil(try store.read(service: service))
        try store.write(service: service, value: "first-value")
        XCTAssertEqual(try store.read(service: service), "first-value")

        try store.write(service: service, value: "second-value")
        XCTAssertEqual(try store.read(service: service), "second-value")

        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent(service).path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

}
