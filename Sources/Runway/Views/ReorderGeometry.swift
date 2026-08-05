import SwiftUI

struct ReorderLift {
    enum Payload {
        case dashboardProvider(provider: Provider, plan: String?, rows: [WidgetData], errorMessage: String? = nil, errorIsConnectPrompt: Bool = false)
        case dashboardMetric(data: WidgetData)
        case customizeProviderRow(provider: Provider, isEnabled: Bool, metricCount: Int)
        case customizeMetric(title: String)
    }

    let id: String
    let payload: Payload
    let sourceFrame: CGRect
    let touchOffset: CGPoint
    var location: CGPoint

    /// The one place a lift is built from a drag value. Every reorder site (dashboard/Customize ×
    /// provider/metric) differs only in the `payload`; the frame lookup and touch-offset math are
    /// identical, so they live here once. Returns `nil` when the dragged row has no recorded frame.
    static func make(
        id: String,
        payload: Payload,
        value: DragGesture.Value,
        frames: [String: CGRect]
    ) -> ReorderLift? {
        guard let sourceFrame = frames[id] else { return nil }
        return ReorderLift(
            id: id,
            payload: payload,
            sourceFrame: sourceFrame,
            touchOffset: CGPoint(
                x: value.startLocation.x - sourceFrame.minX,
                y: value.startLocation.y - sourceFrame.minY
            ),
            location: value.location
        )
    }
}

struct ReorderLiftPreview: View {
    let lift: ReorderLift

    // The previews are deliberately the same views the live screens render (shared row/card
    // builders); reading the compact layout here keeps a lifted provider block matched to its source.
    private let density = DensitySetting.compact

    var body: some View {
        preview
            .frame(width: lift.sourceFrame.width)
            .scaleEffect(1.025)
            .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 8)
            .position(
                x: lift.location.x - lift.touchOffset.x + lift.sourceFrame.width / 2,
                y: lift.location.y - lift.touchOffset.y + lift.sourceFrame.height / 2
            )
            .animation(.none, value: lift.location)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var preview: some View {
        switch lift.payload {
        case .dashboardProvider(let provider, let plan, let rows, let errorMessage, let errorIsConnectPrompt):
            dashboardProviderPreview(
                provider: provider,
                plan: plan,
                rows: rows,
                errorMessage: errorMessage,
                errorIsConnectPrompt: errorIsConnectPrompt
            )
        case .dashboardMetric(let data):
            dashboardMetricPreview(data)
        case .customizeProviderRow(let provider, let isEnabled, let metricCount):
            customizeProviderRowPreview(provider: provider, isEnabled: isEnabled, metricCount: metricCount)
        case .customizeMetric(let title):
            customizeMetricPreview(title)
        }
    }

    private func dashboardProviderPreview(
        provider: Provider,
        plan: String?,
        rows: [WidgetData],
        errorMessage: String?,
        errorIsConnectPrompt: Bool
    ) -> some View {
        // Same anatomy as the live dashboard section (`WidgetGroupedListView.section` + `container`):
        // Header over the shared metric card, at the compact layout's header→card spacing. When the
        // live card shows the error prompt instead of rows, the lifted chip shows it too (inert —
        // the whole preview is non-interactive).
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            ProviderSectionHeader(provider: provider, plan: plan)
                .padding(.horizontal, 8)

            DashboardMetricCard {
                if let errorMessage {
                    ProviderErrorCardView(
                        message: errorMessage,
                        isRefreshing: false,
                        style: errorIsConnectPrompt ? .connect : .warning,
                        onRefresh: {}
                    )
                } else {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        WidgetRowView(data: row)
                    }
                }
            }
        }
    }

    private func dashboardMetricPreview(_ data: WidgetData) -> some View {
        WidgetRowView(data: data)
            .liftedRowSurface()
    }

    private func customizeProviderRowPreview(provider: Provider, isEnabled: Bool, metricCount: Int) -> some View {
        // Same row anatomy as the live L1 (`ProviderListRow`), rendered inert — the lift's shadow +
        // scale read as the floating chip, and the whole preview is non-interactive (`.allowsHitTesting`
        // false in `body`), so the toggle/chevron carry no live action.
        ProviderListRow(
            provider: provider,
            isEnabled: isEnabled,
            metricCount: metricCount,
            handle: { $0 }
        )
        .liftedRowSurface()
    }

    private func customizeMetricPreview(_ title: String) -> some View {
        CustomizeMetricRow(title: title,
            trailing: {
                CustomizeStarPlaceholder()
                CustomizeSwitchPlaceholder()
            }
        )
        .liftedRowSurface()
    }

}

/// The latest reorder-row frames, held behind a plain reference (deliberately NOT `@Observable` /
/// `@State`-value semantics). Row frames change on every animation frame of a card-expand or
/// window-height morph, and storing them as view state re-rendered the whole list per frame — the
/// main-thread churn that made the panel's growth visibly stutter. Gestures instead read `frames`
/// through this box at event time, which also means mid-drag hit-testing always sees the current
/// layout rather than a render-time snapshot.
@MainActor
final class ReorderFrameStore {
    private(set) var frames: [String: CGRect] = [:]
    /// Which modifier instance last wrote each id. A drag between Customize sections remounts the
    /// row under the same id, and the replacement can record its geometry BEFORE the outgoing
    /// instance's delayed `onDisappear` runs — an unconditional removal there would delete the live
    /// entry and leave the row untargetable until its next geometry change.
    private var owners: [String: UUID] = [:]

    func record(id: String, frame: CGRect, owner: UUID) {
        frames[id] = frame
        owners[id] = owner
    }

    /// Removes the entry only if `owner` is still the latest writer (see `owners`).
    func removeIfOwned(id: String, owner: UUID) {
        guard owners[id] == owner else { return }
        frames[id] = nil
        owners[id] = nil
    }
}

extension View {
    /// Records this row's frame (in the popover's reorder coordinate space) into `store` so the
    /// shared drag gesture can hit-test rows and build lifts.
    ///
    /// This deliberately avoids SwiftUI's pasteboard-backed `.draggable` / `.dropDestination` APIs,
    /// which are unreliable in this popover, AND the preference system its first implementation
    /// used: rows move on every animation frame of a screen slide or card-expand morph, and a
    /// per-frame `PreferenceKey` update invalidated the hosting view's preference outputs, which
    /// made AppKit rebuild the whole key-view loop (`FocusBridge.invalidateKeyViewLoop`) on every
    /// frame — measured at ~30% of each morph frame's render time. `onGeometryChange` delivers the
    /// same rect straight to the plain box: no preference propagation, no host invalidation, and
    /// the write is a dictionary assignment.
    /// Takes the named space's `String` name rather than a `CoordinateSpace`: the geometry
    /// transform closure is `@Sendable`, and `CoordinateSpace` isn't — every caller uses a named
    /// space anyway, and the name crosses the isolation boundary cleanly.
    func reorderFrame(
        id: String,
        in spaceName: String,
        store: ReorderFrameStore,
        yOutset: CGFloat = 0
    ) -> some View {
        modifier(ReorderFrameModifier(id: id, spaceName: spaceName, store: store, yOutset: yOutset))
    }
}

private struct ReorderFrameModifier: ViewModifier {
    let id: String
    let spaceName: String
    let store: ReorderFrameStore
    let yOutset: CGFloat
    /// This instance's identity for the store's ownership check — see `ReorderFrameStore.owners`.
    @State private var token = UUID()

    func body(content: Content) -> some View {
        // Captured as locals so the `@Sendable` transform closure doesn't reach through
        // main-actor-isolated `self`.
        let spaceName = spaceName
        let yOutset = yOutset
        return content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(spaceName)).insetBy(dx: 0, dy: -yOutset)
            } action: { frame in
                store.record(id: id, frame: frame, owner: token)
            }
            // The preference dictionary used to drop a row's entry when it unmounted; direct writes
            // need the same hygiene or a stale frame could satisfy a later hit-test (e.g. the L2
            // grip scan iterates every recorded frame, not just current-row ids). Ownership-checked
            // so a remounted replacement's fresh entry survives this instance's late teardown.
            .onDisappear { store.removeIfOwned(id: id, owner: token) }
    }
}

/// The shared drag-to-reorder gesture used by both the dashboard list and the Customize screen, for both
/// provider headers and metric rows. The gesture body (lift tracking, target hit-testing, spring + haptic)
/// lives here once; each caller supplies only what differs: the active-row binding, the lift builder, the
/// current ordered ids, and the reorder action.
@MainActor
func reorderDragGesture(
    id: String,
    coordinateSpaceName: String,
    rowFrames: ReorderFrameStore,
    active: Binding<String?>,
    lift: Binding<ReorderLift?>,
    makeLift: @escaping (DragGesture.Value) -> ReorderLift?,
    orderedIDs: @escaping () -> [String],
    reorder: @escaping (_ target: String) -> Bool
) -> some Gesture {
    DragGesture(minimumDistance: 4, coordinateSpace: .named(coordinateSpaceName))
        .onChanged { value in
            active.wrappedValue = id
            if lift.wrappedValue?.id != id, let newLift = makeLift(value) {
                lift.wrappedValue = newLift
            }
            lift.wrappedValue?.location = value.location
            guard let target = reorderTarget(
                at: value.location,
                in: rowFrames.frames,
                excluding: id,
                orderedIDs: orderedIDs()
            ) else { return }
            var moved = false
            withAnimation(Motion.spring) {
                moved = reorder(target)
            }
            if moved { Haptics.snap() }
        }
        .onEnded { _ in
            active.wrappedValue = nil
            lift.wrappedValue = nil
        }
}

func reorderTarget(
    at location: CGPoint,
    in frames: [String: CGRect],
    excluding draggedID: String,
    orderedIDs: [String]
) -> String? {
    guard let from = orderedIDs.firstIndex(of: draggedID) else { return nil }
    let crossingThreshold = 0.20

    for id in orderedIDs where id != draggedID {
        guard let to = orderedIDs.firstIndex(of: id),
              let frame = frames[id]
        else { continue }

        guard frame.insetBy(dx: 0, dy: -2).contains(location) else { continue }

        // Reorder only after crossing partway into the target row. This avoids the jumpy feel where a row moves
        // as soon as the pointer barely enters a neighbor, while still feeling less delayed than the midpoint.
        if to > from {
            return location.y >= frame.minY + frame.height * crossingThreshold ? id : nil
        } else {
            return location.y <= frame.maxY - frame.height * crossingThreshold ? id : nil
        }
    }

    return nil
}
