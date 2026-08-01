import XCTest
@testable import Runway

/// The Settings window's pane identity: raw values are persisted (last-selected pane, per-pane
/// height keys) and double as the toolbar item identifiers, so they must stay stable, and every
/// pane must round-trip through its raw value.
final class SettingsPaneTests: XCTestCase {
    func testRawValuesAreStable() {
        XCTAssertEqual(
            SettingsPane.allCases.map(\.rawValue),
            ["general", "appearance", "notifications", "advanced"]
        )
    }

    func testRawValueRoundTrips() {
        for pane in SettingsPane.allCases {
            XCTAssertEqual(SettingsPane(rawValue: pane.rawValue), pane)
        }
    }

    func testEveryPaneHasTitleAndSymbol() {
        for pane in SettingsPane.allCases {
            XCTAssertFalse(pane.title.isEmpty)
            XCTAssertFalse(pane.systemSymbol.isEmpty)
        }
    }
}
