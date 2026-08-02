import SwiftUI
import os

/// Mirrors `PanelHeightModifier`'s idiom for the screen-switch slide: an identity `GeometryEffect`
/// whose only job is the per-frame `animatableData` hook, recording the slide progress the popover
/// is ACTUALLY rendering. The `slideProgress` state hits its target the instant `withAnimation`
/// commits — state alone cannot tell how far a push has visibly travelled — but a mid-flight
/// reversal must start the next push from the pages' rendered positions, not their logical ones
/// (see `DashboardView`'s slide `onChange`). The effect is an identity transform: no visual change,
/// only the hook.
struct SlideProgressEffect: GeometryEffect {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set {
            progress = newValue
            SlideProgressBridge.push(newValue)
        }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        // Re-pushed on every re-render (not only animated frames), so un-animated jumps — the
        // hidden close-time walk sets the progress directly — keep the bridge truthful too.
        SlideProgressBridge.push(progress)
        return ProjectionTransform()
    }
}

/// The last slide progress the render tree actually drew. `OSAllocatedUnfairLock` so the
/// nonisolated `Animatable` setter and the main-actor read at switch time stay clean under strict
/// concurrency — same shape as `PanelHeightBridge`, minus the scheduling (this one is only ever
/// read synchronously at the moment a switch starts).
enum SlideProgressBridge {
    private static let state = OSAllocatedUnfairLock(initialState: CGFloat(1))

    nonisolated static func push(_ progress: CGFloat) {
        state.withLock { $0 = progress }
    }

    nonisolated static func renderedProgress() -> CGFloat {
        state.withLock { $0 }
    }
}
