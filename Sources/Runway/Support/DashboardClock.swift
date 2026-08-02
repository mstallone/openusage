import Foundation
import Observation

/// The popover's shared wall clock: one timer that ticks `perSecond` (the footer's refresh
/// countdown) and `halfMinute` (the metric rows' relative reset dates) while the popover is on
/// screen, and stops cold when it closes.
///
/// This replaces per-view `TimelineView`s gated on `\.popoverIsVisible`. That gate was an `if`
/// branch swap, and because `NSPanel.orderOut` keeps the SwiftUI tree mounted, every open and close
/// structurally tore down and rebuilt every reset-bearing row's subtree just to mount or unmount its
/// timeline — the single biggest cost on the popup-open path. Reading a clock property registers a
/// plain observation instead: rows keep one stable structure for their whole life, only re-rendering
/// when the date they read actually changes, and a closed popover ticks nothing.
///
/// `start()` stamps both dates fresh, so reopening re-renders exactly the views whose displayed time
/// went stale while the popover was closed — the same freshness the timeline mount used to provide.
@MainActor
@Observable
final class DashboardClock {
    private(set) var perSecond = Date()
    private(set) var halfMinute = Date()
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// Idempotent; called from the panel-show chokepoint.
    func start() {
        guard ticker == nil else { return }
        let now = Date()
        perSecond = now
        halfMinute = now
        ticker = Task { @MainActor [weak self] in
            var beat = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.perSecond = Date()
                beat += 1
                if beat.isMultiple(of: 30) {
                    self.halfMinute = self.perSecond
                }
            }
        }
    }

    /// Called from every panel-hide chokepoint. The dates keep their last values (nothing on screen
    /// reads them while hidden), so stopping never invalidates the hidden tree.
    func stop() {
        ticker?.cancel()
        ticker = nil
    }
}
