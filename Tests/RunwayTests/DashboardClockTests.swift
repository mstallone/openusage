import XCTest
@testable import Runway

@MainActor
final class DashboardClockTests: XCTestCase {
    func testStartStampsBothDatesFresh() {
        let clock = DashboardClock()
        let before = Date()
        clock.start()
        defer { clock.stop() }
        XCTAssertGreaterThanOrEqual(clock.perSecond, before)
        XCTAssertEqual(clock.perSecond, clock.halfMinute)
    }

    func testStartIsIdempotentWhileRunning() {
        let clock = DashboardClock()
        clock.start()
        defer { clock.stop() }
        let stamped = clock.perSecond
        clock.start()
        XCTAssertEqual(clock.perSecond, stamped)
    }

    func testStopKeepsLastDates() {
        let clock = DashboardClock()
        clock.start()
        let stamped = clock.perSecond
        clock.stop()
        XCTAssertEqual(clock.perSecond, stamped)
        XCTAssertEqual(clock.halfMinute, stamped)
    }
}
