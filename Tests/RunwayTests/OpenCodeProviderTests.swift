import XCTest
@testable import Runway

/// End-to-end provider behavior: detection via the Go auth key or local usage, and a refresh that yields
/// the Go meters + combined spend tiles + trend, plus the not-logged-in path.
@MainActor
final class OpenCodeProviderTests: XCTestCase {
    private func d(_ iso: String) -> Date { RunwayISO8601.date(from: iso)! }
    private func epochMs(_ iso: String) -> Int { Int(d(iso).timeIntervalSince1970 * 1000) }
    private func row(_ iso: String, _ cost: String, _ tokens: Int, _ model: String, _ provider: String) -> String {
        "[\(epochMs(iso)),\(cost),\(tokens),\"\(model)\",\"\(provider)\"]"
    }
    private let authJSON = #"{"opencode-go":{"type":"api","key":"sk-test"}}"#

    private func authStore(files: TextFileAccessing) -> OpenCodeAuthStore {
        OpenCodeAuthStore(
            files: files,
            environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
            homeDirectory: { URL(fileURLWithPath: "/nonexistent") }
        )
    }

    func testHasLocalCredentialsViaGoAuthKey() async {
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] })
        )
        let has = await provider.hasLocalCredentials()
        XCTAssertTrue(has)
    }

    func testHasLocalCredentialsViaLocalUsage() async {
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            )
        )
        let has = await provider.hasLocalCredentials()
        XCTAssertTrue(has)
    }

    func testHasLocalCredentialsFalseWhenAbsent() async {
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": "[]"]),
                databasePaths: { ["/oc/opencode.db"] }
            )
        )
        let has = await provider.hasLocalCredentials()
        XCTAssertFalse(has)
    }

    func testRefreshProducesMetersTilesAndTrend() async {
        let now = d("2026-07-12T12:00:00.000Z")
        let db = "[" + [
            row("2026-07-12T11:00:00.000Z", "2.0", 1000, "glm-5.2", "opencode-go"),
            row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode")
        ].joined(separator: ",") + "]"
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            now: { now }
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.plan, "Go")
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
        XCTAssertNotNil(snapshot.line(label: "Monthly"))
        XCTAssertNotNil(snapshot.line(label: "Usage Trend"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
    }

    func testRefreshNotLoggedInWhenNoKeyAndNoDatabase() async {
        let now = d("2026-07-12T12:00:00.000Z")
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            now: { now }
        )
        let snapshot = await provider.refresh()
        XCTAssertTrue(snapshot.lines.contains { $0.isError })
    }

    func testRefreshShowsZeroCapMetersWithGoKeyButNoDatabase() async {
        // Freshly logged into Go, before the first local message: the key alone establishes the plan,
        // so the published caps show at $0 instead of a bare "No usage data".
        let now = d("2026-07-12T12:00:00.000Z")
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            now: { now }
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.plan, "Go")
        guard case .progress(_, let used, let limit, _, _, _, _)? = snapshot.line(label: "Session") else {
            return XCTFail("expected a Session meter")
        }
        XCTAssertEqual(used, 0)
        XCTAssertEqual(limit, OpenCodeUsageMapper.sessionCap)
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
        XCTAssertNotNil(snapshot.line(label: "Monthly"))
    }

    func testRefreshErrorsWhenAllDatabasesUnreadable() async {
        // A valid Go key with a locked/corrupt database must surface a read error, not $0 meters.
        let now = d("2026-07-12T12:00:00.000Z")
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(failing: ["/oc/opencode.db"]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            now: { now }
        )
        let snapshot = await provider.refresh()
        XCTAssertTrue(snapshot.lines.contains { $0.isError })
        XCTAssertNil(snapshot.line(label: "Session"))
    }

    func testRefreshSurfacesUnreadableAuthFileInsteadOfNotLoggedIn() async {
        // auth.json exists but can't be read, and there's no database: broken storage, not logout.
        let now = d("2026-07-12T12:00:00.000Z")
        let provider = OpenCodeProvider(
            authStore: authStore(files: UnreadableFiles(present: ["/oc/auth.json"])),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            now: { now }
        )
        let snapshot = await provider.refresh()
        XCTAssertTrue(snapshot.lines.contains { $0.isError })
    }

    func testHasLocalCredentialsTrueWhenAuthFileUnreadable() async {
        // An unreadable auth.json is itself an OpenCode footprint — enable the provider so refresh()
        // can show the actionable error rather than staying invisible.
        let provider = OpenCodeProvider(
            authStore: authStore(files: UnreadableFiles(present: ["/oc/auth.json"])),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] })
        )
        let has = await provider.hasLocalCredentials()
        XCTAssertTrue(has)
    }

    func testSpendTilesAreNotMarkedEstimated() async {
        // OpenCode records its own per-message cost — the tiles must not carry the local-estimate ⓘ.
        let now = d("2026-07-12T12:00:00.000Z")
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            now: { now }
        )
        let snapshot = await provider.refresh()
        guard case .values(_, let values, _, _, _, _)? = snapshot.line(label: "Today") else {
            return XCTFail("expected a Today tile")
        }
        XCTAssertFalse(values.contains(where: \.estimated))
    }

    func testStaleGoHistoryDoesNotShowGoPlanOrMeters() async {
        // Zen-only recent usage + an old opencode-go anchor + no Go key: no "Go" badge, no cap meters,
        // but the Zen spend still shows in the tiles.
        let now = d("2026-07-12T12:00:00.000Z")
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db], anchor: "1700000000000"),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            now: { now }
        )
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
    }
}

private final class StubSQLite: SQLiteAccessing, @unchecked Sendable {
    var data: [String: String]
    var anchor: String?
    var failing: Set<String>
    init(data: [String: String] = [:], anchor: String? = nil, failing: Set<String> = []) {
        self.data = data
        self.anchor = anchor
        self.failing = failing
    }

    func queryValue(path: String, sql: String) throws -> String? {
        if failing.contains(path) { throw SQLiteError.queryFailed("boom") }
        if sql.contains("json_group_array") { return data[path] }
        if sql.contains("MIN(time_created)") { return anchor }
        if sql.contains("SELECT 1") {
            let payload = data[path]
            return (payload != nil && payload != "[]" && !(payload ?? "").isEmpty) ? "1" : nil
        }
        return nil
    }

    func execute(path: String, sql: String) throws {}
}
