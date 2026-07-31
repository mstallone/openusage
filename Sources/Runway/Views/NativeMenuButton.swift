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

    /// When the last menu session ended (`NSEvent.timestamp` clock) and whether a reopen is parked
    /// until mouse-up. Clicking the control while its menu is open closes the menu — the tracking
    /// session consumes that mouseDown, so it never reaches `mouseDown` here. The *next* click
    /// inside the double-click window is the "click again to reopen" gesture, and popping on its
    /// mouseDown races the previous session's teardown (AppKit drops or instantly re-closes the new
    /// menu), so that reopen waits for the mouseUp instead — by then the old session is gone, and
    /// with the button already released the menu opens and stays.
    private var lastMenuCloseTime: TimeInterval = 0
    private var reopenOnMouseUp = false

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

    override func mouseDown(with event: NSEvent) {
        if event.timestamp - lastMenuCloseTime < NSEvent.doubleClickInterval {
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
        guard let makeItems else { return }
        let menu = NSMenu()
        menu.delegate = self
        for item in makeItems() {
            menu.addItem(item)
        }
        let below = NSPoint(
            x: bounds.minX,
            y: isFlipped ? bounds.maxY + Self.menuGap : bounds.minY - Self.menuGap
        )
        menu.popUp(positioning: nil, at: below, in: self)
    }
}
