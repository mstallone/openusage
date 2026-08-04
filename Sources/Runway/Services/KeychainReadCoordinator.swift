import Foundation

/// Process-wide gate for the in-process reads of ACL-protected Keychain items belonging to other
/// apps: everything read through `SecurityKeychainAccessor`, plus the Safe Storage keys Claude
/// Desktop and Sakana decode themselves (via `externalRead`). Runway's own item
/// (`RunwayOwnedKeychainStore`) deliberately stays outside — its ACL names Runway, so it never
/// prompts and never contends for approval. It exists to keep
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

    /// Identifies one in-flight read. Passed to the read closure so anything it observes —
    /// UI-gate contention, the failing `OSStatus` — is attributed to that read and travels with
    /// its sequenced outcome, instead of being left in an item-wide side channel that a concurrent
    /// read could consume.
    struct ReadTicket {
        fileprivate let sequence: Int
    }

    private struct Entry {
        /// Fingerprint the cached outcome belongs to. `nil` (the probe failed or was skipped) never
        /// matches the change-gated cache path.
        var fingerprint: String?
        /// Whether an explicit user action produced this value. Only such an entry may answer a
        /// caller that timed out behind a stuck flight: that stuck read may be fetching a rotation
        /// of this very secret, and a background value — which can also carry a nil fingerprint
        /// when its probe failed — gives no reason to believe it is still current.
        var fromUserAction: Bool = false
        /// Last successful read, served while the fingerprint is unchanged and the entry is fresh.
        var value: NonInteractiveKeychainRead?
        /// Tripped by a failed/denied read; answers `.unavailable` without touching the Keychain
        /// until revalidation is due or an interactive read succeeds.
        var tripped: Bool
        var updatedAt: Date
    }

    private let condition = NSCondition()
    private var entries: [Key: Entry] = [:]
    /// Hands every read a start ticket, so a store can be ordered by when its read BEGAN rather
    /// than when it finished. Two overlapping reads would otherwise be indistinguishable, and the
    /// first to finish would win even when it is the older, staler one.
    private var nextSequence = 0
    /// The start ticket of the read whose outcome each item currently holds. A store from an older
    /// read is dropped: a wedged read finishing after a newer one already recovered the item must
    /// not clobber the fresher entry.
    private var storedSequences: [Key: Int] = [:]
    private var inFlight: Set<Key> = []
    /// Why an item's last read failed: `true` = its ACL has not approved this app, `false` = the
    /// keychain itself could not be read. Captured from the read's own `OSStatus`, because a second
    /// attributes probe cannot recover it — the breaker answers those locally once tripped.
    private var lastFailureDenied: [Key: Bool] = [:]
    /// Reads that never reached securityd because the process-wide UI gate was unavailable (for
    /// example, a stuck suppression scope or a refresh cancelled while queued). Keyed by READ, not
    /// by item: two reads of the same item overlap routinely, and one read's contention must never
    /// excuse another read's genuine failure.
    private var contendedSequences: Set<Int> = []
    /// Failure categories reported by a read that has not stored its outcome yet, keyed the same
    /// way and for the same reason — a category belongs to the read that observed the status.
    private var pendingCategories: [Int: Bool] = [:]
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
        read: (ReadTicket) -> NonInteractiveKeychainRead
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
            // ONLY a value an explicit user action produced. Any background value was cached
            // against the item as it was BEFORE the stuck read began, and that read may be fetching
            // a rotation of exactly this secret — serving the cached one would authenticate with a
            // superseded token.
            if let entry, !entry.tripped, entry.fromUserAction, let value = entry.value,
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
        let sequence = takeSequence()
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

        let result = read(ReadTicket(sequence: sequence))

        condition.lock()
        storeIfCurrent(
            key: key,
            sequence: sequence,
            fingerprint: fingerprint,
            value: result == .unavailable ? nil : result,
            tripped: result == .unavailable
        )
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
        read: (ReadTicket) throws -> String?
    ) throws -> String? {
        let key = Key(service: service, account: account)

        condition.lock()
        let acquired = waitWhileInFlight(key, deadline: now().addingTimeInterval(inFlightWait))
        if acquired {
            inFlight.insert(key)
        }
        let sequence = takeSequence()
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
            let value = try read(ReadTicket(sequence: sequence))
            condition.lock()
            storeIfCurrent(
                key: key,
                sequence: sequence,
                fingerprint: fingerprint,
                fromUserAction: true,
                value: value.map(NonInteractiveKeychainRead.value) ?? .missing,
                tripped: false
            )
            condition.unlock()
            return value
        } catch {
            condition.lock()
            storeIfCurrent(key: key, sequence: sequence, fingerprint: fingerprint, value: nil, tripped: true)
            condition.unlock()
            throw error
        }
    }

    /// Single-flight + breaker for a bespoke in-process secret read that does not speak
    /// `NonInteractiveKeychainRead` — the Safe Storage keys Claude Desktop and Sakana decode
    /// themselves. Those items are read directly through `SecItemCopyMatching`, so without this they
    /// would keep starting fresh Security calls behind a wedged predecessor and would never trip a
    /// breaker after a denial.
    ///
    /// Non-interactive callers that cannot take the flight (or whose item is freshly tripped) get
    /// `unavailable()` thrown without touching Security.framework. Interactive callers proceed past
    /// a stuck flight — manual recovery must not hang — and a success clears the breaker.
    func externalRead<T>(
        service: String,
        account: String?,
        interactive: Bool,
        unavailable: (_ permissionDenied: Bool) -> Error,
        read: (ReadTicket) throws -> T
    ) throws -> T {
        let key = Key(service: service, account: account)

        condition.lock()
        let acquired = waitWhileInFlight(key, deadline: now().addingTimeInterval(inFlightWait))
        if !acquired, !interactive {
            condition.unlock()
            AppLog.warn(.keychain, "keychain read skipped behind a stuck operation for one item; reporting unavailable")
            throw unavailable(false)
        }
        if !interactive, let entry = entries[key], entry.tripped,
           now().timeIntervalSince(entry.updatedAt) < revalidateAfter {
            // Replay the SAME failure category the original read produced: telling the user to
            // approve Safe Storage would be wrong advice after, say, an errSecIO outage.
            let denied = lastFailureDenied[key] ?? false
            condition.unlock()
            throw unavailable(denied)
        }
        if acquired {
            inFlight.insert(key)
        }
        let sequence = takeSequence()
        condition.unlock()

        defer {
            if acquired {
                condition.lock()
                inFlight.remove(key)
                condition.broadcast()
                condition.unlock()
            }
        }

        do {
            let value = try read(ReadTicket(sequence: sequence))
            condition.lock()
            storeIfCurrent(key: key, sequence: sequence, value: nil, tripped: false)
            condition.unlock()
            return value
        } catch {
            condition.lock()
            storeIfCurrent(key: key, sequence: sequence, value: nil, tripped: true)
            condition.unlock()
            throw error
        }
    }

    /// Must be called under `condition`'s lock. Drops the write when a newer one already landed —
    /// a stuck read finishing after a successful recovery must not re-trip the breaker — and
    /// downgrades a failure that never reached securityd. Every path (background, interactive,
    /// external) goes through this so both rules hold everywhere rather than on one path.
    /// Must be called under `condition`'s lock. Takes the read's start ticket.
    private func storeIfCurrent(
        key: Key,
        sequence: Int,
        fingerprint: String? = nil,
        fromUserAction: Bool = false,
        value: NonInteractiveKeychainRead?,
        tripped: Bool
    ) {
        // This read's OWN observations, taken by sequence — a concurrent read of the same item
        // cannot consume them. Removed even when the outcome is discarded below, so nothing leaks.
        let wasContention = contendedSequences.remove(sequence) != nil
        let category = pendingCategories.removeValue(forKey: sequence)
        // `>=` and not `>`: a read stores at most once, so the only way to match is to be that
        // same read writing its own outcome.
        guard sequence >= storedSequences[key, default: Int.min] else { return }
        storedSequences[key] = sequence
        // A read the UI gate turned away never reached securityd, so it is not evidence about this
        // item and must not trip the breaker.
        let failed = tripped && !wasContention
        store(
            key: key,
            fingerprint: fingerprint,
            fromUserAction: fromUserAction,
            value: value,
            tripped: failed
        )
        // The category describes the failure just stored, so it lands with it or not at all.
        lastFailureDenied[key] = failed ? category : nil
    }

    /// Marks the next stored outcome for this item as UI-gate contention rather than a real
    /// failure: the read never reached securityd, so tripping the breaker would lock out an item
    /// that was never attempted.
    func recordContention(_ ticket: ReadTicket) {
        condition.lock()
        contendedSequences.insert(ticket.sequence)
        condition.unlock()
    }

    /// Records why a read failed, so callers can tell "not approved yet" from "couldn't be read"
    /// without a follow-up probe.
    func recordFailureCategory(_ ticket: ReadTicket, permissionDenied: Bool) {
        condition.lock()
        pendingCategories[ticket.sequence] = permissionDenied
        condition.unlock()
    }

    /// `true` when the last failed read of this item was an ACL denial, `false` when the keychain
    /// was unreadable, `nil` when no failure has been seen.
    ///
    /// The category describes a FAILED outcome, so it only answers while the item's stored outcome
    /// is a failure. Categories are recorded by the read itself, without the sequence check that
    /// guards the cache, so an older read finishing after a newer recovery can leave one behind —
    /// this keeps that stale verdict from outliving the failure it described.
    func lastFailureWasPermissionDenied(service: String, account: String?) -> Bool? {
        let key = Key(service: service, account: account)
        condition.lock()
        defer { condition.unlock() }
        guard entries[key]?.tripped == true else { return nil }
        return lastFailureDenied[key]
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
            // The wedged operation may never produce a diagnostic of its own, so an unexplained
            // "unknown" here would be the only trace of it. Same reasoning as the read paths.
            AppLog.warn(.keychain, "keychain probe timed out behind a stuck operation for one item; reporting unknown")
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
    private func takeSequence() -> Int {
        nextSequence += 1
        return nextSequence
    }

    /// Must be called under `condition`'s lock.
    private func store(
        key: Key,
        fingerprint: String?,
        fromUserAction: Bool,
        value: NonInteractiveKeychainRead?,
        tripped: Bool
    ) {
        entries[key] = Entry(
            fingerprint: fingerprint,
            fromUserAction: fromUserAction,
            value: value,
            tripped: tripped,
            updatedAt: now()
        )
    }
}
