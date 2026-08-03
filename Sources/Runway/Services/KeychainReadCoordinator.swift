import Foundation

/// Process-wide gate for the in-process reads of ACL-protected Keychain items (Claude Code's
/// credentials and any other foreign item read through `SecurityKeychainAccessor`). It exists to keep
/// Runway's Keychain traffic minimal and bounded when `securityd` is slow, wedged, or showing an
/// approval dialog (the 2026-08-03 incident):
///
/// - **Change-gated reads.** The item's non-secret attribute fingerprint (which includes its
///   modification date) is probed first — an in-process, prompt-free query that returns in
///   microseconds. The secret is only read when that fingerprint differs from the last successful
///   read, so a 5-minute refresh cadence performs one ACL-checked secret read per actual credential
///   rotation instead of one per cycle.
/// - **Single-flight.** Concurrent readers of the same service/account (multiple Claude cards, the
///   default-account observer) share one underlying read. A non-interactive caller never waits more
///   than `inFlightWait` on someone else's read — beyond that it reports `.unavailable` rather than
///   stacking blocked calls onto a wedged `securityd`.
/// - **Circuit breaker.** After a failed or denied read, non-interactive reads of that item are
///   answered `.unavailable` locally — no Keychain traffic — until the item's fingerprint changes or
///   an explicit interactive (manual-refresh) read succeeds.
///
/// Cached secrets live only in this process's memory, exactly like the credential states the
/// providers already hold between refreshes.
final class KeychainReadCoordinator: @unchecked Sendable {
    static let shared = KeychainReadCoordinator()

    private struct Key: Hashable {
        var service: String
        var account: String?
    }

    private struct Entry {
        /// Fingerprint the cached outcome belongs to. Never nil — outcomes without a fingerprint
        /// are not cached at all (an absent fingerprint cannot distinguish "item missing" from
        /// "probe failed", so nothing can be safely keyed to it).
        var fingerprint: String
        /// Last successful read, served while the fingerprint is unchanged.
        var value: NonInteractiveKeychainRead?
        /// Tripped by a failed/denied read; answers `.unavailable` without touching the Keychain
        /// until the fingerprint changes or an interactive read succeeds.
        var tripped: Bool
    }

    private let condition = NSCondition()
    private var entries: [Key: Entry] = [:]
    private var inFlight: Set<Key> = []
    private let inFlightWait: TimeInterval

    init(inFlightWait: TimeInterval = 2) {
        self.inFlightWait = inFlightWait
    }

    /// Background read: serve the cache when the item is unchanged, honor the breaker, otherwise
    /// perform `read` (single-flight per item).
    func nonInteractiveRead(
        service: String,
        account: String?,
        fingerprint: () -> String?,
        read: () -> NonInteractiveKeychainRead
    ) -> NonInteractiveKeychainRead {
        let key = Key(service: service, account: account)
        let fingerprint = fingerprint()

        condition.lock()
        let deadline = Date().addingTimeInterval(inFlightWait)
        while inFlight.contains(key), Date() < deadline {
            condition.wait(until: deadline)
        }
        if inFlight.contains(key) {
            // Someone else's read of this item has been stuck past the deadline (an open approval
            // dialog or a wedged securityd). Report unavailable instead of piling on.
            condition.unlock()
            return .unavailable
        }
        if let fingerprint, let entry = entries[key], entry.fingerprint == fingerprint {
            if entry.tripped {
                condition.unlock()
                return .unavailable
            }
            if let value = entry.value {
                condition.unlock()
                return value
            }
        }
        inFlight.insert(key)
        condition.unlock()

        let result = read()

        condition.lock()
        if let fingerprint {
            entries[key] = Entry(
                fingerprint: fingerprint,
                value: result == .unavailable ? nil : result,
                tripped: result == .unavailable
            )
        } else {
            entries[key] = nil
        }
        inFlight.remove(key)
        condition.broadcast()
        condition.unlock()
        return result
    }

    /// Explicit user-action read: always performs `read` (it may legitimately prompt), then updates
    /// the cache. Success clears the breaker; a thrown denial trips it so background refreshes stop
    /// re-asking securityd until the item changes or the user acts again.
    func interactiveRead(
        service: String,
        account: String?,
        fingerprint: () -> String?,
        read: () throws -> String?
    ) throws -> String? {
        let key = Key(service: service, account: account)
        let fingerprint = fingerprint()

        condition.lock()
        while inFlight.contains(key) {
            condition.wait()
        }
        inFlight.insert(key)
        condition.unlock()

        defer {
            condition.lock()
            inFlight.remove(key)
            condition.broadcast()
            condition.unlock()
        }

        do {
            let value = try read()
            condition.lock()
            if let fingerprint {
                entries[key] = Entry(
                    fingerprint: fingerprint,
                    value: value.map(NonInteractiveKeychainRead.value) ?? .missing,
                    tripped: false
                )
            } else {
                entries[key] = nil
            }
            condition.unlock()
            return value
        } catch {
            condition.lock()
            if let fingerprint {
                entries[key] = Entry(fingerprint: fingerprint, value: nil, tripped: true)
            } else {
                entries[key] = nil
            }
            condition.unlock()
            throw error
        }
    }
}
