import AppKit
import QuartzCore

/// Owns the menu-bar panel's placement and content-driven height changes. The status-item controller
/// still owns panel creation and show/hide; this type owns only the height boundary between SwiftUI and
/// AppKit.
///
/// A height morph never resizes the window at all: `NSWindow.setFrame` forces a synchronous
/// window-server commit (backing-store reallocation + frame/content sync), and even occasional
/// mid-interaction resizes stretch the hosting layer for a frame and read as jank. Instead the window
/// opens **once per session at the screen-clamped maximum height** and stays there; the *visual*
/// panel — the AppKit backdrop via `onVisualHeightChange`, and SwiftUI's own height-framed,
/// corner-clipped content — grows and shrinks inside it on SwiftUI's clock. The window's uncovered
/// region renders fully transparent, and the window server routes mouse events in fully transparent
/// regions of a borderless non-opaque panel to the window beneath (verified empirically with
/// `NSWindow.windowNumber(at:)` against this exact panel configuration), so the region neither shows
/// nor blocks anything. Outside-click dismissal still hit-tests the visual panel rect, not the window
/// frame (`PanelOutsideClickMonitor`), so a click there closes the popover like any outside click.
@MainActor
final class PanelHeightController: NSObject {
    static let panelWidth: CGFloat = 320
    static let defaultHeight: CGFloat = 800

    private let panel: MenuBarPanel
    private let currentScreen: () -> PopoverScreen
    private let defaults: UserDefaults

    private var anchorScreen: NSScreen?
    private var anchorTopLeft: NSPoint?
    private var morphSettleTask: Task<Void, Never>?
    private(set) var isMorphing = false
    /// Paces morph frames while the panel is open: once per display refresh it drains the newest
    /// height from `PanelHeightBridge` and applies it. See `PanelHeightBridge.takePending` for why the
    /// main-queue hop alone isn't enough. Pauses itself after a morph goes quiet (so an idle popover
    /// costs no timer wakeups and doesn't pin ProMotion at full rate) and resumes on the next height
    /// push, which arrives through the bridge's main-queue fallback while paced.
    private var displayLink: CADisplayLink?
    /// Consecutive display-link ticks with nothing pending; drives the idle pause above.
    private var idleTicks = 0
    /// The height of the panel the user actually sees — the backdrop and the SwiftUI-clipped content,
    /// always ≤ the fixed window height. This is also the height that gets remembered per screen.
    private(set) var visualHeight: CGFloat = PanelHeightController.defaultHeight
    /// Installed by `StatusItemController`: sizes the AppKit backdrop (the tray / vibrancy layers) to
    /// the visual height so the revealed panel and its backing always match.
    var onVisualHeightChange: ((CGFloat) -> Void)?

    init(
        panel: MenuBarPanel,
        defaults: UserDefaults = .standard,
        currentScreen: @escaping () -> PopoverScreen
    ) {
        self.panel = panel
        self.defaults = defaults
        self.currentScreen = currentScreen
    }

    /// Installs the narrow callbacks SwiftUI uses: apply one animated visual height, clamp a target to
    /// the available display height, and read the opening height for the first pre-measurement render.
    func installBridge() {
        MenuBarPopover.applyHeight = { [weak self] height in
            self?.applyVisualHeight(height)
        }
        MenuBarPopover.clampHeight = { [weak self] rawHeight in
            self?.clampedHeight(rawHeight) ?? rawHeight
        }
        MenuBarPopover.openingHeight = { [weak self] in
            self?.visualHeight ?? Self.defaultHeight
        }
    }

    /// Clears the previous session, captures the display, and opens at the remembered guess. This must
    /// happen before SwiftUI sees the popover as shown, because that signal immediately asks the clamp
    /// hook for this display's real maximum height.
    func prepareForOpening(below buttonRect: NSRect) {
        morphSettleTask?.cancel()
        isMorphing = false
        PanelHeightBridge.invalidate()

        let screen = NSScreen.screens.first { $0.frame.intersects(buttonRect) } ?? NSScreen.main
        anchorScreen = screen
        let topLeft = PanelGeometry.clampedTopLeft(
            below: buttonRect,
            width: Self.panelWidth,
            visibleFrame: screen?.visibleFrame
        )
        anchorTopLeft = topLeft

        // The window takes the whole allowed height for the session; only the visual panel (backdrop +
        // SwiftUI content) opens at the remembered guess and animates from there.
        panel.setFrame(
            PanelGeometry.frame(topLeft: topLeft, width: Self.panelWidth, height: maximumHeight()),
            display: false
        )
        let remembered = loadHeight(for: currentScreen()) ?? Self.defaultHeight
        let height = clampedHeight(remembered)
        visualHeight = height
        onVisualHeightChange?(height)
        panel.invalidateShadow()
        startDisplayLink()
    }

    /// Saves before the caller changes screens or orders the panel out.
    func saveBeforeClosing() {
        guard panel.isVisible else { return }
        saveHeight(visualHeight, for: currentScreen())
    }

    /// Clears all opening-session state after the panel is ordered out.
    func finishClosing() {
        anchorTopLeft = nil
        anchorScreen = nil
        morphSettleTask?.cancel()
        isMorphing = false
        displayLink?.invalidate()
        displayLink = nil
        PanelHeightBridge.setPaced(false)
        PanelHeightBridge.invalidate()
    }

    private func startDisplayLink() {
        guard displayLink == nil, let view = panel.contentView else { return }
        let link = view.displayLink(target: self, selector: #selector(displayLinkFired))
        // Without a floor the link downclocks when morph frames run long, and the panel edge visibly
        // notches; ask for the anchored display's full rate — SwiftUI animates the panel at that
        // cadence, and the backdrop should keep step — and let the idle pause handle quiet stretches.
        // The link is recreated per open, so a screen change between opens picks up the new rate.
        let maxRate = Float((anchorScreen ?? NSScreen.main)?.maximumFramesPerSecond ?? 120)
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: min(60, maxRate),
            maximum: maxRate,
            preferred: maxRate
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
        idleTicks = 0
        PanelHeightBridge.setPaced(true)
    }

    /// Quiet ticks before the link pauses itself: long enough to outlast a spring's sub-pixel tail
    /// (which the apply threshold below drops), short enough that an open-and-idle popover stops
    /// ticking within a second.
    private static let idleTicksBeforePause = 60

    @objc private func displayLinkFired() {
        guard let height = PanelHeightBridge.takePending() else {
            idleTicks += 1
            if idleTicks >= Self.idleTicksBeforePause {
                pauseDisplayLink()
            }
            return
        }
        idleTicks = 0
        applyVisualHeight(height)
    }

    /// Hand consumption back to the bridge's main-queue fallback, then stop ticking. Order matters:
    /// once pacing is off, a concurrent push schedules its own fallback apply, and `resumePacing`
    /// restarts the link — so drain anything that squeaked in between under the old mode before
    /// actually pausing.
    private func pauseDisplayLink() {
        PanelHeightBridge.setPaced(false)
        if let height = PanelHeightBridge.takePending() {
            PanelHeightBridge.setPaced(true)
            applyVisualHeight(height)
            return
        }
        displayLink?.isPaused = true
    }

    /// Called from the fallback apply while the link is paused: take over pacing again for the morph
    /// that just started.
    private func resumePacingIfNeeded() {
        guard let displayLink, displayLink.isPaused else { return }
        displayLink.isPaused = false
        idleTicks = 0
        PanelHeightBridge.setPaced(true)
    }

    private func applyVisualHeight(_ rawHeight: CGFloat) {
        guard rawHeight > 1, panel.isVisible else { return }
        resumePacingIfNeeded()
        // Deliberately NOT clamped: every target (and the opening guess) is already clamped before it
        // animates, so per-frame values only leave the range during spring overshoot — and SwiftUI
        // renders those raw values. Re-clamping here would pin the backdrop at the boundary while the
        // panel dips past it (visible at a target sitting exactly on the 200pt minimum), splitting the
        // two bottom edges. Past the maximum both sides clip at the window bounds — the backdrop via
        // its below-required height constraint, the panel via the host layer mask — so they agree there.
        guard abs(visualHeight - rawHeight) > 0.5 else { return }
        visualHeight = rawHeight
        onVisualHeightChange?(rawHeight)
        // The shadow follows the window's rendered alpha shape — the visual panel, not the fixed
        // window frame — so refresh it as the shape animates. This is the only per-frame AppKit work
        // a morph does; the window itself never moves.
        panel.invalidateShadow()
        isMorphing = true
        scheduleMorphSettle()
    }

    private func scheduleMorphSettle() {
        morphSettleTask?.cancel()
        morphSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, self.panel.isVisible else { return }
            self.isMorphing = false
            self.panel.invalidateShadow()
            self.saveHeight(self.visualHeight, for: self.currentScreen())
        }
    }

    private func clampedHeight(_ rawHeight: CGFloat) -> CGFloat {
        PanelGeometry.clampedHeight(rawHeight, maximum: maximumHeight())
    }

    private func maximumHeight() -> CGFloat {
        guard let anchorTopLeft, let visibleFrame = (anchorScreen ?? NSScreen.main)?.visibleFrame else {
            return Self.defaultHeight
        }
        return PanelGeometry.maximumHeight(topLeft: anchorTopLeft, visibleFrame: visibleFrame)
    }

    private func loadHeight(for screen: PopoverScreen) -> CGFloat? {
        let value = defaults.double(forKey: Self.heightKey(for: screen))
        return value > 0 ? CGFloat(value) : nil
    }

    private func saveHeight(_ height: CGFloat, for screen: PopoverScreen) {
        defaults.set(Double(height), forKey: Self.heightKey(for: screen))
    }

    private static func heightKey(for screen: PopoverScreen) -> String {
        switch screen {
        case .dashboard: "runway.panel.height.dashboard"
        case .customize: "runway.panel.height.customize"
        case .settings: "runway.panel.height.settings"
        }
    }
}

/// Pure panel geometry, kept separate so display clamping can be tested without opening a window.
enum PanelGeometry {
    static let topGap: CGFloat = 4
    static let screenMargin: CGFloat = 8
    static let minimumHeight: CGFloat = 200

    static func clampedTopLeft(below buttonRect: NSRect, width: CGFloat, visibleFrame: NSRect?) -> NSPoint {
        var x = buttonRect.minX
        if let visibleFrame {
            x = min(
                max(x, visibleFrame.minX + screenMargin),
                visibleFrame.maxX - width - screenMargin
            )
        }
        return NSPoint(x: x, y: buttonRect.minY - topGap)
    }

    static func maximumHeight(topLeft: NSPoint, visibleFrame: NSRect) -> CGFloat {
        let roomBelowAnchor = topLeft.y - visibleFrame.minY - screenMargin
        let aestheticCap = floor(visibleFrame.height * 0.85)
        return max(1, min(roomBelowAnchor, aestheticCap))
    }

    static func clampedHeight(_ rawHeight: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(rawHeight, minimumHeight), maximum)
    }

    static func frame(topLeft: NSPoint, width: CGFloat, height: CGFloat) -> NSRect {
        NSRect(
            origin: NSPoint(x: topLeft.x, y: topLeft.y - height),
            size: NSSize(width: width, height: height)
        )
    }
}
