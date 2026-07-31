import SwiftUI

/// A one-line label that treats text longer than its slot the way the Total Spend legend treats
/// long account titles: at rest it truncates normally; while `isHovered` (and actually truncated)
/// it crossfades to a marquee that scrolls once to the end of the string and holds, so the tail
/// stays reachable. Measures its own slot and ideal width, and is completely inert when the text
/// fits. The legend row keeps its own instance of the same machinery (`MarqueeTextScroller`)
/// because it also reclaims width from the amount column before falling back to the marquee.
struct HoverMarqueeText: View {
    let text: String
    let font: Font
    let isHovered: Bool

    @State private var availableWidth: CGFloat = 0
    @State private var idealWidth: CGFloat = 0

    var body: some View {
        label
            .opacity(isActive ? 0 : 1)
            .overlay(alignment: .leading) {
                if let metrics {
                    // The scroller exists whenever the text overflows, but only shows while the
                    // hover is on — at rest the truncated (ellipsized) base label is the visible one.
                    MarqueeTextScroller(
                        text: text,
                        font: font,
                        distance: metrics.distance,
                        duration: metrics.duration,
                        isActive: isActive
                    )
                    .opacity(isActive ? 1 : 0)
                }
            }
            // Crossfade between the resting truncated label and the marquee — the legend row's
            // rule: never animate a Text proposal through many truncation points, which visibly
            // stutters on long names.
            .animation(.easeOut(duration: 0.12), value: isActive)
            .clipped()
            .background {
                // Hidden ideal-width probe: the same label without a width constraint, so the
                // marquee distance is the text's real overflow.
                label
                    .fixedSize(horizontal: true, vertical: false)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.width
                    } action: { width in
                        // No +1 fudge (unlike the legend's area-based measurement): `availableWidth`
                        // here is this label's own laid-out width, which for a fitting name equals
                        // its ideal width up to subpixel rounding. The metrics' >1pt floor then keeps
                        // a fitting name from registering as overflow — with the fudge, every name
                        // "overflowed" by ~2pt and hover ran a pointless few-pixel shimmy.
                        idealWidth = ceil(width)
                    }
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                availableWidth = width
            }
    }

    private var metrics: MarqueeTextMetrics? {
        MarqueeTextMetrics.resolve(availableWidth: availableWidth, textWidth: idealWidth)
    }

    private var isActive: Bool {
        isHovered && metrics != nil
    }

    private var label: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
    }
}

/// A marquee is reserved for text that does not fit its slot. Distance controls how far the text
/// travels; duration keeps the speed readable without making unusually long account names take
/// forever.
struct MarqueeTextMetrics {
    let distance: CGFloat
    let duration: TimeInterval

    static func resolve(availableWidth: CGFloat, textWidth: CGFloat) -> Self? {
        guard availableWidth > 0 else { return nil }

        let distance = textWidth - availableWidth
        guard distance > 1 else { return nil }

        return Self(
            distance: distance,
            duration: min(6, max(1, distance / 32))
        )
    }
}

/// Reduce Motion replaces the marquee with one immediate state change. At rest the prefix remains
/// visible; hovering jumps to the ending so both sides of an overlong text remain reachable.
struct MarqueeTextOffset {
    static func immediateTarget(
        isActive: Bool,
        reduceMotion: Bool,
        distance: CGFloat
    ) -> CGFloat {
        isActive && reduceMotion ? -distance : 0
    }
}

/// Scrolls once from the beginning to the end of an overlong text, then holds the ending in view.
/// Reset waits until the parent hover crossfade is complete so leaving the hover cannot make the
/// text visibly snap back underneath the pointer.
struct MarqueeTextScroller: View {
    let text: String
    let font: Font
    let distance: CGFloat
    let duration: TimeInterval
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    /// Bumped at every activation. Rapid hover out/in can otherwise leave the previous run's scroll
    /// animation in flight when the new run resets the offset; SwiftUI composes animations on the
    /// same attribute additively, so the stale delta rides on top of the reset and shoves the text
    /// right — a large empty gap at the leading edge that drains away over seconds. A fresh identity
    /// per run discards the old node and every animation attached to it.
    @State private var run = 0

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: offset)
            .id(run)
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
        guard isActive else {
            do {
                try await Task.sleep(for: .milliseconds(140))
            } catch {
                return
            }
            setOffset(0)
            return
        }

        let immediateTarget = MarqueeTextOffset.immediateTarget(
            isActive: isActive,
            reduceMotion: reduceMotion,
            distance: distance
        )
        run += 1 // fresh node first, so the reset below can't merge with a previous run's animation
        setOffset(immediateTarget)
        guard !reduceMotion else { return }

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
    private func setOffset(_ target: CGFloat) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            offset = target
        }
    }

    private struct TaskKey: Hashable {
        let isActive: Bool
        let reduceMotion: Bool
        let distance: CGFloat
        let duration: TimeInterval
    }
}
