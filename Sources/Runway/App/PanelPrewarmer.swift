import AppKit

/// Pre-warms the menu-bar panel so the first open runs at warm speed.
///
/// The hidden tree is laid out at panel setup, but nothing RENDERS and the window is never
/// MATERIALIZED until the first click — so that click used to pay every one-time cost (font glyph
/// caches, glass materials, CoreAnimation layer construction, and the window server creating the
/// panel) on top of the normal open: measured ~87ms cold vs ~35ms warm. Two passes after launch
/// settles move all of it to idle time: the early one (+2s) pays the one-time costs, the later one
/// (+12s) re-lays-out the content the first refresh batch delivered in between. Each pass is
/// invisible — offscreen raster via `cacheDisplay`, window ordered front at alpha 0 and straight
/// back out — and skipped once the user has opened the panel for real.
///
/// Split out of `StatusItemController` (which owns show/hide and must stay lean); the controller
/// only reports the first real open via `noteOpened()`.
@MainActor
final class PanelPrewarmer {
    private let panel: NSPanel
    private let hostView: NSView
    private let heightController: PanelHeightController
    /// The status button's screen rect at warm-up time, or nil when the button is unavailable.
    private let anchorRect: () -> NSRect?
    private var hasOpened = false

    init(
        panel: NSPanel,
        hostView: NSView,
        heightController: PanelHeightController,
        anchorRect: @escaping () -> NSRect?
    ) {
        self.panel = panel
        self.hostView = hostView
        self.heightController = heightController
        self.anchorRect = anchorRect
    }

    /// Called from the real open path: any later warm-up pass would render content the open
    /// already warmed, which is pure main-actor waste.
    func noteOpened() {
        hasOpened = true
    }

    /// Schedules the two warm-up passes. RUNWAY_UI_PROFILE_COLD=1 disables them so the harness can
    /// measure the true cold path (without it, the scripted "cold open" measures the shipped
    /// first-click experience — see docs/debugging.md).
    func scheduleWarmups() {
        guard ProcessInfo.processInfo.environment["RUNWAY_UI_PROFILE_COLD"] != "1" else { return }
        Task { @MainActor [weak self] in
            // Absolute offsets from launch, not sequential sleeps: the second pass must land AT
            // +12s (right after the first refresh batch), not at 12s-plus-however-long the first
            // pass took — users opening in that drift window would still pay the refreshed-content
            // layout this pass exists to absorb.
            let launch = ContinuousClock.now
            for offset in [Duration.seconds(2), .seconds(12)] {
                try? await Task.sleep(until: launch + offset, clock: .continuous)
                guard let self, !self.hasOpened, !self.panel.isVisible else { return }
                self.prewarm()
            }
        }
    }

    /// One invisible warm-up pass over everything the first open would otherwise pay for the first
    /// time: the real opening frame, a full layout at it, an offscreen raster (fonts, materials,
    /// layer construction), and the window server's panel materialization.
    private func prewarm() {
        UIProfiler.measure("prewarm.render") {
            // Anchor at the real opening frame first — warming up at the setup-time default frame
            // leaves the first open re-laying-out everything at the actual anchor size anyway.
            if let buttonRect = anchorRect() {
                heightController.prepareForOpening(below: buttonRect)
            }
            hostView.layoutSubtreeIfNeeded()
            if let rep = hostView.bitmapImageRepForCachingDisplay(in: hostView.bounds) {
                hostView.cacheDisplay(in: hostView.bounds, to: rep)
            }
            // First-ever ordering makes the window server create the panel (~30ms billed to the
            // first open otherwise). Do it invisibly: alpha 0, no key, straight back out. The real
            // open runs `prepareForOpening` again, so no anchor state leaks from here.
            let alpha = panel.alphaValue
            panel.alphaValue = 0
            panel.orderFront(nil)
            panel.orderOut(nil)
            panel.alphaValue = alpha
            heightController.finishClosing()
        }
    }
}
