import AppKit
import SwiftUI

/// The Settings window's Advanced pane: the terminal helper, logging controls, and updates.
struct AdvancedSettingsPane: View {
    @Environment(AppContainer.self) private var container
    @Environment(UpdaterController.self) private var updater

    @State private var commandLineTool = CommandLineToolInstaller()
    @AppStorage(LogLevelSetting.key) private var logLevel = LogLevelSetting.fallback
    /// Surfaced under the Logging rows when copying the path or revealing the file fails.
    @State private var logActionError: String?
    private let density = DensitySetting.compact

    var body: some View {
        @Bindable var updater = updater
        return VStack(alignment: .leading, spacing: density.sectionSpacing) {
            SettingsSection("Command Line") {
                SettingsRow("Terminal Helper") {
                    switch commandLineTool.status {
                    case .installed:
                        Button("Uninstall") { commandLineTool.uninstall() }
                    case .notInstalled:
                        Button("Install…") { commandLineTool.install() }
                    case .conflict:
                        Text("Unavailable")
                            .foregroundStyle(.secondary)
                    }
                }
                SettingsCaption("Adds a global `runway` command agents can use to monitor limits.")
                if commandLineTool.status == .conflict {
                    SettingsInlineNotice("\(commandLineTool.destinationPath) already exists and wasn't installed by Runway.")
                } else if let errorMessage = commandLineTool.errorMessage {
                    SettingsInlineNotice(errorMessage)
                }
            }
            // Log-level control plus copy/reveal buttons for the file log. The file lives at a fixed
            // path (`~/Library/Logs/Runway/Runway.log`); raising the level here applies live (no
            // restart) and persists across launches. Default Info, Debug is opt-in.
            SettingsSection("Logging") {
                SettingsRow("Log Level") {
                    SettingsMenuPicker($logLevel, options: LogLevelSetting.allCases, label: \.label)
                        .onChange(of: logLevel) {
                            // Apply the new floor to the file sink immediately, then record the transition.
                            AppLog.reloadLevel()
                            AppLog.info(.config, "Log level changed to \(logLevel.rawValue)")
                        }
                }
                SettingsCardButton("Copy Log Path") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    guard pasteboard.setString(LogFile.url.path, forType: .string) else {
                        logActionError = "Couldn't copy the log path to the clipboard."
                        AppLog.warn(.config, "Copy log path failed")
                        return
                    }
                    logActionError = nil
                }
                SettingsCardButton("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([LogFile.url])
                    logActionError = nil
                }
                if let logActionError {
                    SettingsInlineNotice(logActionError)
                }
            }
            // Visible whenever the updater is active (only the signed release build ships a feed; the
            // dev build and a bare `swift run`, with no feed, hide this).
            if updater.isActive {
                SettingsSection("Updates") {
                    SettingsRow("Update Automatically") {
                        Toggle("", isOn: $updater.automaticallyChecksForUpdates)
                            .settingsSwitchStyle()
                    }
                    SettingsCardButton("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            commandLineTool.refreshStatus()
        }
    }
}
