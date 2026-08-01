import SwiftUI

/// The "wrong door" cross-link pinned under the last card of Customize (L1). Customize and Settings
/// sound alike, so people regularly open one while hunting for the other. This is the Apple-native
/// shape for "go somewhere else" in a settings surface: a grouped-card navigation row — icon, label,
/// trailing chevron — matching the provider rows above it, rather than a text link (footnote text is
/// Apple's idiom for explanations, not navigation). The whole row is tappable; the caller supplies
/// the destination action (e.g. opening the standalone Settings window).
struct ScreenCrossLinkRow: View {
    /// SF Symbol leading the row, e.g. "gearshape".
    let systemImage: String
    /// The row's title, e.g. "Settings".
    let title: String
    /// One-line secondary description of what lives there.
    let subtitle: String
    /// Navigates to the destination.
    let action: () -> Void

    private let density = DensitySetting.compact

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: density.headerPointSize, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: density.planBadgePointSize))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, density.controlRowPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardSurface()
    }
}
