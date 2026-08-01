import KeyboardShortcuts
import SwiftUI

/// The Settings window's General pane: app behavior (Total Spend card, login item, global
/// shortcut), iCloud sync, and privacy.
struct GeneralSettingsPane: View {
    @Environment(AppContainer.self) private var container

    @State private var launchAtLogin = LaunchAtLoginSetting()
    @AppStorage(TotalSpendSetting.key) private var showTotalSpend = true
    private let density = DensitySetting.compact

    var body: some View {
        @Bindable var privacy = container.privacy
        return VStack(alignment: .leading, spacing: density.sectionSpacing) {
            SettingsSection("General") {
                // The dashboard's cross-provider Total Spend card; at least one enabled spend-capable
                // provider must exist, so this toggle can't conjure it up alone.
                SettingsRow("Show Total Spend") {
                    Toggle("", isOn: $showTotalSpend)
                        .settingsSwitchStyle()
                }
                SettingsRow("Launch at Login") {
                    Toggle("", isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.update(to: $0) }
                    ))
                        .settingsSwitchStyle()
                }
                if let launchAtLoginError = launchAtLogin.errorMessage {
                    SettingsInlineNotice(launchAtLoginError)
                }
                // Click-to-record field; its ⓧ clears the combo and disables the shortcut.
                SettingsRow("Global Shortcut") {
                    ShortcutRecorderField(name: .togglePopover)
                        .hoverTooltip("Open Runway from anywhere")
                }
            }
            ICloudSyncSettingsSection(sync: container.iCloudSync)
            SettingsSection("Privacy") {
                SettingsRow("Hide From Screen Share") {
                    Toggle("", isOn: $privacy.hideUsageWhileScreenSharing)
                        .settingsSwitchStyle()
                }
                SettingsCaption("While your screen is shared or recorded, the menu bar shows “Runway” instead of your usage.")
            }
        }
    }
}
