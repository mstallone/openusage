import AppKit
import SwiftUI

/// The row of per-provider quick-link buttons (e.g. "Status", "Console") shown in a provider card's
/// expanded area. Lays out up to three across; extra links wrap to the next row. Each button opens its
/// URL in the default browser. Mirrors the legacy Tauri `provider-card` quick-links row, adapted to the
/// native card's expanded area (issue #596 — "bring back provider buttons").
struct ProviderLinksView: View {
    let links: [ProviderLink]
    /// Matches the metric-row inset so the button row lines up with the rows above/below it.
    private static let horizontalInset: CGFloat = 14

    private let density = DensitySetting.compact

    /// Hard ceiling from #596: never more than three buttons across, regardless of how many links a
    /// provider ships. Fewer links use fewer columns so a lone button isn't boxed into a third of the row.
    private static let maxColumns = 3

    /// Eager stacks, deliberately NOT a `LazyVGrid`: this row lives inside the popover's animated
    /// scroll content, and a lazy container re-resolves its cells against the scroll viewport — when
    /// a card above this one expands and the content shifts inside the animation, the buttons'
    /// committed positions reset to the viewport origin, so they visibly flew in from the window top
    /// instead of gliding down with their card like the (eager) metric rows around them. Laziness
    /// buys nothing for a handful of buttons; plain stacks keep their positions across the morph.
    var body: some View {
        let columnCount = min(Self.maxColumns, max(1, links.count))
        let rows = stride(from: 0, to: links.count, by: columnCount).map {
            Array(links[$0 ..< min($0 + columnCount, links.count)])
        }
        VStack(alignment: .leading, spacing: density.expandedGridSpacing) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(alignment: .top, spacing: density.expandedGridSpacing) {
                    ForEach(rows[rowIndex], id: \.self) { link in
                        linkButton(link)
                    }
                    // Invisible fillers keep a partial last row's buttons at the same column width
                    // as the full rows above — the grid's flexible columns did this implicitly.
                    ForEach(0 ..< (columnCount - rows[rowIndex].count), id: \.self) { _ in
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: 0)
                    }
                }
            }
        }
        .padding(.horizontal, Self.horizontalInset)
        .padding(.top, density.textRowPadding)
        .padding(.bottom, density.textRowPadding)
    }

    private func linkButton(_ link: ProviderLink) -> some View {
        Button {
            if let url = URL(string: link.url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 4) {
                Text(link.label)
                    .font(.system(size: density.supportingPointSize, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: density.supportingPointSize - 2))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel("\(link.label), opens in browser")
    }
}
