import XCTest
@testable import Runway

/// The in-popover screen mode (dashboard / Customize) and its `isEditing` bridge,
/// which older call sites still drive Customize through.
@MainActor
final class PopoverScreenTests: XCTestCase {
    func testStartsOnDashboard() {
        let store = makeStore("Default")
        XCTAssertEqual(store.screen, .dashboard)
        XCTAssertFalse(store.isEditing)
    }

    func testIsEditingBridgesCustomizeScreen() {
        let store = makeStore("Bridge")

        store.isEditing = true
        XCTAssertEqual(store.screen, .customize)

        store.isEditing = false
        XCTAssertEqual(store.screen, .dashboard)
    }

    func testScreensReplaceEachOther() {
        let store = makeStore("Switch")

        store.screen = .customize
        store.screen = .dashboard
        XCTAssertEqual(store.screen, .dashboard)
        XCTAssertFalse(store.isEditing)

        store.screen = .customize
        XCTAssertTrue(store.isEditing)
    }

    private func makeStore(_ name: String) -> LayoutStore {
        let suiteName = "RunwayTests.PopoverScreen.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
    }
}
