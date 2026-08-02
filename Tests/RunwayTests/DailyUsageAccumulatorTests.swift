import XCTest
@testable import Runway

/// Direct pins for the shared accumulate-then-assemble contract behind the Claude/Codex/Grok scanners
/// (the class of drift behind the ccusage false-zero fix): one `dayKey` spelling, newest-first day
/// order, per-model accumulation, always-priced days, and unknown models isolated from the series.
final class DailyUsageAccumulatorTests: XCTestCase {
    func testDayKeyUsesInjectedCalendarAndZeroPads() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 2024-03-07 23:30 UTC — pads month and day to two digits.
        let date = calendar.date(from: DateComponents(year: 2024, month: 3, day: 7, hour: 23, minute: 30))!
        XCTAssertEqual(DailyUsageAccumulator.dayKey(from: date, calendar: calendar), "2024-03-07")

        // The key is local-calendar: one instant, two time zones, two different days.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(DailyUsageAccumulator.dayKey(from: date, calendar: tokyo), "2024-03-08")
    }

    func testDayKeyMatchesLegacyStringFormat() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Sweep component shapes the manual zero-padding must reproduce byte-for-byte, including a
        // pre-1000 year (4-digit pad) — the exact output `String(format: "%04d-%02d-%02d")` gave.
        let cases: [(Int, Int, Int)] = [(2024, 3, 7), (2026, 12, 31), (2025, 1, 1), (987, 10, 9)]
        for (year, month, day) in cases {
            let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
            XCTAssertEqual(
                DailyUsageAccumulator.dayKey(from: date, calendar: calendar),
                String(format: "%04d-%02d-%02d", year, month, day)
            )
        }
    }

    func testDayKeyCacheMatchesDayKeyAcrossDayBoundaries() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var cache = DailyUsageAccumulator.DayKeyCache(calendar: calendar)
        let base = calendar.date(from: DateComponents(year: 2026, month: 2, day: 27))!

        // Hourly steps across three days (spanning a month boundary), then jumps backwards — the
        // cache must agree with the uncached key in and out of order.
        var dates: [Date] = (0..<72).map { base.addingTimeInterval(Double($0) * 3600) }
        dates.append(base)
        dates.append(base.addingTimeInterval(-1))
        dates.append(calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!)

        for date in dates {
            XCTAssertEqual(
                cache.key(for: date),
                DailyUsageAccumulator.dayKey(from: date, calendar: calendar),
                "cache disagreed for \(date)"
            )
        }
    }

    func testDayKeyCacheHandlesMidnightSkippingDSTTransition() {
        // Egypt springs forward at midnight, so the DST start day begins at 01:00 — a cache that
        // computes the day's end as startOfDay + 1 day overshoots the NEXT day's real start and
        // would bill its first hour to the previous day.
        var cairo = Calendar(identifier: .gregorian)
        cairo.timeZone = TimeZone(identifier: "Africa/Cairo")!
        var cache = DailyUsageAccumulator.DayKeyCache(calendar: cairo)

        let dstDayNoon = cairo.date(from: DateComponents(year: 2026, month: 4, day: 24, hour: 12))!
        let nextDayEarly = cairo.date(from: DateComponents(year: 2026, month: 4, day: 25, minute: 30))!
        for date in [dstDayNoon, nextDayEarly, dstDayNoon] {
            XCTAssertEqual(
                cache.key(for: date),
                DailyUsageAccumulator.dayKey(from: date, calendar: cairo),
                "cache disagreed for \(date)"
            )
        }
    }

    func testBuildSortsDaysNewestFirstAndSumsPerModel() {
        var accumulator = DailyUsageAccumulator()
        accumulator.add(day: "2024-06-01", tokens: 100, cost: 1.0, model: "sonnet")
        accumulator.add(day: "2024-06-03", tokens: 50, cost: 0.5, model: "sonnet")
        accumulator.add(day: "2024-06-01", tokens: 200, cost: 2.0, model: "sonnet")
        accumulator.add(day: "2024-06-01", tokens: 10, cost: 0.1, model: "opus")

        let scan = accumulator.build()
        XCTAssertEqual(scan.series.daily.map(\.date), ["2024-06-03", "2024-06-01"])
        XCTAssertEqual(scan.series.daily.map(\.totalTokens), [50, 310])
        // Every counted day is priced — a real cost, never nil-by-omission.
        XCTAssertEqual(scan.series.daily[1].costUSD ?? -1, 3.1, accuracy: 0.0001)

        let june1 = scan.modelUsage?.daily.first { $0.date == "2024-06-01" }
        let models = Dictionary(uniqueKeysWithValues: (june1?.models ?? []).map { ($0.model, $0) })
        XCTAssertEqual(models["sonnet"]?.totalTokens, 300)
        XCTAssertEqual(models["sonnet"]?.costUSD ?? -1, 3.0, accuracy: 0.0001)
        XCTAssertEqual(models["opus"]?.totalTokens, 10)
    }

    func testUnknownModelsStayOutOfTheSeries() {
        var accumulator = DailyUsageAccumulator()
        accumulator.addUnknownModel(day: "2024-06-02", model: "mystery-model")

        let scan = accumulator.build()
        // A day with only unpriceable usage never enters the series or the model breakdown — it
        // surfaces solely through the warning-triangle set.
        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertEqual(scan.modelUsage?.daily.isEmpty, true)
        XCTAssertEqual(scan.unknownModelsByDay, ["2024-06-02": ["mystery-model"]])
    }
}
