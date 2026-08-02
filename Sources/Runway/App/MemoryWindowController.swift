import AppKit
import SwiftUI

/// Lets callers anywhere in the app — the popover footer's gear menu and the status item's context
/// menu — open the standalone Memory window without knowing who owns it. Installed by
/// `StatusItemController` at launch, mirroring the `SettingsWindowLink` pattern.
@MainActor
public enum MemoryWindowLink {
    /// Closes the popover (when open) and shows the Memory window.
    public static var openHandler: (@MainActor () -> Void)?

    public static func open() {
        openHandler?()
    }
}

/// The Memory window: a plain titled window that also closes on Esc and ⌘W. As a menu-bar accessory
/// app Runway has no visible main menu to route ⌘W through, so the window handles the keystroke
/// itself when it bubbles up the responder chain unclaimed. Unlike `SettingsWindow`, closes go
/// through `performClose` so the delegate's dirty-editor prompt always gets its say.
final class MemoryWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        // Esc belongs to a live text view (end editing) — the same carve-out as the popover's key
        // monitor, and what keeps Esc inside the editor's `TextEditor` from closing the window.
        if event.keyCode == 53, // Esc
           !(firstResponder is NSText) {
            performClose(nil)
            return
        }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return
        }
        super.keyDown(with: event)
    }
}

/// Owns the standalone Memory Explorer window — same lifecycle discipline as
/// `SettingsWindowController`:
/// - **Lazy**: nothing exists until the first open — launching the app allocates only this
///   controller. The `MemoryStore` (and its scanned inventory) is built with the window.
/// - **Torn down on close**: `windowWillClose` drops the window, the hosting controller, and the
///   store, so a closed Memory window costs zero CPU and memory.
/// - **Remembered geometry**: the window is resizable and its frame persists via
///   `setFrameAutosaveName` — no manual height bookkeeping like Settings' fixed-width panes need.
///
/// Close safety: memory files are edited explicitly (no autosave), so `windowShouldClose` prompts
/// Save / Discard / Cancel while the editor holds unsaved changes, and `windowDidBecomeKey` nudges
/// the editor to re-stat its file for external changes.
@MainActor
final class MemoryWindowController: NSObject, NSWindowDelegate {
    private let activation: ActivationPolicyCoordinator
    /// The account registry, injected into the window's environment so the sidebar can resolve
    /// renamed Claude/Codex account cards by home path — live, like every other card title.
    private let accounts: ProviderAccountsStore

    private var window: MemoryWindow?
    private var hosting: NSHostingController<AnyView>?
    private var store: MemoryStore?
    /// Set after the close prompt's Save completes so the programmatic re-close skips a second
    /// prompt; reset with the rest of the teardown.
    private var closeIsApproved = false

    private static let frameAutosaveName = "RunwayMemoryWindow"
    private static let defaultContentSize = NSSize(width: 980, height: 620)
    private static let minimumContentSize = NSSize(width: 720, height: 460)

    init(accounts: ProviderAccountsStore, activation: ActivationPolicyCoordinator = .shared) {
        self.accounts = accounts
        self.activation = activation
        super.init()
    }

    /// Shows the window, creating it on first use.
    ///
    /// Same foreground story as Settings: plain `activate(ignoringOtherApps:)` is unreliable for
    /// this dockless accessory app while another app is frontmost (sparkle-project/Sparkle#2889),
    /// so the window holds a promotion via the shared `ActivationPolicyCoordinator` for its
    /// lifetime; `windowWillClose` releases the hold.
    func show() {
        if window == nil {
            UIProfiler.measure("memoryOpen.buildWindow") { buildWindow() }
        }
        guard let window else { return }
        activation.acquire(.memoryWindow, reason: "memory window opened")
        // `makeKeyAndOrderFront` does not pull a window back out of the Dock, so a minimized
        // Memory window would make every entry point look dead.
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        UIProfiler.measure("memoryOpen.orderFront") { window.makeKeyAndOrderFront(nil) }
    }

    /// The UI-profiling driver's close chokepoint: a direct close (no dirty prompt — the driver
    /// never types), running the full `windowWillClose` teardown a real close runs.
    func close() {
        window?.close()
    }

    /// The live store while the window is up — the profiling driver selects documents through it.
    var currentStore: MemoryStore? { store }

    /// Quit (Dock, status menu, ⌘Q) never routes through `windowShouldClose`, so the app delegate
    /// asks here: a dirty memory buffer gets the same Save / Discard / Cancel say before the
    /// process exits. Save is async, so it answers `.terminateLater` and replies when the write
    /// lands — or fails, which cancels the quit (the editor still holds the buffer).
    static func terminationReplyForDirtyEditor() -> NSApplication.TerminateReply {
        guard MemoryEditorState.shared.isDirty else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save Changes?"
        alert.informativeText = "A memory has unsaved changes. Quitting without saving discards them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard let save = MemoryEditorState.shared.saveDirtyDocument else {
                AppLog.error(.memory, "quit prompt chose Save but no editor save hook is installed; nothing to write")
                return .terminateNow
            }
            Task { @MainActor in
                do {
                    try await save()
                    NSApplication.shared.reply(toApplicationShouldTerminate: true)
                } catch {
                    AppLog.error(.memory, "saving before quit failed: \(error.localizedDescription)")
                    NSApplication.shared.reply(toApplicationShouldTerminate: false)
                }
            }
            return .terminateLater
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    // MARK: - Window construction

    private func buildWindow() {
        let store = MemoryStore()
        self.store = store

        let hosting = NSHostingController(
            rootView: AnyView(
                MemoryRootView()
                    .environment(store)
                    .environment(accounts)
            )
        )
        // The user owns this window's size (resizable + frame autosave); letting the hosting
        // controller push its ideal size would fight that.
        hosting.sizingOptions = []
        self.hosting = hosting

        let window = MemoryWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // Nothing to restore (reopening rescans the live files), and the restoration machinery
        // would keep the closed window alive — defeating the close-means-teardown design.
        window.isRestorable = false
        window.delegate = self
        // The title stays set for Mission Control and accessibility, but the bar itself dissolves:
        // `MemoryRootView`'s vibrancy backdrop owns the whole window surface and the traffic lights
        // float over it (the sidebar clears them with top padding).
        window.title = "Memory"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentMinSize = Self.minimumContentSize
        window.contentViewController = hosting
        // Follows the app-wide theme override automatically, like every regular window (see
        // `SettingsWindowController.buildWindow`).

        // AppKit persists and restores the resizable frame under this name; first-ever open (no
        // saved frame yet) centers instead.
        window.setFrameAutosaveName(Self.frameAutosaveName)
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }

        self.window = window
        AppLog.info(.memory, "Memory window opened")
    }

    // MARK: - NSWindowDelegate

    /// Returning to the window is the moment an external change (a live agent rewriting a memory
    /// file) becomes visible — nudge the editor to re-stat its document.
    func windowDidBecomeKey(_ notification: Notification) {
        Task { @MainActor in
            await MemoryEditorState.shared.recheckExternalChange?()
        }
    }

    /// Guards every close path (close button, Esc, ⌘W — all routed through `performClose`) while
    /// the editor holds unsaved changes: Save writes the buffer and then closes, Discard closes and
    /// drops the buffer with the teardown, Cancel keeps the window up.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard MemoryEditorState.shared.isDirty, !closeIsApproved else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save Changes?"
        alert.informativeText = "This memory has unsaved changes. Closing without saving discards them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Saving is async (the write runs off the main actor); veto this close and re-close
            // once the save lands. A failed save keeps the window open — the editor surfaces the
            // error, and closing anyway would silently drop the buffer.
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A nil hook means the editor is no longer mounted and the dirty flag is stale —
                // there is no buffer left to write. Anything else must actually save; an
                // optional-chained call would report vacuous success and close over a dropped buffer.
                guard let save = MemoryEditorState.shared.saveDirtyDocument else {
                    AppLog.error(.memory, "close prompt chose Save but no editor save hook is installed; nothing to write")
                    self.closeIsApproved = true
                    self.window?.close()
                    return
                }
                do {
                    try await save()
                    self.closeIsApproved = true
                    self.window?.close()
                } catch MemoryEditorError.conflictDetected {
                    // The editor is showing Reload / Overwrite; the window stays open for the
                    // user to answer, and closing retries after that.
                    AppLog.info(.memory, "close-prompt save hit a disk conflict; leaving the window open")
                } catch {
                    // The window silently staying open would read as a broken close button.
                    AppLog.error(.memory, "saving before close failed: \(error.localizedDescription)")
                    let failureAlert = NSAlert()
                    failureAlert.alertStyle = .warning
                    failureAlert.messageText = "Could Not Save"
                    failureAlert.informativeText = error.localizedDescription
                    failureAlert.runModal()
                }
            }
            return false
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    /// The whole point of the teardown: a closed Memory window keeps no SwiftUI tree, no hosting
    /// view, no window, and no store — reopening rebuilds them and rescans in milliseconds.
    func windowWillClose(_ notification: Notification) {
        guard let window else { return }
        // Undo `show()`'s promotion. The coordinator only drops to `.accessory` once no other
        // surface (Settings, a live Sparkle update window) still holds the front.
        activation.release(.memoryWindow)
        window.delegate = nil
        // Release outside the delegate callback — deallocating an NSWindow while AppKit is still
        // unwinding its close is the classic over-release crash. Detach the content controller
        // first: the AppKit↔SwiftUI bridge otherwise keeps the closed window (and the whole
        // editor tree) alive, which is exactly the idle cost this window exists to avoid.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.window?.contentViewController = nil
            self.hosting = nil
            self.window = nil
            self.store = nil
            self.closeIsApproved = false
            // The editor's `onDisappear` also resets this; doing it here too keeps a torn-down
            // window from leaving a stale dirty flag if the SwiftUI teardown is ever skipped.
            MemoryEditorState.shared.reset()
        }
    }
}
