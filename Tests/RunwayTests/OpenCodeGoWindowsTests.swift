import XCTest
@testable import Runway

/// The Go plan window math: rolling 5h session, UTC-Monday week, and the earliest-usage-anchored month
/// (with day-of-month clamping and a calendar-month fallback).
final class OpenCodeGoWindowsTests: XCTestCase {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private func d(_ iso: String) -> Date { RunwayISO8601.date(from: iso)! }
    private func epochMs(_ iso: String) -> Double { d(iso).timeIntervalSince1970 * 1000 }

    func testSessionRolling5Hours() {
        let now = d("2026-07-12T12:00:00.000Z")
        let costs: [(ms: Double, cost: Double)] = [
            (ms: epochMs("2026-07-12T11:00:00.000Z"), cost: 2.0),  // 1h ago, in window
            (ms: epochMs("2026-07-12T08:30:00.000Z"), cost: 1.5),  // 3.5h ago, in window (oldest)
            (ms: epochMs("2026-07-12T06:00:00.000Z"), cost: 5.0)   // 6h ago, outside 5h window
        ]
        let windows = OpenCodeGoWindowMath.compute(costs: costs, anchorMs: nil, now: now)
        XCTAssertEqual(windows.sessionSpend, 3.5, accuracy: 0.0001)
        // Reset is 5h after the oldest in-window row (08:30 → 13:30).
        XCTAssertEqual(windows.sessionResetsAt, d("2026-07-12T13:30:00.000Z"))
    }

    func testSessionResetIsFiveHoursAheadWhenIdle() {
        let now = d("2026-07-12T12:00:00.000Z")
        let windows = OpenCodeGoWindowMath.compute(costs: [], anchorMs: nil, now: now)
        XCTAssertEqual(windows.sessionSpend, 0, accuracy: 0.0001)
        XCTAssertEqual(windows.sessionResetsAt, d("2026-07-12T17:00:00.000Z"))
    }

    func testWeeklyUTCMondayBoundary() {
        let now = d("2026-07-12T12:00:00.000Z") // Sunday
        let costs: [(ms: Double, cost: Double)] = [
            (ms: epochMs("2026-07-06T00:00:00.000Z"), cost: 4.0),  // Monday 00:00 — first instant of week
            (ms: epochMs("2026-07-05T23:59:59.000Z"), cost: 9.0),  // just before week start — excluded
            (ms: epochMs("2026-07-12T11:00:00.000Z"), cost: 1.0)   // in week
        ]
        let windows = OpenCodeGoWindowMath.compute(costs: costs, anchorMs: nil, now: now)
        XCTAssertEqual(windows.weeklySpend, 5.0, accuracy: 0.0001)
        XCTAssertEqual(windows.weeklyResetsAt, d("2026-07-13T00:00:00.000Z"))
        XCTAssertEqual(utc.component(.weekday, from: windows.weeklyResetsAt!), 2) // Monday
    }

    func testMonthlyAnchoredToEarliestDayOfMonth() {
        let now = d("2026-07-12T12:00:00.000Z")
        let anchor = epochMs("2026-03-05T09:30:00.000Z") // day 5 @ 09:30
        let costs: [(ms: Double, cost: Double)] = [
            (ms: epochMs("2026-07-05T09:30:00.000Z"), cost: 10.0), // cycle-start instant — included
            (ms: epochMs("2026-07-05T09:29:59.000Z"), cost: 7.0),  // one second before — excluded
            (ms: epochMs("2026-07-11T00:00:00.000Z"), cost: 5.0)   // in cycle
        ]
        let windows = OpenCodeGoWindowMath.compute(costs: costs, anchorMs: anchor, now: now)
        XCTAssertEqual(windows.monthlySpend, 15.0, accuracy: 0.0001)
        XCTAssertEqual(windows.monthlyResetsAt, d("2026-08-05T09:30:00.000Z"))
        let start = d("2026-07-05T09:30:00.000Z")
        let end = d("2026-08-05T09:30:00.000Z")
        XCTAssertEqual(windows.monthlyPeriodMs, Int((end.timeIntervalSince1970 - start.timeIntervalSince1970) * 1000))
    }

    func testMonthlyAnchorLaterInMonthUsesPreviousCycle() {
        let now = d("2026-07-12T12:00:00.000Z")
        let anchor = epochMs("2026-01-20T00:00:00.000Z") // day 20 — after today's 12th
        let windows = OpenCodeGoWindowMath.compute(costs: [], anchorMs: anchor, now: now)
        // July 20 start is in the future, so the live cycle is June 20 → July 20.
        XCTAssertEqual(windows.monthlyResetsAt, d("2026-07-20T00:00:00.000Z"))
    }

    func testMonthlyAnchorDayClampedForShortMonth() {
        let now = d("2026-06-15T12:00:00.000Z") // June has 30 days
        let anchor = epochMs("2026-01-31T00:00:00.000Z") // day 31
        let windows = OpenCodeGoWindowMath.compute(costs: [], anchorMs: anchor, now: now)
        // June clamps 31→30; June 30 start is future → cycle is May 31 → June 30.
        XCTAssertEqual(windows.monthlyResetsAt, d("2026-06-30T00:00:00.000Z"))
    }

    func testMonthlyCalendarFallbackWithoutAnchor() {
        let now = d("2026-07-12T12:00:00.000Z")
        let windows = OpenCodeGoWindowMath.compute(costs: [], anchorMs: nil, now: now)
        XCTAssertEqual(windows.monthlyResetsAt, d("2026-08-01T00:00:00.000Z"))
    }
}
