import SwiftUI

/// The Settings window's Appearance pane: how the menu bar and popover look, and how usage reads.
struct AppearanceSettingsPane: View {
    @Environment(AppContainer.self) private var container

    @AppStorage(AppearanceSetting.key) private var appearance = AppearanceSetting.system
    @AppStorage(TimeFormatSetting.key) private var timeFormat = TimeFormatSetting.auto
    private let density = DensitySetting.compact

    var body: some View {
        @Bindable var layout = container.layout
        @Bindable var store = container.dataStore
        @Bindable var transparency = container.transparency
        return VStack(alignment: .leading, spacing: density.sectionSpacing) {
            SettingsSection("Appearance") {
                SettingsRow("Icon Style") {
                    SettingsMenuPicker($layout.menuBarStyle, options: MenuBarStyle.allCases, label: \.label)
                }
                SettingsRow("Theme") {
                    SettingsMenuPicker($appearance, options: AppearanceSetting.allCases, label: \.label)
                        // NSApp-level so the popover panel restyles too (it ignores
                        // preferredColorScheme); this window inherits the NSApp appearance directly.
                        .onChange(of: appearance) {
                            AppearanceSetting.applyCurrent()
                        }
                }
                SettingsRow("Time Format") {
                    SettingsMenuPicker($timeFormat, options: TimeFormatSetting.allCases, label: \.label)
                }
                // Translucent popover the proper way (behind-window vibrancy, text stays legible). It
                // yields to the system accessibility settings, and to the party easter egg while that's
                // running (the egg drives the look) — either way, see the paused notice below.
                SettingsRow("Increase Transparency") {
                    Toggle("", isOn: $transparency.increaseTransparency)
                        .settingsSwitchStyle()
                        // Party mode owns the look while it's active, so disable (dim) the toggle to show
                        // it has no effect right now — its stored value resumes once the egg is exited.
                        .disabled(transparency.secretCodeActive)
                }
                // Egg first: while Party runs it overrides the toggle regardless of the system flags, so
                // its notice takes precedence over the accessibility one.
                if transparency.secretCodeActive {
                    SettingsInlineNotice("Party mode is on, so this stays paused.")
                } else if transparency.isPaused {
                    SettingsInlineNotice("macOS Reduce Transparency or Increase Contrast is on, so this stays paused.")
                }
                // Both rows surface only after the secret code has been entered. Party Mode is the egg's
                // own switch: turning it off (like re-typing the code) exits the egg and hides both rows,
                // dropping back to the base state. Drunk Mode escalates the readable party into the woozy,
                // barely-readable state and back — turning it off stays in the party (4 → 3), while turning
                // Party Mode off from there clears Drunk Mode too (4 → base).
                if transparency.secretCodeActive {
                    SettingsRow("Party Mode") {
                        Toggle("", isOn: $transparency.partyModeActive)
                            .settingsSwitchStyle()
                    }
                    SettingsRow("Drunk Mode") {
                        Toggle("", isOn: $transparency.drunkMode)
                            .settingsSwitchStyle()
                    }
                    // The egg yields to the accessibility flags too: when one is on the panel stays
                    // opaque, so explain why the party looks normal rather than leaving it a mystery.
                    if transparency.partyPaused {
                        SettingsInlineNotice("macOS Reduce Transparency or Increase Contrast is on, so the party stays paused.")
                    }
                }
            }
            SettingsSection("Usage Display") {
                SettingsRow("Show Usage As") {
                    SettingsMenuPicker($store.meterStyle, options: WidgetDisplayMode.allCases, label: \.label)
                }
                SettingsRow("Reset Times") {
                    SettingsMenuPicker($store.resetDisplayMode, options: ResetDisplayMode.allCases, label: \.label)
                }
                // Off (default) leaves pacing on yellow and red only. On also surfaces projection
                // and the even-pace tick on blue rows.
                SettingsRow("Always Show Pacing") {
                    Toggle("", isOn: $store.alwaysShowPacing)
                        .settingsSwitchStyle()
                        .hoverTooltip("Show how you're pacing on every metric, not just ones near their limit")
                }
            }
        }
    }
}
