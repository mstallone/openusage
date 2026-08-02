import SwiftUI

/// The scroll container shared by the popover's full-height screens (dashboard and Customize). Each
/// one fills the region the pinned footer leaves and keeps the native scroll edge effect alive while
/// hiding the scrollbar.
///
/// The scroll edge effect (the blur as content passes under the `safeAreaBar`) needs the scroll view
/// to keep a vertical scroller, so indicators are not hidden the SwiftUI way (that removes the
/// scroller and kills the effect). `invisibleOverlayScroller()` instead keeps the overlay scroller
/// (which reserves no gutter) and just makes it invisible: effect intact, no visible bar.
///
/// Screen-specific modifiers — scroll position, edge-effect style, `onAppear`, reorder-frame
/// preferences — are applied by the caller on the returned view, since those differ per screen.
///
/// It also reports its inner content's ideal height straight into the shared
/// `PanelHeightCoordinator` so the popover can auto-fit the visual panel to its content (see
/// `DashboardView`'s coordinated morph). A vertical `ScrollView` proposes `nil` height to its
/// children, so the measured value is the content's intrinsic height — invariant to the
/// window/viewport height, which is what keeps the auto-fit from feeding back on itself.
///
/// The report is an `onGeometryChange` call, deliberately NOT a `PreferenceKey` bubbled up to the
/// per-screen wrapper (the original design): content height changes on every frame of a card-expand
/// morph, and each per-frame preference update invalidated the hosting view's preference outputs,
/// making AppKit rebuild the key-view loop every frame (see `reorderFrame`, which dropped the
/// preference system for the same reason). The coordinator is an `@Observable` class held as
/// `@State` by `DashboardView`, so its identity is stable across body evaluations and this input
/// never dirties the scroll subtree.
struct PopoverScrollView<Content: View>: View {
    let heightCoordinator: PanelHeightCoordinator
    let screen: PopoverScreen
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical) {
            content
                .invisibleOverlayScroller()
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    guard height > 0 else { return }
                    heightCoordinator.setScrollContent(height, for: screen)
                }
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
