import SwiftUI

/// The dashboard display: one inset group per provider (System Settings style). A provider's icon + name
/// sits above a rounded container holding its metric rows, so heterogeneous metric sets read as belonging
/// to their provider. Rows are the shared `WidgetRowView`, fed by the same `WidgetDataStore` the menu bar
/// uses.
///
/// Reordering works here directly (no Customize needed): drag any metric row to reorder it within its
/// provider, or drag a provider's header line to reorder whole providers. Customize stays the discoverable,
/// obvious place to do the same plus toggle metrics on/off. Both surfaces use the same local gesture/geometry
/// helper so they work inside the menu-bar popover without a system drag/drop session.
struct WidgetGroupedListView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(\.colorScheme) private var colorScheme
    let groups: [ProviderGroup]
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?

    @State private var rowFrames = ReorderFrameStore()
    @State private var activeProviderID: String?
    @State private var activeMetricID: String?
    /// The card the "Rename…" alert is currently editing; `nil` when the alert is closed.
    @State private var renameCardID: String?
    @State private var renameDraft = ""
    private let density = DensitySetting.compact

    var body: some View {
        // Provider-section spacing is noticeably wider than the in-card row rhythm (so groups
        // still read as groups); the exact step comes from the compact layout definition.
        VStack(alignment: .leading, spacing: density.sectionSpacing) {
            ForEach(groups) { group in
                section(group)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.spring, value: groups.map(\.provider.id))
        .alert("Rename Card", isPresented: isRenamePresented) {
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                if let renameCardID {
                    // A cleared field resets the card back to its derived name.
                    container.accounts.rename(cardID: renameCardID, to: renameDraft)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave the name empty to go back to the default.")
        }
    }

    private var isRenamePresented: Binding<Bool> {
        Binding(
            get: { renameCardID != nil },
            set: { if !$0 { renameCardID = nil } }
        )
    }

    private func section(_ group: ProviderGroup) -> some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            header(group)
            container(group)
        }
        .opacity(activeProviderID == group.provider.id ? 0 : 1)
        .reorderFrame(id: group.provider.id, in: reorderSpaceName, store: rowFrames)
    }

    private func header(_ group: ProviderGroup) -> some View {
        // Only a notice a refresh can actually move gets the clickable triangle. A `.wait` notice
        // (Claude's "manual refreshes will make it worse" during an Anthropic rate limit) keeps the
        // inert glyph, so the app never offers the action its own tooltip warns against.
        let canRefreshNotice = dataStore.headerNoticeAction(for: group.provider.id) == .refresh
        return ProviderSectionHeader(
            provider: group.provider,
            plan: dataStore.plan(for: group.provider.id),
            warning: dataStore.headerNotice(for: group.provider.id),
            noticeIsConnectPrompt: dataStore.noticeIsConnectPrompt(for: group.provider.id),
            refreshing: dataStore.refreshingProviderIDs.contains(group.provider.id),
            staleness: dataStore.stalenessHint(for: group.provider.id),
            onWarningRefresh: canRefreshNotice ? { refreshProvider(group.provider.id) } : nil,
            onCopyScreenshot: { shareCard(group) }
        )
        // Keep the provider mark and hover-revealed copy control aligned with the card's content edges.
        .padding(.horizontal, 8)
        .highPriorityGesture(providerDragGesture(for: group))
        .contextMenu {
            let name = container.displayName(for: group.provider)
            // Hides the whole provider section (the Customize provider list brings it back). Mirrors
            // the per-metric "Hide" but one level up, so the verb order reads the same on a header as a row.
            Button("Hide \(name)") {
                container.enablement.setEnabled(false, for: group.provider.id)
            }
            Divider()
            Button("Refresh \(name)") {
                refreshProvider(group.provider.id)
            }
            // Renaming needs an account record to write to, so it only shows on account-model cards
            // whose identity has been observed at least once.
            if container.canRename(group.provider.id) {
                Button("Rename…") {
                    // Seed with the STORED rename (empty when none), not the derived title —
                    // confirming an untouched field must stay "no rename", not freeze the derived
                    // name into a custom label that future account-label updates can't refresh.
                    renameDraft = container.accounts
                        .record(backingCardID: group.provider.id)?.customLabel ?? ""
                    renameCardID = group.provider.id
                }
            }
            Button("Customize…") {
                openCustomize(for: group.provider.id)
            }
            Divider()
            Button("Share Screenshot") { _ = shareCard(group) }
        }
    }

    /// Renders the provider's branded share card and copies the PNG to the clipboard. The appearance is
    /// taken from the popover's own `colorScheme` — this view is hosted in the popover panel, whose
    /// appearance is `AppearanceSetting.current` (explicit for Light/Dark, the menu bar for System) — so
    /// the export matches the card on screen instead of guessing from `NSApp.effectiveAppearance`. The
    /// same render path backs the footer's "Share Screenshot" submenu, which reaches it without a
    /// right-click.
    private func shareCard(_ group: ProviderGroup) -> Bool {
        ShareCardRenderer.share(
            group: group,
            dataStore: dataStore,
            layout: layout,
            appearance: colorScheme,
            displayName: container.displayName(for: group.provider)
        )
    }

    /// A row's placed widget paired with its resolved descriptor + data, so each `dataStore.data(for:)`
    /// is computed once per render and reused by both the condensing rule and the row. Keyed off the
    /// `PlacedWidget` so `ForEach` identity stays exactly what it was before this was precomputed.
    private struct ResolvedRow: Identifiable {
        let widget: PlacedWidget
        let descriptor: WidgetDescriptor
        let data: WidgetData
        var id: PlacedWidget.ID { widget.id }
    }

    private enum DashboardMetricCardRow: Identifiable {
        case metric(ResolvedRow)
        case divider
        /// The provider's quick-link buttons (Status / Console / Dashboard ...), pinned at the
        /// bottom of the collapsible expanded section. They collapse with the caret — part of the
        /// expander, not always-visible chrome.
        case links([ProviderLink])

        var id: String {
            switch self {
            case .metric(let row):
                "metric:\(row.descriptor.id)"
            case .divider:
                "expanded-divider"
            case .links:
                "provider-links"
            }
        }
    }

    /// The provider's card body: its metric rows, or — when the provider has an error and no
    /// last-good data at all — the error prompt in their place. A column of "No data" bars under an
    /// unexplained header triangle told the user nothing about what to do next.
    @ViewBuilder
    private func container(_ group: ProviderGroup) -> some View {
        if let message = emptyStateError(for: group) {
            // The error body replaces only the metric rows. The provider's quick links keep their
            // usual place behind the caret — a Status or API-keys page is often exactly what
            // resolves the error. The data-less expanded metrics stay hidden.
            let links = group.provider.visibleLinks
            let isExpanded = layout.isProviderExpanded(group.provider.id)
            DashboardMetricCard {
                errorBody(message: message, providerID: group.provider.id)
                if !links.isEmpty {
                    expandToggle(providerID: group.provider.id, isExpanded: isExpanded)
                    if isExpanded {
                        ProviderLinksView(links: links)
                    }
                }
            }
        } else {
            metricContainer(group)
        }
    }

    /// The empty-state judgment must see exactly the rows this card renders — its placed, applicable
    /// descriptors — so data belonging only to hidden metrics can't mask the error prompt.
    private func emptyStateError(for group: ProviderGroup) -> String? {
        let placed = (group.alwaysShownWidgets + group.expandedWidgets).compactMap { widget -> WidgetDescriptor? in
            guard let descriptor = layout.descriptor(for: widget),
                  dataStore.isMetricApplicable(descriptor)
            else {
                return nil
            }
            return descriptor
        }
        return dataStore.emptyStateError(for: group.provider.id, placedDescriptors: placed)
    }

    private func errorBody(message: String, providerID: String) -> some View {
        ProviderErrorCardView(
            message: message,
            isRefreshing: dataStore.refreshingProviderIDs.contains(providerID),
            style: dataStore.noticeIsConnectPrompt(for: providerID) ? .connect : .warning,
            onRefresh: { refreshProvider(providerID) }
        )
    }

    /// The one forced refresh every user-initiated control on this screen runs: the header and row
    /// context menus, the error card's Refresh button, and the header's warning triangle. Interactive
    /// and forced because it is an explicit user action — the one that may legitimately raise a
    /// Keychain approval prompt, which background refreshes must never do.
    private func refreshProvider(_ providerID: String) {
        Task { await dataStore.refresh(providerID: providerID, force: true, interactive: true) }
    }

    private func metricContainer(_ group: ProviderGroup) -> some View {
        // Resolve each row's descriptor + data exactly once per render, then reuse it for both the
        // neighbor-aware condensing rule and the row itself — `dataStore.data(for:)` used to be
        // recomputed several times per row (twice per adjacent pair plus once in `row`).
        let providerID = group.provider.id
        let isExpanded = layout.isProviderExpanded(providerID)
        let resolvedAlwaysRows = resolvedRows(group.alwaysShownWidgets)
        let resolvedExpandedRows = resolvedRows(group.expandedWidgets)
        let (alwaysRows, expandedRows) = promotedRowsIfNeeded(
            alwaysRows: resolvedAlwaysRows,
            expandedRows: resolvedExpandedRows
        )
        // The caret separates Always Visible and On Demand rows, so text-row condensing should not
        // bridge across it. Each side tightens only against rows on the same side of the separator.
        let condensedIDs = visibleCondensedTextRowIDs(alwaysRows: alwaysRows, expandedRows: isExpanded ? expandedRows : [])
        let cardRows = metricCardRows(
            alwaysRows: alwaysRows,
            expandedRows: expandedRows,
            hasExpandedMetrics: !expandedRows.isEmpty,
            isExpanded: isExpanded,
            links: group.provider.visibleLinks
        )
        // Same card builder the lifted preview uses, so the floating chip can't drift from the live card.
        return DashboardMetricCard {
            // One stable list keeps the drag-owning metric row alive when it crosses the caret boundary.
            // Separate always-shown/expanded loops can tear that source view down before `onEnded` fires,
            // leaving the lift overlay visible until another drag forces a reset.
            ForEach(cardRows) { cardRow in
                switch cardRow {
                case .metric(let entry):
                    row(entry.descriptor, data: entry.data, in: providerID,
                        condensedTop: condensedIDs.contains(entry.descriptor.id))
                case .links(let links):
                    ProviderLinksView(links: links)
                case .divider:
                    expandToggle(providerID: providerID, isExpanded: isExpanded)
                }
            }
        }
    }

    private func resolvedRows(_ widgets: [PlacedWidget]) -> [ResolvedRow] {
        widgets.compactMap { widget -> ResolvedRow? in
            guard let descriptor = layout.descriptor(for: widget),
                  dataStore.isMetricApplicable(descriptor)
            else {
                return nil
            }
            return ResolvedRow(widget: widget, descriptor: descriptor, data: dataStore.data(for: descriptor))
        }
    }

    /// The dashboard promises at least one Always Visible row. Account-aware filtering can remove every
    /// row on that side (for example, a Business Copilot seat whose org metrics were saved On Demand),
    /// so promote the applicable On Demand rows rather than rendering a header-only card.
    private func promotedRowsIfNeeded(
        alwaysRows: [ResolvedRow],
        expandedRows: [ResolvedRow]
    ) -> (always: [ResolvedRow], expanded: [ResolvedRow]) {
        alwaysRows.isEmpty && !expandedRows.isEmpty
            ? (expandedRows, [])
            : (alwaysRows, expandedRows)
    }

    private func metricCardRows(
        alwaysRows: [ResolvedRow],
        expandedRows: [ResolvedRow],
        hasExpandedMetrics: Bool,
        isExpanded: Bool,
        links: [ProviderLink]
    ) -> [DashboardMetricCardRow] {
        // Provider quick-link buttons live INSIDE the collapsible expanded section, pinned at its
        // bottom, so collapsing the caret hides them along with the expanded metrics — they're part of
        // the expander, not always-visible chrome. The caret shows for any provider with expanded
        // content (metrics OR links), so a links-only provider still gets a caret to reveal its buttons.
        let hasLinks = !links.isEmpty
        let hasExpandedContent = hasExpandedMetrics || hasLinks
        return alwaysRows.map(DashboardMetricCardRow.metric)
            + (hasExpandedContent ? [.divider] : [])
            + (isExpanded && !expandedRows.isEmpty ? expandedRows.map(DashboardMetricCardRow.metric) : [])
            + (isExpanded && hasLinks ? [.links(links)] : [])
    }

    /// The centered caret at the bottom of a provider card that reveals or hides its On Demand metrics
    /// and quick links. Rendered whenever the provider has either kind of expanded content.
    private func expandToggle(providerID: String, isExpanded: Bool) -> some View {
        Button {
            withAnimation(Motion.spring) {
                // Same transaction as the row change, so the panel height (and the footer riding it)
                // animates on the same spring clock as the unfolding rows — see `coAnimateExpansion`.
                MenuBarPopover.coAnimateExpansion?(providerID, !isExpanded)
                _ = layout.setProviderExpanded(!isExpanded, for: providerID)
            }
        } label: {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .reorderFrame(id: expandedDividerID(for: providerID), in: reorderSpaceName, store: rowFrames)
        .accessibilityLabel(isExpanded ? "Show less" : "Show more")
    }

    private func expandedDividerID(for providerID: String) -> String {
        "\(providerID)::dashboard-expanded-divider"
    }

    private func visibleCondensedTextRowIDs(alwaysRows: [ResolvedRow], expandedRows: [ResolvedRow]) -> Set<String> {
        condensedTextRowIDs(alwaysRows).union(condensedTextRowIDs(expandedRows))
    }

    /// Neighbor-aware rule (shared with the share-card export via `WidgetData.condensedTextRowOffsets`):
    /// IDs of text-only rows sitting directly under another text-only row. Rows can't see their
    /// neighbors, so the list computes the pairs; Compact density pulls these rows up so a run of
    /// one-liners reads as one cluster. Called per segment (always-shown / expanded), so the expand
    /// caret is never crossed.
    private func condensedTextRowIDs(_ rows: [ResolvedRow]) -> Set<String> {
        let offsets = WidgetData.condensedTextRowOffsets(in: rows.map(\.data))
        return Set(offsets.map { rows[$0].descriptor.id })
    }

    private func row(_ descriptor: WidgetDescriptor, data: WidgetData, in providerID: String,
                     condensedTop: Bool) -> some View {
        let isActive = activeMetricID == descriptor.id
        return WidgetRowView(
            data: data,
            onToggleResetDisplay: { dataStore.resetDisplayMode.toggle() },
            onToggleMeterStyle: { dataStore.meterStyle.toggle() },
            condensedTop: condensedTop
        )
            // Reset credits are the app's only provider write. Bind this row to the service for its
            // exact Codex card; non-Codex rows and static renders receive nil/read-only behavior.
            .environment(
                \.codexResetClaim,
                container.codexResetClaims.service(for: providerID)
            )
            .contentShape(Rectangle())
            .opacity(isActive ? 0 : 1)
            .highPriorityGesture(metricDragGesture(for: descriptor, providerID: providerID))
            .contextMenu { rowMenu(descriptor, providerID: providerID) }
            .reorderFrame(id: descriptor.id, in: reorderSpaceName, store: rowFrames)
    }

    /// Desktop-native management for a single metric: hide it, pin/unpin it, refresh its provider, or jump
    /// into Customize — without a trip through Customize first. Hide leads (the most-reached-for verb), then
    /// star, then a divider before the two provider-/app-level actions.
    @ViewBuilder
    private func rowMenu(_ descriptor: WidgetDescriptor, providerID: String) -> some View {
        Button("Hide") {
            layout.setMetricEnabled(descriptor.id, false)
        }
        if descriptor.pinnable {
            Button(layout.isPinned(descriptor.id) ? "Unstar" : "Star for menu bar") {
                if layout.isPinned(descriptor.id) {
                    layout.setPinned(false, for: descriptor.id)
                } else if layout.canPin(descriptor.id, matching: dataStore.isMetricApplicable) {
                    layout.setPinned(
                        true,
                        for: descriptor.id,
                        matching: dataStore.isMetricApplicable
                    )
                } else {
                    layout.notePinDenied(descriptor.id, matching: dataStore.isMetricApplicable)
                }
            }
        }
        Divider()
        if let provider = layout.provider(id: providerID) {
            Button("Refresh \(container.displayName(for: provider))") {
                refreshProvider(providerID)
            }
        }
        Button("Customize…") {
            openCustomize(for: providerID)
        }
    }

    /// From the dashboard, jump straight into this provider's Customize metrics (L2), not the provider list.
    private func openCustomize(for providerID: String) {
        withAnimation(Motion.modeSwitch) {
            layout.customizeProviderID = providerID
            layout.isEditing = true
        }
    }

    private func providerDragGesture(for group: ProviderGroup) -> some Gesture {
        reorderDragGesture(
            id: group.provider.id,
            coordinateSpaceName: reorderSpaceName,
            rowFrames: rowFrames,
            active: $activeProviderID,
            lift: $reorderLift,
            makeLift: { makeProviderLift(for: group, value: $0) },
            orderedIDs: { groups.map(\.provider.id) },
            reorder: { layout.reorderProvider(dragged: group.provider.id, target: $0) }
        )
    }

    private func metricDragGesture(for descriptor: WidgetDescriptor, providerID: String) -> some Gesture {
        reorderDragGesture(
            id: descriptor.id,
            coordinateSpaceName: reorderSpaceName,
            rowFrames: rowFrames,
            active: $activeMetricID,
            lift: $reorderLift,
            makeLift: { makeMetricLift(for: descriptor, value: $0) },
            orderedIDs: { metricTargetIDs(for: providerID) },
            reorder: { target in
                let current = metricTargetIDs(for: providerID)
                if current.contains(expandedDividerID(for: providerID)) {
                    guard let next = LayoutStore.reordered(current, dragged: descriptor.id, target: target) else {
                        return false
                    }
                    return layout.applyMetricDividerOrder(
                        next,
                        dragged: descriptor.id,
                        dividerID: expandedDividerID(for: providerID),
                        in: providerID
                    )
                }
                return layout.reorderMetric(dragged: descriptor.id, target: target, in: providerID)
            }
        )
    }

    private func metricTargetIDs(for providerID: String) -> [String] {
        guard let group = groups.first(where: { $0.provider.id == providerID }) else {
            return []
        }
        let rawAlwaysShown = group.alwaysShownWidgets.compactMap { widget -> String? in
            guard let descriptor = layout.descriptor(for: widget),
                  dataStore.isMetricApplicable(descriptor)
            else {
                return nil
            }
            return descriptor.id
        }
        let rawExpanded = group.expandedWidgets.compactMap { widget -> String? in
            guard let descriptor = layout.descriptor(for: widget),
                  dataStore.isMetricApplicable(descriptor)
            else {
                return nil
            }
            return descriptor.id
        }
        let alwaysShown = rawAlwaysShown.isEmpty ? rawExpanded : rawAlwaysShown
        let expanded = rawAlwaysShown.isEmpty ? [] : rawExpanded
        // The caret is a drop target whenever the expanded section is open — including a links-only
        // section (buttons but no expanded metrics), so a metric can be dragged past the caret to tuck
        // it below the fold even when only buttons are showing there.
        let hasExpandedContent = !expanded.isEmpty || !group.provider.visibleLinks.isEmpty
        guard hasExpandedContent, layout.isProviderExpanded(providerID) else { return alwaysShown }
        return alwaysShown + [expandedDividerID(for: providerID)] + expanded
    }

    private func makeProviderLift(for group: ProviderGroup, value: DragGesture.Value) -> ReorderLift? {
        // The floating preview should match what the card shows: the error prompt when that is on
        // screen, otherwise only the always-shown rows unless this provider's caret is currently open.
        let errorMessage = emptyStateError(for: group)
        let (alwaysRows, expandedRows) = promotedRowsIfNeeded(
            alwaysRows: resolvedRows(group.alwaysShownWidgets),
            expandedRows: resolvedRows(group.expandedWidgets)
        )
        let visibleRows = layout.isProviderExpanded(group.provider.id)
            ? alwaysRows + expandedRows
            : alwaysRows
        return ReorderLift.make(
            id: group.provider.id,
            payload: .dashboardProvider(
                provider: group.provider,
                plan: dataStore.plan(for: group.provider.id),
                rows: errorMessage == nil ? visibleRows.map(\.data) : [],
                errorMessage: errorMessage,
                errorIsConnectPrompt: dataStore.noticeIsConnectPrompt(for: group.provider.id)
            ),
            value: value,
            frames: rowFrames.frames
        )
    }

    private func makeMetricLift(for descriptor: WidgetDescriptor, value: DragGesture.Value) -> ReorderLift? {
        ReorderLift.make(
            id: descriptor.id,
            payload: .dashboardMetric(data: dataStore.data(for: descriptor)),
            value: value,
            frames: rowFrames.frames
        )
    }
}
