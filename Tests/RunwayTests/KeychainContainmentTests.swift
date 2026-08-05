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

        XCTAssertEqual(load.keychainAccessStatus, .connectRequired)
        XCTAssertEqual(keychain.serviceWideReads, 0, "a protected exact item must end the lookup")
    }
}

/// The current-user item is present but unreadable; any service-wide read is recorded so the test
/// can prove it never happens.
private final class CurrentUserProtectedKeychain: KeychainReading, @unchecked Sendable {
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

        XCTAssertNil(coordinator.lastFailureCategory(service: "svc", account: "acct"))

        _ = coordinator.nonInteractiveRead(
            service: "svc", account: "acct", fingerprint: { "fp-1" },
            read: { ticket in
                coordinator.recordFailureCategory(ticket, category: .permissionDenied)
                return NonInteractiveKeychainRead.unavailable
            }
        )
        // The item is tripped now — a probe answers nil locally — but the category still reads back.
        XCTAssertNil(coordinator.probe(service: "svc", account: "acct") { true })
        XCTAssertEqual(coordinator.lastFailureCategory(service: "svc", account: "acct"), .permissionDenied)

        // Once the breaker revalidates and the read succeeds, there is no failure to describe.
        clock.advance(61)
        _ = coordinator.nonInteractiveRead(
            service: "svc", account: "acct", fingerprint: { "fp-2" },
            read: { _ in NonInteractiveKeychainRead.value("secret") }
        )
        XCTAssertNil(coordinator.lastFailureCategory(service: "svc", account: "acct"))
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
                read: { _ in
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
            read: { _ in "approved-secret" }
        )
        XCTAssertEqual(recovered, "approved-secret")

        releaseA.signal()
        wait(for: [aDone], timeout: 2)

        let reads = Counter()
        let after = coordinator.nonInteractiveRead(
            service: "svc", account: nil, fingerprint: { "fp-1" },
            read: { _ in reads.increment(); return .value("approved-secret") }
        )
        XCTAssertEqual(after, .value("approved-secret"))
        XCTAssertEqual(reads.value, 1, "the stale failure must not have re-tripped the breaker")
    }

    func testANewerRecoveryWinsEvenWhenTheOlderReadFinishesFirst() {
        // The mirror of the stale-completion case: A is stuck, B bypasses it after the deadline,
        // then A finishes BEFORE B returns. Ordering by completion would let A's failure land last
        // and leave the item tripped for the whole window, even though the user just approved it.
        let coordinator = KeychainReadCoordinator(inFlightWait: 0.05)
        let aStarted = DispatchSemaphore(value: 0)
        let releaseA = DispatchSemaphore(value: 0)
        let aFinished = DispatchSemaphore(value: 0)
        let aDone = expectation(description: "older read finished")

        let readerA = Thread {
            _ = try? coordinator.interactiveRead(
                service: "svc", account: nil, fingerprint: { "fp-1" },
                read: { _ in
                    aStarted.signal()
                    releaseA.wait()
                    throw KeychainError.readFailed("denied")
                }
            )
            aFinished.signal()
            aDone.fulfill()
        }
        readerA.start()
        XCTAssertEqual(aStarted.wait(timeout: .now() + 2), .success)

        // B starts second and succeeds, but lets A store first.
        let recovered = try? coordinator.interactiveRead(
            service: "svc", account: nil, fingerprint: { "fp-1" },
            read: { _ in
                releaseA.signal()
                XCTAssertEqual(aFinished.wait(timeout: .now() + 2), .success)
                return "approved-secret"
            }
        )
        XCTAssertEqual(recovered, "approved-secret")
        wait(for: [aDone], timeout: 2)

        let reads = Counter()
        let after = coordinator.nonInteractiveRead(
            service: "svc", account: nil, fingerprint: { "fp-1" },
            read: { _ in reads.increment(); return .value("approved-secret") }
        )
        XCTAssertEqual(after, .value("approved-secret"))
        XCTAssertEqual(reads.value, 1, "the older read's failure must not have won the store")
    }

    func testAStuckFlightNeverServesAFingerprintedCacheEntry() {
        // The stuck read may be fetching a rotation of exactly the secret the cache holds, so a
        // fingerprinted entry (cached against the item's PREVIOUS attributes) must not be served.
        // Only an interactive recovery's entry, which carries no fingerprint, may answer here.
        let coordinator = KeychainReadCoordinator(inFlightWait: 0.05)
        _ = coordinator.nonInteractiveRead(
            service: "svc", account: nil, fingerprint: { "fp-1" },
            read: { _ in .value("cached-under-fp-1") }
        )

        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let stuckDone = expectation(description: "stuck read finished")
        let stuck = Thread {
            _ = coordinator.nonInteractiveRead(
                service: "svc", account: nil, fingerprint: { "fp-2" },
                read: { _ in
                    started.signal()
                    release.wait()
                    return .value("rotated")
                }
            )
            stuckDone.fulfill()
        }
        stuck.start()
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)

        let timedOut = coordinator.nonInteractiveRead(
            service: "svc", account: nil, fingerprint: { XCTFail("must not probe behind a stuck flight"); return nil },
            read: { _ in XCTFail("must not read behind a stuck flight"); return .unavailable }
        )
        XCTAssertEqual(timedOut, .unavailable, "a superseded secret must never be served as current")

        release.signal()
        wait(for: [stuckDone], timeout: 2)
    }

    func testAStuckFlightNeverServesABackgroundValueWithNoFingerprint() {
        // A background probe can fail and store its value with a nil fingerprint too, so "no
        // fingerprint" does not mean "a user just approved this". Only an explicit user action's
        // value may answer here, because the stuck read may be fetching a rotation of this secret.
        let coordinator = KeychainReadCoordinator(inFlightWait: 0.05)
        _ = coordinator.nonInteractiveRead(
            service: "svc", account: nil,
            fingerprint: { nil },
            read: { _ in .value("background-value") }
        )

        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let stuckDone = expectation(description: "stuck read finished")
        let stuck = Thread {
            _ = coordinator.nonInteractiveRead(
                service: "svc", account: nil, fingerprint: { "fp-2" },
                read: { _ in started.signal(); release.wait(); return .value("rotated") }
            )
            stuckDone.fulfill()
        }
        stuck.start()
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)

        let timedOut = coordinator.nonInteractiveRead(
            service: "svc", account: nil,
            fingerprint: { XCTFail("must not probe behind a stuck flight"); return nil },
            read: { _ in XCTFail("must not read behind a stuck flight"); return .unavailable }
        )
        XCTAssertEqual(timedOut, .unavailable, "a background value is no evidence the secret is current")

        release.signal()
        wait(for: [stuckDone], timeout: 2)
    }

    func testAnUnreadableKeychainIsRecordedAsNotDenied() {
        let coordinator = KeychainReadCoordinator()
        _ = coordinator.nonInteractiveRead(
            service: "svc", account: "acct", fingerprint: { "fp-1" },
            read: { ticket in
                coordinator.recordFailureCategory(ticket, category: .unreadable)
                return NonInteractiveKeychainRead.unavailable
            }
        )
        XCTAssertEqual(coordinator.lastFailureCategory(service: "svc", account: "acct"), .unreadable)
    }

    func testAStaleCategoryCannotOutliveTheFailureItDescribed() {
        // A category belongs to the read that observed the status, and travels with that read's
        // sequenced outcome. A stale read's verdict must never be reported as the item's current
        // one once a newer read has recovered it.
        let coordinator = KeychainReadCoordinator()
        _ = coordinator.nonInteractiveRead(
            service: "svc", account: "acct", fingerprint: { "fp-1" },
            read: { ticket in
                coordinator.recordFailureCategory(ticket, category: .permissionDenied)
                return NonInteractiveKeychainRead.unavailable
            }
        )
        XCTAssertEqual(coordinator.lastFailureCategory(service: "svc", account: "acct"), .permissionDenied)

        // The user approves; the interactive read clears the breaker (a background read would be
        // answered locally by it and never reach Security at all). The recovery clears the category
        // along with the failure it described.
        _ = try? coordinator.interactiveRead(
            service: "svc", account: "acct", fingerprint: { "fp-2" },
            read: { _ in "approved-secret" }
        )
        XCTAssertNil(
            coordinator.lastFailureCategory(service: "svc", account: "acct"),
            "a recovered item has no failure to describe"
        )
    }
}

/// UI-gate contention is not evidence about the item that was skipped.
final class KeychainContentionTests: XCTestCase {
    func testContentionNeitherTripsTheBreakerNorRecordsADenial() {
        let coordinator = KeychainReadCoordinator()
        var reads = 0

        // A read that never reached securityd because another provider's dialog held the gate.
        let first = coordinator.nonInteractiveRead(
            service: "svc", account: "acct", fingerprint: { "fp-1" },
            read: { ticket in
                coordinator.recordContention(ticket)
                reads += 1
                return .unavailable
            }
        )
        XCTAssertEqual(first, .unavailable)
        XCTAssertNil(
            coordinator.lastFailureCategory(service: "svc", account: "acct"),
            "contention says nothing about this item's ACL"
        )

        // The very next pass must try for real rather than being locked out for 15 minutes.
        let second = coordinator.nonInteractiveRead(
            service: "svc", account: "acct", fingerprint: { "fp-1" },
            read: { _ in reads += 1; return .value("secret") }
        )
        XCTAssertEqual(second, .value("secret"))
        XCTAssertEqual(reads, 2, "an item that was never attempted must not be circuit-broken")
    }

    func testAStaleContentionMarkerCannotDisableTheBreaker() {
        // The marker is keyed by item, not by read. If a read records contention and then loses the
        // sequence race, leaving its marker behind, the NEXT read's genuine failure would absorb it
        // and skip tripping the breaker — Runway would keep calling securityd exactly when it
        // should back off, which inverts the guarantee this whole class exists for.
        let coordinator = KeychainReadCoordinator(inFlightWait: 0.05)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let staleDone = expectation(description: "stale contended read finished")

        // A: turned away by the UI gate, and slow enough that B stores first.
        let stale = Thread {
            _ = coordinator.nonInteractiveRead(
                service: "svc", account: nil, fingerprint: { "fp-1" },
                read: { ticket in
                    started.signal()
                    release.wait()
                    // Turned away by the UI gate only now — AFTER the newer read already stored,
                    // so nothing else consumes this marker before the stale store is discarded.
                    coordinator.recordContention(ticket)
                    return .unavailable
                }
            )
            staleDone.fulfill()
        }
        stale.start()
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)

        // B bypasses the stuck flight and recovers the item, so A's outcome is discarded.
        _ = try? coordinator.interactiveRead(
            service: "svc", account: nil, fingerprint: { "fp-1" },
            read: { _ in "approved-secret" }
        )
        release.signal()
        wait(for: [staleDone], timeout: 2)

        // A genuine denial now must trip the breaker: the next background read is answered locally.
        // Both of these run on the test thread, so a plain counter is enough.
        var reads = 0
        _ = coordinator.nonInteractiveRead(
            service: "svc", account: nil, fingerprint: { "fp-2" },
            read: { _ in reads += 1; return .unavailable }
        )
        _ = coordinator.nonInteractiveRead(
            service: "svc", account: nil, fingerprint: { "fp-3" },
            read: { _ in reads += 1; return .unavailable }
        )
        XCTAssertEqual(reads, 1, "the second read must be answered by the breaker, not sent to Security")
    }

    func testOneReadsContentionCannotExcuseAnotherReadsGenuineFailure() {
        // The inverse of the stale-marker case. A is turned away by the UI gate; B overlaps it and
        // hits a REAL Security failure. If the marker is item-wide, B consumes A's and its own
        // genuine failure is excused — so the breaker never trips and the next refresh calls
        // securityd again. Contention is evidence about a READ, not about the item.
        let coordinator = KeychainReadCoordinator(inFlightWait: 0.05)
        let aStarted = DispatchSemaphore(value: 0)
        let releaseA = DispatchSemaphore(value: 0)
        let aDone = expectation(description: "contended read finished")

        let readerA = Thread {
            _ = coordinator.nonInteractiveRead(
                service: "svc", account: nil, fingerprint: { "fp-1" },
                read: { ticket in
                    coordinator.recordContention(ticket)
                    aStarted.signal()
                    releaseA.wait()
                    return .unavailable
                }
            )
            aDone.fulfill()
        }
        readerA.start()
        XCTAssertEqual(aStarted.wait(timeout: .now() + 2), .success)

        // B bypasses A's stuck flight and fails for real — a denial, not contention.
        _ = try? coordinator.interactiveRead(
            service: "svc", account: nil, fingerprint: { "fp-1" },
            read: { _ in throw KeychainError.readFailed("denied") }
        )
        releaseA.signal()
        wait(for: [aDone], timeout: 2)

        // B's denial must have tripped the item: no further Security call until revalidation.
        var reads = 0
        let after = coordinator.nonInteractiveRead(
            service: "svc", account: nil, fingerprint: { "fp-2" },
            read: { _ in reads += 1; return .unavailable }
        )
        XCTAssertEqual(after, .unavailable)
        XCTAssertEqual(reads, 0, "a genuine failure must trip the breaker even alongside a contended read")
    }

    /// The Safe Storage readers go through `externalRead`, which used to trip on every thrown
    /// error — including the one the UI gate synthesizes when it turns a read away.
    func testContentionDoesNotTripTheBreakerOnTheExternalPath() {
        let coordinator = KeychainReadCoordinator()
        struct Unreadable: Error {}
        var reads = 0

        XCTAssertThrowsError(
            try coordinator.externalRead(
                service: "svc", account: nil, interactive: false,
                unavailable: { _ in Unreadable() },
                read: { ticket in
                    coordinator.recordContention(ticket)
                    reads += 1
                    throw Unreadable()
                }
            )
        )

        let recovered = try? coordinator.externalRead(
            service: "svc", account: nil, interactive: false,
            unavailable: { _ in Unreadable() },
            read: { _ in reads += 1; return "safe-storage-key" }
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
                unavailable: { $0 == .permissionDenied ? Failure.denied : Failure.unreadable },
                read: { ticket in
                    coordinator.recordFailureCategory(ticket, category: .permissionDenied)
                    throw Failure.denied
                }
            )
        )

        // The breaker answers this one locally; it must still say "denied".
        XCTAssertThrowsError(
            try coordinator.externalRead(
                service: "svc", account: nil, interactive: false,
                unavailable: { $0 == .permissionDenied ? Failure.denied : Failure.unreadable },
                read: { _ in XCTFail("the breaker must answer without calling Security"); return "" }
            )
        ) { XCTAssertEqual($0 as? Failure, .denied) }
    }
}
