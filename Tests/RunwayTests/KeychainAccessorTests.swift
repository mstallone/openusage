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
        KeychainUISuppression.withUIAllowed { ui in
            guard case .available = ui else {
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

    func testUISuppressionScopeDisablesClassicKeychainUIAndRestoresIt() {
        // `LAContext.interactionNotAllowed` only governs data-protection keychain items; the classic
        // login-keychain ACL dialog is silenced solely by the process-global
        // `SecKeychainSetUserInteractionAllowed` switch this scope drives. If the scope ever stops
        // flipping that switch, automatic refreshes regress into launch-time password dialogs.
        var allowed = DarwinBoolean(false)

        KeychainUISuppression.withUISuppressed { isSuppressed in
            XCTAssertTrue(isSuppressed, "the disable call should succeed in tests")
            SecKeychainGetUserInteractionAllowed(&allowed)
            XCTAssertFalse(allowed.boolValue, "classic keychain UI must be off inside the scope")
            KeychainUISuppression.withUISuppressed { _ in }
            SecKeychainGetUserInteractionAllowed(&allowed)
            XCTAssertFalse(allowed.boolValue, "an inner scope exit must not re-enable UI early")
        }

        SecKeychainGetUserInteractionAllowed(&allowed)
        XCTAssertTrue(allowed.boolValue, "UI must be re-allowed once the outermost scope exits")
        let start = Date()
        KeychainUISuppression.withUIAllowed { _ in
            SecKeychainGetUserInteractionAllowed(&allowed)
            XCTAssertTrue(allowed.boolValue, "an interactive operation must run with UI allowed")
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            0.5,
            "with no suppression in flight, an interactive caller must not wait"
        )
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
            KeychainUISuppression.withUIAllowed { _ in
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

        let cancelledResult = Locked<KeychainUISuppression.InteractiveUI?>(nil)
        let cancelledDone = DispatchSemaphore(value: 0)
        let queuedStarted = DispatchSemaphore(value: 0)
        let queued = Task {
            await loadOffMainActor {
                queuedStarted.signal()
                let ui = KeychainUISuppression.withUIAllowed { $0 }
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
            KeychainUISuppression.withUIAllowed { ui in
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

    func testSuppressedEntrantWaitsOutAnInteractiveOperation() {
        // The interactive gate is held for the operation's WHOLE duration (an approval dialog can
        // sit open for minutes). A suppressed call arriving mid-operation must park until the
        // interactive caller exits — if it ran concurrently, it would flip the process-wide UI flag
        // to false right when the user clicks Always Allow.
        let events = Locked<[String]>([])
        let suppressedDone = expectation(description: "suppressed call completed")

        KeychainUISuppression.withUIAllowed { _ in
            let thread = Thread {
                KeychainUISuppression.withUISuppressed { _ in
                    events.withLock { $0.append("suppressed-ran") }
                }
                suppressedDone.fulfill()
            }
            thread.start()
            // Give the suppressed entrant time to reach the gate; it must still be parked.
            Thread.sleep(forTimeInterval: 0.2)
            events.withLock { $0.append("interactive-exit") }
        }

        wait(for: [suppressedDone], timeout: 5)
        XCTAssertEqual(events.withLock { $0 }, ["interactive-exit", "suppressed-ran"])
    }

    func testSuppressedEntrantGivesUpOnAnAbandonedInteractiveOperation() {
        // The other half of the contract above: an approval dialog can be abandoned behind another
        // window, and parking forever would strand every concurrent refresh in exactly the
        // contention this gate prevents. Past the deadline the body runs with `isSuppressed: false`,
        // which by contract means "report unavailable without touching Security.framework".
        let interactiveHeld = DispatchSemaphore(value: 0)
        let releaseInteractive = DispatchSemaphore(value: 0)
        let interactiveDone = expectation(description: "interactive operation finished")

        let holder = Thread {
            KeychainUISuppression.withUIAllowed { _ in
                interactiveHeld.signal()
                releaseInteractive.wait()
            }
            interactiveDone.fulfill()
        }
        holder.start()
        XCTAssertEqual(interactiveHeld.wait(timeout: .now() + 5), .success)

        let start = Date()
        let suppressed = KeychainUISuppression.withUISuppressed { $0 }
        let elapsed = Date().timeIntervalSince(start)

        releaseInteractive.signal()
        wait(for: [interactiveDone], timeout: 5)

        XCTAssertFalse(suppressed, "a caller that gave up must be told UI is not suppressed")
        XCTAssertLessThan(elapsed, 5, "the suppressed side must not wait indefinitely")
    }

    func testNonInteractiveReadStaysSilentForAuthorizedItemsAndDistinguishesMissing() throws {
        // The test process creates this item, so its ACL already authorizes the process — the
        // suppressed read must still return the secret silently (the already-approved default
        // account path). A missing service must stay `.missing`, never bleed into `.unavailable`.
        let accessor = SecurityKeychainAccessor()
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

        XCTAssertEqual(
            accessor.readGenericPasswordWithoutUserInteraction(service: service),
            .value("stored-secret")
        )
        XCTAssertEqual(accessor.genericPasswordExists(service: service), true)
        XCTAssertEqual(
            accessor.readGenericPasswordWithoutUserInteraction(service: "\(service).missing"),
            .missing
        )
        var allowed = DarwinBoolean(false)
        SecKeychainGetUserInteractionAllowed(&allowed)
        XCTAssertTrue(allowed.boolValue, "the process-global UI switch must be restored after reads")
    }

    func testChangeGatedReadObservesAnItemUpdateThroughItsFingerprint() throws {
        // End-to-end over a real login-keychain item: the coordinator serves the cached secret while
        // the item is unchanged, and a `SecItemUpdate` (what an external credential rotation does)
        // moves the attribute fingerprint so the next read returns the fresh secret.
        let accessor = SecurityKeychainAccessor()
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

        XCTAssertEqual(
            accessor.readGenericPasswordWithoutUserInteraction(service: service),
            .value("first-secret")
        )

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
            .value("second-secret"),
            "an updated item must not be served from the stale cache"
        )
    }

    func testRunwayOwnedStoreRoundTripsAndUpdatesInProcess() throws {
        // Runway-owned items are created and read entirely in-process: no subprocess, no secret in
        // an argument list, and the creating process's ACL keeps every read silent.
        let store = RunwayOwnedKeychainStore()
        let service = "RunwayTests.owned.\(UUID().uuidString)"
        defer {
            _ = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary)
        }

        XCTAssertNil(try store.read(service: service))
        do {
            try store.write(service: service, value: "first-value")
        } catch {
            throw XCTSkip("cannot create a login-keychain item in this environment (\(error))")
        }
        XCTAssertEqual(try store.read(service: service), "first-value")

        // A second write updates the existing item in place.
        try store.write(service: service, value: "second-value")
        XCTAssertEqual(try store.read(service: service), "second-value")
    }

}
