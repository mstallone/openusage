import SwiftUI

/// The "Update Available" banner at the top of the dashboard. Shows while a *scheduled* Sparkle check
/// has found a new version (`UpdaterController.availableUpdateVersion`): for a menu-bar (dockless)
/// app macOS keeps Sparkle's own alert window behind everything, so the popover carries the reminder
/// instead. The install button runs a user-initiated check, which Sparkle presents frontmost (its
/// window with release notes, download progress, and the install flow). The close button snoozes the
/// banner; the next scheduled check re-surfaces the update.
///
/// Same grouped content card as `CustomizeHintCard` (`cardSurface`), scrolling with the sections.
struct UpdateBannerCard: View {
    @Environment(UpdaterController.self) private var updater
    /// The found update's display version, e.g. "0.8.1".
    let version: String

    var body: some View {
        DismissableHintCard(
            systemImage: "arrow.down.circle",
            title: "Update Available",
            message: "Runway \(version) is ready to download.",
            buttonTitle: "Install Update",
            action: { updater.installAvailableUpdate() },
            onDismiss: { withAnimation(Motion.spring) { updater.dismissAvailableUpdate() } }
        )
    }
}
