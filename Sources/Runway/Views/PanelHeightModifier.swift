import SwiftUI
import os

/// Drives the AppKit side of the visual panel — the backdrop height and the window shadow — on
/// SwiftUI's animation clock. This is the "single clock": SwiftUI owns the animated panel height (the
/// window itself is a fixed-size transparent canvas that never resizes while open, see
/// `PanelHeightController`), and AppKit passively follows the same value, so the tray/vibrancy backing
/// can never fight or lag the SwiftUI-rendered panel by more than a frame.
///
/// `animatableData == height` is the per-frame interpolation hook: during a `withAnimation`, the
/// animation system sets `animatableData` once per display refresh with the interpolated height, and
/// the setter forwards it (via `PanelHeightBridge`) to the controller — so the backdrop and the
/// SwiftUI panel ride the *same* spring. `effectValue` also forwards the current value so non-animated
/// height establishments still resize the backdrop. A height of 0 is the "not established yet"
/// sentinel (the backdrop keeps the opening-guess size the controller seeded) and is skipped, so the
/// first render before measurement lands never pushes a bogus height.
///
/// Built as a `GeometryEffect` (like `DenyShakeEffect`) rather than a plain `ViewModifier`: a custom
/// `ViewModifier` that implements `body` is inferred `@MainActor` (because `ViewModifier.body` is), which
/// would make `animatableData` `@MainActor` and violate `Animatable`'s `nonisolated` requirement.
/// `GeometryEffect` supplies its own `body`, so the struct stays nonisolated and the `Animatable`
/// conformance is clean; the forwarding goes through the `nonisolated` `PanelHeightBridge`. The effect
/// itself is an identity transform — we only want its per-frame `animatableData` hook, no visual change.
struct PanelHeightModifier: GeometryEffect {
    var height: CGFloat

    var animatableData: CGFloat {
        get { height }
        set {
            height = newValue
            PanelHeightBridge.push(newValue)
        }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        PanelHeightBridge.push(height)
        return ProjectionTransform()
    }
}

/// Forwards interpolated heights from the (nonisolated) `Animatable` setter to the `@MainActor` panel
/// controller. SwiftUI interpolates on the main thread, and the apply is a direct frame set on a
/// constraint-free sibling view plus a shadow invalidation — nothing that re-enters layout — so pushes
/// apply **synchronously, inside the same transaction as the SwiftUI frame they match**. That's what
/// glues the AppKit backdrop to the clipped panel: any deferred apply (a main-queue hop, or the
/// display link this replaced) lands 0-or-1 frames behind SwiftUI, and during a shrink a one-frame-late
/// backdrop pokes out below the footer as a trailing tray strip. A coalesced main-queue hop remains
/// only as a safety net for a push that ever arrives off the main thread.
enum PanelHeightBridge {
    private struct State {
        var generation = 0
        var pendingHeight: CGFloat?
        var isScheduled = false
        /// The last height pushed. `effectValue` re-pushes the current height on every re-render of
        /// the popover root — including renders where nothing moved — and dropping those duplicates
        /// keeps the synchronous path from re-applying identical frames.
        var lastPushed: CGFloat?
    }

    /// Bumped on every panel open and close. A queued height is applied only if the generation is
    /// unchanged between when it was scheduled and when it runs — so a spring morph in flight when the
    /// panel closes can never resize a hidden, or a freshly reopened, panel with a stale height (the
    /// async hops are otherwise un-cancellable). `OSAllocatedUnfairLock` so the nonisolated `push` and
    /// the main-actor `invalidate` can touch it safely.
    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Invalidate every in-flight height. Call on panel open and close.
    nonisolated static func invalidate() {
        state.withLock {
            $0.generation += 1
            $0.pendingHeight = nil
            $0.isScheduled = false
            $0.lastPushed = nil
        }
    }

    nonisolated static func push(_ height: CGFloat) {
        guard height > 0 else { return }
        let isMain = Thread.isMainThread
        let isNew = state.withLock { state -> Bool in
            guard height != state.lastPushed else { return false }
            state.lastPushed = height
            // A synchronous apply supersedes any height still queued by the off-main safety net —
            // its hop drains this slot when it runs, so clearing it here keeps a stale older height
            // from being applied after the newer one.
            if isMain { state.pendingHeight = nil }
            return true
        }
        guard isNew else { return }
        // Normal path: same thread, same transaction — the backdrop commits with this exact frame.
        if isMain {
            MainActor.assumeIsolated {
                MenuBarPopover.applyHeight?(height)
            }
            return
        }
        let (scheduled, shouldSchedule) = state.withLock { state -> (Int, Bool) in
            state.pendingHeight = height
            let scheduled = state.generation
            guard !state.isScheduled else { return (scheduled, false) }
            state.isScheduled = true
            return (scheduled, true)
        }
        guard shouldSchedule else { return }
        DispatchQueue.main.async {
            let height = state.withLock { state -> CGFloat? in
                guard state.generation == scheduled else { return nil }
                let height = state.pendingHeight
                state.pendingHeight = nil
                state.isScheduled = false
                return height
            }
            guard let height else { return }
            MainActor.assumeIsolated {
                MenuBarPopover.applyHeight?(height)
            }
        }
    }
}

extension View {
    /// Make the panel's AppKit backing (backdrop + shadow) follow `height` on SwiftUI's animation
    /// clock. Attach at the body root, outside any `.animation(nil, …)` scope, so the height rides the
    /// active spring.
    func drivesPanelHeight(_ height: CGFloat) -> some View {
        modifier(PanelHeightModifier(height: height))
    }
}
