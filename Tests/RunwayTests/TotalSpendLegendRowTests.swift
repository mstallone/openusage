import XCTest
@testable import Runway

final class TotalSpendLegendRowTests: XCTestCase {
    func testShortTitleKeepsTheTitleAndValueStateOnHover() {
        XCTAssertFalse(
            LegendRowPresentation.titleNeedsFullWidth(
                availableWidth: 200,
                titleWidth: 80,
                valueWidth: 40,
                spacing: 8
            )
        )
    }

    func testTruncatedTitleUsesTheFullWidthHoverState() {
        XCTAssertTrue(
            LegendRowPresentation.titleNeedsFullWidth(
                availableWidth: 200,
                titleWidth: 156,
                valueWidth: 40,
                spacing: 8
            )
        )
    }

    func testTitleThatExactlyFitsDoesNotChangeOnHover() {
        XCTAssertFalse(
            LegendRowPresentation.titleNeedsFullWidth(
                availableWidth: 200,
                titleWidth: 152,
                valueWidth: 40,
                spacing: 8
            )
        )
    }

    func testVeryLongTitleUsesTheFullWidthHoverStateWithoutWrapping() {
        XCTAssertTrue(
            LegendRowPresentation.titleNeedsFullWidth(
                availableWidth: 200,
                titleWidth: 240,
                valueWidth: 40,
                spacing: 8
            )
        )
    }

    func testMissingGeometryKeepsTheRestingState() {
        XCTAssertFalse(
            LegendRowPresentation.titleNeedsFullWidth(
                availableWidth: 0,
                titleWidth: 50,
                valueWidth: 40,
                spacing: 8
            )
        )
    }
}
