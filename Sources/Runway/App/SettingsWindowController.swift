import AppKit
import SwiftUI

/// Lets callers anywhere in the app — the popover footer's gear menu, the Customize cross-link, the
/// ⌘, key monitor, the status item's context menu, and the app menu's Settings… item (in the
/// RunwayApp target, hence `public`) — open the standalone Settings window without knowing who owns
/// it. Installed by `StatusItemController` at launch, mirroring the `MenuBarPopover` handler pattern.
@MainActor
public enum SettingsWindowLink {
    /// Closes the popover (when open) and shows the Settings window.
    static var openHandler: (() -> Void)?

    public static func open() {
        openHandler?()
    }
}

/// The Settings window: a plain titled window that also closes on Esc and ⌘W. As a menu-bar
/// accessory app Runway has no visible main menu to route ⌘W through, so the window handles the
/// keystroke itself when it bubbles up the responder chain unclaimed.
final class SettingsWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        // Esc belongs to the shortcut recorder while it's capturing a combo (cancel), and to a live
        // text field (end editing) — same carve-outs as the popover's key monitor.
        if event.keyCode == 53, // Esc
           !ShortcutRecorderField.isRecordingActive,
           !(firstResponder is NSText) {
            close()
            return
        }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "w" {
            close()
            return
        }
        super.keyDown(with: event)
    }
}

/// Owns the standalone Settings window — a real, activating window instead of the old in-popover
/// screen, so Settings no longer pays the popover's auto-fit morph machinery and the popover no
/// longer carries the Settings tree.
///
/// Built for speed and low footprint:
/// - **Lazy**: nothing exists until the first open — launching the app allocates only this
///   controller.
/// - **One pane at a time**: a preferences-style selectable toolbar mounts only the active pane's
///   SwiftUI tree, so opening Settings lays out a handful of rows, not every section at once (the
///   in-popover screen needed staged mounting to avoid exactly that first-layout stall).
/// - **Torn down on close**: `windowWillClose` drops the window and its hosting controller, so a
///   closed Settings window costs zero CPU and memory — no retained tree, no observers firing while
///   hidden.
/// - **Remembered geometry**: per-pane content heights and the window's top-left corner persist, so
///   every open lands at the right size and place with no first-frame resize.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private let container: AppContainer
    private let updater: UpdaterController
    private let defaults: UserDefaults
    private let activation: ActivationPolicyCoordinator

    private var window: SettingsWindow?
    private var hosting: NSHostingController<AnyView>?
    private var selectedPane: SettingsPane

    private static let paneKey = "runway.settings.pane"
    private static let topLeftXKey = "runway.settings.topLeftX"
    private static let topLeftYKey = "runway.settings.topLeftY"
    /// Opening guess for a pane that has never reported its content height.
    private static let defaultContentHeight: CGFloat = 440
    private static let minimumContentHeight: CGFloat = 140

    init(
        container: AppContainer,
        updater: UpdaterController,
        defaults: UserDefaults = .standard,
        activation: ActivationPolicyCoordinator = .shared
    ) {
        self.container = container
        self.updater = updater
        self.defaults = defaults
        self.activation = activation
        self.selectedPane = defaults.string(forKey: Self.paneKey)
            .flatMap(SettingsPane.init(rawValue:)) ?? .general
        super.init()
    }

    /// Shows the window, creating it on first use.
    ///
    /// Plain `activate(ignoringOtherApps:)` is unreliable for this dockless accessory app while
    /// another app is frontmost (sparkle-project/Sparkle#2889 — the same limitation `MenuBarPanel`
    /// documents): the window can order in behind the frontmost app or never become key, killing
    /// Esc/⌘W and the shortcut recorder. So Settings holds a foreground promotion via the shared
    /// `ActivationPolicyCoordinator` for the window's lifetime (a Dock icon shows while Settings is
    /// open, like during an update session); `windowWillClose` releases the hold, and the
    /// coordinator restores the accessory policy once no other surface (a live Sparkle update
    /// window) still needs the front.
    func show() {
        if window == nil {
            buildWindow()
        }
        guard let window else { return }
        activation.acquire(.settingsWindow, reason: "settings window opened")
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Window construction

    private func buildWindow() {
        let hosting = NSHostingController(rootView: paneRoot(selectedPane))
        // The controller owns all sizing (remembered per-pane heights + the content-height callback);
        // letting the hosting controller also push its ideal size would fight that single owner.
        hosting.sizingOptions = []
        self.hosting = hosting

        let window = SettingsWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: SettingsPaneHost.contentWidth,
                height: rememberedHeight(for: selectedPane)
            ),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // A settings window has nothing to restore (its state is UserDefaults), and the restoration
        // machinery would keep the closed window alive — defeating the close-means-teardown design.
        window.isRestorable = false
        window.delegate = self
        window.title = selectedPane.title
        window.contentViewController = hosting
        // Follows the app-wide theme override automatically: `AppearanceSetting.applyCurrent()` sets
        // `NSApp.appearance`, which every regular window inherits (only the popover panel needs the
        // explicit per-window pin).

        let toolbar = NSToolbar(identifier: "RunwaySettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        toolbar.selectedItemIdentifier = selectedPane.toolbarItemIdentifier

        self.window = window
        // Fresh window, fresh animation state — a stale target from a previous window's life would
        // make the dedupe guard skip this first sizing.
        targetContentHeight = 0
        setContentHeight(rememberedHeight(for: selectedPane), animated: false)
        if let topLeft = savedTopLeft() {
            window.setFrameTopLeftPoint(topLeft)
            // The saved point can sit too low for this pane's height (or come from a rearranged
            // display) — order-front only keeps the title bar visible, not the bottom controls.
            window.setFrame(constrainedToScreen(window.frame), display: false)
        } else {
            window.center()
        }
        AppLog.info(.statusItem, "Settings window opened (pane: \(selectedPane.rawValue))")
    }

    private func paneRoot(_ pane: SettingsPane) -> AnyView {
        AnyView(
            SettingsPaneHost(pane: pane) { [weak self] height in
                self?.paneContentHeightChanged(pane, height)
            }
            .environment(container)
            .environment(updater)
        )
    }

    // MARK: - Pane selection

    @objc private func selectPane(_ sender: NSToolbarItem) {
        guard let pane = SettingsPane(rawValue: sender.itemIdentifier.rawValue),
              pane != selectedPane else { return }
        selectedPane = pane
        defaults.set(pane.rawValue, forKey: Self.paneKey)
        guard let window, let hosting else { return }
        window.title = pane.title
        // AppKit only tracks selection for genuine toolbar clicks; pin it so a programmatic
        // selection (or any missed click bookkeeping) can't leave the highlight on the old pane.
        window.toolbar?.selectedItemIdentifier = pane.toolbarItemIdentifier
        hosting.rootView = paneRoot(pane)
        // Resize to the pane's remembered height immediately (System Settings-style animated frame
        // change); the content-height callback then corrects it only if the content changed since the
        // pane was last shown.
        setContentHeight(rememberedHeight(for: pane), animated: true)
    }

    // MARK: - Sizing

    /// The pane's content reported its intrinsic height (initial layout or an in-pane change like an
    /// error notice or the iCloud device list appearing). Remember it and follow it.
    private func paneContentHeightChanged(_ pane: SettingsPane, _ height: CGFloat) {
        guard pane == selectedPane, height > 1 else { return }
        // Remember the RAW measured height — the screen cap belongs to whatever display the window
        // is on when it's applied (`setContentHeight`/`rememberedHeight` clamp at use time), so a
        // height capped by a small display can't stick after moving to a larger one.
        defaults.set(Double(height), forKey: Self.heightKey(for: pane))
        // The geometry callback can fire inside a SwiftUI layout pass; resizing the window there
        // would re-enter the same layout. Defer one runloop turn — on a plain open the remembered
        // height already matches and the deferred call is a no-op.
        Task { @MainActor [weak self] in
            self?.setContentHeight(height, animated: true)
        }
    }

    /// The content height the window is at or currently animating toward. Deduping retargets against
    /// this — never against the live frame, which sits mid-flight during an animation — is what keeps
    /// a follow-up measurement with the same value from restarting the resize partway through (the
    /// visible stutter this replaces).
    private var targetContentHeight: CGFloat = 0

    /// Resizes the window's content region, keeping the top-left corner fixed like every macOS
    /// settings window. Animated resizes ride `NSAnimationContext` + `animator()` — the non-blocking,
    /// eased window animation — not the legacy `setFrame(_:display:animate:)`, whose linear blocking
    /// NSAnimation visibly stutters with a SwiftUI hosting view re-laying out on every step. A new
    /// target arriving mid-animation retargets the same animator smoothly instead of snapping.
    private func setContentHeight(_ height: CGFloat, animated: Bool) {
        guard let window else { return }
        let clamped = clampedContentHeight(height)
        guard abs(clamped - targetContentHeight) > 0.5 else { return }
        targetContentHeight = clamped
        let contentRect = NSRect(
            origin: .zero,
            size: NSSize(width: SettingsPaneHost.contentWidth, height: clamped)
        )
        var frame = window.frameRect(forContentRect: contentRect)
        // Top-left anchored, like every macOS settings window — then constrained so the grown bottom
        // edge can't land below the usable screen (AppKit does not constrain programmatic setFrame,
        // and a non-resizable window with off-screen controls is unusable until dragged).
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        frame = constrainedToScreen(frame)
        if animated, window.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }

    /// Caps a pane at the display's usable height; past the cap the pane's own scroll view takes
    /// over. The title bar + toolbar chrome is measured exactly (a zero-height content rect's frame
    /// is pure chrome), so a maxed-out pane still fits the whole window on screen.
    private func clampedContentHeight(_ raw: CGFloat) -> CGFloat {
        let visible = (window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let chrome = window.map {
            $0.frameRect(forContentRect: NSRect(
                origin: .zero,
                size: NSSize(width: SettingsPaneHost.contentWidth, height: 0)
            )).height
        } ?? 100
        return min(max(raw, Self.minimumContentHeight), visible - chrome)
    }

    /// Shifts a frame back inside the usable screen: lifts it when its bottom would fall below the
    /// visible area (a taller pane on a low-positioned window), keeps the title bar under the menu
    /// bar, and pulls it back horizontally (a saved position from a disconnected or rearranged
    /// display would otherwise reopen the non-resizable window fully off-screen — AppKit's
    /// order-front constraint doesn't cover X). Height is already capped to fit; on a display
    /// narrower than the window the left edge wins.
    private func constrainedToScreen(_ rawFrame: NSRect) -> NSRect {
        guard let visible = (window?.screen ?? NSScreen.main)?.visibleFrame else { return rawFrame }
        var frame = rawFrame
        if frame.minY < visible.minY {
            frame.origin.y = visible.minY
        }
        if frame.maxY > visible.maxY {
            frame.origin.y = visible.maxY - frame.height
        }
        frame.origin.x = max(min(frame.minX, visible.maxX - frame.width), visible.minX)
        return frame
    }

    private func rememberedHeight(for pane: SettingsPane) -> CGFloat {
        let stored = defaults.double(forKey: Self.heightKey(for: pane))
        return stored > 0 ? clampedContentHeight(CGFloat(stored)) : Self.defaultContentHeight
    }

    private static func heightKey(for pane: SettingsPane) -> String {
        "runway.settings.height.\(pane.rawValue)"
    }

    // MARK: - Position memory

    private func savedTopLeft() -> NSPoint? {
        guard defaults.object(forKey: Self.topLeftXKey) != nil,
              defaults.object(forKey: Self.topLeftYKey) != nil else { return nil }
        return NSPoint(
            x: defaults.double(forKey: Self.topLeftXKey),
            y: defaults.double(forKey: Self.topLeftYKey)
        )
    }

    // MARK: - NSWindowDelegate

    /// The height cap belongs to the display, so dragging the open window onto a different (e.g.
    /// shorter) screen re-derives the current pane's height there — otherwise a window sized on a
    /// tall display would keep its bottom controls stranded past a shorter display's edge, with the
    /// pane's scroll view none the wiser. Un-animated: this fires mid-drag, and an animation would
    /// fight the user's hand.
    func windowDidChangeScreen(_ notification: Notification) {
        setContentHeight(rememberedHeight(for: selectedPane), animated: false)
    }

    /// The whole point of the teardown: a closed Settings window keeps no SwiftUI tree, no hosting
    /// view, and no window — reopening rebuilds one pane from the live stores in a few milliseconds.
    func windowWillClose(_ notification: Notification) {
        guard let window else { return }
        defaults.set(Double(window.frame.minX), forKey: Self.topLeftXKey)
        defaults.set(Double(window.frame.maxY), forKey: Self.topLeftYKey)
        // Undo `show()`'s promotion. The coordinator only drops to `.accessory` once no other
        // surface (a live Sparkle update window) still holds the front.
        activation.release(.settingsWindow)
        window.delegate = nil
        // Release outside the delegate callback — deallocating an NSWindow while AppKit is still
        // unwinding its close is the classic over-release crash. Detach the content controller and
        // toolbar first: the AppKit↔SwiftUI bridge otherwise keeps the closed window (and the whole
        // pane tree) alive, which is exactly the idle cost this window exists to avoid.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.window?.toolbar = nil
            self.window?.contentViewController = nil
            self.hosting = nil
            self.window = nil
        }
    }

    // MARK: - NSToolbarDelegate

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let pane = SettingsPane(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.systemSymbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(selectPane(_:))
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.toolbarItemIdentifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
}

private extension SettingsPane {
    var toolbarItemIdentifier: NSToolbarItem.Identifier {
        NSToolbarItem.Identifier(rawValue)
    }
}
