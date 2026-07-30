import AppKit

/// Owns the local and global mouse monitors that dismiss the menu-bar panel.
@MainActor
final class PanelOutsideClickMonitor {
    private let panel: MenuBarPanel
    private let statusItem: NSStatusItem
    private let isMorphing: () -> Bool
    /// The panel's current *visual* height. The window is a fixed-size transparent canvas taller than
    /// the visible panel (see `PanelHeightController`), so inside/outside must be judged against the
    /// visual rect — a click in the window's transparent remainder is an outside click.
    private let visualHeight: () -> CGFloat
    private let onInsidePanelClick: () -> Void
    private let onDismiss: () -> Void
    private var monitors: [Any] = []

    init(
        panel: MenuBarPanel,
        statusItem: NSStatusItem,
        isMorphing: @escaping () -> Bool,
        visualHeight: @escaping () -> CGFloat,
        onInsidePanelClick: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.panel = panel
        self.statusItem = statusItem
        self.isMorphing = isMorphing
        self.visualHeight = visualHeight
        self.onInsidePanelClick = onInsidePanelClick
        self.onDismiss = onDismiss
    }

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            // NSEvent is not Sendable, so only copy these small values before returning to the main actor.
            let windowID = event.window.map(ObjectIdentifier.init)
            let windowTypeName = event.window.map { String(describing: type(of: $0)) }
            MainActor.assumeIsolated {
                self?.handleClick(
                    windowID: windowID,
                    windowTypeName: windowTypeName,
                    screenPoint: NSEvent.mouseLocation
                )
            }
            return event
        }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            // Read the location now; the pointer may move before the main-actor task runs.
            let screenPoint = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handleClick(windowID: nil, windowTypeName: nil, screenPoint: screenPoint)
            }
        }) {
            monitors.append(global)
        }
    }

    func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
    }

    private func handleClick(
        windowID: ObjectIdentifier?,
        windowTypeName: String?,
        screenPoint: NSPoint
    ) {
        let isInsidePanel = PanelOutsideClickPolicy.visualPanelRect(
            panelFrame: panel.frame,
            visualHeight: visualHeight()
        ).contains(screenPoint)
        let hasWindowContext = windowID != nil && windowTypeName != nil
        let buttonWindowID = statusItem.button?.window.map(ObjectIdentifier.init)
        let context = PanelOutsideClickContext(
            isMorphing: isMorphing(),
            hasAttachedSheet: panel.attachedSheet != nil,
            isOnStatusButton: isOnStatusButton(screenPoint),
            isInsidePanel: isInsidePanel,
            // An event routed to the panel window only keeps it open when it also lands on the visible
            // panel — the window extends transparently below it, and a click there must dismiss.
            isPanelWindow: hasWindowContext && windowID == ObjectIdentifier(panel) && isInsidePanel,
            isStatusItemWindow: hasWindowContext && windowID == buttonWindowID,
            eventWindowTypeName: hasWindowContext ? windowTypeName : nil
        )

        if PanelOutsideClickPolicy.shouldKeepOpen(context) {
            if isInsidePanel { onInsidePanelClick() }
            return
        }
        onDismiss()
    }

    private func isOnStatusButton(_ screenPoint: NSPoint) -> Bool {
        guard let button = statusItem.button, let buttonWindow = button.window else { return false }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        return PanelOutsideClickPolicy.pointHitsStatusButton(
            screenPoint,
            buttonFrame: buttonFrame,
            screenTop: buttonWindow.screen?.frame.maxY
        )
    }
}

struct PanelOutsideClickContext {
    var isMorphing = false
    var hasAttachedSheet = false
    var isOnStatusButton = false
    var isInsidePanel = false
    var isPanelWindow = false
    var isStatusItemWindow = false
    var eventWindowTypeName: String?
}

enum PanelOutsideClickPolicy {
    /// The on-screen rect of the *visible* panel: the top `visualHeight` points of the window frame.
    /// The window itself stays at the screen-clamped maximum height while open, so the frame's lower
    /// remainder is transparent dead space that must count as "outside" for dismissal.
    static func visualPanelRect(panelFrame: NSRect, visualHeight: CGFloat) -> NSRect {
        NSRect(
            x: panelFrame.minX,
            y: panelFrame.maxY - min(visualHeight, panelFrame.height),
            width: panelFrame.width,
            height: min(visualHeight, panelFrame.height)
        )
    }

    static func shouldKeepOpen(_ context: PanelOutsideClickContext) -> Bool {
        context.isMorphing
            || context.hasAttachedSheet
            || context.isOnStatusButton
            || context.isInsidePanel
            || context.isPanelWindow
            || context.isStatusItemWindow
            || context.eventWindowTypeName?.localizedCaseInsensitiveContains("menu") == true
            // A hover popover (model breakdown, usage trend, resets timeline) is its own window that
            // floats *outside* the panel frame, so a click on an interactive control inside it — e.g.
            // the resets "Use" button — otherwise reads as an outside click and tears the panel down
            // before the control's mouse-up fires. Its backing window class is `_NSPopoverWindow`.
            || context.eventWindowTypeName?.localizedCaseInsensitiveContains("popover") == true
    }

    /// Status-button hit test. Differs from `NSRect.contains(buttonFrame)` in two ways, both needed
    /// so a click with the cursor slammed against the top of the screen — the natural way to click
    /// the menu bar — counts as *on* the button (issue #1008):
    /// - The hit zone extends from the button frame's top edge to the top of the button's screen:
    ///   the button is a few points shorter than the menu bar (observed live: a 22pt-tall button
    ///   frame ending at y=1551 in a menu bar whose screen tops out at y=1555), while macOS still
    ///   routes a click in that strip to the button.
    /// - Edges are inclusive, where `contains` excludes max edges: a top-pinned cursor reports
    ///   exactly the screen's `maxY`.
    /// Without these, the monitor misread a dead-center click on the icon as an outside click: the
    /// panel dismissed on mouse-down, then the button's mouse-up action toggled it right back open —
    /// the second click never closed it. The monitor must agree with how macOS routes the click, or
    /// its dismissal races the button's toggle.
    static func pointHitsStatusButton(_ point: NSPoint, buttonFrame: NSRect, screenTop: CGFloat?) -> Bool {
        guard !buttonFrame.isEmpty else { return false }
        let top = max(buttonFrame.maxY, screenTop ?? buttonFrame.maxY)
        return point.x >= buttonFrame.minX && point.x <= buttonFrame.maxX
            && point.y >= buttonFrame.minY && point.y <= top
    }
}
