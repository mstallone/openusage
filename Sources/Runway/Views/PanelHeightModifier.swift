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
/// controller. Applying synchronously is off the table: the setter fires from inside SwiftUI's update
/// pass, and resizing the backdrop re-enters AppKit layout — it would trip
/// `_NSDetectedLayoutRecursion`. So pushes only record the newest pending height, and one of two
/// deferred consumers applies it:
///
/// - **Paced** (the app's normal mode): the panel controller's display link drains `takePending()`
///   once per display refresh — see `takePending` for why this beats the main-queue hop.
/// - **Fallback** (no display link installed, e.g. unit tests): a coalesced `DispatchQueue.main`
///   hop applies the newest pending height just after the update pass unwinds.
///
/// Either way bursts coalesce to the newest height, so the panel never replays stale animation frames
/// after SwiftUI has already moved on. SwiftUI interpolates on the main thread, so `assumeIsolated`
/// is the right bridge to the `@MainActor` closure in the fallback.
enum PanelHeightBridge {
    private struct State {
        var generation = 0
        var pendingHeight: CGFloat?
        var isScheduled = false
        /// True while the panel controller's display link is draining `takePending()` once per display
        /// refresh. Pushes then only record the height — no main-queue hop — so each display frame gets
        /// exactly one apply instead of racing consumers applying two heights back to back.
        var isPaced = false
        /// The last height recorded, applied or not. `effectValue` re-pushes the current height on
        /// every re-render of the popover root — including renders where nothing moved — and dropping
        /// those duplicates here is what lets the controller's display link see a genuinely quiet
        /// stream and pause itself.
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

    /// Consume the newest pending height, or `nil` when nothing new arrived. The panel controller's
    /// display link drains this once per display refresh: the main-queue hop below only runs when the
    /// run loop goes idle, which a morph's continuous SwiftUI layout passes can starve for several
    /// frames at a time — the backdrop edge then jumps in visible steps. The display link is a
    /// run-loop timer source, so it fires between passes at display cadence regardless of idleness.
    /// Both consumers take from this one slot, so whichever runs first applies the freshest height and
    /// the other becomes a no-op.
    nonisolated static func takePending() -> CGFloat? {
        state.withLock { state in
            guard let height = state.pendingHeight else { return nil }
            state.pendingHeight = nil
            return height
        }
    }

    /// Enable or disable display-link pacing (see `State.isPaced`). Survives `invalidate()`, which is
    /// generation/pending bookkeeping — the pacing mode belongs to the controller's link lifecycle.
    nonisolated static func setPaced(_ paced: Bool) {
        state.withLock { $0.isPaced = paced }
    }

    nonisolated static func push(_ height: CGFloat) {
        guard height > 0 else { return }
        let (scheduled, shouldSchedule) = state.withLock { state -> (Int, Bool) in
            let scheduled = state.generation
            guard height != state.lastPushed else { return (scheduled, false) }
            state.lastPushed = height
            state.pendingHeight = height
            guard !state.isPaced, !state.isScheduled else { return (scheduled, false) }
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
