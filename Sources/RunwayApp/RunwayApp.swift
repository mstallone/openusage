import Runway
import SwiftUI

@main
struct RunwayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu-bar app: the status item and custom panel are AppKit-owned (see StatusItemController),
        // so no window scene is wanted. `Settings` gives SwiftUI a valid scene without creating
        // an activation window.
        Settings {
            EmptyView()
        }
        .commands {
            // The app menu is visible whenever the app is promoted to `.regular` (the Settings
            // window or a Sparkle update session is up). The standard Runway → Settings… item (⌘,)
            // would open this empty SwiftUI scene as a blank window — replace it so the one menu
            // entry point routes to the real Settings window instead.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    SettingsWindowLink.open()
                }
                .keyboardShortcut(",")
            }
        }
    }
}
