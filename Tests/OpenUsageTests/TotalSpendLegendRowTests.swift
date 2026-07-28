import XCTest
@testable import OpenUsage

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

        XCTAssertEqual(allocation.reclaimedWidth, 50)
        XCTAssertEqual(allocation.hiddenValueFraction, 0.42)
    }
}
