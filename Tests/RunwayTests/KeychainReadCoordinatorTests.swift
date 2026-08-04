import XCTest
@testable import Runway

final class KeychainReadCoordinatorTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func withLock<T>(_ body: (inout Value) -> T) -> T {
            lock.withLock { body(&value) }
        }
    }

    func testUnchangedFingerprintServesCachedValueWithoutASecondRead() {
        let coordinator = KeychainReadCoordinator()
        let reads = Counter()
        func read() -> NonInteractiveKeychainRead {
            reads.increment()
            return .value("secret")
        }

        let first = coordinator.nonInteractiveRead(
            service: "svc", account: nil, fingerprint: { "fp-1" }, read: read
        )
        let second = coordinator.nonInteractiveRead(
            service: "svc", account: nil, fingerprint: { "fp-1" }, read: read
        )

        XCTAssertEqual(first, .value("secret"))
        XCTAssertEqual(second, .value("secret"))
        XCTAssertEqual(reads.value, 1, "an unchanged item must be served from the cache")
    }

    func testChangedFingerprintTriggersAFreshRead() {
        let coordinator = KeychainReadCoordinator()
        let reads = Counter()

        _ = coordinator.nonInteractiveRead(
            service: "svc", account: nil, fingerprint: { "fp-1" },
            read: { reads.increment(); return .value("old") }
        )
        let updated = coordinator.nonInteractiveRead(
            service: "svc", account: nil, fingerprint: { "fp-2" },
            read: { reads.increment(); return .value("new") }
        )

        XCTAssertEqual(updated, .value("new"))
        XCTAssertEqual(reads.value, 2)
    }

    func testMissingFingerprintNeverCaches() {
        // A nil fingerprint cannot distinguish "item absent" from "probe failed", so nothing may be
        // keyed to it — every read goes through.
        let coordinator = KeychainReadCoordinator()
        let reads = Counter()
        func read() -> NonInteractiveKeychainRead {
            reads.increment()
            return .missing
        }

        _ = coordinator.nonInteractiveRead(service: "svc", account: nil, fingerprint: { nil }, read: read)
        _ = coordinator.nonInteractiveRead(service: "svc", account: nil, fingerprint: { nil }, read: read)

        XCTAssertEqual(reads.value, 2)
    }

    func testDeniedReadTripsTheBreakerUntilRevalidationOrUserAction() {
        // A tripped entry answers locally with NO Keychain traffic at all — not even the attribute
        // probe, which blocks like any other call against a wedged securityd. Change-detection for
        // tripped items therefore happens on the revalidation cadence (or a manual refresh).
        let clock = Locked(Date(timeIntervalSince1970: 1_000_000))
        let coordinator = KeychainReadCoordinator(revalidateAfter: 60, now: { clock.withLock { $0 } })
        let reads = Counter()

        let denied = coordinator.nonInteractiveRead(
            service: "svc", account: nil, fingerprint: { "fp-1" },
            read: { reads.increment(); return .unavailable }
        )
        // Within the interval: answered locally; neither the probe nor the read runs.
        let heldBack = coordinator.nonInteractiveRead(
            service: "svc", account: nil,
            fingerprint: { XCTFail("a tripped entry must not probe the Keychain"); return "fp-2" },
            read: { reads.increment(); return .value("never") }
        )
        // Past the interval: the breaker re-checks for real (and finds the re-login).
        clock.withLock { $0 = $0.addingTimeInterval(61) }
        let retried = coordinator.nonInteractiveRead(
            service: "svc", account: nil, fingerprint: { "fp-2" },
            read: { reads.increment(); return .value("fresh") }
        )

        XCTAssertEqual(denied, .unavailable)
        XCTAssertEqual(heldBack, .unavailable)
        XCTAssertEqual(retried, .value("fresh"))
        XCTAssertEqual(reads.value, 2)
    }

    func testTrippedItemSuppressesMetadataProbesToo() {
        // Existence/fingerprint probes are Security calls as well: after a read fails, they must not
        // keep querying the same wedged securityd. `nil` ("unknown") is the honest answer, and every
        // caller already takes its safe side on it.
        let clock = Locked(Date(timeIntervalSince1970: 1_000_000))
        let coordinator = KeychainReadCoordinator(revalidateAfter: 60, now: { clock.withLock { $0 } })

        _ = coordinator.nonInteractiveRead(
            service: "svc", account: nil, fingerprint: { "fp-1" },
            read: { .unavailable }
        )

        let suppressed: Bool? = coordinator.probe(service: "svc", account: nil) {
            XCTFail("a tripped item must not issue a metadata query")
            return true
        }
        XCTAssertNil(suppressed)

        // Past revalidation the item is checked for real again.
        clock.withLock { $0 = $0.addingTimeInterval(61) }
        XCTAssertEqual(coordinator.probe(service: "svc", account: nil) { true }, true)
    }

    func testTimeoutBehindAStuckFlightServesAFreshRecoveredManualResult() {
        // A manual read can recover while the wedged background read never returns. Later background
        // callers give up on the stuck flight within the bounded wait — but must serve the fresh
        // manual result instead of reporting the credentials unavailable.
        let coordinator = KeychainReadCoordinator(inFlightWait: 0.05)
        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = DispatchSemaphore(value: 0)

        let stuck = Thread {
            _ = coordinator.nonInteractiveRead(
                service: "svc", account: nil, fingerprint: { "fp-1" },
                read: {
                    readStarted.signal()
                    releaseRead.wait()
                    return .unavailable
                }
            )
        }
        stuck.start()
        XCTAssertEqual(readStarted.wait(timeout: .now() + 2), .success)

        let manual = try? coordinator.interactiveRead(
            service: "svc", account: nil, fingerprint: { "fp-1" },
            read: { "approved-secret" }
        )
        XCTAssertEqual(manual, "approved-secret")

        // The background flight is still stuck; a new background caller times out — and gets the
        // recovered value, not `.unavailable`.
        let background = coordinator.nonInteractiveRead(
            service: "svc", account: nil,
            fingerprint: { XCTFail("must not probe while the flight is stuck"); return nil },
            read: { XCTFail("must not read while the flight is stuck"); return .unavailable }
        )
        releaseRead.signal()

        XCTAssertEqual(background, .value("approved-secret"))
    }

    func testInteractiveSuccessSeedsTheCacheAndClearsTheBreaker() throws {
        let coordinator = KeychainReadCoordinator()
        let reads = Counter()

        // Background read is denied and trips the breaker.
        _ = coordinator.nonInteractiveRead(
            service: "svc", account: nil, fingerprint: { "fp-1" },
            read: { .unavailable }
        )
        // The user refreshes manually and approves the prompt.
        let approved = try coordinator.interactiveRead(
            service: "svc", account: nil, fingerprint: { "fp-1" },
            read: { "secret" }
        )
        // Later background reads are served from the cache without touching securityd.
        let background = coordinator.nonInteractiveRead(
            service: "svc", account: nil, fingerprint: { "fp-1" },
            read: { reads.increment(); return .unavailable }
        )

        XCTAssertEqual(approved, "secret")
        XCTAssertEqual(background, .value("secret"))
        XCTAssertEqual(reads.value, 0)
    }

    func testInteractiveDenialTripsTheBreakerForBackgroundReads() {
        let coordinator = KeychainReadCoordinator()
        let reads = Counter()

        XCTAssertThrowsError(try coordinator.interactiveRead(
            service: "svc", account: nil, fingerprint: { "fp-1" },
            read: { throw KeychainError.readFailed("denied") }
        ))
        let background = coordinator.nonInteractiveRead(
            service: "svc", account: nil, fingerprint: { "fp-1" },
            read: { reads.increment(); return .unavailable }
        )

        XCTAssertEqual(background, .unavailable)
        XCTAssertEqual(reads.value, 0, "a denied manual read must stop background retries until the item changes")
    }

    func testLateArriverSkipsEvenTheFingerprintProbeWhileAReadIsStuck() {
        // The fingerprint probe is a Keychain call too: against a wedged securityd it blocks like
        // any other. A caller that gives up on someone else's stuck read must not have touched the
        // Keychain at all — no probe, no read.
        let coordinator = KeychainReadCoordinator(inFlightWait: 0.05)
        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = DispatchSemaphore(value: 0)
        let probes = Counter()

        let readerA = Thread {
            _ = coordinator.nonInteractiveRead(
                service: "svc", account: nil, fingerprint: { probes.increment(); return "fp-1" },
                read: {
                    readStarted.signal()
                    releaseRead.wait()
                    return .value("secret")
                }
            )
        }
        readerA.start()
        XCTAssertEqual(readStarted.wait(timeout: .now() + 2), .success)

        let blocked = coordinator.nonInteractiveRead(
            service: "svc", account: nil,
            fingerprint: { probes.increment(); return "fp-1" },
            read: { XCTFail("must not read"); return .value("never") }
        )
        releaseRead.signal()

        XCTAssertEqual(blocked, .unavailable)
        XCTAssertEqual(probes.value, 1, "only reader A may probe; the late arriver stays off the Keychain")
    }

    func testMetadataProbeDoesNotStackBehindAStuckReadOfTheSameItem() {
        // Existence/fingerprint probes are prompt-free but still securityd round trips: against a
        // wedge they block like anything else. A probe of an item whose read is stuck must give up
        // within the bounded wait — without running its query — and report nil ("unknown").
        let coordinator = KeychainReadCoordinator(inFlightWait: 0.05)
        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = DispatchSemaphore(value: 0)

        let readerA = Thread {
            _ = coordinator.nonInteractiveRead(
                service: "svc", account: nil, fingerprint: { "fp-1" },
                read: {
                    readStarted.signal()
                    releaseRead.wait()
                    return .value("secret")
                }
            )
        }
        readerA.start()
        XCTAssertEqual(readStarted.wait(timeout: .now() + 2), .success)

        let blocked: Bool? = coordinator.probe(service: "svc", account: nil) {
            XCTFail("the probe body must not run while the item's read is stuck")
            return true
        }
        releaseRead.signal()

        XCTAssertNil(blocked)
        // Once the flight clears, probes run normally.
        let deadline = Date().addingTimeInterval(2)
        var after: Bool?
        while after == nil, Date() < deadline {
            after = coordinator.probe(service: "svc", account: nil) { true }
        }
        XCTAssertEqual(after, true)
    }

    func testCachedValueIsRevalidatedAfterTheStalenessBound() {
        // The Keychain modification date has one-second resolution, so a secret-only rotation in the
        // same second leaves the fingerprint unchanged. The revalidation interval bounds how long
        // such a collision can serve a stale secret.
        let clock = Locked(Date(timeIntervalSince1970: 1_000_000))
        let coordinator = KeychainReadCoordinator(
            revalidateAfter: 60,
            now: { clock.withLock { $0 } }
        )
        let reads = Counter()

        _ = coordinator.nonInteractiveRead(
            service: "svc", account: nil, fingerprint: { "fp-1" },
            read: { reads.increment(); return .value("old") }
        )
        // Within the interval and unchanged: cache hit.
        clock.withLock { $0 = $0.addingTimeInterval(30) }
        XCTAssertEqual(
            coordinator.nonInteractiveRead(
                service: "svc", account: nil, fingerprint: { "fp-1" },
                read: { reads.increment(); return .value("collided") }
            ),
            .value("old")
        )
        // Past the interval: same fingerprint, but the secret is re-read.
        clock.withLock { $0 = $0.addingTimeInterval(31) }
        XCTAssertEqual(
            coordinator.nonInteractiveRead(
                service: "svc", account: nil, fingerprint: { "fp-1" },
                read: { reads.increment(); return .value("collided") }
            ),
            .value("collided")
        )
        XCTAssertEqual(reads.value, 2)
    }

    func testManualReadProceedsPastAStuckBackgroundReadAndItsResultIsNotClobbered() {
        // Manual refresh is the documented recovery path; it must not hang behind the very wedge the
        // coordinator exists to contain. Past the bounded wait it performs its own read — and when
        // the wedged background read finally finishes, its stale outcome must not overwrite the
        // fresher manual result.
        let coordinator = KeychainReadCoordinator(inFlightWait: 0.05)
        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = DispatchSemaphore(value: 0)
        let backgroundDone = expectation(description: "background read completed")

        let background = Thread {
            _ = coordinator.nonInteractiveRead(
                service: "svc", account: nil, fingerprint: { "fp-1" },
                read: {
                    readStarted.signal()
                    releaseRead.wait()
                    return .unavailable
                }
            )
            backgroundDone.fulfill()
        }
        background.start()
        XCTAssertEqual(readStarted.wait(timeout: .now() + 2), .success)

        let manual = try? coordinator.interactiveRead(
            service: "svc", account: nil, fingerprint: { "fp-1" },
            read: { "approved-secret" }
        )
        XCTAssertEqual(manual, "approved-secret")

        releaseRead.signal()
        wait(for: [backgroundDone], timeout: 2)

        // The stale read finally returned `.unavailable`. It must not have clobbered the recovered
        // entry into a tripped one — otherwise this next background read would be suppressed
        // locally instead of running. (It re-reads rather than serving cache because the manual
        // path deliberately skipped its fingerprint probe while the flight was stuck.)
        let reads = Counter()
        let afterwards = coordinator.nonInteractiveRead(
            service: "svc", account: nil, fingerprint: { "fp-1" },
            read: { reads.increment(); return .value("approved-secret") }
        )
        XCTAssertEqual(afterwards, .value("approved-secret"))
        XCTAssertEqual(reads.value, 1, "a stale result must not leave the item tripped")
    }

    func testConcurrentReadersShareOneReadAndLateArriversDoNotPileOn() {
        // Reader A holds the underlying read open. Reader B (same item) must give up after the
        // bounded wait instead of stacking a second call onto a wedged securityd; once A finishes,
        // reader C is served from the cache.
        let coordinator = KeychainReadCoordinator(inFlightWait: 0.05)
        let reads = Counter()
        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = DispatchSemaphore(value: 0)

        let readerA = Thread {
            _ = coordinator.nonInteractiveRead(
                service: "svc", account: nil, fingerprint: { "fp-1" },
                read: {
                    reads.increment()
                    readStarted.signal()
                    releaseRead.wait()
                    return .value("secret")
                }
            )
        }
        readerA.start()
        XCTAssertEqual(readStarted.wait(timeout: .now() + 2), .success)

        // B arrives while A's read is stuck: bounded wait, then a local "unavailable".
        let blocked = coordinator.nonInteractiveRead(
            service: "svc", account: nil, fingerprint: { "fp-1" },
            read: { reads.increment(); return .value("never") }
        )
        XCTAssertEqual(blocked, .unavailable)

        releaseRead.signal()
        // Give A a moment to publish its result, then C reads from the cache.
        let deadline = Date().addingTimeInterval(2)
        var cached: NonInteractiveKeychainRead = .unavailable
        while Date() < deadline {
            cached = coordinator.nonInteractiveRead(
                service: "svc", account: nil, fingerprint: { "fp-1" },
                read: { reads.increment(); return .value("secret") }
            )
            if cached == .value("secret") { break }
        }
        XCTAssertEqual(cached, .value("secret"))
        XCTAssertEqual(reads.value, 1, "only reader A's underlying read may run")
    }
}

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
