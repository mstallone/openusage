import SwiftUI

/// One ranked legend entry. At rest the amount keeps the rows easy to compare. When that leaves too
/// little room for the title, hovering crossfades to a second layout that gives the title only the
/// width it needs. The amount yields from its leading edge through a soft fade, preserving its
/// trailing digits whenever they still fit. A title wider than the whole row then scrolls to reveal
/// its ending. Both layouts stay single-line, so the title never reflows and the row never changes
/// height.
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
            LegendRowTextLayout(reclaimedWidth: 0, spacing: valueSpacing) {
                measuredTitleLabel
                measuredValueLabel
            }
            .opacity(revealsHoverLayout ? 0 : 1)

            LegendRowTextLayout(
                reclaimedWidth: allocation.reclaimedWidth,
                spacing: valueSpacing
            ) {
                hoverTitleLabel
                valueLabel
                    .mask(LegendValueFadeMask(hiddenFraction: allocation.hiddenValueFraction))
            }
            .opacity(revealsHoverLayout ? 1 : 0)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            textAreaWidth = width
        }
        // The two states already have their final geometry. Crossfading them avoids animating a Text
        // proposal through many truncation points, which made long account labels visibly stutter.
        .animation(.easeOut(duration: 0.12), value: revealsHoverLayout)
    }

    private var allocation: LegendRowWidthAllocation {
        LegendRowWidthAllocation.resolve(
            availableWidth: textAreaWidth,
            titleWidth: titleIdealWidth,
            valueWidth: valueIdealWidth,
            spacing: valueSpacing
        )
    }

    private var revealsHoverLayout: Bool {
        isHovered && allocation.reclaimedWidth > 0
    }

    private var marqueeMetrics: LegendRowMarqueeMetrics? {
        LegendRowMarqueeMetrics.resolve(
            availableWidth: textAreaWidth,
            titleWidth: titleIdealWidth
        )
    }

    private var hoverTitleLabel: some View {
        titleLabel
            .opacity(marqueeMetrics == nil ? 1 : 0)
            .overlay(alignment: .leading) {
                if let marqueeMetrics {
                    LegendRowMarqueeTitle(
                        title: title,
                        fontSize: fontSize,
                        distance: marqueeMetrics.distance,
                        duration: marqueeMetrics.duration,
                        isActive: revealsHoverLayout
                    )
                }
            }
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

/// The final hover allocation is computed before hover changes the presentation. The title first
/// consumes the inter-column spacing, then only the leading portion of the amount it actually needs.
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
        guard availableWidth > 0, titleWidth > 0, valueWidth > 0 else { return .none }

        let displayedValueWidth = min(valueWidth, availableWidth)
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

/// A marquee is reserved for titles that still do not fit after the amount has yielded the entire
/// row. Distance controls how far the title travels; duration keeps the speed readable without
/// making unusually long account names take forever.
struct LegendRowMarqueeMetrics {
    let distance: CGFloat
    let duration: TimeInterval

    static func resolve(availableWidth: CGFloat, titleWidth: CGFloat) -> Self? {
        guard availableWidth > 0 else { return nil }

        let distance = titleWidth - availableWidth
        guard distance > 1 else { return nil }

        return Self(
            distance: distance,
            duration: min(6, max(1, distance / 32))
        )
    }
}

/// One of the two final title/value layouts. `reclaimedWidth` is deliberately not animatable: hover
/// crossfades between a resting instance and an already-expanded instance instead of changing a
/// Text proposal frame by frame.
private struct LegendRowTextLayout: Layout {
    let reclaimedWidth: CGFloat
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
        max(0, valueWidth + spacing - reclaimedWidth)
    }
}

/// Scrolls once from the beginning to the end of an overlong title, then holds the ending in view.
/// Reset waits until the parent hover crossfade is complete so leaving a row cannot make the title
/// visibly snap back underneath the pointer.
private struct LegendRowMarqueeTitle: View {
    let title: String
    let fontSize: CGFloat
    let distance: CGFloat
    let duration: TimeInterval
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0

    var body: some View {
        Text(title)
            .font(.system(size: fontSize))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: offset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .task(id: taskKey) {
                await updateOffset()
            }
    }

    private var taskKey: TaskKey {
        TaskKey(
            isActive: isActive,
            reduceMotion: reduceMotion,
            distance: distance,
            duration: duration
        )
    }

    @MainActor
    private func updateOffset() async {
        guard isActive, !reduceMotion else {
            if !isActive {
                do {
                    try await Task.sleep(for: .milliseconds(140))
                } catch {
                    return
                }
            }
            resetOffset()
            return
        }

        resetOffset()
        do {
            try await Task.sleep(for: .milliseconds(450))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        withAnimation(.linear(duration: duration)) {
            offset = -distance
        }
    }

    @MainActor
    private func resetOffset() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            offset = 0
        }
    }

    private struct TaskKey: Hashable {
        let isActive: Bool
        let reduceMotion: Bool
        let distance: CGFloat
        let duration: TimeInterval
    }
}

/// Keeps the trailing digits anchored while only the portion competing with the title disappears.
/// The mask is already at its final state before the hover crossfade begins.
private struct LegendValueFadeMask: View {
    let hiddenFraction: CGFloat

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
