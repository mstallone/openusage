import AppKit
import SwiftUI

/// Watches the status item for notch occlusion and, while the item is effectively hidden, shows a
/// small surrogate pill just below the menu bar at the nearest visible notch edge so the app stays
/// reachable (clicking the pill opens the dashboard). There is no API to move the status item
/// itself — its x is dictated by the neighbors to its right — so a visible stand-in is the only
/// way to keep an entry point on screen.
///
/// The pill is a borderless non-activating panel like the dashboard's `MenuBarPanel`, but it never
/// needs to become key: it only forwards a click. It hides again the moment the status item comes
/// back out of the notch (the user quit another menu-bar app, changed displays, …).
@MainActor
final class StatusItemOcclusionMonitor {
    /// Gap between the notch edge and the pill, and between the menu bar and the pill's top.
    private static let edgeGap: CGFloat = 6
    private static let topGap: CGFloat = 4
    /// The menu bar only reflows on external events (apps adding/removing items) that AppKit does
    /// not announce, so a slow poll backstops the screen-parameters observer.
    private static let pollInterval: Duration = .seconds(30)

    private let statusItem: NSStatusItem
    private let onActivate: () -> Void

    private var pill: NSPanel?
    private var screenObserver: NSObjectProtocol?
    private var pollTask: Task<Void, Never>?
    /// True while the dashboard panel is open — the pill would sit exactly under it.
    private var suppressed = false
    private var dismissedUntilRelaunch = false
    /// Keeps the pill where the user dragged it for the lifetime of one occlusion episode.
    private var hasPositionedPill = false
    /// One self-rescue per occlusion episode: the rescue rewrites the item's preferred position and
    /// re-adds it, so retrying in a loop would fight the menu bar (and the user).
    private var hasAttemptedRescue = false
    private(set) var currentOcclusion: NotchGeometry.Occlusion?

    /// - Parameters:
    ///   - onActivate: opens the dashboard (a pill click).
    ///   - onRescue: asked once per occlusion episode to move the status item back into view;
    ///     the monitor re-measures shortly after and only shows the pill if the item is still hidden.
    init(
        statusItem: NSStatusItem,
        onActivate: @escaping () -> Void,
        onRescue: @escaping (NotchGeometry.Occlusion) -> Void
    ) {
        self.statusItem = statusItem
        self.onActivate = onActivate
        self.onRescue = onRescue
    }

    private let onRescue: (NotchGeometry.Occlusion) -> Void

    func start() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // New screen geometry invalidates any earlier pill placement (including a user
                // drag): a display swap or resolution change can leave the old frame beside a notch
                // that moved, or entirely offscreen. Let the next show re-derive it.
                self.hasPositionedPill = false
                self.recheck()
            }
        }
        pollTask = Task { @MainActor [weak self] in
            // First check waits a beat so the menu bar finishes placing the new item.
            try? await Task.sleep(for: .seconds(2))
            while !Task.isCancelled {
                guard let self else { return }
                self.recheck()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    /// Hides the pill while the dashboard panel is open and re-evaluates once it closes.
    func setSuppressed(_ value: Bool) {
        suppressed = value
        if value {
            pill?.orderOut(nil)
        } else {
            recheck()
        }
    }

    func recheck() {
        // Every entry point funnels here, so gate the whole fallback in one place: `start()` is
        // already conditional, but `setSuppressed(false)` runs on every panel close regardless —
        // without this guard, macOS 27+ (native overflow management) could still trigger a rescue
        // or pill for an item the system is presenting behind its chevron.
        guard NotchGeometry.fallbackIsNeeded else { return }
        guard let occlusion = measureOcclusion(), occlusion.isEffectivelyHidden else {
            if currentOcclusion != nil {
                AppLog.info(.statusItem, "Status item is visible again")
            }
            currentOcclusion = nil
            hasPositionedPill = false
            hasAttemptedRescue = false
            pill?.orderOut(nil)
            return
        }
        let entering = currentOcclusion == nil
        currentOcclusion = occlusion
        if entering {
            AppLog.warn(
                .statusItem,
                "Status item is \(Int(occlusion.hiddenFraction * 100))% behind the notch"
            )
        }
        // First response: ask the controller to move the item back into the visible menu bar, then
        // re-measure after the menu bar reflows. The pill only appears if the rescue didn't stick.
        if !hasAttemptedRescue {
            hasAttemptedRescue = true
            onRescue(occlusion)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                self?.recheck()
            }
            return
        }
        guard !suppressed, !dismissedUntilRelaunch else { return }
        showPill(for: occlusion)
    }

    // MARK: - Measurement

    private func measureOcclusion() -> NotchGeometry.Occlusion? {
        guard
            let button = statusItem.button,
            let window = button.window,
            let screen = window.screen,
            let notch = NotchGeometry.notchRect(of: screen)
        else { return nil }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        return NotchGeometry.occlusion(of: rect, notch: notch)
    }

    // MARK: - Pill

    private func showPill(for occlusion: NotchGeometry.Occlusion) {
        let pill = self.pill ?? makePill()
        self.pill = pill
        if !hasPositionedPill,
           let screen = statusItem.button?.window?.screen,
           let notch = NotchGeometry.notchRect(of: screen) {
            let size = pill.contentView?.fittingSize ?? NSSize(width: 110, height: 26)
            let x: CGFloat = switch occlusion.nearestVisibleEdge {
            case .left: occlusion.nearestVisibleEdgeX - size.width - Self.edgeGap
            case .right: occlusion.nearestVisibleEdgeX + Self.edgeGap
            }
            let y = notch.minY - Self.topGap - size.height
            pill.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: false)
            hasPositionedPill = true
        }
        pill.orderFrontRegardless()
    }

    private func makePill() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = FirstMouseHostingView(rootView: SurrogatePillView(
            onActivate: { [weak self] in self?.onActivate() },
            onDismiss: { [weak self] in self?.dismissUntilRelaunch() }
        ))
        return panel
    }

    private func dismissUntilRelaunch() {
        dismissedUntilRelaunch = true
        pill?.orderOut(nil)
        AppLog.info(.statusItem, "Surrogate pill hidden until relaunch by the user")
    }
}

/// Hosting view for the pill that accepts first-mouse: another app is almost always active (this
/// is an accessory app), and a stock `NSHostingView` in a nonactivating panel can swallow the first
/// click as window activation before the SwiftUI action runs — the same AppKit behavior
/// `NativeMenuButton` overrides for the footer's gear menu.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The pill's face: just the brand glyph in a small capsule — the status item's stand-in, so it
/// reads (and takes space) like a menu-bar icon, not a widget. Click opens the dashboard; the
/// context menu offers a way out for users who'd rather live with the hidden status item.
///
/// A real `Button`, not a tap gesture: VoiceOver announces it with a name and button role — this
/// pill is the only visible recovery entry point while the status item is hidden, so assistive
/// tech must be able to find and activate it.
private struct SurrogatePillView: View {
    let onActivate: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onActivate) {
            Group {
                if let icon = MenuBarIcon.image {
                    Image(nsImage: icon)
                        .renderingMode(.template)
                } else {
                    Text("Runway")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(.primary)
            .padding(6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Runway")
        // The hosting view's fittingSize sizes the pill window; without this the content reports
        // its compressed size and clips.
        .fixedSize()
        .contextMenu {
            Button("Hide Until Relaunch", action: onDismiss)
        }
    }
}
