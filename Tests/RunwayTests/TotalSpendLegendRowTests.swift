import XCTest
@testable import Runway

final class TotalSpendLegendRowTests: XCTestCase {
    func testShortTitleKeepsTheEntireValueOnHover() {
        let allocation = LegendRowWidthAllocation.resolve(
            availableWidth: 200,
            titleWidth: 80,
            valueWidth: 40,
            spacing: 8
        )

        XCTAssertEqual(allocation.reclaimedWidth, 0)
        XCTAssertEqual(allocation.hiddenValueFraction, 0)
    }

    func testTitleConsumesSpacingBeforeFadingValue() {
        let allocation = LegendRowWidthAllocation.resolve(
            availableWidth: 200,
            titleWidth: 156,
            valueWidth: 40,
            spacing: 8
        )

        XCTAssertEqual(allocation.reclaimedWidth, 4)
        XCTAssertEqual(allocation.hiddenValueFraction, 0)
    }

    func testValueFadesOnlyByTheWidthTheTitleNeeds() {
        let allocation = LegendRowWidthAllocation.resolve(
            availableWidth: 200,
            titleWidth: 170,
            valueWidth: 40,
            spacing: 8
        )

        XCTAssertEqual(allocation.reclaimedWidth, 18)
        XCTAssertEqual(allocation.hiddenValueFraction, 0.25)
    }

    func testVeryLongTitleCanFullyReclaimItsOwnValue() {
        let allocation = LegendRowWidthAllocation.resolve(
            availableWidth: 200,
            titleWidth: 240,
            valueWidth: 40,
            spacing: 8
        )

        XCTAssertEqual(allocation.reclaimedWidth, 48)
        XCTAssertEqual(allocation.hiddenValueFraction, 1)
    }

    func testValueWiderThanRowUsesTheDisplayedWidthForAllocation() {
        let allocation = LegendRowWidthAllocation.resolve(
            availableWidth: 100,
            titleWidth: 50,
            valueWidth: 300,
            spacing: 8
        )

        XCTAssertEqual(allocation.reclaimedWidth, 58)
        XCTAssertEqual(allocation.hiddenValueFraction, 0.5)

        let displayedValueWidth: CGFloat = 100
        let reservedWidth = max(0, displayedValueWidth + 8 - allocation.reclaimedWidth)
        XCTAssertEqual(100 - reservedWidth, 50, "the title receives its full requested width")
    }
}
