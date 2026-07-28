import XCTest
@testable import Runway

/// The Go cap meters: correct caps, dollar format, resets, and periods.
final class OpenCodeUsageMapperTests: XCTestCase {
    func testMeterLinesCarryCapsFormatsResetsAndPeriods() {
        let reset = RunwayISO8601.date(from: "2026-07-12T13:30:00.000Z")!
        let windows = OpenCodeGoWindows(
            sessionSpend: 6.0, sessionResetsAt: reset,
            weeklySpend: 12.0, weeklyResetsAt: reset,
            monthlySpend: 40.0, monthlyResetsAt: reset, monthlyPeriodMs: 2_592_000_000
        )
        let lines = OpenCodeUsageMapper.meterLines(windows)
        XCTAssertEqual(lines.map(\.label), ["Session", "Weekly", "Monthly"])

        guard case let .progress(_, sessionUsed, sessionLimit, sessionFormat, sessionReset, sessionPeriod, _) = lines[0] else {
            return XCTFail("session is not a progress line")
        }
        XCTAssertEqual(sessionUsed, 6.0)
        XCTAssertEqual(sessionLimit, 12)
        XCTAssertEqual(sessionFormat, .dollars)
        XCTAssertEqual(sessionReset, reset)
        XCTAssertEqual(sessionPeriod, 5 * 60 * 60 * 1000)

        guard case let .progress(_, _, weeklyLimit, weeklyFormat, _, weeklyPeriod, _) = lines[1] else {
            return XCTFail("weekly is not a progress line")
        }
        XCTAssertEqual(weeklyLimit, 30)
        XCTAssertEqual(weeklyFormat, .dollars)
        XCTAssertEqual(weeklyPeriod, 7 * 24 * 60 * 60 * 1000)

        guard case let .progress(_, monthlyUsed, monthlyLimit, monthlyFormat, _, monthlyPeriod, _) = lines[2] else {
            return XCTFail("monthly is not a progress line")
        }
        XCTAssertEqual(monthlyUsed, 40.0)
        XCTAssertEqual(monthlyLimit, 60)
        XCTAssertEqual(monthlyFormat, .dollars)
        XCTAssertEqual(monthlyPeriod, 2_592_000_000)
    }
}
