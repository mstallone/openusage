import AppKit
import SwiftUI

/// The dashboard footer's trailing control: a single **gear** menu button in Liquid Glass. An earlier
/// split button ("Customize" + separate chevron) confused people, and the "Options ⌄" capsule that
/// replaced it claimed more footer than one control deserved — so everything lives in one compact,
/// obvious gear menu: Customize / Settings / Memory / Share Screenshot / Check for Updates / About /
/// Quit.
/// Customize leads the menu because it's the screen users reach for most; Settings stays one click
/// away (and always via ⌘,).
///
/// The gear is a `.buttonStyle(.plain)` `Menu` with one `interactiveGlass(in: Circle())` treatment
/// behind it — the system `.buttonStyle(.glass)` renders flat on a `Menu` (its own button chrome wins),
/// so the treatment goes on the container. Increase Transparency adds an adaptive frosted base beneath
/// the glass for contrast; macOS 15 uses that frosted circle as its fallback. The menu renders in its
/// own `NSMenu`-backed window, which the panel's outside-click policy keeps the popover open for.
///
/// Only the dashboard's footer shows this (`PopoverFooter` renders nothing elsewhere); Customize
/// carries its own top-leading back button (`PopoverTopBar`) to return home, and Settings lives in
/// its own window.
///
/// Shortcuts survive: ⌘, (Settings window), ⌘M (Memory window), ⏎ (Customize) and Esc are handled
/// by the always-on `PopoverKeyReader` monitor, so they fire from every screen. The menu items only
/// carry their ⌘ key-equivalents as labels and fire while the menu is open, so the monitor and the
/// items never double-fire. ⌘Q (Quit) is unowned elsewhere, so it rides its menu item directly.
struct HeaderView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(UpdaterController.self) private var updater
    @Environment(PopoverTransparencyStore.self) private var transparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.popoverIsVisible) private var popoverIsVisible

    @State private var isHovered = false

    /// Control diameter, so the gear matches the footer's other chrome.
    private static let controlHeight: CGFloat = 28

    /// The gear menu button on one glass circle.
    var body: some View {
        optionsButton
            .fixedSize()
            // Hover highlight inside the circle — drawn over the glass, under the glyph — so the
            // gear reads as hoverable even where the glass shimmer alone is too subtle (and on
            // macOS 15, where the frosted fallback has no hover response at all).
            .background {
                Circle().fill(Color.primary.opacity(isHovered ? 0.08 : 0))
            }
            .interactiveGlass(
                in: Circle(),
                reinforced: transparency.effectiveStyle.needsChromeLegibilityBacking
            )
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            // `NSPanel.orderOut` retains this SwiftUI tree and may not deliver a hover exit, so
            // clear the hover at the panel's authoritative close signal.
            .onChange(of: popoverIsVisible) { _, isVisible in
                if !isVisible { isHovered = false }
            }
            // This view is conditionally removed with the footer on Customize, and a removed view
            // gets no hover exit — reset here so the gear can't remount pre-highlighted.
            .onDisappear { isHovered = false }
    }

    /// The options pull-down: a bare gear glyph. `.menuStyle(.button)` + `.buttonStyle(.plain)` strip
    /// the menu chrome so `interactiveGlass` owns the surface; `.menuIndicator(.hidden)` drops the
    /// built-in arrow — the gear alone is the affordance.
    private var optionsButton: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
                .frame(width: Self.controlHeight, height: Self.controlHeight)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Options")
    }

    /// The menu's items. Customize leads (the in-popover screen users reach for most), then Settings,
    /// which opens the standalone Settings window (closing the popover on the way, via the installed
    /// handler). `autoenablesItems` has no SwiftUI equivalent, so the Check for Updates item disables
    /// itself when Sparkle can't currently check — e.g. dev builds with no feed, or while a check is
    /// already in flight. Customize, Settings, and Memory carry their key equivalents so the menu
    /// shows the shortcuts: when the menu is open the items handle them; when it's closed the
    /// `PopoverKeyReader` monitor handles (and consumes) them first, so the equivalents can't
    /// double-fire. Same split as the Quit ⌘Q item below.
    @ViewBuilder
    private var menuItems: some View {
        Button { toggle(.customize) } label: {
            Label("Customize", systemImage: "slider.horizontal.3")
        }
        .keyboardShortcut(.return, modifiers: [])

        Button { SettingsWindowLink.open() } label: {
            Label("Settings", systemImage: "gearshape")
        }
        .keyboardShortcut(",")

        Button { MemoryWindowLink.open() } label: {
            Label("Memory", systemImage: "brain")
        }
        .keyboardShortcut("m")

        Divider()

        shareScreenshotMenu

        Button { updater.checkForUpdates() } label: {
            Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(!updater.canCheckForUpdates)

        Divider()

        Button { AboutPanel.present() } label: {
            Label("About Runway", systemImage: "info.circle")
        }
        Button(role: .destructive) { NSApplication.shared.terminate(nil) } label: {
            Label("Quit Runway", systemImage: "power")
        }
        .keyboardShortcut("q") // ⌘Q — unowned elsewhere, so safe to register on the item.
    }

    /// The footer's "Share Screenshot" submenu: one entry per provider currently showing on the
    /// dashboard (`displayGroups` — enabled providers with at least one visible metric), so a screenshot
    /// is reachable without right-clicking a card. Each entry runs the same render path as the per-provider
    /// right-click "Share Screenshot": a branded PNG of that provider's card copied to the clipboard. The
    /// menu renders in its own `NSMenu`-backed window, so firing an item doesn't close the popover the way
    /// a navigation toggle would — the share card reads the same live stores the dashboard does.
    @ViewBuilder
    private var shareScreenshotMenu: some View {
        let groups = layout.displayGroups(matching: dataStore.isMetricApplicable)
        Menu {
            if groups.isEmpty {
                // No provider is showing anything to screenshot — grey the item out instead of offering
                // an empty submenu.
                Button("No Enabled Providers") {}
                    .disabled(true)
            } else {
                ForEach(groups) { group in
                    Button(container.displayName(for: group.provider)) { shareCard(group) }
                }
            }
        } label: {
            Label("Share Screenshot", systemImage: "square.and.arrow.up")
        }
    }

    /// Renders the provider's branded share card and copies the PNG to the clipboard — the same action as
    /// the dashboard's per-provider right-click "Share Screenshot". The appearance comes from the
    /// popover's own `colorScheme`: the footer lives in the popover panel, whose appearance is
    /// `AppearanceSetting.current` (explicit for Light/Dark, the menu bar for System), so the export
    /// matches the card on screen instead of guessing from `NSApp.effectiveAppearance`.
    private func shareCard(_ group: ProviderGroup) {
        ShareCardRenderer.share(
            group: group,
            dataStore: dataStore,
            layout: layout,
            appearance: colorScheme,
            displayName: container.displayName(for: group.provider)
        )
    }

    private func toggle(_ screen: PopoverScreen) {
        withAnimation(Motion.modeSwitch) {
            layout.screen = layout.screen == screen ? .dashboard : screen
        }
    }
}
