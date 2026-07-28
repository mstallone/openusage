import SwiftUI

/// One ranked legend entry. At rest the amount keeps the rows easy to compare; pointing at a row
/// gives its title only the extra width it needs. Short titles keep their full amount; longer titles
/// first consume the inter-column gap, then progressively fade the amount from its leading edge.
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
            LegendRowTextLayout(
                reclaimedWidth: allocation.reclaimedWidth,
                spacing: valueSpacing
            ) {
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
                valueLabel
                    .mask(LegendValueFadeMask(hiddenFraction: allocation.hiddenValueFraction))
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
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                textAreaWidth = width
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(Motion.modeSwitch) {
                isHovered = inside
            }
        }
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

    private var allocation: LegendRowWidthAllocation {
        guard isHovered else { return .none }
        return LegendRowWidthAllocation.resolve(
            availableWidth: textAreaWidth,
            titleWidth: titleIdealWidth,
            valueWidth: valueIdealWidth,
            spacing: valueSpacing
        )
    }

    private var titleLabel: some View {
        Text(title)
            .font(.system(size: fontSize))
            .foregroundStyle(.primary)
            .lineLimit(titleRequiresWrapping ? nil : 1)
            .fixedSize(horizontal: false, vertical: titleRequiresWrapping)
    }

    private var titleRequiresWrapping: Bool {
        isHovered && textAreaWidth > 0 && titleIdealWidth > textAreaWidth
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

/// The per-row width decision is kept separate from rendering so short labels never pay for the
/// expansion required by a different row.
struct LegendRowWidthAllocation {
    let reclaimedWidth: CGFloat
    let hiddenValueFraction: CGFloat

    static let none = LegendRowWidthAllocation(reclaimedWidth: 0, hiddenValueFraction: 0)

    static func resolve(
        availableWidth: CGFloat,
        titleWidth: CGFloat,
        valueWidth: CGFloat,
        spacing: CGFloat
    ) -> Self {
        guard availableWidth > 0, valueWidth > 0 else { return .none }

        let displayedValueWidth = min(valueWidth, availableWidth)
        // Keep the signed resting width here. When value + spacing already exceeds the row, its
        // negative remainder is the overflow that must be reclaimed before the title gains width.
        let restingTitleWidth = availableWidth - displayedValueWidth - spacing
        let reclaimedWidth = min(
            displayedValueWidth + spacing,
            max(0, titleWidth - restingTitleWidth)
        )
        let hiddenValueWidth = min(displayedValueWidth, max(0, reclaimedWidth - spacing))

        return Self(
            reclaimedWidth: reclaimedWidth,
            hiddenValueFraction: hiddenValueWidth / displayedValueWidth
        )
    }
}

/// Holds the row width steady while reclaiming only the width this title needs. Expanding one title
/// therefore never changes the proposal received by its sibling legend rows.
private struct LegendRowTextLayout: Layout {
    var reclaimedWidth: CGFloat
    let spacing: CGFloat

    var animatableData: CGFloat {
        get { reclaimedWidth }
        set { reclaimedWidth = newValue }
    }

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
        max(0, valueWidth + spacing - reclaimedWidth)
    }
}

/// Keeps the trailing digits anchored while the portion competing with the title disappears through
/// a soft leading-edge fade. At zero the mask is fully opaque, so hovering a short row changes
/// nothing about its amount.
private struct LegendValueFadeMask: View, @MainActor Animatable {
    var hiddenFraction: CGFloat

    var animatableData: CGFloat {
        get { hiddenFraction }
        set { hiddenFraction = newValue }
    }

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(1, max(0, hiddenFraction))

            if clamped <= 0.001 {
                Rectangle()
                    .fill(.white)
            } else if clamped >= 0.999 {
                Rectangle()
                    .fill(.clear)
            } else {
                let fadeFraction = min(1 - clamped, 10 / max(1, proxy.size.width))
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: clamped),
                        .init(color: .white, location: clamped + fadeFraction),
                        .init(color: .white, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
    }
}
