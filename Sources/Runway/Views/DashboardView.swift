import SwiftUI

/// The popover content: the provider/metric list (or the Customize screen) as a scroll view between
/// fixed chrome — a top back/title bar on Customize and bottom identity/action chrome on the
/// dashboard. (Settings is not a popover screen; it lives in its own window, see
/// `SettingsWindowController`.)
///
/// A screen switch plays as one connected push: the outgoing screen stays mounted — frozen at its
/// pre-switch panel size (`pages`) so the per-frame height morph can't re-layout it — and slides
/// out while the destination slides in from the opposite edge, the two tiling edge-to-edge like the
/// L1↔L2 push inside Customize, on one critically damped `Motion.push` (bounce at full-width travel
/// exposes bare tray at the panel edges). After the push the outgoing page stays PARKED offscreen,
/// so switching back needs no mount — profiling showed the destination mount was the switch's
/// dominant stall. This is not the old two-page pager (which doubled the expensive dashboard
/// layouts on every frame of every transition): the parked tree's constant size proposal keeps its
/// layout cached, and the popover-close reset unmounts it. (A `cacheDisplay` raster of the outgoing
/// screen was tried instead and reverted: rasterizing the hosting view cost 85–330ms of main-thread
/// stall on the very frame the switch started.) Each screen's scroll
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
    /// Reduce Motion: the screen-switch entrance keeps its (shortened) animation but loses its
    /// horizontal travel, so a mode switch reads as a quick fade-in-place instead of a slide.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    /// The `layout.screenSlideID` whose push has finished (its `withAnimation` completion fired).
    /// The parked page's `.disabled` keys off this, NOT off `isSliding`: state-level progress hits
    /// its target the instant the animation commits, so `isSliding` reads false while the exit
    /// slide is still visibly running — disabling on it dimmed the outgoing page's controls
    /// mid-flight.
    @State private var settledSlideID = 0
    /// The pager's mounted pages, parked-outgoing (if any) first. THE single source of truth for
    /// what `modeBody` mounts, written atomically in the slide `onChange` — deriving the list from
    /// `layout.screen` plus separate outgoing state instead let the body evaluation between a
    /// mid-flight reversal's screen change and its `onChange` see a contradictory pair (the same
    /// screen on both sides: duplicate `ForEach` IDs, and a transient unmount/remount of a page
    /// that was supposed to stay warm). Empty until the first switch of a popover session (and
    /// reset to empty on close); `pagerPages` then falls back to just the active screen.
    ///
    /// After a push settles the outgoing page is deliberately KEPT, parked fully offscreen at its
    /// frozen size: profiling showed the destination tree's mount is the switch's dominant
    /// main-thread stall (~90ms baseline), so the parked page makes every switch after a screen's
    /// first one mount-free — the pager just swaps the two pages' roles. The parked tree costs
    /// nothing per frame (constant size proposal + clipped offscreen) and unmounts with the
    /// popover-close reset.
    @State private var pages: [PagerPage] = []

    private struct PagerPage: Identifiable {
        let screen: PopoverScreen
        /// The pre-switch panel height the page froze at when it left. Set only on the parked
        /// outgoing page — doubles as its role marker in `modeBody`; nil marks the active page.
        let frozenHeight: CGFloat?
        var id: PopoverScreen { screen }
    }
    /// Reset to the top whenever the popover closes, so it never reopens mid-scroll.
    @State private var dashboardScrollPosition = ScrollPosition(edge: .top)
    /// Measured expanded-section height per provider, learned from the first expand's measurement.
    /// Lets later caret toggles co-animate the panel height in the SAME transaction as the row change
    /// (one spring clock — no footer catch-up); a provider's first toggle uses a row-count estimate
    /// and the measurement that follows issues a small same-spring correction. Keyed by the
    /// provider's expanded-section *composition* (`expansionDeltaKey`), so customizing what sits
    /// behind the caret misses the cache and re-learns instead of retargeting by a stale height.
    @State private var expansionDeltas: [String: CGFloat] = [:]
    /// The composition key whose caret toggle is awaiting its measurement, with the pre-toggle
    /// target the actual delta is derived from and the row-count estimate the settled value is
    /// sanity-checked against. Cleared when the dashboard measurement settles.
    @State private var pendingExpansion: (cacheKey: String, fromTarget: CGFloat, estimate: CGFloat)?
    /// Debounce for measurement-driven re-targets: armed on every `measuredIdeal` change while the
    /// popover is shown, fired ~2 quiet frames after the last one (see the `onChange` below).
    @State private var measurementSettleTask: Task<Void, Never>?
    /// Explicit caret-morph-in-flight marker: set by every caret toggle, cleared only when the
    /// settle actually lands (or the popover closes / the screen changes). Branch selection and
    /// learning eligibility key off THIS, not off `pendingExpansion` — a superseding toggle clears
    /// `pendingExpansion`, and inferring "clean" from that let a third rapid toggle learn from an
    /// intermediate measurement.
    @State private var expansionSettling = false
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
    /// Fallback entrance travel for the rare switch with no outgoing page to slide out beside the
    /// destination (no established height yet): a compact directional entrance still communicates
    /// hierarchy, and the popover surface fills the small uncovered strip while the page settles.
    /// With an outgoing page mounted the travel is the full panel width — see `screenEntranceOffset`.
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
            // Record the slide progress each rendered frame (identity effect, no visual change):
            // a mid-flight reversal reads it to continue the push from where the pages visibly
            // are — see the slide `onChange` and `SlideProgressEffect`.
            .modifier(SlideProgressEffect(progress: slideProgress))
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
                // The switched-away screen used to unmount here, and hover UI dismissal rode its
                // rows' `onDisappear`. A parked page never disappears, so dismiss explicitly — a
                // Usage Trend hover detail (or a tooltip) left open at switch time would otherwise
                // keep floating over the destination screen.
                HoverTooltips.dismissAll()
                HoverPopoverState.dismissAll()
                // A caret morph can't outlive its screen: leaving the dashboard mid-settle must
                // not let Customize measurements learn a delta or take the caret debounce path.
                measurementSettleTask?.cancel()
                measurementSettleTask = nil
                pendingExpansion = nil
                expansionSettling = false
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
                // Hidden — this is the close-time reset walking Customize back to the dashboard,
                // not a user navigation. There is no entrance to play and nothing on screen: commit
                // the slide state synchronously and walk the height directly, instead of spawning
                // the animation task below, whose deferred spring would re-dirty the settled hidden
                // tree AFTER `finishClosing()` cleared the display clamp — recreating exactly the
                // deferred cleanup the close-time settle exists to remove.
                guard transparency.popoverShown else {
                    animatedSlideID = id
                    settledSlideID = id
                    slideProgress = 1
                    // The hidden walk is not a push: drop any parked page so the close-time settle
                    // (not a later open) pays its unmount.
                    pages = [PagerPage(screen: layout.screen, frozenHeight: nil)]
                    if let target = heightCoordinator.target(for: layout.screen) {
                        didEstablishHeight = true
                        if abs(target - animatedHeight) > 0.5 { animatedHeight = target }
                    }
                    return
                }
                // A switch during a still-running push is always a direction flip (there are only
                // two screens), and it must continue from the pages' RENDERED positions — the
                // state-level progress hit 1 the instant the previous push committed, so only the
                // bridge knows how far it visibly got. The travel is symmetric, so seeding
                // `1 - rendered` puts both pages exactly where they are and the new push carries
                // on seamlessly instead of snapping to the edges. A settled push has rendered = 1,
                // which seeds the usual 0.
                slideProgress = 1 - min(max(SlideProgressBridge.renderedProgress(), 0), 1)
                animatedSlideID = id
                // Park the screen being left, frozen at the panel height it holds this instant
                // (`animatedHeight` is still the pre-switch value here), so it slides out beside
                // the entering destination — and stays mounted for a mount-free switch back.
                // Under Reduce Motion the switch plays as a fade in place; a second mounted tree
                // would be pure cost, so the active page stands alone.
                pages = reduceMotion || animatedHeight <= 0
                    ? [PagerPage(screen: layout.screen, frozenHeight: nil)]
                    : [
                        PagerPage(screen: layout.screenSlideFrom, frozenHeight: animatedHeight),
                        PagerPage(screen: layout.screen, frozenHeight: nil),
                    ]
                let destination = layout.screen
                Task { @MainActor in
                    // Co-animate the entrance and height on one clock. The destination is usually
                    // mounted and measured by now; if it is not, keep the current opening height and
                    // establish the real target once its measurement lands.
                    let coTarget: CGFloat? = heightCoordinator.target(for: destination)
                        ?? (animatedHeight > 0 ? animatedHeight : nil)
                    if coTarget != nil { didEstablishHeight = true }
                    withAnimation(Motion.push, completionCriteria: .logicallyComplete) {
                        slideProgress = 1
                        if let coTarget { animatedHeight = coTarget }
                    } completion: {
                        // The parked outgoing page deliberately stays mounted (see `pages`) — the
                        // settle leaves it exactly one panel-width offscreen, clipped away — but
                        // only NOW does it leave the interactive path (see the `.disabled` in
                        // `modeBody`). Recording a stale id when a newer push superseded this one
                        // is harmless: it simply doesn't match, so the newer push's pages stay
                        // fully interactive until their own completion.
                        settledSlideID = id
                        guard let target = heightCoordinator.target(for: layout.screen) else { return }
                        if !didEstablishHeight {
                            didEstablishHeight = true
                            animatedHeight = target
                        } else if abs(target - animatedHeight) > 1 {
                            withAnimation(Motion.push) { animatedHeight = target }
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
                    measurementSettleTask = nil
                    if abs(target - animatedHeight) > 0.5 { animatedHeight = target }
                } else if !expansionSettling {
                    // Ordinary content change (the update banner or first-run hint dismissing, a
                    // refresh loading rows): re-target throughout the change so the panel
                    // co-animates with the content instead of trailing it by a debounce and
                    // leaving a blank strip or clipped rows. These are one-off, short animations;
                    // the measured per-frame-retarget stall source was the caret unfold, which
                    // keeps its debounce below.
                    measurementSettleTask?.cancel()
                    measurementSettleTask = nil
                    if !isSliding, abs(target - animatedHeight) > 1 {
                        withAnimation(Motion.spring) { animatedHeight = target }
                    }
                } else {
                    // Caret unfold in flight: its co-animate already set the estimated target, and
                    // every interpolated measurement until it settles is partial — wait for ~2
                    // quiet frames, then learn the exact delta and issue at most one correction.
                    measurementSettleTask?.cancel()
                    measurementSettleTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(120))
                        guard !Task.isCancelled else { return }
                        applySettledMeasurement()
                        measurementSettleTask = nil
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
                    // The baseline the delta applies to. A SUPERSEDING toggle (an earlier morph is
                    // still settling) must build on the DRIVEN model target — `animatedHeight`
                    // already holds where the previous toggle is heading — because `measuredIdeal`
                    // is still an interpolated mid-flight height; deriving from it could drive a
                    // rapid expand/collapse below the collapsed height or swallow a second card's
                    // expansion. A clean toggle uses the settled measurement as before.
                    let fromIdeal = expansionSettling
                        ? animatedHeight
                        : (heightCoordinator.measuredIdeal[.dashboard] ?? animatedHeight)
                    let key = expansionDeltaKey(for: providerID)
                    let estimate = estimatedExpansionDelta(for: providerID)
                    let delta = expansionDeltas[key] ?? estimate
                    // Learn only from a clean toggle: while an earlier caret morph is still
                    // settling (`expansionSettling` — an explicit marker cleared only when the
                    // settle actually lands, so a third rapid toggle can't sneak through the
                    // window where a second one already cancelled the debounce) or any measurement
                    // is in flight, `fromIdeal` is a partial mid-animation value and the settled
                    // delta would be cached wrong. Skipping just means the estimate covers this
                    // toggle and the next clean one re-learns exactly.
                    if !expansionSettling, measurementSettleTask == nil {
                        pendingExpansion = (key, fromIdeal, estimate)
                    } else {
                        pendingExpansion = nil
                    }
                    expansionSettling = true
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

    /// Ties a learned delta to the provider's current expanded-section composition: the ordered
    /// metric IDs the caret actually reveals (order matters — adjacent text rows condense) plus
    /// quick-links presence. Customizing what sits behind the caret — or an account/plan change
    /// shifting which metrics are applicable — changes the key, so a stale height can't retarget
    /// the first toggle after either; the estimate covers that toggle and the measurement re-learns.
    private func expansionDeltaKey(for providerID: String) -> String {
        guard let group = layout.displayGroups.first(where: { $0.provider.id == providerID }) else {
            return providerID
        }
        let metricIDs = expandedSectionRows(for: group).map(\.id)
        let links = group.provider.visibleLinks.isEmpty ? "" : "|links"
        return "\(providerID)|\(metricIDs.joined(separator: ","))\(links)"
    }

    /// First-toggle guess for a provider's expanded-section height: the rows its caret actually
    /// reveals, each estimated by its rendered anatomy (see `estimatedRowHeight`), plus the
    /// quick-links row when present. The real measurement replaces this within a couple of frames
    /// (with a small same-spring correction) and is remembered exactly afterwards. A flat
    /// rows × constant guess overshot text-heavy expansions by 40–60pt — the default On Demand set
    /// (Usage Trend plus the Today/Yesterday/30 Days cluster) is mostly condensed ~20pt text rows,
    /// not 36pt control rows — so a provider's first toggle each session sprang the panel visibly
    /// past the real height (into the screen clamp on tall dashboards) before settling back.
    private func estimatedExpansionDelta(for providerID: String) -> CGFloat {
        guard let group = layout.displayGroups.first(where: { $0.provider.id == providerID }) else {
            return 0
        }
        let rows = expandedSectionRows(for: group).map(\.data)
        // Per-side rule, matching the card: the expanded section condenses only within itself
        // (never across the caret), and its first row keeps the full gap.
        let condensed = WidgetData.condensedTextRowOffsets(in: rows)
        let rowsHeight = rows.enumerated().reduce(CGFloat(0)) { sum, row in
            sum + estimatedRowHeight(row.element, condensedTop: condensed.contains(row.offset))
        }
        return rowsHeight + estimatedLinksRowHeight(for: group)
    }

    /// The rows the provider's caret ACTUALLY reveals — mirroring the card's render path
    /// (`WidgetGroupedListView.metricContainer`), which drops rows the account's plan makes
    /// inapplicable and, when that filtering empties the Always Visible side, PROMOTES the
    /// applicable On Demand rows above the caret (leaving the expansion links-only). Counting the
    /// raw saved widgets instead made a provider with saved-but-inapplicable On Demand metrics —
    /// a Copilot seat whose other-plan rows never render — estimate a several-rows-too-large
    /// delta: the panel sprang past the real height, the settle sprang it back, and the learn
    /// step's sanity check discarded the wildly-off value, so EVERY toggle replayed the
    /// overshoot-and-correct wobble instead of just the first.
    private func expandedSectionRows(for group: ProviderGroup) -> [(id: String, data: WidgetData)] {
        func applicable(_ widgets: [PlacedWidget]) -> [(id: String, data: WidgetData)] {
            widgets.compactMap { widget in
                guard let descriptor = layout.descriptor(for: widget),
                      dataStore.isMetricApplicable(descriptor) else { return nil }
                return (descriptor.id, dataStore.data(for: descriptor))
            }
        }
        guard !applicable(group.alwaysShownWidgets).isEmpty else { return [] }
        return applicable(group.expandedWidgets)
    }

    /// One row's estimated rendered height, mirroring `WidgetRowView`'s anatomy branch by branch
    /// (chart → sparkline, bounded → label/meter/reading, unbounded → one line plus optional
    /// subtitle) on the compact density constants. Line heights are rounded-up approximations of
    /// the resolved fonts; the settled measurement still corrects and learns the exact value, this
    /// only has to land close enough that the first toggle's correction is invisible.
    private func estimatedRowHeight(_ data: WidgetData, condensedTop: Bool) -> CGFloat {
        let density = DensitySetting.compact
        let labelLine: CGFloat = 15
        let supportingLine: CGFloat = 14
        if data.isChart, data.hasData {
            // The sparkline lays its label BESIDE the bars (`UsageSparkline` is an HStack), so the
            // row's content height is the taller of the two, not their sum.
            return density.textRowPadding * 2 + max(labelLine, density.trendChartHeight)
        }
        if data.isBounded {
            return density.barRowPadding * 2 + labelLine + density.rowInnerSpacing * 2
                + density.meterHeight + supportingLine
        }
        let top = condensedTop ? density.condensedTextRowTopPadding : density.textRowPadding
        let subtitle: CGFloat = data.unboundedSubtitle == nil ? 0 : supportingLine
        return top + density.textRowPadding + labelLine + subtitle
    }

    /// The quick-links row's estimated height: small bordered buttons (~22pt) in up-to-three-across
    /// rows with the grid gap, inside the row's text paddings (see `ProviderLinksView`).
    private func estimatedLinksRowHeight(for group: ProviderGroup) -> CGFloat {
        let linkCount = group.provider.visibleLinks.count
        guard linkCount > 0 else { return 0 }
        let density = DensitySetting.compact
        let buttonRows = CGFloat((linkCount + 2) / 3)
        return density.textRowPadding * 2 + buttonRows * 22
            + (buttonRows - 1) * density.expandedGridSpacing
    }

    /// The debounced tail of the measurement `onChange`: runs once the screen's content measurement
    /// has gone quiet, learns a pending caret toggle's exact expanded-section height from the settled
    /// value, and issues at most ONE spring re-target for the whole morph.
    private func applySettledMeasurement() {
        // The morph this settle belongs to is over either way; every exit below must drop the
        // in-flight marker or the next ordinary content change would wrongly take the debounce path.
        expansionSettling = false
        // Belt over the close path's cancel: a settle that somehow fires after `orderOut` must not
        // spring a hidden panel or learn from a collapsed tree.
        guard transparency.popoverShown else { pendingExpansion = nil; return }
        // Consumed on another screen (the user opened Customize before the dashboard settle fired):
        // never learn from Customize measurements, and never leave the stale pending state to
        // misclassify later Customize changes or the next dashboard toggle.
        guard layout.screen == .dashboard else { pendingExpansion = nil; return }
        guard let target = heightCoordinator.target(for: layout.screen) else { return }
        // A caret toggle's measurement just settled: learn the provider's exact expanded-section
        // height so the NEXT toggle co-animates with zero correction. Sanity-checked against the
        // row-count estimate: an unrelated height change overlapping the settle (a refresh
        // replacing loading rows, the update banner dismissing) folds into the measured
        // difference, and caching that would drive the next toggle to the wrong height — a delta
        // implausibly far from the estimate is discarded, the estimate keeps covering toggles,
        // and a clean settle later re-learns exactly.
        if let pending = pendingExpansion, let ideal = heightCoordinator.measuredIdeal[.dashboard] {
            let learned = abs(ideal - pending.fromTarget)
            if abs(learned - pending.estimate) <= max(60, pending.estimate * 0.75) {
                expansionDeltas[pending.cacheKey] = learned
            }
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
        // Unmount the parked page here, in the close-time hidden settle, so an open never pays it:
        // a page parked across the close would sit hidden measuring and re-laying-out for nothing.
        // (When the screen assignment above changed anything, the slide onChange's hidden walk has
        // already done this; this covers closing from the dashboard with a parked Customize.)
        pages = []
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
        expansionSettling = false
        // The driven height is deliberately KEPT across the close (it used to reset to the 0
        // sentinel here). The close-time settle re-measures the collapsed dashboard while hidden and
        // the `measuredIdeal` onChange walks the retained value to the collapsed target, so the next
        // open finds the height already correct and its pre-show layout pass has nothing to do —
        // resetting to 0 made every reopen pay a full-tree re-layout just to walk 0 → target. The
        // reopen seed above and the measurement onChange below still correct it (un-animated) if the
        // screen or content changed while closed.
        dashboardScrollPosition.scrollTo(edge: .top)
    }

    /// The transition-scoped pager. Steady state keeps exactly one live screen tree; during a push
    /// the screen being left stays mounted (`outgoing`) and slides out while the destination (page
    /// plus its chrome) enters from the direction implied by `slideRank`, the two tiling
    /// edge-to-edge so the switch reads as one connected push. Two guards keep this cheaper than
    /// the old permanently-mounted two-page pager (which doubled the expensive dashboard layouts on
    /// every frame of the height morph): the outgoing tree is wrapped in a CONSTANT size frame —
    /// its pre-switch panel size — so the per-frame animated height never re-proposes (and so never
    /// re-lays-out) that subtree, and it unmounts in the push's completion.
    ///
    /// Why offsets and not a SwiftUI `.transition`: the cards' fill is translucent `.quaternary`
    /// glass. Any transition carrying `.opacity` composites a screen into a transparency layer where
    /// that material has no vibrant backdrop to sample and resolves to its opaque near-white base — a
    /// white flash across the grey cards (the regression this removes; it has no clean SwiftUI fix).
    /// A pure offset never touches opacity, so the glass keeps sampling the live popover backdrop.
    /// `.animation(nil, value:)` stops the structural mount/unmount of either page from inheriting
    /// the caller's mode-switch animation — only `slideProgress` animates the offsets.
    private var modeBody: some View {
        ZStack(alignment: .top) {
            // A ForEach keyed by screen, not an `if let` beside the destination: the pager's pages
            // must keep their STRUCTURAL IDENTITY when a screen changes roles. With positional
            // identity, every switch would tear down the parked tree and mount a fresh copy into
            // the outgoing slot — a full extra layout of the most expensive screen right on the
            // interaction frame. Keyed by screen, a role flip re-uses the exact tree that was
            // already mounted (and the parked page's frozen proposal equals the size it was last
            // laid out at, so parking re-lays-out nothing).
            ForEach(pagerPages) { page in
                screenView(page.screen)
                    // The parked page freezes at its pre-switch panel size (`frozenHeight`) — a
                    // constant proposal, so the per-frame height morph never re-lays-out that
                    // subtree. The active page passes nil and keeps tracking the animated frame.
                    .frame(width: Self.popoverWidth, height: page.frozenHeight, alignment: .top)
                    .offset(x: page.frozenHeight == nil ? screenEntranceOffset : screenExitOffset)
                    // The parked page is decoration: mid-push, clicks belong to the destination (a
                    // click landing on a half-departed row would act on the wrong screen), and at
                    // rest it sits offscreen.
                    .allowsHitTesting(page.frozenHeight == nil)
                    // Pointer hits are only one input path. Once the exit slide settles
                    // (`settledSlideID` — the animation completion's signal; `isSliding` reads
                    // false the instant the push COMMITS, long before it stops moving), the parked
                    // page must also leave the keyboard focus loop and shortcut table — deferred
                    // to the settle so its still-visible controls don't grey out mid-flight. It
                    // leaves the accessibility tree immediately: even mid-push it's decoration a
                    // VoiceOver user should never land on.
                    .disabled(page.frozenHeight != nil && settledSlideID == layout.screenSlideID)
                    .accessibilityHidden(page.frozenHeight != nil)
            }
        }
        .frame(width: Self.popoverWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(nil, value: layout.screenSlideID)
    }

    /// What `modeBody` mounts: the atomically-written `pages`, or just the active screen before
    /// the session's first switch (and after the close-time reset).
    private var pagerPages: [PagerPage] {
        pages.isEmpty ? [PagerPage(screen: layout.screen, frozenHeight: nil)] : pages
    }

    /// Whether a parked outgoing page is mounted beside the active one — the full-width push plays
    /// only then (see `screenEntranceOffset`).
    private var hasParkedPage: Bool {
        pages.contains { $0.frozenHeight != nil }
    }

    /// True from the moment `layout.screen` changes until the slide reaches the incoming screen.
    private var isSliding: Bool {
        layout.screenSlideID != 0
            && (layout.screenSlideID != animatedSlideID || slideProgress < 1)
    }

    /// Starts the entering destination toward the edge it came from, then settles it at zero. With
    /// a parked page sliding out beside it the destination travels the full panel width, its
    /// leading edge glued to the parked page's trailing edge for the whole push; without one
    /// (Reduce Motion off but no height established yet) it keeps the compact directional entrance.
    /// Until this transition's state has committed, progress remains zero so the first frame cannot
    /// flash at its final position.
    private var screenEntranceOffset: CGFloat {
        guard isSliding, !reduceMotion else { return 0 }
        let travel = hasParkedPage ? Self.popoverWidth : Self.screenEntranceDistance
        return slideDirection * travel * (1 - slideRenderProgress)
    }

    /// The outgoing page's travel: the full panel width opposite the entrance, so the two screens
    /// tile edge-to-edge and the switch reads as one connected push.
    private var screenExitOffset: CGFloat {
        -slideDirection * Self.popoverWidth * slideRenderProgress
    }

    /// +1 when the destination sits to the right of the screen being left (it enters from the
    /// trailing edge), -1 on the way back.
    private var slideDirection: CGFloat {
        layout.screenSlideFrom.slideRank < layout.screen.slideRank ? 1 : -1
    }

    /// The slide progress this transition renders at: pinned to zero until the freshly-started
    /// transition's state has committed (see `animatedSlideID`).
    private var slideRenderProgress: CGFloat {
        animatedSlideID == layout.screenSlideID ? slideProgress : 0
    }

    /// Builds one full page for the pager: the screen's scroll body wrapped in ITS OWN pinned
    /// chrome, keyed on the `screen` parameter (never `layout.screen`) so the outgoing page keeps
    /// drawing its own bar and footer while it slides out. The caller offsets the whole page as one
    /// unit — chrome travels with its screen. The soft scroll-edge styles and bars still attach to
    /// the screen's `PopoverScrollView`, the documented place for them.
    @ViewBuilder
    private func screenView(_ screen: PopoverScreen) -> some View {
        scrollBody(for: screen)
            // Auto-fit: the scroll content reports its intrinsic height (invariant to the viewport)
            // straight into `heightCoordinator`, which sums it with the chrome into this screen's
            // ideal window height — see `PopoverScrollView` for why it's not a preference.
            .softTopScrollEdge()
            .softBottomScrollEdge()
            .pinnedTopBar(spacing: 0) {
                PopoverTopBar(
                    screen: screen,
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
                    screen: screen,
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
