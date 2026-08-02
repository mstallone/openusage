import XCTest
@testable import Runway

/// The store's contract on fakes: reload merges database rows into the scanned inventory, content
/// loads compose correctly, and save/delete/create keep the files and the MEMORY.md index in sync.
@MainActor
final class MemoryStoreTests: XCTestCase {
    private let home = "/Users/dev"
    private var claudeMemoryDir: String { "\(home)/.claude/projects/-Users-dev-proj/memory" }

    /// An in-memory file map plus a call log, so tests can prove writes go through the
    /// mode-preserving API (`FakeFiles` is final and would route saves through `writeText`).
    private final class RecordingFiles: TextFileAccessing, @unchecked Sendable {
        var files: [String: String]
        var preservingModeWrites: [String] = []

        init(_ files: [String: String] = [:]) {
            self.files = files
        }

        func exists(_ path: String) -> Bool { files[path] != nil }
        func readText(_ path: String) throws -> String { files[path] ?? "" }
        func readTextIfPresent(_ path: String) throws -> String? { files[path] }
        func writeText(_ path: String, _ text: String) throws { files[path] = text }
        func remove(_ path: String) throws { files.removeValue(forKey: path) }

        /// Paths whose mode-preserving writes fail — the index-write-failure rollback case.
        var failingWritePaths: Set<String> = []

        func writeTextPreservingMode(_ path: String, _ text: String) throws {
            if failingWritePaths.contains(path) { throw POSIXError(.EACCES) }
            preservingModeWrites.append(path)
            files[path] = text
        }
    }

    private final class ScriptedSQLite: SQLiteAccessing, @unchecked Sendable {
        /// JSON returned per query, matched by a substring of the SQL; nil entry → throw.
        var listJSON: String?
        var rowJSON: String?
        var error: Error?
        var listQueryCount = 0

        func queryValue(path: String, sql: String) throws -> String? { nil }
        func execute(path: String, sql: String) throws {}

        func queryJSONRows(path: String, sql: String) throws -> String? {
            if let error { throw error }
            if sql.contains("WHERE thread_id") { return rowJSON }
            listQueryCount += 1
            return listJSON
        }
    }

    /// A mutable date the `modificationDates` closure can consult, so a test can "touch" a file
    /// between reloads.
    private final class DateBox: @unchecked Sendable {
        var value: Date
        init(_ value: Date) { self.value = value }
    }

    private func makeStore(
        files: RecordingFiles,
        sqlite: ScriptedSQLite = ScriptedSQLite(),
        subdirectories: [String],
        modificationDates: @escaping @Sendable (String) -> Date? = { _ in nil }
    ) -> MemoryStore {
        let homeURL = URL(fileURLWithPath: home)
        let scanner = MemoryInventoryScanner(
            environment: FakeEnvironment(),
            files: files,
            homeDirectory: { homeURL },
            listSubdirectories: { url in
                subdirectories
                    .map { URL(fileURLWithPath: $0) }
                    .filter { $0.deletingLastPathComponent().path == url.path }
            },
            listFiles: { url in
                files.files.keys
                    .filter { URL(fileURLWithPath: $0).deletingLastPathComponent().path == url.path }
                    .sorted()
                    .map { URL(fileURLWithPath: $0) }
            },
            slugDecoder: ProjectSlugDecoder(directoryExists: { _ in false })
        )
        return MemoryStore(
            files: files,
            scanner: scanner,
            database: CodexMemoryDatabase(sqlite: sqlite),
            modificationDate: modificationDates
        )
    }

    private func claudeProjectFixture() -> RecordingFiles {
        RecordingFiles([
            "\(home)/.claude/CLAUDE.md": "Global instructions",
            "\(claudeMemoryDir)/MEMORY.md": """
            # Memory Index

            - [Fact One](fact-one.md) — hook one
            """,
            "\(claudeMemoryDir)/fact-one.md": """
            ---
            name: Fact One
            description: hook one
            ---

            body one
            """,
        ])
    }

    private let claudeSubdirectories = [
        "/Users/dev/.claude",
        "/Users/dev/.claude/projects/-Users-dev-proj",
    ]

    func testCreateInstructionFileDoesNotClobberAFileThatAppearedSinceTheScan() async throws {
        let files = RecordingFiles([:])
        let store = makeStore(files: files, subdirectories: ["\(home)/.gemini"])
        await store.reload()
        let source = try XCTUnwrap(store.sources.first { $0.id.hasPrefix("gemini:") })

        // An agent wrote the file between the scan and the click.
        files.files["\(home)/.gemini/GEMINI.md"] = "the agent's fresh instructions"
        try await store.createInstructionFile(for: source)

        XCTAssertEqual(files.files["\(home)/.gemini/GEMINI.md"], "the agent's fresh instructions",
                       "creating means \"make the file exist\" — a late writer's content wins")
    }

    func testCreateFactRollsBackTheFileWhenTheIndexWriteFails() async throws {
        let files = claudeProjectFixture()
        files.failingWritePaths = ["\(claudeMemoryDir)/MEMORY.md"]
        let store = makeStore(files: files, subdirectories: claudeSubdirectories)
        await store.reload()
        let project = try XCTUnwrap(store.sources.first?.projects.first)

        do {
            _ = try await store.createFact(in: project, name: "New Fact", description: "hook", type: "project")
            XCTFail("the failing index write must throw")
        } catch {}

        XCTAssertNil(files.files["\(claudeMemoryDir)/new-fact.md"],
                     "a fact whose index line could not be written must not linger unindexed")
    }

    // MARK: - Reload

    func testReloadReusesListingForUnchangedDatabaseAndRelistsWhenItMoves() async throws {
        let files = RecordingFiles([
            "\(home)/.codex/AGENTS.md": "agents",
            "\(home)/.codex/memories_1.sqlite": "«binary»",
        ])
        let sqlite = ScriptedSQLite()
        sqlite.listJSON = #"[{"thread_id":"t1","rollout_slug":"slug"}]"#
        let dbDate = DateBox(Date(timeIntervalSince1970: 100))
        let walDate = DateBox(Date(timeIntervalSince1970: 100))
        let store = makeStore(
            files: files,
            sqlite: sqlite,
            subdirectories: ["\(home)/.codex"],
            modificationDates: { path in
                if path.hasSuffix("memories_1.sqlite-wal") { return walDate.value }
                if path.hasSuffix("memories_1.sqlite") { return dbDate.value }
                return nil
            }
        )

        await store.reload()
        await store.reload()
        XCTAssertEqual(sqlite.listQueryCount, 1, "an unchanged database must reuse its cached rows")

        dbDate.value = Date(timeIntervalSince1970: 200)
        await store.reload()
        XCTAssertEqual(sqlite.listQueryCount, 2, "a changed modification date must re-list")

        // WAL-mode commits touch only the -wal sidecar; the cache must notice that too.
        walDate.value = Date(timeIntervalSince1970: 300)
        await store.reload()
        XCTAssertEqual(sqlite.listQueryCount, 3, "a changed WAL sidecar must re-list")
    }

    func testReloadDemotesAndReRanksAReadySourceWhoseDatabaseListsNothing() async throws {
        let files = RecordingFiles([
            // Codex's only artifact is a database file — the scanner optimistically marks it
            // Ready; the zero-row listing must demote it below the genuinely ready Gemini.
            "\(home)/.codex/memories_1.sqlite": "«binary»",
            "\(home)/.gemini/GEMINI.md": "global notes",
        ])
        let sqlite = ScriptedSQLite()
        sqlite.listJSON = "[]"
        let store = makeStore(
            files: files,
            sqlite: sqlite,
            subdirectories: ["\(home)/.codex", "\(home)/.gemini"]
        )

        await store.reload()

        XCTAssertEqual(store.sources.map(\.harness), ["Gemini", "Codex"])
        XCTAssertEqual(store.sources[0].status, .ready)
        XCTAssertEqual(store.sources[1].status, .missingFile,
                       "a database with nothing in it is not content — the home has no files to read")
    }

    func testReloadListsCodexDatabaseDocuments() async throws {
        let files = RecordingFiles([
            "\(home)/.codex/AGENTS.md": "agents",
            "\(home)/.codex/memories_1.sqlite": "«binary»",
        ])
        let sqlite = ScriptedSQLite()
        sqlite.listJSON = """
        [{"thread_id":"t1","rollout_slug":"fix-crash","generated_at":"2026-07-30T10:00:00Z","usage_count":2}]
        """
        let store = makeStore(files: files, sqlite: sqlite, subdirectories: ["\(home)/.codex"])

        await store.reload()

        XCTAssertFalse(store.isLoading)
        let source = try XCTUnwrap(store.sources.first)
        XCTAssertNil(source.footnote)
        XCTAssertEqual(source.databaseDocuments.map(\.id), ["sqlite:\(home)/.codex/memories_1.sqlite#t1"])
        XCTAssertEqual(source.databaseDocuments.first?.title, "fix-crash")
        XCTAssertEqual(source.databaseDocuments.first?.isEditable, false)
    }

    func testReloadDatabaseFailureBecomesFootnoteNotACrash() async throws {
        let files = RecordingFiles([
            "\(home)/.codex/AGENTS.md": "agents",
            "\(home)/.codex/memories_1.sqlite": "«binary»",
        ])
        let sqlite = ScriptedSQLite()
        sqlite.error = SQLiteError.queryFailed("locked")
        let store = makeStore(files: files, sqlite: sqlite, subdirectories: ["\(home)/.codex"])

        await store.reload()

        let source = try XCTUnwrap(store.sources.first)
        XCTAssertTrue(source.databaseDocuments.isEmpty)
        XCTAssertEqual(source.footnote, "The memory database could not be read: locked")
        // The file-backed side of the source stays usable.
        XCTAssertEqual(source.instructions?.title, "AGENTS.md")
    }

    func testReloadWithoutDatabaseFileNeverQueries() async throws {
        let files = RecordingFiles(["\(home)/.codex/AGENTS.md": "agents"])
        let sqlite = ScriptedSQLite()
        sqlite.error = SQLiteError.queryFailed("must not be called")
        let store = makeStore(files: files, sqlite: sqlite, subdirectories: ["\(home)/.codex"])

        await store.reload()

        let source = try XCTUnwrap(store.sources.first)
        XCTAssertNil(source.footnote)
        XCTAssertTrue(source.databaseDocuments.isEmpty)
    }

    // MARK: - Lookup

    func testLookupFindsDocumentProjectAndSource() async throws {
        let store = makeStore(files: claudeProjectFixture(), subdirectories: claudeSubdirectories)
        await store.reload()

        let fact = try XCTUnwrap(store.document(withID: "\(claudeMemoryDir)/fact-one.md"))
        XCTAssertEqual(fact.kind, .fact)
        XCTAssertEqual(store.projectGroup(containing: fact)?.slug, "-Users-dev-proj")
        XCTAssertEqual(store.source(containing: fact)?.harness, "Claude Code")
        XCTAssertNil(store.document(withID: "/nowhere.md"))
    }

    // MARK: - Content

    func testLoadContentReturnsFileTextAndModificationDate() async throws {
        let statDate = Date(timeIntervalSinceReferenceDate: 123)
        let path = "\(claudeMemoryDir)/fact-one.md"
        let store = makeStore(
            files: claudeProjectFixture(),
            subdirectories: claudeSubdirectories,
            modificationDates: { $0 == path ? statDate : nil }
        )
        await store.reload()

        let fact = try XCTUnwrap(store.document(withID: path))
        let content = try await store.loadContent(fact)

        XCTAssertTrue(content.text.hasSuffix("body one"))
        XCTAssertEqual(content.modificationDate, statDate)
        let fresh = await store.currentModificationDate(of: fact)
        XCTAssertEqual(fresh, statDate)
    }

    func testLoadContentComposesDatabaseRowBodies() async throws {
        let files = RecordingFiles([
            "\(home)/.codex/AGENTS.md": "agents",
            "\(home)/.codex/memories_1.sqlite": "«binary»",
        ])
        let sqlite = ScriptedSQLite()
        sqlite.listJSON = """
        [{"thread_id":"t1","rollout_slug":"fix-crash"}]
        """
        sqlite.rowJSON = """
        [{"thread_id":"t1","raw_memory":"the memory body","rollout_summary":"what happened"}]
        """
        let store = makeStore(files: files, sqlite: sqlite, subdirectories: ["\(home)/.codex"])
        await store.reload()

        let doc = try XCTUnwrap(store.sources.first?.databaseDocuments.first)
        let content = try await store.loadContent(doc)

        XCTAssertEqual(content.text, "the memory body\n\n---\n\n## Rollout Summary\n\nwhat happened")
        XCTAssertNil(content.modificationDate)
        let fresh = await store.currentModificationDate(of: doc)
        XCTAssertNil(fresh)
    }

    // MARK: - Save

    func testSaveWritesThroughPreservingModeAndRefreshesModificationDate() async throws {
        let files = claudeProjectFixture()
        let path = "\(claudeMemoryDir)/fact-one.md"
        let savedDate = Date(timeIntervalSinceReferenceDate: 456)
        let store = makeStore(
            files: files,
            subdirectories: claudeSubdirectories,
            modificationDates: { $0 == path ? savedDate : nil }
        )
        await store.reload()

        let fact = try XCTUnwrap(store.document(withID: path))
        try await store.save(fact, text: "new body")

        XCTAssertEqual(files.files[path], "new body")
        XCTAssertEqual(files.preservingModeWrites, [path])
        XCTAssertEqual(store.document(withID: path)?.modificationDate, savedDate)
    }

    func testSaveOnReadOnlyDatabaseDocumentThrows() async throws {
        let doc = MemoryDocument(
            id: "sqlite:/db#t1",
            title: "row",
            subtitle: nil,
            kind: .databaseMemory,
            location: .sqliteRow(dbPath: "/db", threadID: "t1"),
            modificationDate: nil,
            isEditable: false
        )
        let store = makeStore(files: RecordingFiles(), subdirectories: [])

        do {
            try await store.save(doc, text: "nope")
            XCTFail("saving a read-only document must throw")
        } catch let error as MemoryStoreError {
            XCTAssertEqual(error, .documentIsReadOnly)
        }
    }

    // MARK: - Delete

    func testDeleteFactRemovesFileAndItsIndexLine() async throws {
        let files = claudeProjectFixture()
        let path = "\(claudeMemoryDir)/fact-one.md"
        let store = makeStore(files: files, subdirectories: claudeSubdirectories)
        await store.reload()
        store.selectedDocumentID = path

        let fact = try XCTUnwrap(store.document(withID: path))
        try await store.deleteFact(fact)

        XCTAssertNil(files.files[path])
        let index = try XCTUnwrap(files.files["\(claudeMemoryDir)/MEMORY.md"])
        XCTAssertFalse(index.contains("fact-one.md"))
        XCTAssertTrue(index.contains("# Memory Index"))
        XCTAssertNil(store.selectedDocumentID)
        // The reload after the delete no longer lists the fact.
        XCTAssertNil(store.document(withID: path))
    }

    func testDeleteRejectsNonFactDocuments() async throws {
        let store = makeStore(files: claudeProjectFixture(), subdirectories: claudeSubdirectories)
        await store.reload()

        let instructions = try XCTUnwrap(store.document(withID: "\(home)/.claude/CLAUDE.md"))
        do {
            try await store.deleteFact(instructions)
            XCTFail("deleting a non-fact must throw")
        } catch let error as MemoryStoreError {
            XCTAssertEqual(error, .notAFact)
        }
    }

    // MARK: - Create

    func testCreateFactWritesTemplateAndAppendsIndexLine() async throws {
        let files = claudeProjectFixture()
        let store = makeStore(files: files, subdirectories: claudeSubdirectories)
        await store.reload()

        let project = try XCTUnwrap(store.sources.first?.projects.first)
        let id = try await store.createFact(
            in: project,
            name: "Deploy Checklist Notes",
            description: "steps before shipping",
            type: "project"
        )

        let expectedPath = "\(claudeMemoryDir)/deploy-checklist-notes.md"
        XCTAssertEqual(id, expectedPath)
        XCTAssertEqual(files.files[expectedPath], MemoryFrontmatter.template(
            name: "Deploy Checklist Notes",
            description: "steps before shipping",
            type: "project"
        ))
        let index = try XCTUnwrap(files.files["\(claudeMemoryDir)/MEMORY.md"])
        XCTAssertTrue(index.contains("- [Deploy Checklist Notes](deploy-checklist-notes.md) — steps before shipping"))
        // The reload after the create lists the new fact.
        XCTAssertEqual(store.document(withID: expectedPath)?.title, "Deploy Checklist Notes")
    }

    func testCreateFactSuffixesCollidingSlugs() async throws {
        let files = claudeProjectFixture()
        files.files["\(claudeMemoryDir)/notes.md"] = "existing"
        files.files["\(claudeMemoryDir)/notes-2.md"] = "also existing"
        let store = makeStore(files: files, subdirectories: claudeSubdirectories)
        await store.reload()

        let project = try XCTUnwrap(store.sources.first?.projects.first)
        let id = try await store.createFact(in: project, name: "Notes!", description: "", type: "user")

        XCTAssertEqual(id, "\(claudeMemoryDir)/notes-3.md")
        // An empty description appends no hook.
        let index = try XCTUnwrap(files.files["\(claudeMemoryDir)/MEMORY.md"])
        XCTAssertTrue(index.contains("- [Notes!](notes-3.md)\n"))
    }

    func testCreateFactCreatesMissingIndex() async throws {
        // A project directory holding one orphaned fact and no MEMORY.md yet.
        let files = RecordingFiles([
            "\(home)/.claude/CLAUDE.md": "instructions",
            "\(claudeMemoryDir)/orphan.md": "orphan body",
        ])
        let store = makeStore(files: files, subdirectories: claudeSubdirectories)
        await store.reload()

        let project = try XCTUnwrap(store.sources.first?.projects.first)
        _ = try await store.createFact(in: project, name: "Fresh", description: "hook", type: "user")

        XCTAssertEqual(files.files["\(claudeMemoryDir)/MEMORY.md"], "- [Fresh](fresh.md) — hook\n")
    }

    func testCreateInstructionFileWritesEmptyFileAtTheExpectedPath() async throws {
        let files = RecordingFiles()
        let store = makeStore(files: files, subdirectories: ["\(home)/.gemini"])
        await store.reload()

        let source = try XCTUnwrap(store.sources.first)
        XCTAssertEqual(source.status, .missingFile)

        try await store.createInstructionFile(for: source)

        XCTAssertEqual(files.files["\(home)/.gemini/GEMINI.md"], "")
        XCTAssertEqual(files.preservingModeWrites, ["\(home)/.gemini/GEMINI.md"])
        // The reload after the create now sees the (empty) file.
        XCTAssertEqual(store.sources.first?.status, .empty)
        XCTAssertEqual(store.sources.first?.instructions?.title, "GEMINI.md")
    }
}
