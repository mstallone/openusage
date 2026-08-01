import AppKit
import SwiftUI

/// A pull-down control that pops a real AppKit `NSMenu` beneath its SwiftUI label.
///
/// Exists because SwiftUI's `Menu` popup on macOS measures its item rows asynchronously and can
/// open at a stale width, middle-truncating item titles ("Cost/MTok" → "Co…Tok") and visibly
/// re-laying-out as it appears. `NSMenu` sizes synchronously from its item titles before showing,
/// so the popup is always wide enough and opens in one clean frame — on mouse-down, like every
/// native menu. The menu's own tracking window is one the panel's outside-click policy already
/// keeps the popover open for (see `PanelOutsideClickPolicy`).
///
/// Items come from a builder closure evaluated at open time, so per-open state (like a checkmark
/// on the current selection via `NSMenuItem.state`) is always current. Build items with
/// `ClosureMenuItem` to keep actions inline.
struct NativeMenuButton<Label: View>: View {
    private let accessibilityLabel: String
    private let accessibilityValue: String?
    private let makeItems: @MainActor () -> [NSMenuItem]
    private let label: Label

    /// Weak handle to the press surface, so keyboard activation can open the same menu a physical
    /// click would.
    @State private var surface = SurfaceBox()

    /// - Parameters:
    ///   - accessibilityLabel: What the control is, announced by VoiceOver ("Total Spend Metric").
    ///   - accessibilityValue: The current selection, announced as the pop-up's value.
    ///   - items: Builds the menu items at open time.
    ///   - label: The visible SwiftUI label.
    init(
        accessibilityLabel: String,
        accessibilityValue: String? = nil,
        items: @escaping @MainActor () -> [NSMenuItem],
        @ViewBuilder label: () -> Label
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.makeItems = items
        self.label = label()
    }

    /// A SwiftUI `Button` under an AppKit press surface. The surface intercepts physical clicks so
    /// the menu opens on mouse-down like a native pull-down, and it is also the control's one
    /// accessibility element — a real pop-up button role (which SwiftUI cannot express) whose press
    /// action opens the menu. The button underneath — which neither mouse events nor assistive tech
    /// reach — keeps the control in the Tab key-view loop with Space activation.
    var body: some View {
        Button {
            surface.view?.presentMenu()
        } label: {
            label
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
        .overlay(
            MenuPressSurface(
                box: surface,
                makeItems: makeItems,
                accessibilityLabel: accessibilityLabel,
                accessibilityValue: accessibilityValue
            )
        )
    }
}

@MainActor
private final class SurfaceBox {
    weak var view: MenuPressView?
}

/// Transparent AppKit surface over the label that owns the mouse-down → menu hand-off and the
/// pop-up-button accessibility semantics.
private struct MenuPressSurface: NSViewRepresentable {
    let box: SurfaceBox
    let makeItems: @MainActor () -> [NSMenuItem]
    let accessibilityLabel: String
    let accessibilityValue: String?

    func makeNSView(context: Context) -> MenuPressView {
        let view = MenuPressView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: MenuPressView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: MenuPressView) {
        view.makeItems = makeItems
        view.setAccessibilityLabel(accessibilityLabel)
        view.setAccessibilityValue(accessibilityValue)
        box.view = view
    }
}

private final class MenuPressView: NSView, NSMenuDelegate {
    var makeItems: (@MainActor () -> [NSMenuItem])?

    /// Gap between the label's bottom edge and the menu's top edge.
    private static let menuGap: CGFloat = 4

    /// Reopen machinery for "click again quickly to reopen" while the menu is open. That gesture is
    /// mostly invisible: the click that dismisses is consumed by the menu's tracking session, and a
    /// fast follow-up click gets discarded by AppKit before the app sees any of it (not even a
    /// local event monitor fires). Three paths cover the speeds:
    /// - delivered: the follow-up mouseDown actually arrives (slower re-clicks) → `reopenOnMouseUp`
    ///   parks the reopen until the release, past the old session's teardown;
    /// - consumed: both downs happened inside the session — the window-server click counter (which
    ///   counts physical downs no matter who swallowed them) reads ≥2 for the session;
    /// - discarded: the follow-up down lands after the close but is never delivered — the counter
    ///   ticks up during the post-close watch window.
    /// `sessionGeneration` invalidates a pending watch whenever a new session starts or a real
    /// mouseDown arrives, so only one path can fire.
    private var lastMenuCloseTime: TimeInterval = 0
    private var reopenOnMouseUp = false
    private var sessionGeneration = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The surface is the control's accessibility element, with the pop-up role the SwiftUI
        // `Menu` it replaces had — so VoiceOver announces a choice menu, not a plain button.
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The panel is a non-activating key panel that can briefly cede key status to the menu's own
    /// window; without this, the first click back on the control after a dismissal can be eaten as
    /// window-activating click-through instead of reaching `mouseDown`.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        // A real mouseDown supersedes any post-close watch — exactly one reopen path may fire.
        sessionGeneration += 1
        if event.timestamp - lastMenuCloseTime < NSEvent.doubleClickInterval {
            // Popping now would race the previous session's teardown (AppKit drops the menu);
            // park the reopen until the release, when the old session is fully gone.
            reopenOnMouseUp = true
        } else {
            presentMenu()
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard reopenOnMouseUp else { return }
        reopenOnMouseUp = false
        // Only when the release still lands on the control — dragging off cancels, like any button.
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.presentMenu()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        lastMenuCloseTime = ProcessInfo.processInfo.systemUptime
    }

    override func accessibilityPerformPress() -> Bool {
        presentMenu()
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        presentMenu()
        return true
    }

    func presentMenu() {
        // The re-click watch and the accessibility press can outlive a panel hide — the panel is
        // ordered out with its SwiftUI tree (and this view) retained, and an ordered-out window
        // still passes the cursor geometry test. Never pop a menu for a hidden panel. (Same
        // lifecycle guard as `PopoverKeyReader`.)
        guard let makeItems, window?.isVisible == true else { return }
        sessionGeneration += 1
        let menu = NSMenu()
        menu.delegate = self
        for item in makeItems() {
            menu.addItem(item)
        }
        let below = NSPoint(
            x: bounds.minX,
            y: isFlipped ? bounds.maxY + Self.menuGap : bounds.minY - Self.menuGap
        )
        let downsAtOpen = Self.leftMouseDownCounter()
        menu.popUp(positioning: nil, at: below, in: self)
        scheduleReclickWatch(downsDuringSession: Int(Self.leftMouseDownCounter() &- downsAtOpen))
    }

    /// Physical left-mouse-down count for the login session, straight from the window server —
    /// it keeps counting even when the events are swallowed before the app sees them.
    private static func leftMouseDownCounter() -> UInt32 {
        CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown)
    }

    private func isCursorOverControl() -> Bool {
        guard let window else { return false }
        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return bounds.contains(convert(point, from: nil))
    }

    /// After a session ends, watch briefly for the invisible half of a quick re-click: either the
    /// session already swallowed a second down (the counter read ≥2 during it with the cursor on
    /// the control; a plain dismissing click is exactly 1, and a double-click on a *closed* control
    /// also reads 1 because its first down is what started the session), or a discarded follow-up
    /// down ticks the counter during the double-click window after the close. Confirmation and
    /// firing rules live in `MenuReclickWatchPolicy`; the watch fires at most once.
    private func scheduleReclickWatch(downsDuringSession: Int) {
        let overControl = isCursorOverControl()
        let deadline = ProcessInfo.processInfo.systemUptime + NSEvent.doubleClickInterval + 0.15
        watchTick(
            generation: sessionGeneration,
            confirmed: downsDuringSession >= 2 && overControl,
            lastCounter: Self.leftMouseDownCounter(),
            wasOverControl: overControl,
            deadline: deadline
        )
    }

    private func watchTick(
        generation: Int,
        confirmed: Bool,
        lastCounter: UInt32,
        wasOverControl: Bool,
        deadline: TimeInterval
    ) {
        guard generation == sessionGeneration else { return }
        let counterNow = Self.leftMouseDownCounter()
        let overNow = isCursorOverControl()
        let nowConfirmed = MenuReclickWatchPolicy.confirms(
            alreadyConfirmed: confirmed,
            counterAdvanced: counterNow != lastCounter,
            overControlNow: overNow,
            overControlAtPriorTick: wasOverControl
        )
        if MenuReclickWatchPolicy.mayReopen(
            confirmed: nowConfirmed,
            buttonsPressed: NSEvent.pressedMouseButtons != 0,
            overControlNow: overNow
        ) {
            presentMenu()
            return
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.watchTick(
                generation: generation,
                confirmed: nowConfirmed,
                lastCounter: counterNow,
                wasOverControl: overNow,
                deadline: deadline
            )
        }
    }
}

/// Decision rules for the post-close re-click watch, split out so the spurious-reopen cases are
/// testable. The counter is session-wide (every app's clicks tick it), so an increment alone must
/// never count as a click on this control.
enum MenuReclickWatchPolicy {
    /// Whether this tick confirms a re-click on the control. A prior confirmation latches (so a
    /// re-click observed while the button is still down survives until it can fire). A fresh
    /// counter increment confirms only when the cursor was on the control at the ticks on *both*
    /// sides of it — a genuine swallowed re-click happens with the cursor parked on the control,
    /// while a click on anything else followed by hovering back is bracketed by an off-control
    /// tick and stays unconfirmed.
    static func confirms(
        alreadyConfirmed: Bool,
        counterAdvanced: Bool,
        overControlNow: Bool,
        overControlAtPriorTick: Bool
    ) -> Bool {
        alreadyConfirmed || (counterAdvanced && overControlNow && overControlAtPriorTick)
    }

    /// A confirmed re-click reopens only once the button is released and the cursor is still on
    /// the control.
    static func mayReopen(confirmed: Bool, buttonsPressed: Bool, overControlNow: Bool) -> Bool {
        confirmed && !buttonsPressed && overControlNow
    }
}
