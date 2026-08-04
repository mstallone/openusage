import XCTest
@testable import Runway

/// Claude's credential load must not follow a protected current-user item with a service-wide read:
/// that is another Security call behind the same wedge, and with several `Claude Code-credentials`
/// items it could select a different account's login.
final class ClaudeProtectedItemContainmentTests: XCTestCase {
    func testUnavailableCurrentUserReadNeverBroadensToTheServiceWideRead() {
        let keychain = CurrentUserProtectedKeychain()
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(),
            files: FakeFiles(),
            keychain: keychain
        )

        let load = store.loadCredentialSet()

        XCTAssertEqual(load.keychainAccessStatus, .permissionRequired)
        XCTAssertEqual(keychain.serviceWideReads, 0, "a protected exact item must end the lookup")
    }
}

/// The current-user item is present but unreadable; any service-wide read is recorded so the test
/// can prove it never happens.
private final class CurrentUserProtectedKeychain: KeychainAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var serviceWide = 0

    var serviceWideReads: Int { lock.withLock { serviceWide } }

    func readGenericPassword(service: String) throws -> String? {
        lock.withLock { serviceWide += 1 }
        return nil
    }

    func readGenericPasswordWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        lock.withLock { serviceWide += 1 }
        return .unavailable
    }

    func readGenericPasswordForCurrentUserWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        .unavailable
    }

    func genericPasswordForCurrentUserExists(service: String) -> Bool? {
        true
    }

    func genericPasswordExists(service: String) -> Bool? {
        true
    }

    func writeGenericPassword(service: String, value: String) throws {}
}

/// The breaker answers later probes locally, so "was this an ACL denial or an unreadable keychain?"
/// has to be remembered from the read that produced the failure.
final class KeychainFailureCategoryTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    /// Minimal mutable clock (the suite's own `Locked` is private to its test class).
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    }

    func testRecordedDenialSurvivesTheBreakerAndIsClearedByASuccess() {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let coordinator = KeychainReadCoordinator(
            revalidateAfter: 60,
            now: { clock.now }
        )

        XCTAssertNil(coordinator.lastFailureWasPermissionDenied(service: "svc", account: "acct"))

        coordinator.recordFailureCategory(service: "svc", account: "acct", permissionDenied: true)
        _ = coordinator.nonInteractiveRead(
            service: "svc", account: "acct", fingerprint: { "fp-1" },
            read: { NonInteractiveKeychainRead.unavailable }
        )
        // The item is tripped now — a probe answers nil locally — but the category still reads back.
        XCTAssertNil(coordinator.probe(service: "svc", account: "acct") { true })
        XCTAssertEqual(coordinator.lastFailureWasPermissionDenied(service: "svc", account: "acct"), true)

        // Once the breaker revalidates and the read succeeds, there is no failure to describe.
        clock.advance(61)
        _ = coordinator.nonInteractiveRead(
            service: "svc", account: "acct", fingerprint: { "fp-2" },
            read: { NonInteractiveKeychainRead.value("secret") }
        )
        XCTAssertNil(coordinator.lastFailureWasPermissionDenied(service: "svc", account: "acct"))
    }

    func testAnOlderInteractiveCompletionCannotOverwriteANewerRecovery() {
        // Reviewer-requested: interactive read A stalls past the bounded wait, B bypasses it and
        // recovers; A must not then re-trip the item and lock background refreshes out.
        let coordinator = KeychainReadCoordinator(inFlightWait: 0.05)
        let aStarted = DispatchSemaphore(value: 0)
        let releaseA = DispatchSemaphore(value: 0)
        let aDone = expectation(description: "stalled interactive read finished")

        let readerA = Thread {
            _ = try? coordinator.interactiveRead(
                service: "svc", account: nil, fingerprint: { "fp-1" },
                read: {
                    aStarted.signal()
                    releaseA.wait()
                    throw KeychainError.readFailed("denied")
                }
            )
            aDone.fulfill()
        }
        readerA.start()
        XCTAssertEqual(aStarted.wait(timeout: .now() + 2), .success)

        let recovered = try? coordinator.interactiveRead(
            service: "svc", account: nil, fingerprint: { "fp-1" },
            read: { "approved-secret" }
        )
        XCTAssertEqual(recovered, "approved-secret")

        releaseA.signal()
        wait(for: [aDone], timeout: 2)

        let reads = Counter()
        let after = coordinator.nonInteractiveRead(
            service: "svc", account: nil, fingerprint: { "fp-1" },
            read: { reads.increment(); return .value("approved-secret") }
        )
        XCTAssertEqual(after, .value("approved-secret"))
        XCTAssertEqual(reads.value, 1, "the stale failure must not have re-tripped the breaker")
    }

    func testAnUnreadableKeychainIsRecordedAsNotDenied() {
        let coordinator = KeychainReadCoordinator()
        coordinator.recordFailureCategory(service: "svc", account: "acct", permissionDenied: false)
        XCTAssertEqual(coordinator.lastFailureWasPermissionDenied(service: "svc", account: "acct"), false)
    }
}

/// UI-gate contention is not evidence about the item that was skipped.
final class KeychainContentionTests: XCTestCase {
    func testContentionNeitherTripsTheBreakerNorRecordsADenial() {
        let coordinator = KeychainReadCoordinator()
        var reads = 0

        // A read that never reached securityd because another provider's dialog held the gate.
        coordinator.recordContention(service: "svc", account: "acct")
        let first = coordinator.nonInteractiveRead(
            service: "svc", account: "acct", fingerprint: { "fp-1" },
            read: { reads += 1; return .unavailable }
        )
        XCTAssertEqual(first, .unavailable)
        XCTAssertNil(
            coordinator.lastFailureWasPermissionDenied(service: "svc", account: "acct"),
            "contention says nothing about this item's ACL"
        )

        // The very next pass must try for real rather than being locked out for 15 minutes.
        let second = coordinator.nonInteractiveRead(
            service: "svc", account: "acct", fingerprint: { "fp-1" },
            read: { reads += 1; return .value("secret") }
        )
        XCTAssertEqual(second, .value("secret"))
        XCTAssertEqual(reads, 2, "an item that was never attempted must not be circuit-broken")
    }

    /// The Safe Storage readers go through `externalRead`, which used to trip on every thrown
    /// error — including the one the UI gate synthesizes when it turns a read away.
    func testContentionDoesNotTripTheBreakerOnTheExternalPath() {
        let coordinator = KeychainReadCoordinator()
        struct Unreadable: Error {}
        var reads = 0

        coordinator.recordContention(service: "svc", account: nil)
        XCTAssertThrowsError(
            try coordinator.externalRead(
                service: "svc", account: nil, interactive: false,
                unavailable: { _ in Unreadable() },
                read: { reads += 1; throw Unreadable() }
            )
        )

        let recovered = try? coordinator.externalRead(
            service: "svc", account: nil, interactive: false,
            unavailable: { _ in Unreadable() },
            read: { reads += 1; return "safe-storage-key" }
        )
        XCTAssertEqual(recovered, "safe-storage-key")
        XCTAssertEqual(reads, 2, "the skipped read must not lock the item out")
    }

    /// The external path replays the recorded category, so it has to be recorded there too —
    /// otherwise a real denial degrades into generic "couldn't be read" advice for 15 minutes.
    func testExternalReadReplaysTheRecordedDenialCategory() {
        let coordinator = KeychainReadCoordinator()
        enum Failure: Error, Equatable { case denied, unreadable }

        XCTAssertThrowsError(
            try coordinator.externalRead(
                service: "svc", account: nil, interactive: false,
                unavailable: { $0 ? Failure.denied : Failure.unreadable },
                read: {
                    coordinator.recordFailureCategory(service: "svc", account: nil, permissionDenied: true)
                    throw Failure.denied
                }
            )
        )

        // The breaker answers this one locally; it must still say "denied".
        XCTAssertThrowsError(
            try coordinator.externalRead(
                service: "svc", account: nil, interactive: false,
                unavailable: { $0 ? Failure.denied : Failure.unreadable },
                read: { XCTFail("the breaker must answer without calling Security"); return "" }
            )
        ) { XCTAssertEqual($0 as? Failure, .denied) }
    }
}
