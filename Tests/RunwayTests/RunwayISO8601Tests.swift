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
}
