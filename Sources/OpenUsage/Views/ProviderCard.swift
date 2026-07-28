import SwiftUI

/// The grouped metric-card body shared by the live dashboard list and its lifted drag preview:
/// a spacing-0 stack of rows (separated by row padding, never dividers), the density gutter that
/// keeps the first/last row off the card edge, and the shared card surface. Both surfaces build the
/// card through this so the floating preview can't drift from the live card (it once hard-coded its
/// spacing and even drew dividers the live list doesn't).
///
/// The live list threads per-row gestures/opacity/frames through `rows`; the preview passes plain
/// `WidgetRowView`s; the preview's shadow supplies its lifted depth.
struct DashboardMetricCard<Rows: View>: View {
    @ViewBuilder var rows: Rows

    private let density = DensitySetting.compact

    var body: some View {
        VStack(spacing: 0) {
            rows
        }
        .padding(.vertical, density.cardGutter)
        .cardSurface()
    }
}
