import AppKit
import SwiftUI

/// Renders a `ShareCardView` into a PNG and copies it to the clipboard. Mirrors `MenuBarStripRenderer`'s
/// `ImageRenderer` → `cgImage` → `NSImage` path (×4 for a crisp, large export), then PNG-encodes it and
/// writes it to the pasteboard.
@MainActor
enum ShareCardRenderer {
    /// Off-screen render scale. ×4 turns the popover-scale card into a crisp, large PNG — a 360pt card
    /// ships as a 1440px image — without authoring a separate large-format layout.
    static let scale: CGFloat = 4

    /// The audible failure cue for a share action that couldn't produce or copy its PNG. Indirect so
    /// the test suite can silence it — the failure paths are unit-tested, and an automated run must
    /// not play the system alert sound.
    static var playAlertSound: () -> Void = { NSSound.beep() }

    /// The card rendered to an `NSImage`, or `nil` if `ImageRenderer` produces no CGImage. The image's
    /// point size is the card's natural (flexible) size; its pixel size is that times `scale`.
    static func image<Card: View>(for view: Card) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        )
    }

    /// PNG-encodes an `NSImage`, or `nil` if the bitmap can't be formed.
    static func pngData(from image: NSImage) -> Data? {
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Writes the card's PNG onto the general pasteboard (replacing its contents). Beeps and logs if the
    /// PNG can't be encoded or the pasteboard rejects it, so a failed copy isn't silently swallowed.
    /// Returns `true` only when the PNG actually landed on the pasteboard, so callers can gate a success
    /// confirmation on it (and not claim "copied" when nothing was written).
    @discardableResult
    static func copyToPasteboard(_ image: NSImage) -> Bool {
        guard let png = pngData(from: image) else {
            AppLog.error(.lifecycle, "share card: failed to encode PNG for clipboard")
            playAlertSound()
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setData(png, forType: .png) else {
            AppLog.error(.lifecycle, "share card: pasteboard rejected the PNG")
            playAlertSound()
            return false
        }
        return true
    }

    /// Orchestrates a Share Screenshot action end to end: resolve the provider's visible rows from the data
    /// store, build the card with the effective appearance, render it, and copy the PNG to the clipboard.
    /// On a successful copy it asks the layout store to surface a transient "Copied to clipboard" pill —
    /// a clipboard write gives no other signal that it landed.
    /// The rows mirror what the dashboard shows — always-shown plus expanded only when the provider's
    /// caret is open — so the export matches what the user sees.
    ///
    /// The render uses the same compact layout as the popover, keeping the exported card consistent
    /// with the live view.
    /// `displayName` carries the live card title (a rename can land mid-session, after the
    /// `Provider`'s own name was baked at launch); `nil` falls back to the baked name.
    @discardableResult
    static func share(
        group: ProviderGroup,
        dataStore: WidgetDataStore,
        layout: LayoutStore,
        appearance: ColorScheme,
        displayName: String? = nil
    ) -> Bool {
        let isExpanded = layout.isProviderExpanded(group.provider.id)
        let rawAlwaysRows = group.alwaysShownWidgets.compactMap { widget -> WidgetData? in
            guard let descriptor = layout.descriptor(for: widget),
                  dataStore.isMetricApplicable(descriptor)
            else {
                return nil
            }
            return dataStore.data(for: descriptor)
        }
        let rawExpandedRows = group.expandedWidgets.compactMap { widget -> WidgetData? in
            guard let descriptor = layout.descriptor(for: widget),
                  dataStore.isMetricApplicable(descriptor)
            else {
                return nil
            }
            return dataStore.data(for: descriptor)
        }
        // Match the dashboard's invariant after account-aware filtering: if no applicable metric remains
        // Always Visible, promote the On Demand rows rather than exporting a blank collapsed card.
        let alwaysRows = rawAlwaysRows.isEmpty ? rawExpandedRows : rawAlwaysRows
        let expandedRows = rawAlwaysRows.isEmpty ? [] : rawExpandedRows
        let rows = isExpanded ? alwaysRows + expandedRows : alwaysRows
        let view = ShareCardView(
            provider: group.provider,
            plan: dataStore.plan(for: group.provider.id),
            rows: rows,
            appearance: appearance,
            expandBoundaryIndex: isExpanded ? alwaysRows.count : nil,
            displayNameOverride: displayName,
            // When the live card shows the empty-state error prompt instead of rows, the export
            // mirrors it — otherwise the shared PNG would be a wall of "No data" rows with the
            // on-screen reason missing. Judged against the same placed, applicable descriptors the
            // dashboard card uses.
            errorMessage: dataStore.emptyStateError(
                for: group.provider.id,
                placedDescriptors: (group.alwaysShownWidgets + group.expandedWidgets).compactMap { widget in
                    guard let descriptor = layout.descriptor(for: widget),
                          dataStore.isMetricApplicable(descriptor)
                    else {
                        return nil
                    }
                    return descriptor
                }
            ),
            errorIsConnectPrompt: dataStore.noticeIsConnectPrompt(for: group.provider.id)
        )
        return renderAndCopy(view, label: group.provider.id, layout: layout)
    }

    /// The Total Spend counterpart to `share(group:…)`: renders the aggregate ring card for the
    /// currently selected period and metric and copies the PNG to the clipboard, with the same compact
    /// render and the same "Copied to clipboard" confirmation. `total` is passed
    /// already aggregated — the card computed it for the on-screen ring, so the export can't drift
    /// from the display. Returns whether the PNG landed on the pasteboard, so the share button can
    /// gate its own "copied" micro-animation on actual success.
    @discardableResult
    static func shareTotalSpend(
        total: TotalSpend,
        metric: TotalSpendMetric,
        appearance: ColorScheme,
        layout: LayoutStore
    ) -> Bool {
        let projection = total.projection(for: metric)
        guard !projection.isEmpty else {
            playAlertSound()
            return false
        }
        let view = TotalSpendShareCardView(total: total, metric: metric, appearance: appearance)
        return renderAndCopy(view, label: metric.title.lowercased(), layout: layout)
    }

    /// Shared render→copy pipeline for both share actions. Rasterizes `view`, copies the PNG, and on a
    /// successful copy surfaces the transient "Copied to clipboard" pill (a clipboard write gives no
    /// other signal). Beeps and logs (naming the card with `label`) on failure, so a failed export is
    /// never silently swallowed. Returns whether the PNG landed on the pasteboard.
    @discardableResult
    private static func renderAndCopy<Card: View>(_ view: Card, label: String, layout: LayoutStore) -> Bool {
        guard let image = image(for: view) else {
            AppLog.error(.lifecycle, "share card: ImageRenderer produced no image for \(label)")
            playAlertSound()
            return false
        }
        guard copyToPasteboard(image) else { return false }
        layout.presentShareConfirmation()
        return true
    }
}
