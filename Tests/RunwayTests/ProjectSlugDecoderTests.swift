import XCTest
@testable import Runway

/// The slug→path decode rules: greedy dash-splitting verified against an injected filesystem,
/// with backtracking across dashed components and dot-directory recovery from doubled dashes.
/// Everything runs on a fake `directoryExists` — no real filesystem.
final class ProjectSlugDecoderTests: XCTestCase {
    private func makeDecoder(knownDirectories: Set<String>) -> ProjectSlugDecoder {
        ProjectSlugDecoder(directoryExists: { knownDirectories.contains($0) })
    }

    func testDecodesAPlainPath() {
        let decoder = makeDecoder(knownDirectories: [
            "/Users", "/Users/dev", "/Users/dev/project",
        ])

        XCTAssertEqual(decoder.bestEffortPath(fromSlug: "-Users-dev-project"), "/Users/dev/project")
    }

    func testDecodesAComponentContainingADash() {
        // "/Users/dev/my" does not exist, so the greedy split must extend across the dash.
        let decoder = makeDecoder(knownDirectories: [
            "/Users", "/Users/dev", "/Users/dev/my-branch",
        ])

        XCTAssertEqual(
            decoder.bestEffortPath(fromSlug: "-Users-dev-my-branch"), "/Users/dev/my-branch"
        )
    }

    func testDecodesADotDirectoryFromADoubledDash() {
        let decoder = makeDecoder(knownDirectories: [
            "/Users",
            "/Users/stallone",
            "/Users/stallone/.superset",
            "/Users/stallone/.superset/worktrees",
            "/Users/stallone/.superset/worktrees/abc123",
            "/Users/stallone/.superset/worktrees/abc123/my-branch",
        ])

        XCTAssertEqual(
            decoder.bestEffortPath(fromSlug: "-Users-stallone--superset-worktrees-abc123-my-branch"),
            "/Users/stallone/.superset/worktrees/abc123/my-branch"
        )
    }

    func testReturnsNilWhenNoFullPathVerifies() {
        // A verified prefix is not enough — the whole path must exist.
        let decoder = makeDecoder(knownDirectories: ["/Users", "/Users/dev"])

        XCTAssertNil(decoder.bestEffortPath(fromSlug: "-Users-nobody-project"))
    }

    func testReturnsNilForEmptyOrRelativeSlug() {
        let decoder = makeDecoder(knownDirectories: ["/Users"])

        XCTAssertNil(decoder.bestEffortPath(fromSlug: ""))
        XCTAssertNil(decoder.bestEffortPath(fromSlug: "-"))
        XCTAssertNil(decoder.bestEffortPath(fromSlug: "Users-dev"))
    }
}
