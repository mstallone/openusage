import SwiftUI

/// One ranked legend entry. At rest the amount keeps the rows easy to compare. When that leaves too
/// little room for the title, hovering crossfades to a second, full-width title that was laid out in
/// advance. Only opacity animates: the title never reflows and the row never changes height.
struct TotalSpendLegendRow: View {
    let title: String
    let value: String
    let color: Color
    let fontSize: CGFloat

    @Environment(\.popoverIsVisible) private var popoverIsVisible
    @State private var isHovered = false
    @State private var textAreaWidth: CGFloat = 0
    @State private var titleIdealWidth: CGFloat = 0
    @State private var valueIdealWidth: CGFloat = 0

    private let valueSpacing: CGFloat = 8

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            textContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // `NSPanel.orderOut` retains this SwiftUI tree and may not deliver a hover exit. Clear the
        // transient presentation state at the panel's authoritative close signal so a later open
        // cannot inherit a hidden amount from the previous session.
        .onChange(of: popoverIsVisible) { _, isVisible in
            if !isVisible { isHovered = false }
        }
        // The visual hover state temporarily suppresses the amount, but assistive technologies
        // should always receive the complete, stable row.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value)")
    }

    private var textContent: some View {
        ZStack(alignment: .leading) {
            LegendRowTextLayout(spacing: valueSpacing) {
                measuredTitleLabel
                measuredValueLabel
            }
            .opacity(revealsFullWidthTitle ? 0 : 1)

            titleLabel
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(revealsFullWidthTitle ? 1 : 0)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            textAreaWidth = width
        }
        // The two states already have their final geometry. Crossfading them avoids animating a Text
        // proposal through many truncation points, which made long account labels visibly stutter.
        .animation(.easeOut(duration: 0.12), value: revealsFullWidthTitle)
    }

    private var revealsFullWidthTitle: Bool {
        isHovered && LegendRowPresentation.titleNeedsFullWidth(
            availableWidth: textAreaWidth,
            titleWidth: titleIdealWidth,
            valueWidth: valueIdealWidth,
            spacing: valueSpacing
        )
    }

    private var measuredTitleLabel: some View {
        titleLabel
            .background {
                titleLabel
                    .fixedSize(horizontal: true, vertical: false)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.width
                    } action: { width in
                        titleIdealWidth = ceil(width) + 1
                    }
            }
    }

    private var measuredValueLabel: some View {
        valueLabel
            .background {
                valueLabel
                    .fixedSize(horizontal: true, vertical: false)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.width
                    } action: { width in
                        valueIdealWidth = ceil(width)
                    }
            }
    }

    private var titleLabel: some View {
        Text(title)
            .font(.system(size: fontSize))
            .foregroundStyle(.primary)
            .lineLimit(1)
    }

    private var valueLabel: some View {
        Text(value)
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// Keeps the hover decision independently testable. A short title stays in the stable title/value
/// state; only a title truncated by its own amount gets the full-width hover state.
struct LegendRowPresentation {
    static func titleNeedsFullWidth(
        availableWidth: CGFloat,
        titleWidth: CGFloat,
        valueWidth: CGFloat,
        spacing: CGFloat
    ) -> Bool {
        guard availableWidth > 0, titleWidth > 0, valueWidth > 0 else { return false }

        let displayedValueWidth = min(valueWidth, availableWidth)
        let restingTitleWidth = max(0, availableWidth - displayedValueWidth - spacing)
        return titleWidth > restingTitleWidth
    }
}

/// The resting title/value layout. Its geometry never changes on hover; the full-width title is a
/// separate overlay in `TotalSpendLegendRow`.
private struct LegendRowTextLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let titleIdeal = subviews[0].sizeThatFits(.unspecified)
        let valueIdeal = subviews[1].sizeThatFits(.unspecified)
        let width = proposal.width ?? titleIdeal.width + spacing + valueIdeal.width
        let valueSize = constrainedValueSize(
            subviews[1],
            maximumWidth: width,
            height: proposal.height
        )
        let titleWidth = max(0, width - reservedWidth(for: valueSize.width))
        let titleSize = subviews[0].sizeThatFits(
            ProposedViewSize(width: titleWidth, height: proposal.height)
        )
        return CGSize(width: width, height: max(titleSize.height, valueSize.height))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let valueSize = constrainedValueSize(
            subviews[1],
            maximumWidth: bounds.width,
            height: bounds.height
        )
        let titleWidth = max(0, bounds.width - reservedWidth(for: valueSize.width))
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: titleWidth, height: bounds.height)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.maxX, y: bounds.midY),
            anchor: .trailing,
            proposal: ProposedViewSize(width: valueSize.width, height: bounds.height)
        )
    }

    private func constrainedValueSize(
        _ value: LayoutSubview,
        maximumWidth: CGFloat,
        height: CGFloat?
    ) -> CGSize {
        let ideal = value.sizeThatFits(.unspecified)
        return value.sizeThatFits(
            ProposedViewSize(width: min(ideal.width, maximumWidth), height: height)
        )
    }

    private func reservedWidth(for valueWidth: CGFloat) -> CGFloat {
        valueWidth + spacing
    }
}
