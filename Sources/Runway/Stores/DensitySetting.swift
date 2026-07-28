import AppKit

/// The popover's single compact layout definition. Type, rows, provider sections, and management
/// controls all use these values so the app keeps one consistent information-dense rhythm.
enum DensitySetting: String, Hashable, Sendable, CaseIterable {
    case compact

    // MARK: - Type

    /// Semantic `.headline.weight(.regular)` does not match `.headline` on macOS, so resolve the
    /// compact size explicitly and keep the weight at the call site.
    var labelPointSize: CGFloat {
        NSFont.preferredFont(forTextStyle: .headline).pointSize - 1
    }

    /// Under-bar / detail text recedes instead of reading as a second heavy line.
    var supportingPointSize: CGFloat { 11 }

    /// Provider name in the section header — a touch larger than the metric label below it so the
    /// section title reads as the heaviest thing in the group.
    var headerPointSize: CGFloat { 13 }

    /// Provider mark in the section header.
    var headerIconSize: CGFloat { 14 }

    /// Plan badge beside the provider name — always one step below the supporting text.
    var planBadgePointSize: CGFloat { 10 }

    // MARK: - Dimensions (all on the 4pt grid or its 2pt half-steps)

    /// Vertical padding on a bounded (meter) row.
    var barRowPadding: CGFloat { 5 }

    /// Capsule meter height — a thin hairline like Claude Code's usage bars.
    var meterHeight: CGFloat { 4 }

    /// Usage Trend sparkline height, kept tight with the rest of the card.
    var trendChartHeight: CGFloat { 14 }

    /// Vertical padding on a text-only row.
    var textRowPadding: CGFloat { 4 }

    /// Top padding for a text-only row sitting directly under another text-only row — the
    /// neighbor-aware rule makes runs of one-liners read as one cluster.
    var condensedTextRowTopPadding: CGFloat { 1 }

    /// Spacing inside a bounded row between the label, the meter, and the reading line.
    var rowInnerSpacing: CGFloat { 3 }

    /// Spacing between provider sections, still clearly wider than the in-card rhythm.
    var sectionSpacing: CGFloat { 8 }

    /// Gap between a provider header and its card.
    var headerToCardSpacing: CGFloat { 2 }

    /// Vertical gutter inside a metric card (keeps the first/last row off the card edge).
    var cardGutter: CGFloat { 3 }

    /// Vertical padding on a Customize / Settings control row (toggles, pickers).
    var controlRowPadding: CGFloat { 6 }

    /// Top padding above the dashboard list.
    var contentTopPadding: CGFloat { 10 }

    /// Estimated Customize control-row height for the pre-measurement height seed
    /// (row content ≈ 24pt + `controlRowPadding` × 2).
    var estimatedMetricRowHeight: CGFloat { 36 }

    /// Gap between cells in the provider quick-links grid. Kept tight so two narrow cells still read
    /// as one cluster.
    var expandedGridSpacing: CGFloat { 4 }
}
