import AppKit
import SwiftUI

/// One native tooltip region over the flattened Text strip, expressed in the rendered image's point
/// coordinates. `StatusItemController` maps it into the status button without adding child views, so
/// the whole item keeps its existing click target.
struct MenuBarToolTipRegion: Equatable {
    let displayName: String
    let rect: CGRect
}

/// The flattened menu-bar image plus any native tooltip regions that belong over it.
struct MenuBarStripPresentation {
    let image: NSImage
    let toolTipRegions: [MenuBarToolTipRegion]
}

/// Renders the Text-style menu-bar strip (`MenuBarContent`) into a template `NSImage` for the
/// `MenuBarExtra` label: provider mark + bare value for a single metric, or a tight labeled stack for
/// two. Black-on-clear so macOS tints it for light/dark; sized to its natural width. The image is built
/// outside the `label:` view builder (an `ImageRenderer` inline there throws obscure errors).
@MainActor
enum MenuBarStripRenderer {
    /// Last render, memoized on (content, style). The label view re-evaluates on every snapshot
    /// write — several times per refresh pass — but the strip's visible content rarely changes.
    /// Returning the same `NSImage` instance lets SwiftUI skip the status-item update, and keeps
    /// `ImageRenderer` (which retains a little memory per run on macOS) to actual visual changes.
    private static var lastRender: (
        content: MenuBarContent,
        style: MenuBarStyle,
        presentation: MenuBarStripPresentation?
    )?

    /// The strip image for the given content and style, or `nil` when the content renders nothing
    /// in that style (caller falls back to the app icon). Memoized: equal inputs return the
    /// previously rendered instance.
    static func image(for content: MenuBarContent, style: MenuBarStyle) -> NSImage? {
        presentation(for: content, style: style)?.image
    }

    /// The flattened strip image and its Text-only account tooltip regions. Bars deliberately carry
    /// no regions: they flatten metrics across providers and therefore have no segment-to-account
    /// geometry to label.
    static func presentation(for content: MenuBarContent, style: MenuBarStyle) -> MenuBarStripPresentation? {
        if let lastRender, lastRender.style == style,
           lastRender.content.isRenderEquivalent(to: content, style: style)
        {
            AppLog.debug(.menubar, "strip cache hit")
            return lastRender.presentation
        }
        AppLog.debug(.menubar, "strip cache miss (rendering)")
        let presentation: MenuBarStripPresentation?
        switch style {
        case .text:
            presentation = textPresentation(for: content)
        case .bars:
            presentation = barsImage(for: content).map {
                MenuBarStripPresentation(image: $0, toolTipRegions: [])
            }
        }
        lastRender = (content, style, presentation)
        return presentation
    }

    /// The pinned-metrics strip, or `nil` when nothing is pinned or no pinned metric has data yet
    /// (caller falls back to the app icon).
    ///
    /// The render is trimmed to its visible pixels: the view's anti-aliasing padding and the provider
    /// glyph's normalization inset would otherwise ship as transparent margins, widening the status
    /// item past its artwork (the menu bar already pads every item, so baked-in margins read as an
    /// extra-large gap next to neighboring items).
    static func textImage(for content: MenuBarContent) -> NSImage? {
        textPresentation(for: content)?.image
    }

    private static func textPresentation(for content: MenuBarContent) -> MenuBarStripPresentation? {
        guard !content.isEmpty else { return nil }
        let renderer = ImageRenderer(content: MenuBarTextStrip(content: content))
        renderer.scale = 2
        guard let rendered = renderer.cgImage else { return nil }
        let cgImage = trimmedToVisibleContent(rendered) ?? rendered
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: CGFloat(cgImage.width) / renderer.scale, height: CGFloat(cgImage.height) / renderer.scale)
        )
        image.isTemplate = true
        image.accessibilityDescription = content.accessibilityText
        return MenuBarStripPresentation(
            image: image,
            toolTipRegions: textToolTipRegions(for: content, imageSize: image.size)
        )
    }

    /// Measures each segment using the exact view shared by the flattened strip, then partitions the
    /// final trimmed image at the midpoint of each 11-point inter-segment gap. Scaling the natural
    /// widths back onto the trimmed image absorbs the small transparent edge crop without changing the
    /// strip renderer or leaving dead hover gaps between adjacent accounts.
    private static func textToolTipRegions(
        for content: MenuBarContent,
        imageSize: NSSize
    ) -> [MenuBarToolTipRegion] {
        guard !content.groups.isEmpty, imageSize.width > 0 else { return [] }
        let widths = content.groups.compactMap { group -> CGFloat? in
            let renderer = ImageRenderer(content: MenuBarTextSegment(group: group))
            renderer.scale = 2
            return renderer.cgImage.map { CGFloat($0.width) / renderer.scale }
        }
        guard widths.count == content.groups.count else { return [] }

        let spacing = MenuBarTextStrip.segmentSpacing
        let naturalWidth = widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
        guard naturalWidth > 0 else { return [] }
        let scale = imageSize.width / naturalWidth

        var segmentX: CGFloat = 0
        return zip(content.groups.indices, zip(content.groups, widths)).map { index, pair in
            let (group, width) = pair
            let minX = index == content.groups.startIndex
                ? 0
                : (segmentX - spacing / 2) * scale
            let maxX = index == content.groups.index(before: content.groups.endIndex)
                ? imageSize.width
                : (segmentX + width + spacing / 2) * scale
            segmentX += width + spacing
            return MenuBarToolTipRegion(
                displayName: group.displayName,
                rect: CGRect(x: minX, y: 0, width: max(0, maxX - minX), height: imageSize.height)
            )
        }
    }

    /// Crops fully transparent margins off a rendered strip, or `nil` when the image has no visible
    /// pixels (caller keeps the untrimmed render).
    nonisolated static func trimmedToVisibleContent(_ image: CGImage) -> CGImage? {
        guard let bounds = visibleBounds(of: image) else { return nil }
        return image.cropping(to: bounds)
    }

    /// The bounding box of pixels with non-zero alpha, in pixel coordinates (origin at the top-left
    /// row, matching `CGImage.cropping(to:)`), or `nil` for a fully transparent image.
    nonisolated static func visibleBounds(of image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var alpha = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &alpha, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where alpha[row + x] != 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The compact Bars glyph (≤4 bounded-metric bars), or `nil` when no pinned metric has a fill.
    static func barsImage(for content: MenuBarContent) -> NSImage? {
        let fractions = content.bars.map(\.fraction)
        guard !fractions.isEmpty else { return nil }
        let renderer = ImageRenderer(content: MenuBarBars(fractions: fractions, side: 18))
        renderer.scale = 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = content.accessibilityText
        return image
    }

    /// The screen-share privacy stand-in: the wordmark instead of usage values, shown while
    /// `MenuBarPrivacyStore.concealUsage` is true so a shared or recorded screen never carries token
    /// counts or spend. Deterministic, so rendered once; `nil` only if `ImageRenderer` fails entirely
    /// (caller falls back to the app icon).
    static let privacyImage: NSImage? = {
        let renderer = ImageRenderer(content: MenuBarPrivacyLabel())
        renderer.scale = 2
        guard let rendered = renderer.cgImage else { return nil }
        let cgImage = trimmedToVisibleContent(rendered) ?? rendered
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: CGFloat(cgImage.width) / renderer.scale, height: CGFloat(cgImage.height) / renderer.scale)
        )
        image.isTemplate = true
        image.accessibilityDescription = "Runway, usage hidden while the screen is shared"
        return image
    }()

    /// Last-resort icon if the brand mark fails to load.
    static let fallbackIcon: NSImage = {
        let image = NSImage(
            systemSymbolName: "gauge.with.dots.needle.bottom.50percent",
            accessibilityDescription: "Runway"
        ) ?? NSImage()
        image.isTemplate = true
        return image
    }()
}

/// The brand gauge mark plus wordmark drawn in place of the strip while screen-share privacy is
/// concealing usage. Same black-on-clear template treatment, glyph box, and type size as a
/// single-metric Text strip, so the swap doesn't jump the menu bar's rhythm.
private struct MenuBarPrivacyLabel: View {
    var body: some View {
        HStack(spacing: 5) {
            // The same mark and inset as `MenuBarIcon` (the art carries its own margin), sized to the
            // strip's glyph box so the swap keeps the provider-glyph scale.
            if let mark = ProviderMarks.mark(for: "runway") {
                ProviderIconShape(mark: mark, inset: 0.08)
                    .fill(Color.black)
                    .frame(width: 16, height: 16)
            }
            Text("Runway")
                .font(.system(size: 12, weight: .bold))
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .fixedSize()
    }
}

private struct MenuBarTextStrip: View {
    let content: MenuBarContent
    static let segmentSpacing: CGFloat = 11

    var body: some View {
        HStack(spacing: Self.segmentSpacing) {
            ForEach(content.groups, id: \.providerID) { group in
                MenuBarTextSegment(group: group)
            }
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .fixedSize()
    }
}

/// One provider/account segment shared by the flattened strip and its tooltip-width measurement.
private struct MenuBarTextSegment: View {
    let group: MenuBarContent.Group

    var body: some View {
        HStack(spacing: 4) {
            glyph(group.icon)
            metricsView(group.metrics)
        }
        .monospacedDigit()
        .fixedSize()
    }

    /// A provider's pinned values, no labels: one metric as a single large number, two stacked on two
    /// tight lines (much narrower than side-by-side), read positionally.
    @ViewBuilder
    private func metricsView(_ metrics: [MenuBarContent.Metric]) -> some View {
        if metrics.count <= 1 {
            Text(metrics.first?.value ?? "")
                .font(.system(size: 12, weight: .bold))
        } else {
            VStack(alignment: .trailing, spacing: -2) {
                ForEach(metrics, id: \.id) { metric in
                    Text(metric.value)
                }
            }
            .font(.system(size: 9, weight: .semibold))
            .fixedSize()
        }
    }

    /// Side length of the glyph box. Sized to fill the strip's height so the mark reads at the same
    /// scale as the dual-line metric block beside it (the single number is shorter), instead of
    /// floating small in the middle. `ProviderIconShape` already normalizes every mark to its true
    /// bounding box, so a near-zero `inset` here makes each provider fill this box uniformly.
    private static let glyphSide: CGFloat = 16

    @ViewBuilder
    private func glyph(_ icon: IconSource) -> some View {
        if let mark = ProviderMarks.mark(for: icon.providerID) {
            ProviderIconShape(mark: mark, inset: 0.04)
                .fill(Color.black)
                .frame(width: Self.glyphSide, height: Self.glyphSide)
        } else {
            Circle().fill(Color.black).frame(width: Self.glyphSide - 1, height: Self.glyphSide - 1)
        }
    }
}

/// Draws up to four horizontal usage bars into a compact square — a 1:1 port of the Tauri edition's
/// tray bars: track 0.16 / fill 1.0 / remainder 0.24 opacity (black, so the template tints them), a
/// rounded leading edge with a small rounded moving edge, and near-full quantization so a 97% bar still
/// shows a visible tail.
private struct MenuBarBars: View {
    let fractions: [Double]
    let side: CGFloat

    var body: some View {
        Canvas { context, size in
            draw(into: &context, size: size)
        }
        .frame(width: side, height: side)
    }

    private func draw(into context: inout GraphicsContext, size: CGSize) {
        let n = max(1, min(4, fractions.count))
        let pad = max(1, (size.width * 0.08).rounded())
        let gap = max(1, (size.width * 0.03).rounded())
        let trackX = pad
        let trackW = size.width - 2 * pad

        let layoutN = CGFloat(max(2, n))
        let trackH = max(1, ((size.height - 2 * pad - (layoutN - 1) * gap) / layoutN).rounded(.down))
        let rx = max(1, (trackH / 3).rounded(.down))

        let totalBarsHeight = CGFloat(n) * trackH + CGFloat(n - 1) * gap
        let yOffset = pad + ((size.height - 2 * pad - totalBarsHeight) / 2).rounded(.down)

        for i in 0..<n {
            let y = yOffset + CGFloat(i) * (trackH + gap) + 1

            context.fill(
                bar(x: trackX, y: y, w: trackW, h: trackH, leading: rx, trailing: rx),
                with: .color(.black.opacity(0.16))
            )

            let fill = MenuBarBarGeometry.fill(trackW: trackW, fraction: i < fractions.count ? fractions[i] : 0)
            if fill.fillW > 0 {
                let trailing = fill.fillW >= trackW ? rx : max(0, (rx * 0.35).rounded(.down))
                context.fill(
                    bar(x: trackX, y: y, w: fill.fillW, h: trackH, leading: rx, trailing: trailing),
                    with: .color(.black)
                )
            }
            if fill.fillW > 0, fill.remainderW > 0, let dividerX = fill.dividerX {
                context.fill(
                    bar(x: trackX + dividerX, y: y, w: fill.remainderW, h: trackH,
                        leading: max(0, (rx * 0.2).rounded(.down)), trailing: rx),
                    with: .color(.black.opacity(0.24))
                )
            }
        }
    }

    private func bar(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, leading: CGFloat, trailing: CGFloat) -> Path {
        UnevenRoundedRectangle(
            topLeadingRadius: leading,
            bottomLeadingRadius: leading,
            bottomTrailingRadius: trailing,
            topTrailingRadius: trailing
        )
        .path(in: CGRect(x: x, y: y, width: w, height: h))
    }
}

/// Pure fill geometry for the Bars glyph, factored out so the near-full quantization and minimum-visible
/// remainder rules are unit-testable. A 1:1 port of the Tauri edition's tray math.
enum MenuBarBarGeometry {
    struct Fill: Equatable {
        let fillW: CGFloat
        let remainderW: CGFloat
        let dividerX: CGFloat?
    }

    /// Quantize near-full (0.7–1.0) bars by remainder in 15% steps, so a nearly-full bar still leaves a
    /// visible tail instead of reading as 100%.
    static func visualFraction(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        let clamped = min(1, max(0, fraction))
        if clamped > 0.7, clamped < 1 {
            let remainder = 1 - clamped
            let quantized = min(1, (remainder / 0.15).rounded(.up) * 0.15)
            return max(0, 1 - quantized)
        }
        return clamped
    }

    static func fill(trackW: CGFloat, fraction: Double) -> Fill {
        guard fraction.isFinite, fraction > 0 else { return Fill(fillW: 0, remainderW: 0, dividerX: nil) }
        let visual = visualFraction(fraction)
        if visual >= 1 { return Fill(fillW: trackW, remainderW: 0, dividerX: nil) }
        let minVisible = max(4, (trackW * 0.2).rounded())
        let maxFillW = max(1, trackW - minVisible)
        let fillW = max(1, min(maxFillW, (trackW * CGFloat(visual)).rounded()))
        let trueRemainder = trackW - fillW
        let remainderW = min(trackW - 1, max(trueRemainder, minVisible))
        return Fill(fillW: fillW, remainderW: remainderW, dividerX: trackW - remainderW)
    }
}
