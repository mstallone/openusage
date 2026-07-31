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
    private let makeItems: @MainActor () -> [NSMenuItem]
    private let label: Label

    /// Weak handle to the press surface, so keyboard and VoiceOver activation can open the same
    /// menu a physical click would.
    @State private var surface = SurfaceBox()

    init(items: @escaping @MainActor () -> [NSMenuItem], @ViewBuilder label: () -> Label) {
        self.makeItems = items
        self.label = label()
    }

    /// A SwiftUI `Button` under an AppKit press surface: the surface intercepts physical clicks so
    /// the menu opens on mouse-down like a native pull-down, while the button — which mouse events
    /// therefore never reach — keeps the control in the Tab key-view loop and gives Space/VoiceOver
    /// activation the same menu. The surface is hidden from accessibility so the button is the one
    /// element assistive tech sees.
    var body: some View {
        Button {
            surface.view?.presentMenu()
        } label: {
            label
        }
        .buttonStyle(.plain)
        .overlay(MenuPressSurface(box: surface, makeItems: makeItems).accessibilityHidden(true))
    }
}

@MainActor
private final class SurfaceBox {
    weak var view: MenuPressView?
}

/// Transparent AppKit surface over the label that owns the mouse-down → menu hand-off.
private struct MenuPressSurface: NSViewRepresentable {
    let box: SurfaceBox
    let makeItems: @MainActor () -> [NSMenuItem]

    func makeNSView(context: Context) -> MenuPressView {
        let view = MenuPressView()
        view.makeItems = makeItems
        box.view = view
        return view
    }

    func updateNSView(_ nsView: MenuPressView, context: Context) {
        nsView.makeItems = makeItems
        box.view = nsView
    }
}

private final class MenuPressView: NSView {
    var makeItems: (@MainActor () -> [NSMenuItem])?

    /// Gap between the label's bottom edge and the menu's top edge.
    private static let menuGap: CGFloat = 4

    override func mouseDown(with event: NSEvent) {
        presentMenu()
    }

    func presentMenu() {
        guard let makeItems else { return }
        let menu = NSMenu()
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
