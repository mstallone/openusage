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
///   rotation instead of one per cycle. Because the modification date has one-second resolution, a
///   secret-only update landing in the same second could leave the fingerprint unchanged — so every
///   cached outcome is revalidated with a real read after `revalidateAfter`, bounding any staleness.
/// - **Single-flight.** Concurrent readers of the same service/account (multiple Claude cards, the
///   default-account observer) share one underlying read. A caller never waits more than
///   `inFlightWait` on someone else's read: a background caller then reports `.unavailable` rather
///   than stacking blocked calls onto a wedged `securityd`, and an interactive caller proceeds with
///   its own read — the user explicitly asked, and manual recovery must not hang behind the very
///   wedge it exists to clear.
/// - **Circuit breaker.** After a failed or denied read, non-interactive reads of that item are
///   answered `.unavailable` locally — no Keychain traffic — until the item's fingerprint changes,
///   the revalidation interval elapses, or an explicit interactive (manual-refresh) read succeeds.
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
        /// Fingerprint the cached outcome belongs to. `nil` (the probe failed or was skipped, e.g.
        /// an interactive read that proceeded past a stuck flight) never matches the change-gated
        /// cache path — a nil-fingerprint value is served ONLY by the stale-flight fallback, and
        /// only while fresh.
        var fingerprint: String?
        /// Last successful read, served while the fingerprint is unchanged and the entry is fresh.
        var value: NonInteractiveKeychainRead?
        /// Tripped by a failed/denied read; answers `.unavailable` without touching the Keychain
        /// until revalidation is due or an interactive read succeeds.
        var tripped: Bool
        var updatedAt: Date
    }

    private let condition = NSCondition()
    private var entries: [Key: Entry] = [:]
    /// Bumped on every store. A background reader that ran overlapped with a newer write (e.g. a
    /// wedged read finishing after a successful manual read) must not clobber the fresher entry.
    private var epochs: [Key: Int] = [:]
    private var inFlight: Set<Key> = []
    private let inFlightWait: TimeInterval
    private let revalidateAfter: TimeInterval
    private let now: @Sendable () -> Date

    init(
        inFlightWait: TimeInterval = 2,
        revalidateAfter: TimeInterval = 15 * 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.inFlightWait = inFlightWait
        self.revalidateAfter = revalidateAfter
        self.now = now
    }

    /// Background read: serve the cache when the item is unchanged and fresh, honor the breaker,
    /// otherwise perform `read`. The WHOLE operation — fingerprint probe included — is one flight
    /// per item: attribute queries are normally instant, but a wedged `securityd` blocks them like
    /// any other call, so concurrent callers must not stack up inside the probe either.
    func nonInteractiveRead(
        service: String,
        account: String?,
        fingerprint: () -> String?,
        read: () -> NonInteractiveKeychainRead
    ) -> NonInteractiveKeychainRead {
        let key = Key(service: service, account: account)

        condition.lock()
        guard waitWhileInFlight(key, deadline: now().addingTimeInterval(inFlightWait)) else {
            // Someone else's read of this item has been stuck past the deadline (an open approval
            // dialog or a wedged securityd). Serve a fresh recovered value when one exists (a
            // manual read can succeed while the stale flight never returns), else report
            // unavailable — logged, because the wedged call may never produce its own diagnostic.
            let entry = entries[key]
            condition.unlock()
            if let entry, !entry.tripped, let value = entry.value,
               now().timeIntervalSince(entry.updatedAt) < revalidateAfter {
                return value
            }
            AppLog.warn(.keychain, "keychain read timed out behind a stuck operation for one item; reporting unavailable")
            return .unavailable
        }
        // Breaker short-circuit BEFORE any Keychain traffic: a freshly tripped entry answers
        // locally — not even the attribute probe runs — until revalidation is due or the user acts.
        // Change-detection for tripped items therefore happens on the revalidation cadence.
        if let entry = entries[key], entry.tripped,
           now().timeIntervalSince(entry.updatedAt) < revalidateAfter {
            condition.unlock()
            return .unavailable
        }
        inFlight.insert(key)
        let epoch = epochs[key, default: 0]
        condition.unlock()

        defer {
            condition.lock()
            inFlight.remove(key)
            condition.broadcast()
            condition.unlock()
        }

        let fingerprint = fingerprint()

        condition.lock()
        if let fingerprint,
           let entry = entries[key],
           entry.fingerprint == fingerprint,
           now().timeIntervalSince(entry.updatedAt) < revalidateAfter
        {
            if entry.tripped {
                condition.unlock()
                return .unavailable
            }
            if let value = entry.value {
                condition.unlock()
                return value
            }
        }
        condition.unlock()

        let result = read()

        condition.lock()
        if epochs[key, default: 0] == epoch {
            store(key: key, fingerprint: fingerprint, value: result == .unavailable ? nil : result, tripped: result == .unavailable)
        }
        condition.unlock()
        return result
    }

    /// Explicit user-action read: always performs `read` (it may legitimately prompt), then updates
    /// the cache. Success clears the breaker; a thrown denial trips it so background refreshes stop
    /// re-asking securityd until the item changes or the user acts again. The wait on a concurrent
    /// read is bounded: past it, this read proceeds anyway — manual recovery must not hang behind a
    /// wedged background read.
    func interactiveRead(
        service: String,
        account: String?,
        fingerprint: () -> String?,
        read: () throws -> String?
    ) throws -> String? {
        let key = Key(service: service, account: account)

        condition.lock()
        let acquired = waitWhileInFlight(key, deadline: now().addingTimeInterval(inFlightWait))
        if acquired {
            inFlight.insert(key)
        }
        condition.unlock()

        defer {
            if acquired {
                condition.lock()
                inFlight.remove(key)
                condition.broadcast()
                condition.unlock()
            }
        }

        // Inside the flight, like the read itself — see `nonInteractiveRead`. When the flight was
        // NOT acquired (a stuck background read), the probe is skipped ENTIRELY: it is one more
        // Security call that can wedge, and `securityd` answering the read is no guarantee the next
        // query returns. The outcome is then stored without a fingerprint — only the stale-flight
        // fallback serves those, and the next clean background read re-reads for real.
        let fingerprint = acquired ? fingerprint() : nil

        do {
            let value = try read()
            condition.lock()
            store(key: key, fingerprint: fingerprint, value: value.map(NonInteractiveKeychainRead.value) ?? .missing, tripped: false)
            condition.unlock()
            return value
        } catch {
            condition.lock()
            store(key: key, fingerprint: fingerprint, value: nil, tripped: true)
            condition.unlock()
            throw error
        }
    }

    /// Bounded, single-flighted metadata query (existence or fingerprint probes). Such probes are
    /// prompt-free by construction, but they are still securityd round trips — against a wedged
    /// securityd they block like any other call, so they must not stack behind a stuck read of the
    /// same item. Returns nil ("unknown") when the item's flight is stuck past the bounded wait.
    ///
    /// Only the PUBLIC probe entry points route through here. The fingerprint the coordinator's own
    /// read path computes runs inside its already-held flight and must stay raw — routing it back
    /// through this method would wait on the very flight it holds.
    func probe<T>(service: String, account: String?, _ body: () -> T?) -> T? {
        let key = Key(service: service, account: account)

        condition.lock()
        guard waitWhileInFlight(key, deadline: now().addingTimeInterval(inFlightWait)) else {
            condition.unlock()
            return nil
        }
        // The breaker covers metadata queries as well: an item whose read just failed must not keep
        // issuing `SecItemCopyMatching` into the same wedged securityd. `nil` ("unknown") is the
        // honest answer, and callers already take their safe side on it.
        if let entry = entries[key], entry.tripped,
           now().timeIntervalSince(entry.updatedAt) < revalidateAfter {
            condition.unlock()
            return nil
        }
        inFlight.insert(key)
        condition.unlock()

        defer {
            condition.lock()
            inFlight.remove(key)
            condition.broadcast()
            condition.unlock()
        }

        return body()
    }

    /// Waits (under `condition`'s lock) while `key` has a read in flight. Returns `false` if the
    /// deadline passed with the read still stuck.
    private func waitWhileInFlight(_ key: Key, deadline: Date) -> Bool {
        while inFlight.contains(key), now() < deadline {
            condition.wait(until: deadline)
        }
        return !inFlight.contains(key)
    }

    /// Must be called under `condition`'s lock.
    private func store(key: Key, fingerprint: String?, value: NonInteractiveKeychainRead?, tripped: Bool) {
        epochs[key, default: 0] += 1
        entries[key] = Entry(fingerprint: fingerprint, value: value, tripped: tripped, updatedAt: now())
    }
}
