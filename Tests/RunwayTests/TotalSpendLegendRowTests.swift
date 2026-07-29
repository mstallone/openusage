import XCTest
@testable import Runway

final class TotalSpendLegendRowTests: XCTestCase {
    func testShortTitleKeepsTheTitleAndValueStateOnHover() {
        let allocation = LegendRowWidthAllocation.resolve(
            availableWidth: 200,
            titleWidth: 80,
            valueWidth: 40,
            spacing: 8
        )

        XCTAssertEqual(allocation.reclaimedWidth, 0)
        XCTAssertEqual(allocation.hiddenValueFraction, 0)
    }

    func testTitleConsumesSpacingBeforeFadingTheValue() {
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

    func testVeryLongTitleCanConsumeTheEntireValue() {
        let allocation = LegendRowWidthAllocation.resolve(
            availableWidth: 200,
            titleWidth: 240,
            valueWidth: 40,
            spacing: 8
        )

        XCTAssertEqual(allocation.reclaimedWidth, 48)
        XCTAssertEqual(allocation.hiddenValueFraction, 1)
    }

    func testMissingGeometryKeepsTheRestingState() {
        let allocation = LegendRowWidthAllocation.resolve(
            availableWidth: 0,
            titleWidth: 50,
            valueWidth: 40,
            spacing: 8
        )

        XCTAssertEqual(allocation.reclaimedWidth, 0)
        XCTAssertEqual(allocation.hiddenValueFraction, 0)
    }

    func testTitleWithinTheFullRowDoesNotMarquee() {
        XCTAssertNil(
            LegendRowMarqueeMetrics.resolve(
                availableWidth: 200,
                titleWidth: 200
            )
        )
    }

    func testTitleWiderThanTheFullRowMarqueesByOnlyItsOverflow() throws {
        let metrics = try XCTUnwrap(
            LegendRowMarqueeMetrics.resolve(
                availableWidth: 200,
                titleWidth: 264
            )
        )

        XCTAssertEqual(metrics.distance, 64)
        XCTAssertEqual(metrics.duration, 2)
    }

    func testMarqueeDurationIsCappedForVeryLongTitles() throws {
        let metrics = try XCTUnwrap(
            LegendRowMarqueeMetrics.resolve(
                availableWidth: 200,
                titleWidth: 600
            )
        )

        XCTAssertEqual(metrics.distance, 400)
        XCTAssertEqual(metrics.duration, 6)
    }

    func testReduceMotionJumpsToTheMarqueeEndingOnHover() {
        XCTAssertEqual(
            LegendRowMarqueeOffset.immediateTarget(
                isActive: true,
                reduceMotion: true,
                distance: 64
            ),
            -64
        )
        XCTAssertEqual(
            LegendRowMarqueeOffset.immediateTarget(
                isActive: false,
                reduceMotion: true,
                distance: 64
            ),
            0
        )
        XCTAssertEqual(
            LegendRowMarqueeOffset.immediateTarget(
                isActive: true,
                reduceMotion: false,
                distance: 64
            ),
            0
        )
    }
}
