import Foundation
import Testing
@testable import Runway

struct RunwayISO8601Tests {
    @Test func parsesZuluISO() {
        let date = RunwayISO8601.date(from: "2099-01-01T00:00:00.000Z")
        #expect(date != nil)
    }

    @Test func normalizesMicrosecondsWithoutTimezoneLikeClaudeAPI() {
        let date = RunwayISO8601.date(from: "2099-01-01T00:00:00.123456")
        #expect(date != nil)
        #expect(RunwayISO8601.string(from: date!) == "2099-01-01T00:00:00.123Z")
    }

    @Test func normalizesSpaceSeparatedUTC() {
        let date = RunwayISO8601.date(from: "2099-01-01 00:00:00 UTC")
        #expect(date != nil)
    }

    @Test func padsShortFractionalSeconds() {
        let date = RunwayISO8601.date(from: "2099-01-01T00:00:00.1Z")
        #expect(date != nil)
        #expect(RunwayISO8601.string(from: date!) == "2099-01-01T00:00:00.100Z")
    }

    @Test func assumesUTCWhenTimezoneIsMissing() {
        let date = RunwayISO8601.date(from: "2099-01-01T00:00:00")
        #expect(date != nil)
        #expect(RunwayISO8601.string(from: date!) == "2099-01-01T00:00:00.000Z")
    }

    @Test func preservesExplicitTimezoneOffsets() {
        let date = RunwayISO8601.date(from: "2099-01-01T01:30:00.12+01:30")
        #expect(date != nil)
        #expect(RunwayISO8601.string(from: date!) == "2099-01-01T00:00:00.120Z")
    }
}
