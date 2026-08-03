import AppKit
import Observation

/// Owns the menu-bar strip's render loop, split out of `StatusItemController`: render the pinned-metrics
/// strip and re-render whenever anything it reads changes (pins, live data, meter style, menu-bar style).
///
/// `withObservationTracking`'s `onChange` is one-shot, so each render re-arms it. After the first change,
/// the next render waits briefly so a burst of snapshot writes collapses into one render with the latest
/// values — avoiding enough repeated work to make the menu-bar item disappear during a busy refresh.
@MainActor
final class StatusItemImageUpdater {
    private let container: AppContainer
    private let gate: StatusItemPresentationGate

    /// - Parameter apply: sets the rendered image and native tooltip regions onto the status item.
    ///   Returns `false` when the status button wasn't available, so the presentation is re-sent on
    ///   the next update instead of being remembered as applied.
    init(container: AppContainer, apply: @escaping (MenuBarStripPresentation) -> Bool) {
        self.container = container
        self.gate = StatusItemPresentationGate(apply: apply)
    }

    /// Render now and re-arm on the next observable change.
    func update() {
        let presentation = withObservationTracking {
            renderButtonPresentation()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleDelayedUpdate()
            }
        }
        gate.submit(presentation)
    }

    /// Re-applies even an unchanged presentation on the next `update()` — for when AppKit rebuilds
    /// the status button (the notch rescue's autosave bounce) and the applied image is gone.
    func forceNextApply() {
        gate.invalidate()
    }

    /// The observation callback fires only once until `update()` reads and re-arms it. Waiting here lets
    /// any immediately-following writes land first; the eventual render then reads their latest values.
    private func scheduleDelayedUpdate() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.update()
        }
    }

    /// The pinned-metrics strip in the chosen style, or the app icon when nothing is pinned.
    private func renderButtonPresentation() -> MenuBarStripPresentation {
        // Screen-share privacy: while a capture is active (and the setting is on), the strip is
        // replaced with the wordmark so a shared screen never carries usage numbers. Read inside the
        // observation closure so the render re-arms on capture-state changes too.
        if container.privacy.concealUsage {
            let image = MenuBarStripRenderer.privacyImage
                ?? MenuBarIcon.image
                ?? MenuBarStripRenderer.fallbackIcon
            return MenuBarStripPresentation(image: image, toolTipRegions: [])
        }
        let content = MenuBarContentBuilder.build(
            groups: container.layout.pinnedGroups,
            data: { container.dataStore.data(for: $0) },
            title: { container.displayName(for: $0) }
        )
        if let presentation = MenuBarStripRenderer.presentation(
            for: content,
            style: container.layout.menuBarStyle
        ) {
            return presentation
        }
        let image = MenuBarIcon.image ?? MenuBarStripRenderer.fallbackIcon
        return MenuBarStripPresentation(image: image, toolTipRegions: [])
    }
}

/// Gates presentations on their way to AppKit: forwards one only when it differs from the last one
/// actually applied. Re-applying is not free — every apply re-registers the native tooltip tags and
/// runs a layout pass on the status button — and most coalesced renders change nothing visible.
///
/// Image comparison is by instance, not by bitmap: `MenuBarStripRenderer` memoizes and returns the
/// identical `NSImage` for unchanged content, and the privacy/fallback images are singletons, so
/// identity is a complete "unchanged" signal.
@MainActor
final class StatusItemPresentationGate {
    private let apply: (MenuBarStripPresentation) -> Bool
    private var lastApplied: MenuBarStripPresentation?

    init(apply: @escaping (MenuBarStripPresentation) -> Bool) {
        self.apply = apply
    }

    func submit(_ presentation: MenuBarStripPresentation) {
        if let lastApplied,
           lastApplied.image === presentation.image,
           lastApplied.toolTipRegions == presentation.toolTipRegions {
            return
        }
        if apply(presentation) {
            lastApplied = presentation
        }
    }

    /// Forgets the applied state so the next `submit` re-applies even an unchanged presentation.
    func invalidate() {
        lastApplied = nil
    }
}
