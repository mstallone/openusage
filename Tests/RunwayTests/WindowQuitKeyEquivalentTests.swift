import AppKit
import XCTest
@testable import Runway

/// ⌘Q pressed while the Settings or Memory window is key must close just that window, never quit
/// the app: while either window is up the app is promoted to `.regular`, so the app menu's Quit
/// item is live and would otherwise take the whole menu-bar app down. The windows claim ⌘Q in
/// `performKeyEquivalent`, which runs before the main menu gets the keystroke.
@MainActor
final class WindowQuitKeyEquivalentTests: XCTestCase {
    private func commandQ(for window: NSWindow) -> NSEvent {
        keyEvent("q", modifierFlags: [.command], keyCode: 12, window: window)
    }

    private func keyEvent(
        _ character: String,
        modifierFlags: NSEvent.ModifierFlags,
        keyCode: UInt16,
        window: NSWindow
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private func expectClose(of window: NSWindow) -> XCTestExpectation {
        let closed = expectation(
            forNotification: NSWindow.willCloseNotification, object: window
        )
        return closed
    }

    func testSettingsWindowConsumesCommandQAndCloses() {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let closed = expectClose(of: window)

        XCTAssertTrue(window.performKeyEquivalent(with: commandQ(for: window)))
        wait(for: [closed], timeout: 1)
    }

    func testMemoryWindowConsumesCommandQAndCloses() {
        let window = MemoryWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let closed = expectClose(of: window)

        XCTAssertTrue(window.performKeyEquivalent(with: commandQ(for: window)))
        wait(for: [closed], timeout: 1)
    }

    func testMemoryWindowRoutesCommandQThroughTheClosePrompt() {
        // ⌘Q must ride `performClose` so a dirty editor's Save / Discard / Cancel prompt
        // (`windowShouldClose`) gets its say — a delegate veto keeps the window open.
        final class VetoDelegate: NSObject, NSWindowDelegate {
            var asked = false
            func windowShouldClose(_ sender: NSWindow) -> Bool {
                asked = true
                return false
            }
        }

        let window = MemoryWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let delegate = VetoDelegate()
        window.delegate = delegate

        XCTAssertTrue(window.performKeyEquivalent(with: commandQ(for: window)))
        XCTAssertTrue(delegate.asked)
        window.delegate = nil
        window.close()
    }

    func testUnrelatedKeyEquivalentsFallThrough() {
        let settings = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        settings.isReleasedWhenClosed = false
        defer { settings.close() }

        // Plain Q (no ⌘) and an unrelated ⌘ equivalent both fall through to AppKit.
        XCTAssertFalse(settings.performKeyEquivalent(
            with: keyEvent("q", modifierFlags: [], keyCode: 12, window: settings)
        ))
        XCTAssertFalse(settings.performKeyEquivalent(
            with: keyEvent("l", modifierFlags: [.command], keyCode: 37, window: settings)
        ))
    }
}
