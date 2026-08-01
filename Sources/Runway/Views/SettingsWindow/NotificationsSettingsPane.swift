import AppKit
import SwiftUI
import UserNotifications

/// The Settings window's Notifications pane. Quota pace notifications: three per-trigger toggles (no
/// master switch — turn all three off to silence), each with an (i) tooltip. A warning glyph on the
/// section header and an action row under the toggles appear when macOS permission isn't authorized
/// and at least one trigger is on. Defaults are all off; the app requests authorization the first
/// time a trigger is turned on.
struct NotificationsSettingsPane: View {
    @Environment(AppContainer.self) private var container

    /// macOS notification authorization for Runway, so the warning glyph and action button can
    /// appear when alerts can't be delivered. Refreshed on appear, when a trigger turns on, and when
    /// the app becomes active again (e.g. the user returns from System Settings after re-enabling).
    private enum AuthState { case authorized, denied, notDetermined }
    @State private var auth: AuthState = .authorized
    private let density = DensitySetting.compact

    var body: some View {
        @Bindable var notifications = container.notificationSettings
        let needsAttention = auth != .authorized && anyToggleOn
        return VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            HStack(spacing: 6) {
                Text("Notifications")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if needsAttention {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .hoverTooltip(auth == .denied
                            ? "Notifications are turned off for Runway. Enable them in System Settings."
                            : "Runway needs permission to send alerts.")
                }
            }
            .padding(.horizontal, 8)
            VStack(spacing: 0) {
                toggleRow(.underTenPercent, isOn: $notifications.underTenPercent)
                toggleRow(.healthyToClose, isOn: $notifications.healthyToClose)
                toggleRow(.closeToRunningOut, isOn: $notifications.closeToRunningOut)
                SettingsCaption("Alerts work while Runway runs in the menu bar, even with the popover closed.")
                if needsAttention {
                    actionRow
                }
            }
            .cardSurface()
        }
        .onChange(of: anyToggleOn) { _, on in
            if on {
                // The first time a trigger is turned on, ask macOS for permission (memoized — it only
                // prompts while authorization is still not determined). Then refresh so the
                // warning/action row reflects the new status.
                AppNotifications.shared.requestAuthorization()
                Task { await refreshAuth() }
            }
        }
        .task { await refreshAuth() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshAuth() }
        }
    }

    /// One trigger row: the setting label, an (i) info icon with a one-sentence tooltip, and the toggle.
    private func toggleRow(_ milestone: PaceMilestone, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 6) {
            Text(milestone.settingLabel)
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .hoverTooltip(milestone.tooltip)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .settingsSwitchStyle()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    /// The conditional action under the toggles: a full-width "Open System Settings" button when macOS
    /// denied permission, or "Allow Notifications" when still undecided. The reason lives in the header
    /// triangle's tooltip. Shown only when a trigger is on.
    private var actionRow: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                if auth == .denied {
                    AppNotifications.shared.openSystemNotificationsSettings()
                } else {
                    AppNotifications.shared.requestAuthorization()
                    Task { await refreshAuth() }
                }
            } label: {
                Text(auth == .denied ? "Open System Settings" : "Allow Notifications")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 12)
            .padding(.vertical, density.controlRowPadding)
        }
    }

    /// True when at least one trigger is on — the gate for the permission warning + action row.
    /// Delegates to the store's `anyEnabled` so the disjunction lives in one place.
    private var anyToggleOn: Bool {
        container.notificationSettings.anyEnabled
    }

    /// Read the live macOS authorization status into `auth`, but only when at least one trigger is
    /// on so no warning shows while all alerts are off.
    private func refreshAuth() async {
        guard anyToggleOn else {
            auth = .authorized
            return
        }
        let status = await AppNotifications.shared.authorizationStatus()
        switch status {
        case .denied: auth = .denied
        case .notDetermined: auth = .notDetermined
        default: auth = .authorized
        }
    }
}
