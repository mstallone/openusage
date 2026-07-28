import AppKit
import XCTest
@testable import Runway

final class PanelGeometryTests: XCTestCase {
    func testHorizontalPlacementStaysInsideVisibleFrame() {
        let visible = NSRect(x: 0, y: 0, width: 500, height: 900)
        let left = PanelGeometry.clampedTopLeft(
            below: NSRect(x: -40, y: 850, width: 20, height: 20),
            width: 320,
            visibleFrame: visible
        )
        let right = PanelGeometry.clampedTopLeft(
            below: NSRect(x: 490, y: 850, width: 20, height: 20),
            width: 320,
            visibleFrame: visible
        )

        XCTAssertEqual(left.x, 8)
        XCTAssertEqual(right.x, 172)
        XCTAssertEqual(left.y, 846)
    }

    func testMaximumHeightUsesAvailableRoomAndDisplayCap() {
        let visible = NSRect(x: 0, y: 0, width: 1200, height: 1000)

        XCTAssertEqual(
            PanelGeometry.maximumHeight(topLeft: NSPoint(x: 100, y: 900), visibleFrame: visible),
            850
        )
    }

    func testShortDisplayMayShrinkBelowNormalMinimum() {
        let visible = NSRect(x: 0, y: 0, width: 500, height: 200)
        let maximum = PanelGeometry.maximumHeight(
            topLeft: NSPoint(x: 100, y: 190),
            visibleFrame: visible
        )

        XCTAssertEqual(maximum, 170)
        XCTAssertEqual(PanelGeometry.clampedHeight(600, maximum: maximum), 170)
    }

    func testHeightClampsToNormalMinimumAndDisplayMaximum() {
        XCTAssertEqual(PanelGeometry.clampedHeight(50, maximum: 700), 200)
        XCTAssertEqual(PanelGeometry.clampedHeight(900, maximum: 700), 700)
        XCTAssertEqual(PanelGeometry.clampedHeight(520, maximum: 700), 520)
    }

    func testChangingHeightKeepsTopEdgeFixed() {
        let topLeft = NSPoint(x: 120, y: 800)
        let short = PanelGeometry.frame(topLeft: topLeft, width: 320, height: 300)
        let tall = PanelGeometry.frame(topLeft: topLeft, width: 320, height: 650)

        XCTAssertEqual(short.maxY, topLeft.y)
        XCTAssertEqual(tall.maxY, topLeft.y)
        XCTAssertEqual(short.minX, tall.minX)
        XCTAssertEqual(short.width, tall.width)
    }
}
