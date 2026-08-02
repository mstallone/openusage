import XCTest
@testable import Runway

final class CodexMemoryDatabaseTests: XCTestCase {
    private let dbPath = "/Users/me/.codex/memories_1.sqlite"

    // MARK: - listDocuments

    func testListDocumentsMapsMetadataRows() throws {
        let sqlite = MockSQLite(json: """
        [
          {"thread_id":"0199c5b1-abcd","rollout_slug":"fix-login-flow","generated_at":"2026-07-30T12:34:56Z","usage_count":3,"last_usage":"2026-08-01T09:00:00Z"},
          {"thread_id":"0199c5b2-ffff","rollout_slug":null,"generated_at":null,"usage_count":null,"last_usage":null}
        ]
        """)

        let documents = try CodexMemoryDatabase(sqlite: sqlite).listDocuments(dbPath: dbPath)

        XCTAssertEqual(documents.count, 2)
        let first = documents[0]
        XCTAssertEqual(first.id, "sqlite:\(dbPath)#0199c5b1-abcd")
        XCTAssertEqual(first.title, "fix-login-flow")
        XCTAssertEqual(first.subtitle, "2026-07-30 · used 3 times")
        XCTAssertEqual(first.kind, .databaseMemory)
        XCTAssertEqual(first.location, .sqliteRow(dbPath: dbPath, threadID: "0199c5b1-abcd"))
        XCTAssertNil(first.modificationDate)
        XCTAssertFalse(first.isEditable)

        let second = documents[1]
        XCTAssertEqual(second.title, "0199c5b2…", "a slugless row falls back to a shortened thread id")
        XCTAssertNil(second.subtitle)
    }

    func testListDocumentsDecodesIntegerTimestamps() throws {
        // Current Codex databases store generated_at/last_usage as INTEGER unix seconds.
        let sqlite = MockSQLite(json: """
        [{"thread_id":"t1","rollout_slug":"numeric-times","generated_at":1782258085,"usage_count":2,"last_usage":1782260000}]
        """)

        let documents = try CodexMemoryDatabase(sqlite: sqlite).listDocuments(dbPath: dbPath)

        XCTAssertEqual(documents.count, 1)
        XCTAssertEqual(documents[0].subtitle, "2026-06-23 · used 2 times")
    }

    func testListDocumentsQueriesMetadataOnlyNewestFirst() throws {
        let sqlite = MockSQLite(json: "[]")

        XCTAssertEqual(try CodexMemoryDatabase(sqlite: sqlite).listDocuments(dbPath: dbPath), [])

        let sql = try XCTUnwrap(sqlite.lastSQL)
        XCTAssertTrue(sql.contains("ORDER BY generated_at DESC"))
        XCTAssertTrue(sql.contains("LIMIT 500"))
        XCTAssertFalse(sql.contains("raw_memory"), "the list query must not fetch bodies")
        XCTAssertFalse(sql.contains("rollout_summary"), "the list query must not fetch bodies")
        XCTAssertEqual(sqlite.lastPath, dbPath)
    }

    func testListDocumentsMissingOrEmptyDatabaseReturnsEmptyList() throws {
        // `queryJSONRows` returns nil both for an absent database and a rowless query.
        let sqlite = MockSQLite(json: nil)

        XCTAssertEqual(try CodexMemoryDatabase(sqlite: sqlite).listDocuments(dbPath: dbPath), [])
    }

    func testListDocumentsMalformedJSONThrows() {
        let sqlite = MockSQLite(json: "not json")

        XCTAssertThrowsError(
            try CodexMemoryDatabase(sqlite: sqlite).listDocuments(dbPath: dbPath)
        ) { error in
            guard case CodexMemoryDatabaseError.malformedRows = error else {
                return XCTFail("expected malformedRows, got \(error)")
            }
        }
    }

    // MARK: - loadRow

    func testLoadRowFetchesBodiesAndMetadata() throws {
        let sqlite = MockSQLite(json: """
        [{"thread_id":"t1","raw_memory":"---\\nname: X\\n---\\nbody","rollout_summary":"summary","rollout_slug":"slug","generated_at":"2026-07-30T12:34:56Z","usage_count":1,"last_usage":"2026-08-01T09:00:00Z"}]
        """)

        let row = try CodexMemoryDatabase(sqlite: sqlite).loadRow(dbPath: dbPath, threadID: "t1")

        XCTAssertEqual(row, CodexMemoryRow(
            threadID: "t1",
            rawMemory: "---\nname: X\n---\nbody",
            rolloutSummary: "summary",
            rolloutSlug: "slug",
            generatedAt: "2026-07-30T12:34:56Z",
            usageCount: 1,
            lastUsage: "2026-08-01T09:00:00Z"
        ))
        let sql = try XCTUnwrap(sqlite.lastSQL)
        XCTAssertTrue(sql.contains("raw_memory"))
        XCTAssertTrue(sql.contains("rollout_summary"))
        XCTAssertTrue(sql.contains("WHERE thread_id = 't1'"))
        XCTAssertEqual(sqlite.lastPath, dbPath)
    }

    func testLoadRowDoublesSingleQuotesInThreadID() throws {
        let sqlite = MockSQLite(json: "[{\"thread_id\":\"o'brien\",\"raw_memory\":\"m\"}]")

        _ = try CodexMemoryDatabase(sqlite: sqlite).loadRow(dbPath: dbPath, threadID: "o'brien")

        XCTAssertTrue(try XCTUnwrap(sqlite.lastSQL).contains("WHERE thread_id = 'o''brien'"))
    }

    func testLoadRowMissingDatabaseThrowsRowNotFound() {
        let sqlite = MockSQLite(json: nil)

        XCTAssertThrowsError(
            try CodexMemoryDatabase(sqlite: sqlite).loadRow(dbPath: dbPath, threadID: "gone")
        ) { error in
            XCTAssertEqual(error as? CodexMemoryDatabaseError, .rowNotFound(threadID: "gone"))
        }
    }

    func testLoadRowWithNoMatchingRowThrowsRowNotFound() {
        let sqlite = MockSQLite(json: "[]")

        XCTAssertThrowsError(
            try CodexMemoryDatabase(sqlite: sqlite).loadRow(dbPath: dbPath, threadID: "gone")
        ) { error in
            XCTAssertEqual(error as? CodexMemoryDatabaseError, .rowNotFound(threadID: "gone"))
        }
    }
}

/// Returns canned `-json` output while recording the query it was asked to run.
private final class MockSQLite: SQLiteAccessing, @unchecked Sendable {
    private let json: String?
    private(set) var lastPath: String?
    private(set) var lastSQL: String?

    init(json: String?) {
        self.json = json
    }

    func queryValue(path: String, sql: String) throws -> String? { nil }

    func queryJSONRows(path: String, sql: String) throws -> String? {
        lastPath = path
        lastSQL = sql
        return json
    }

    func execute(path: String, sql: String) throws {}
}
