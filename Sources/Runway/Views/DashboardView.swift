import SwiftUI

/// The popover content: the provider/metric list (or the Customize screen) as a scroll view between
/// fixed chrome — a top back/title bar on Customize and bottom identity/action chrome on the
/// dashboard. (Settings is not a popover screen; it lives in its own window, see
/// `SettingsWindowController`.)
///
/// The chrome is fixed: it's keyed off `layout.screen` and applied uniformly in `screenView`. A screen
/// switch mounts only its destination and gives it a short directional entrance; keeping the outgoing
/// tree alive for a full-width pager doubled the expensive dashboard/Settings layouts during every
/// transition. Each screen's scroll
/// content underlaps the footer with the native soft scroll-edge fade (`softBottomScrollEdge` →
/// `.scrollEdgeEffectStyle(.soft)`, macOS 26+) — Apple's blurred boundary, not a custom gradient or a
/// material bar. On macOS 15 the footer/top bar still pin via `safeAreaInset`, just without the blur
/// (content scrolls flush). The panel **auto-fits its content**: each screen reports its intrinsic
/// height (`PopoverScrollView` → `PanelHeightCoordinator`, plus the fixed chrome heights), and the visual panel — a height-framed,
/// corner-clipped card pinned to the top of a fixed-size transparent window (see
/// `PanelHeightController`) — animates to that on SwiftUI's clock, with the AppKit backdrop following
/// via `drivesPanelHeight` / `PanelHeightModifier`. The destination is the only live screen tree
/// during a switch, and its height morph rides the same spring as its entrance. Scroll views take
/// over once content exceeds the screen-height cap.
struct DashboardView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(PopoverTransparencyStore.self) private var transparency
    @Environment(UpdaterController.self) private var updater
    @State private var reorderLift: ReorderLift?
    /// The visual panel height SwiftUI drives — the single animation clock. The height frame below
    /// animates the panel itself, and `PanelHeightModifier` follows the same value frame-by-frame onto
    /// the AppKit backdrop, so both ride the same spring as the screen entrance. 0 means "not
    /// established yet": the panel renders at the controller's opening guess until the first
    /// measurement lands, then we snap un-animated.
    @State private var animatedHeight: CGFloat = 0
    /// Whether `animatedHeight` has been seeded for this open. Until then the first measurement (or a
    /// reopen) establishes it without animation; afterwards, changes spring.
    @State private var didEstablishHeight = false
    /// Popover auto-fit height computation: per-screen measured pieces summed into each screen's clamped
    /// morph target (`heightCoordinator.measuredIdeal` / `.target(for:)`). Written from the geometry
    /// actions below. The animation itself — `animatedHeight`, the slide, the `withAnimation` spring —
    /// stays in this view; the coordinator holds only the deterministic measurement.
    @State private var heightCoordinator = PanelHeightCoordinator(
        topBarHeight: Self.topBarHeight,
        footerHeight: Self.footerHeight
    )
    /// Horizontal screen-switch slide: 0 shows the outgoing screen, 1 the incoming one. Drives the
    /// page offset so the screens slide between modes on one spring.
    @State private var slideProgress: CGFloat = 1
    /// The `layout.screenSlideID` whose slide has begun animating. Until it catches up to the store's
    /// id, a freshly-started transition pins to the outgoing screen so the first frame never flashes
    /// the destination.
    @State private var animatedSlideID = 0
    /// Reset to the top whenever the popover closes, so it never reopens mid-scroll.
    @State private var dashboardScrollPosition = ScrollPosition(edge: .top)
    /// Measured expanded-section height per provider, learned from the first expand's measurement.
    /// Lets later caret toggles co-animate the panel height in the SAME transaction as the row change
    /// (one spring clock — no footer catch-up); a provider's first toggle uses a row-count estimate
    /// and the measurement that follows issues a small same-spring correction. Keyed by the
    /// provider's expanded-section *composition* (`expansionDeltaKey`), so customizing what sits
    /// behind the caret misses the cache and re-learns instead of retargeting by a stale height.
    @State private var expansionDeltas: [String: CGFloat] = [:]
    /// The composition key whose caret toggle is awaiting its measurement, with the pre-toggle target
    /// the actual delta is derived from. Cleared when the dashboard measurement settles.
    @State private var pendingExpansion: (cacheKey: String, fromTarget: CGFloat)?
    /// Debounce for measurement-driven re-targets: armed on every `measuredIdeal` change while the
    /// popover is shown, fired ~2 quiet frames after the last one (see the `onChange` below).
    @State private var measurementSettleTask: Task<Void, Never>?
    /// Drives the macOS-native confirmation sheet for the Customize "reset all" button. The alert
    /// attaches to this panel as a sheet (see `StatusItemController`'s attached-sheet guard), so a
    /// click on its buttons can't be misread as an outside click that dismisses the popover.
    @State private var isPresentingResetAllConfirm = false
    /// Shared horizontal inset for dashboard content and fixed chrome.
    private static let outerPadding: CGFloat = 14
    /// Breathing room between the bottom of the scrolling content and the pinned footer. Kept small
    /// because the native scroll edge effect — not whitespace — provides the visual separation.
    private static let contentBottomGap: CGFloat = 12
    /// Footer content starts at the same standard padding as the provider containers.
    private static let footerHorizontalPadding: CGFloat = outerPadding
    private static let reorderSpace = "popoverReorderSpace"
    /// The popover keeps a fixed width while its compact layout auto-fits vertically.
    private static let popoverWidth: CGFloat = 320
    /// Fixed height of the Customize back nav bar — the bar pins itself to exactly this height.
    private static let topBarHeight: CGFloat = 44
    /// Fixed height of the footer bar (dashboard only; Customize shows none). Like the top bar, the
    /// footer is fixed-height chrome: the height coordinator sums this constant into each screen's
    /// morph target, the scroll spacer reserves it, and the overlay bar fills it.
    private static let footerHeight: CGFloat = 40
    /// A compact directional entrance communicates hierarchy without keeping a second full screen tree
    /// alive. The opaque popover surface fills the small uncovered strip while the page settles.
    private static let screenEntranceDistance: CGFloat = 36

    var body: some View {
        modeBody
            .frame(width: Self.popoverWidth)
            // The visual panel: exactly `animatedHeight` tall, growing and shrinking purely inside the
            // fixed-size window (see `PanelHeightController` — the window opens at the screen-clamped
            // maximum and never resizes while open). Footer and chrome pin to this frame's bottom.
            // Until the first measurement lands, the controller's remembered opening height stands in.
            .frame(
                height: animatedHeight > 0 ? animatedHeight : MenuBarPopover.openingHeight?(),
                alignment: .top
            )
            // Paint the page surface behind the panel's content (and its footer). Opaque by default so
            // the popover reads as one solid panel; under Increase Transparency / the egg it clears so
            // the behind-window backdrop (or party gradient) shows through. Inside the height frame so
            // it covers exactly the visual panel — never the window's transparent remainder.
            .background(PopoverSurface())
            // The easter egg's visuals hug the visual panel (and get clipped to its rounded shape
            // below), so party/drunk layers can't paint into the window's transparent remainder.
            .tooMuchTransparency(transparency.effectiveStyle)
            // Inside the clip below, so a drag that wanders past the panel's bottom edge clips the
            // floating chip at the edge (as the window bounds used to) instead of rendering it into
            // the fixed window's transparent remainder. Same origin as the outer fill — the panel is
            // top-aligned at the window's top-left — so the lift's reorder-space coordinates line up.
            .overlay(alignment: .topLeading) {
                if let reorderLift {
                    ReorderLiftPreview(lift: reorderLift)
                }
            }
            // Round the visual panel itself. The host layer's mask only rounds the window bounds, which
            // only coincide with the panel when the content happens to fill the whole window.
            .clipShape(RoundedRectangle(cornerRadius: StatusItemController.cornerRadius, style: .continuous))
            // Top-pin the panel in the window-filling root: the hosting view centers an undersized
            // root, so without this the panel would float mid-window.
            .frame(maxHeight: .infinity, alignment: .top)
            // Drive the backdrop's height on SwiftUI's clock. At the body root, outside `modeBody`'s
            // structural-animation suppression, so it can ride the active transition spring.
            .drivesPanelHeight(animatedHeight)
            .coordinateSpace(name: Self.reorderSpace)
            .background(
                // Esc backs out of Customize first; only from the dashboard does it close the
                // popover. Return opens Customize from the dashboard (the same affordance the
                // footer's gear options menu's Customize item carries) and returns to the
                // dashboard from Customize — matching Esc and the back navigation. Always
                // consumed, so a bare Return can't fall through and dismiss the popover.
                PopoverKeyReader(
                    onEscape: {
                        // From a provider's L2 detail, back out to the L1 list first; only from L1
                        // drop to the dashboard. Pressing Esc again from L1 closes the popover.
                        if layout.customizeProviderID != nil {
                            withAnimation(Motion.spring) { layout.customizeProviderID = nil }
                            return true
                        }
                        guard layout.screen != .dashboard else { return false }
                        withAnimation(Motion.modeSwitch) { layout.screen = .dashboard }
                        return true
                    },
                    onReturn: {
                        // From a provider's L2 detail, back out to the L1 list first — matching Esc —
                        // so Return steps L2 → L1 → dashboard instead of jumping L2 → dashboard.
                        if layout.customizeProviderID != nil {
                            withAnimation(Motion.spring) { layout.customizeProviderID = nil }
                            return true
                        }
                        let target: PopoverScreen = layout.screen == .dashboard ? .customize : .dashboard
                        withAnimation(Motion.modeSwitch) { layout.screen = target }
                        return true
                    },
                    // ⌘, opens the standalone Settings window (closing the popover on the way, via
                    // the installed handler). Handled on this always-on monitor so it fires from
                    // every screen, and so the gear options menu's Settings item can carry ⌘, as a
                    // label without a second SwiftUI registration fighting it.
                    onSettings: {
                        SettingsWindowLink.open()
                        return true
                    },
                    // ⌘Z walks back the last customization step (remove/add, reorder, pin/unpin, caret
                    // move) — app-wide, since Hide and Pin happen via the dashboard's context menus too,
                    // not only in Customize. Always consumed here: by the time the monitor calls this it
                    // has already confirmed the panel owns the keystroke and no text field is editing
                    // (those keep their own ⌘Z), so returning false would only let AppKit beep on an empty
                    // undo. With nothing to undo we swallow it silently instead.
                    onUndo: {
                        guard layout.canUndo else { return true }
                        withAnimation(Motion.spring) { _ = layout.undo() }
                        return true
                    }
                )
            )
            // The controller already owns the exact show/hide moments. Reuse that signal here instead
            // of asking AppKit window notifications to rediscover the same state a second time.
            .onChange(of: transparency.popoverShown) { _, shown in
                if shown {
                    // Reopen: the SwiftUI tree survives a close, so re-seed the height for whatever
                    // screen we're opening on. Un-animated, and ≈ the controller's opening guess, so
                    // there's no visible jump. If not yet measured, the measurement onChange seeds it.
                    // Assign only on a real change: the close-time settle usually leaves the retained
                    // height already at this exact value, and a same-value write would still dirty
                    // the height frame and force a full re-layout inside the open's pre-show pass.
                    if let target = heightCoordinator.target(for: layout.screen) {
                        didEstablishHeight = true
                        if abs(animatedHeight - target) > 0.5 { animatedHeight = target }
                    }
                } else {
                    resetTransientState()
                }
            }
            // A screen switch can tear the list down mid-drag, in which case the gesture's
            // `onEnded` never fires — clear the lift here or its overlay survives onto the new
            // screen.
            .onChange(of: layout.screen) {
                reorderLift = nil
                layout.cancelDrag()
            }
            // The Reset All alert attaches to the Customize L1 nav bar. Leaving the list — back to the
            // dashboard or into a provider's L2 detail — unmounts that host, which dismisses the alert
            // but leaves `isPresentingResetAllConfirm` `true`. Drop it whenever L1 stops being visible
            // so the destructive confirmation can't reappear stale on return without a fresh tap.
            .onChange(of: layout.screen == .customize && layout.customizeProviderID == nil) { _, isL1Visible in
                if !isL1Visible { isPresentingResetAllConfirm = false }
            }
            // Each screen switch mounts the destination at its directional entrance
            // (`slideProgress = 0`), then springs it to rest on the next runloop tick. Deferring the
            // animation one tick is what makes it animate — setting 0 then 1 in the same closure
            // collapses to a no-op (SwiftUI animates from the last *committed* value).
            .onChange(of: layout.screenSlideID) { _, id in
                guard id != 0 else { return }
                slideProgress = 0
                animatedSlideID = id
                let destination = layout.screen
                Task { @MainActor in
                    // Co-animate the entrance and height on one spring. The destination is usually
                    // mounted and measured by now; if it is not, keep the current opening height and
                    // establish the real target once its measurement lands.
                    let coTarget: CGFloat? = heightCoordinator.target(for: destination)
                        ?? (animatedHeight > 0 ? animatedHeight : nil)
                    if coTarget != nil { didEstablishHeight = true }
                    withAnimation(Motion.spring, completionCriteria: .logicallyComplete) {
                        slideProgress = 1
                        if let coTarget { animatedHeight = coTarget }
                    } completion: {
                        guard let target = heightCoordinator.target(for: layout.screen) else { return }
                        if !didEstablishHeight {
                            didEstablishHeight = true
                            animatedHeight = target
                        } else if abs(target - animatedHeight) > 1 {
                            withAnimation(Motion.spring) { animatedHeight = target }
                        }
                    }
                }
            }
            // In-screen growth/shrink (a provider card expands, the footer notice appears, a refresh
            // loads rows): re-target the height on the same spring — but only once the measurement
            // SETTLES. Content re-measures on every frame of an unfold morph (the rows' interpolated
            // heights land here one by one), and re-targeting per measurement thrashed the spring —
            // dozens of overlapping retargets per caret toggle, measured as the popover's worst
            // stall source — and made the delta learning below record partial mid-animation heights.
            // Establishment and the hidden-close walk stay immediate; only the animated re-target
            // (and the learning) waits for ~2 quiet frames.
            .onChange(of: heightCoordinator.measuredIdeal[layout.screen]) { _, _ in
                guard let target = heightCoordinator.target(for: layout.screen) else { return }
                if !didEstablishHeight {
                    didEstablishHeight = true
                    animatedHeight = target
                } else if !transparency.popoverShown {
                    // Hidden — this is the close-time settle's collapsed re-measure landing. Walk
                    // the retained height directly: springing a hidden panel just burns frames
                    // off-screen, and the next open expects the value to already be at rest.
                    measurementSettleTask?.cancel()
                    if abs(target - animatedHeight) > 0.5 { animatedHeight = target }
                } else {
                    measurementSettleTask?.cancel()
                    measurementSettleTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(120))
                        guard !Task.isCancelled else { return }
                        applySettledMeasurement()
                    }
                }
            }
            // Watches for the secret transparency code while the panel is key and toggles the egg. A
            // sibling of `PopoverKeyReader` that only observes (never consumes), so it can't disturb
            // navigation or typing.
            .background(TooMuchTransparencyKeyReader { transparency.toggleSecretCode() })
            // Installed for the provider cards' expand carets: retargets the panel height inside the
            // caret's own `withAnimation`, so rows, panel edge, and footer share one spring clock.
            .onAppear {
                MenuBarPopover.coAnimateExpansion = { providerID, expanding in
                    guard didEstablishHeight, animatedHeight > 0, layout.screen == .dashboard else { return }
                    let fromIdeal = heightCoordinator.measuredIdeal[.dashboard] ?? animatedHeight
                    let key = expansionDeltaKey(for: providerID)
                    let delta = expansionDeltas[key] ?? estimatedExpansionDelta(for: providerID)
                    pendingExpansion = (key, fromIdeal)
                    let ideal = fromIdeal + (expanding ? delta : -delta)
                    // Plain assignment: this runs inside the caret's `withAnimation(Motion.spring)`, so
                    // the change rides that same transaction. The measurement that follows only issues
                    // a correction when the delta was off (a provider's first-ever toggle).
                    animatedHeight = MenuBarPopover.clampHeight?(ideal) ?? ideal
                }
            }
            // Reaches `modeBody`, the `PopoverSurface` background, the `.tooMuchTransparency` egg layers
            // (applied on the visual panel above), and every card: drives whether surfaces paint their
            // opaque base or clear to the behind-window vibrancy backdrop.
            .environment(\.popoverSurfaceTreatment, transparency.surfaceTreatment)
            // Gate the egg's animation loops on whether the popover is on-screen. Applied outside
            // `.tooMuchTransparency` so it reaches both the gradient/rim/drunk layers that modifier adds
            // and the in-content `partyPulse`. Hidden → the loops unmount their `TimelineView` clocks, so a
            // left-on egg spends no CPU; a fresh mount on reopen / in-place activation starts them at once.
            // Sourced from the controller's show/hide chokepoints (`popoverShown`), not occlusion — a
            // `.canJoinAllSpaces` panel is briefly occluded mid Space-switch while still on-screen.
            .environment(\.popoverIsVisible, transparency.popoverShown)
    }

    /// Ties a learned delta to the provider's current expanded-section composition: the ordered On
    /// Demand metric IDs (order matters — adjacent text rows condense) plus quick-links presence.
    /// Customizing what sits behind the caret changes the key, so a stale height can't retarget the
    /// first post-customization toggle; the estimate covers that toggle and the measurement re-learns.
    private func expansionDeltaKey(for providerID: String) -> String {
        guard let group = layout.displayGroups.first(where: { $0.provider.id == providerID }) else {
            return providerID
        }
        let metricIDs = group.expandedWidgets.compactMap { layout.descriptor(for: $0)?.id }
        let links = group.provider.visibleLinks.isEmpty ? "" : "|links"
        return "\(providerID)|\(metricIDs.joined(separator: ","))\(links)"
    }

    /// First-toggle guess for a provider's expanded-section height: its On Demand rows at the compact
    /// row estimate, plus a quick-links row when present. The real measurement replaces this within a
    /// couple of frames (with a small same-spring correction) and is remembered exactly afterwards.
    private func estimatedExpansionDelta(for providerID: String) -> CGFloat {
        guard let group = layout.displayGroups.first(where: { $0.provider.id == providerID }) else {
            return 0
        }
        let rows = CGFloat(group.expandedWidgets.count) * DensitySetting.compact.estimatedMetricRowHeight
        let links: CGFloat = group.provider.visibleLinks.isEmpty ? 0 : 40
        return rows + links
    }

    /// The debounced tail of the measurement `onChange`: runs once the screen's content measurement
    /// has gone quiet, learns a pending caret toggle's exact expanded-section height from the settled
    /// value, and issues at most ONE spring re-target for the whole morph.
    private func applySettledMeasurement() {
        guard let target = heightCoordinator.target(for: layout.screen) else { return }
        // A caret toggle's measurement just settled: learn the provider's exact expanded-section
        // height so the NEXT toggle co-animates with zero correction.
        if let pending = pendingExpansion, layout.screen == .dashboard,
           let ideal = heightCoordinator.measuredIdeal[.dashboard] {
            expansionDeltas[pending.cacheKey] = abs(ideal - pending.fromTarget)
            pendingExpansion = nil
        }
        // Mid-slide the switch path's completion owns the target; deferring here matches the old
        // per-measurement guard.
        guard !isSliding, abs(target - animatedHeight) > 1 else { return }
        withAnimation(Motion.spring) { animatedHeight = target }
    }

    private func resetTransientState() {
        // Backstop for any popover-close path the status-item controller's hide doesn't cover: clear a
        // tooltip the cursor was resting on, since the closed popover fires no hover-exit. The Usage
        // Trend hover popover rides the same backstop.
        HoverTooltips.dismissAll()
        HoverPopoverState.dismissAll()
        if layout.screen != .dashboard { layout.screen = .dashboard }
        reorderLift = nil
        layout.cancelDrag()
        // A "Copied to clipboard" pill mid-countdown would otherwise reappear stale on the next open,
        // since the layout store survives the popover and only the timer clears it.
        layout.clearShareConfirmation()
        layout.clearCustomizationNotice()
        // Dismiss a pending Reset All confirmation if the popover closes mid-alert — the SwiftUI tree
        // survives `orderOut`, so without this the sheet would reappear stale on the next open.
        isPresentingResetAllConfirm = false
        // A debounce armed just before the close would otherwise fire ~120ms after `orderOut` and
        // spring a hidden panel (per-frame layout and backdrop work with nothing on screen). The
        // close-time settle re-measures the collapsed tree anyway, and its hidden-branch walk
        // handles the height directly.
        measurementSettleTask?.cancel()
        measurementSettleTask = nil
        // A caret toggle whose measurement never settled must not learn from the close: the next
        // (collapsed) measurement would record a wrong — even zero — expanded-section delta and the
        // provider's next caret toggle would co-animate to a bogus height until re-learned.
        pendingExpansion = nil
        // The driven height is deliberately KEPT across the close (it used to reset to the 0
        // sentinel here). The close-time settle re-measures the collapsed dashboard while hidden and
        // the `measuredIdeal` onChange walks the retained value to the collapsed target, so the next
        // open finds the height already correct and its pre-show layout pass has nothing to do —
        // resetting to 0 made every reopen pay a full-tree re-layout just to walk 0 → target. The
        // reopen seed above and the measurement onChange below still correct it (un-animated) if the
        // screen or content changed while closed.
        dashboardScrollPosition.scrollTo(edge: .top)
    }

    /// The popover keeps exactly one live screen tree. On a switch the destination's scrolling body
    /// enters from the direction implied by `slideRank`, but the fixed chrome stays in place and the
    /// outgoing screen is removed immediately instead of remaining mounted beside it. Customize and
    /// the dashboard are both substantial trees; the former two-page pager made SwiftUI update,
    /// measure, and draw both throughout the window morph.
    ///
    /// Why an offset and not a SwiftUI `.transition`: the cards' fill is translucent `.quaternary`
    /// glass. Any transition carrying `.opacity` composites a screen into a transparency layer where
    /// that material has no vibrant backdrop to sample and resolves to its opaque near-white base — a
    /// white flash across the grey cards (the regression this removes; it has no clean SwiftUI fix).
    /// A pure offset never touches opacity, so the glass keeps sampling the live popover backdrop.
    /// `.animation(nil, value:)` stops the structural screen replacement from inheriting the caller's
    /// mode-switch animation — only `slideProgress` animates the destination's offset.
    private var modeBody: some View {
        screenView(layout.screen)
            .frame(width: Self.popoverWidth)
            .frame(maxHeight: .infinity, alignment: .top)
        .animation(nil, value: layout.screenSlideID)
    }

    /// True from the moment `layout.screen` changes until the slide reaches the incoming screen.
    private var isSliding: Bool {
        layout.screenSlideID != 0
            && (layout.screenSlideID != animatedSlideID || slideProgress < 1)
    }

    /// Starts the newly-mounted destination a short distance toward the edge it came from, then settles
    /// it at zero. Until this transition's state has committed, progress remains zero so the first frame
    /// cannot flash at its final position.
    private var screenEntranceOffset: CGFloat {
        guard isSliding else { return 0 }
        let direction: CGFloat = layout.screenSlideFrom.slideRank < layout.screen.slideRank ? 1 : -1
        let progress = animatedSlideID == layout.screenSlideID ? slideProgress : 0
        return direction * Self.screenEntranceDistance * (1 - progress)
    }

    /// Builds the one mounted screen: its entering scroll body wrapped in stationary pinned chrome.
    /// Applying the offset before the pinned modifiers keeps the top bar and footer fixed while the
    /// destination content moves. The soft scroll-edge styles and bars still attach to the screen's
    /// `PopoverScrollView`, the documented place for them.
    @ViewBuilder
    private func screenView(_ screen: PopoverScreen) -> some View {
        scrollBody(for: screen)
            .offset(x: screenEntranceOffset)
            // Auto-fit: the scroll content reports its intrinsic height (invariant to the viewport)
            // straight into `heightCoordinator`, which sums it with the chrome into this screen's
            // ideal window height — see `PopoverScrollView` for why it's not a preference.
            .softTopScrollEdge()
            .softBottomScrollEdge()
            .pinnedTopBar(spacing: 0) {
                PopoverTopBar(
                    layout: layout,
                    height: Self.topBarHeight,
                    horizontalPadding: Self.footerHorizontalPadding,
                    onResetAll: {
                        layout.resetToDefault()
                        container.reseedEnabledProviders()
                    },
                    isPresentingResetAllConfirm: $isPresentingResetAllConfirm
                )
            }
            .pinnedFooter(spacing: 0) {
                // The footer lives in the safe-area bar, NOT as a bottom-aligned overlay on the height
                // frame: the bar's position is re-derived from the per-frame layout of the animated
                // frame, so it hugs the panel's bottom edge on every interpolated frame of a morph. An
                // overlay's position animates as its own attribute instead — when a content change
                // lands in one transaction and the height retargets in a second (a provider appears, a
                // caret estimate gets corrected), the overlay's spring runs phase-shifted from the
                // frame growth and the footer visibly trails the edge, sliding over content to catch
                // up (verified frame-by-frame; the safe-area bar shows no such detach).
                PopoverFooter(
                    screen: layout.screen,
                    layout: layout,
                    dataStore: dataStore,
                    horizontalPadding: Self.footerHorizontalPadding,
                    height: Self.footerHeight
                )
            }
    }

    /// The scrolling content for the current screen, without chrome.
    @ViewBuilder
    private func scrollBody(for screen: PopoverScreen) -> some View {
        switch screen {
        case .dashboard:
            DashboardContentView(
                container: container,
                layout: layout,
                updater: updater,
                heightCoordinator: heightCoordinator,
                reorderSpaceName: Self.reorderSpace,
                horizontalPadding: Self.outerPadding,
                bottomGap: Self.contentBottomGap,
                reorderLift: $reorderLift,
                scrollPosition: $dashboardScrollPosition
            )
        case .customize:
            CustomizeView(
                heightCoordinator: heightCoordinator,
                reorderSpaceName: Self.reorderSpace,
                reorderLift: $reorderLift
            )
        }
    }

}

/// The popover's opaque backdrop tray, painted behind all content so the popover reads as one solid
/// panel — the data region never shows the desktop through it. Matches the AppKit panel backdrop
/// (`PopoverBackdropView`'s `NSBox`): SwiftUI uses `Theme.traySurface` here while AppKit uses the
/// matching `Theme.trayNSColor`. The footer draws its own frosted glass bar on top of this (in-window),
/// so glass stays chrome over solid content. Never hit-tests, so it can't steal clicks from the content
/// above it.
private struct PopoverSurface: View {
    @Environment(\.popoverSurfaceTreatment) private var treatment

    var body: some View {
        Group {
            switch treatment {
            case .opaque:
                Theme.traySurface
            case .translucent:
                // Clear so what's behind the page shows through: the behind-window vibrancy backdrop —
                // the blurred desktop for increased/drunk, and the same desktop tinted by the party
                // gradient for party mode.
                Color.clear
            }
        }
        .allowsHitTesting(false)
    }
}
