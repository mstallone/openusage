import AppKit
import Darwin

/// Rejects a second copy of Runway at launch (issue #635). macOS can fire two independent launch
/// triggers on reboot — session restoration ("Reopen windows when logging back in") and the
/// `SMAppService` login item — and a crashed or hung copy can linger holding `127.0.0.1:6736`.
/// Without a guard either path yields a duplicate menu-bar icon (or, for an `LSUIElement` app, a
/// launch that "does nothing"). The decision is split out from the live-workspace query so it can be
/// unit-tested without a second running process.
@MainActor
enum SingleInstanceGuard {
    /// Pure decision: the PID of the instance we should yield to, or `nil` if we should keep running.
    ///
    /// Tie-break is deterministic — the lowest-PID instance is the survivor; every other copy yields
    /// to it. This matters for the reboot race the guard targets: when two launches register at once,
    /// a naive "yield if any other instance exists" rule makes *both* yield and terminate, leaving
    /// zero running instances. Lowest-PID-wins guarantees exactly one survivor. (The one theoretical
    /// hole — PID wraparound between an older instance's launch and ours — needs ~99k intervening PIDs
    /// and is negligible.)
    static func instanceToYieldTo(myPID: pid_t, runningPIDs: [pid_t]) -> pid_t? {
        guard let lowestPeer = runningPIDs.filter({ $0 != myPID }).min(), lowestPeer < myPID else {
            return nil
        }
        return lowestPeer
    }

    /// Live check + handoff. When another instance owns the slot, hands focus to the surviving copy
    /// and returns `true` so the caller bows out before grabbing the local-API port or adding a status
    /// item. Returns `false` (no-op) when we are the survivor, or when unbundled (`swift run`/preview)
    /// has no bundle identifier to match against.
    static func deferToExistingInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let me = NSRunningApplication.current
        // Drop stale entries: yielding to a corpse can cascade into every copy terminating (the
        // zero-survivor outcomes reproduced in #874).
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter(isAlive)
        guard let survivorPID = instanceToYieldTo(
            myPID: me.processIdentifier,
            runningPIDs: running.map(\.processIdentifier)
        ) else {
            return false
        }
        // Resolved from the same snapshot the decision used, so the survivor is still present.
        running.first { $0.processIdentifier == survivorPID }?.activate()
        return true
    }

    /// Focus handoff without the lowest-PID decision: activates any other running copy with our
    /// bundle identifier. Used when `SingleInstanceLock` already told us a peer owns the slot —
    /// lock acquisition order is not PID order, so the peer may have a *higher* PID and
    /// `deferToExistingInstance()` would skip the activation. Best-effort: in the snapshot-miss
    /// race the peer may not be visible to LaunchServices yet, and that's fine — the lock, not
    /// this handoff, is what decides who survives.
    static func activateExistingInstance() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let myPID = NSRunningApplication.current.processIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != myPID && isAlive($0) }?
            .activate()
    }

    /// LaunchServices can briefly keep a just-terminated copy in its snapshot under load (#874).
    /// `isTerminated` catches what it already knows; `kill(pid, 0)` asks the kernel directly.
    private static func isAlive(_ app: NSRunningApplication) -> Bool {
        !app.isTerminated && kill(app.processIdentifier, 0) == 0
    }
}
