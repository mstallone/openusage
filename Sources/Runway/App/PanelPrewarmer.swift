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
    /// Whether any provider refresh is still in flight — the second pass waits these out (bounded)
    /// so it warms the content the launch batch actually delivered.
    private let isRefreshInFlight: () -> Bool
    private var hasOpened = false

    init(
        panel: NSPanel,
        hostView: NSView,
        heightController: PanelHeightController,
        anchorRect: @escaping () -> NSRect?,
        isRefreshInFlight: @escaping () -> Bool
    ) {
        self.panel = panel
        self.hostView = hostView
        self.heightController = heightController
        self.anchorRect = anchorRect
        self.isRefreshInFlight = isRefreshInFlight
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
            // Absolute offsets from launch, not sequential sleeps: the follow-up must key off
            // launch time, not off however long the first pass took.
            let launch = ContinuousClock.now
            try? await Task.sleep(until: launch + .seconds(2), clock: .continuous)
            guard let self, !self.hasOpened, !self.panel.isVisible else { return }
            self.prewarm()

            // Second pass: after the launch refresh batch actually completes, so it warms the
            // content that batch delivered. A fixed +12s assumed the batch was done by then, but a
            // slow provider (Cursor's CSV export alone budgets 30s) can land later and re-dirty
            // the tree AFTER the warm-up. Wait out in-flight refreshes, bounded at +60s so a hung
            // provider can't postpone the pass forever (its snapshot wouldn't change content anyway).
            try? await Task.sleep(until: launch + .seconds(12), clock: .continuous)
            while self.isRefreshInFlight(), ContinuousClock.now < launch + .seconds(60) {
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard !self.hasOpened, !self.panel.isVisible else { return }
            self.prewarm()
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
