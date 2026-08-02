import XCTest
@testable import Runway

/// The profiling harness must be a zero-cost pass-through when the env gate is off — these tests
/// run without RUNWAY_UI_PROFILE, so they pin the disabled behavior every real user gets.
@MainActor
final class UIProfilerTests: XCTestCase {
    func testDisabledOutsideProfilingRuns() {
        XCTAssertFalse(UIProfiler.enabled)
    }

    func testMeasureReturnsBodyValueAndPropagatesErrors() throws {
        XCTAssertEqual(UIProfiler.measure("test") { 41 + 1 }, 42)

        struct Boom: Error {}
        XCTAssertThrowsError(try UIProfiler.measure("test") { throw Boom() })
    }
}
