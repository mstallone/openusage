import XCTest
@testable import Runway

/// The app intentionally exposes one layout and keeps its dimensions compact.
final class DensitySettingTests: XCTestCase {
    func testCompactIsTheOnlyLayout() {
        XCTAssertEqual(DensitySetting.allCases, [.compact])
    }

    func testSectionSpacingStaysWiderThanRowRhythm() {
        let density = DensitySetting.compact
        XCTAssertGreaterThan(density.sectionSpacing, density.textRowPadding)
        XCTAssertGreaterThan(density.sectionSpacing, density.headerToCardSpacing)
    }
}
