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

    func testDeniedReadTripsTheBreakerUntilTheFingerprintChanges() {
        let coordinator = KeychainReadCoordinator()
        let reads = Counter()

        let denied = coordinator.nonInteractiveRead(
            service: "svc", account: nil, fingerprint: { "fp-1" },
            read: { reads.increment(); return .unavailable }
        )
        // Same fingerprint: answered locally, securityd is not contacted again.
        let heldBack = coordinator.nonInteractiveRead(
            service: "svc", account: nil, fingerprint: { "fp-1" },
            read: { reads.increment(); return .value("never") }
        )
        // The item changed (e.g. an external `claude` re-login): the breaker resets and a real read runs.
        let retried = coordinator.nonInteractiveRead(
            service: "svc", account: nil, fingerprint: { "fp-2" },
            read: { reads.increment(); return .value("fresh") }
        )

        XCTAssertEqual(denied, .unavailable)
        XCTAssertEqual(heldBack, .unavailable)
        XCTAssertEqual(retried, .value("fresh"))
        XCTAssertEqual(reads.value, 2)
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
        let afterwards = coordinator.nonInteractiveRead(
            service: "svc", account: nil, fingerprint: { "fp-1" },
            read: { .unavailable }
        )
        XCTAssertEqual(afterwards, .value("approved-secret"))
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
