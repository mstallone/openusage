import XCTest
@testable import Runway

/// The discovery rules: which homes become sources, what each source's status means, and how fact
/// titles are decorated. Everything runs on fakes — no real filesystem.
final class MemoryInventoryScannerTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/dev")

    /// Advances by a fixed step per `now()` call, so the time budget is testable deterministically.
    private final class SteppingClock: @unchecked Sendable {
        private var current = Date(timeIntervalSinceReferenceDate: 0)
        private let step: TimeInterval

        init(step: TimeInterval) { self.step = step }

        func now() -> Date {
            defer { current = current.addingTimeInterval(step) }
            return current
        }
    }

    /// A files double whose reads throw for chosen paths — the "exists but unreadable" case.
    private struct UnreadableFiles: TextFileAccessing {
        let backing: FakeFiles
        let unreadablePaths: Set<String>

        func exists(_ path: String) -> Bool { backing.exists(path) || unreadablePaths.contains(path) }
        func readText(_ path: String) throws -> String {
            guard !unreadablePaths.contains(path) else { throw POSIXError(.EACCES) }
            return try backing.readText(path)
        }
        func readTextIfPresent(_ path: String) throws -> String? {
            guard !unreadablePaths.contains(path) else { throw POSIXError(.EACCES) }
            return try backing.readTextIfPresent(path)
        }
        func writeText(_ path: String, _ text: String) throws { try backing.writeText(path, text) }
        func remove(_ path: String) throws { try backing.remove(path) }
    }

    private func makeScanner(
        environment: [String: String] = [:],
        files: [String: String] = [:],
        unreadablePaths: Set<String> = [],
        subdirectories: [String] = [],
        realDirectories: Set<String> = [],
        timeBudget: TimeInterval = 1.0,
        now: (@Sendable () -> Date)? = nil
    ) -> MemoryInventoryScanner {
        let fileMap = files
        let accessor: any TextFileAccessing = unreadablePaths.isEmpty
            ? FakeFiles(files)
            : UnreadableFiles(backing: FakeFiles(files), unreadablePaths: unreadablePaths)
        return MemoryInventoryScanner(
            environment: FakeEnvironment(environment),
            files: accessor,
            homeDirectory: { [home] in home },
            listSubdirectories: { url in
                subdirectories
                    .map { URL(fileURLWithPath: $0) }
                    .filter { $0.deletingLastPathComponent().path == url.path }
            },
            listFiles: { url in
                fileMap.keys
                    .filter { URL(fileURLWithPath: $0).deletingLastPathComponent().path == url.path }
                    .sorted()
                    .map { URL(fileURLWithPath: $0) }
            },
            slugDecoder: ProjectSlugDecoder(directoryExists: { realDirectories.contains($0) }),
            timeBudget: timeBudget,
            now: now ?? Date.init
        )
    }

    func testTwoClaudeHomesWithProjectsAndFactDecoration() throws {
        let memoryDir = "/Users/dev/.claude/projects/-Users-dev-proj/memory"
        let scanner = makeScanner(
            files: [
                "/Users/dev/.claude/CLAUDE.md": "Global instructions",
                "\(memoryDir)/MEMORY.md": """
                # Memory Index

                - [Index Title](fact-one.md) — index hook
                """,
                "\(memoryDir)/fact-one.md": """
                ---
                name: Front One
                description: front hook one
                ---

                body one
                """,
                // Orphans: no index line, so frontmatter then the filename must decorate them.
                "\(memoryDir)/fact-three.md": "plain body, no frontmatter",
                "\(memoryDir)/fact-two.md": """
                ---
                name: Front Two
                description: front hook two
                ---

                body two
                """,
                "/Users/dev/.claude-personal/CLAUDE.md": "Personal instructions",
            ],
            subdirectories: [
                "/Users/dev/.claude",
                "/Users/dev/.claude-personal",
                "/Users/dev/.claude/projects/-Users-dev-proj",
            ],
            realDirectories: ["/Users", "/Users/dev", "/Users/dev/proj"]
        )

        let (sources, _) = scanner.scan()

        XCTAssertEqual(sources.map(\.harness), ["Claude Code", "Claude Code"])
        XCTAssertEqual(sources.map(\.homePath), ["/Users/dev/.claude", "/Users/dev/.claude-personal"])
        XCTAssertEqual(sources.map(\.status), [.ready, .ready])

        let project = try XCTUnwrap(sources.first?.projects.first)
        XCTAssertEqual(sources.first?.projects.count, 1)
        XCTAssertEqual(project.slug, "-Users-dev-proj")
        XCTAssertEqual(project.displayName, "proj")
        XCTAssertEqual(project.displayPath, "/Users/dev/proj")
        XCTAssertEqual(project.indexDocument?.kind, .memoryIndex)

        // Orphaned facts are listed from the directory, and decoration prefers the index entry,
        // then frontmatter, then the bare filename.
        XCTAssertEqual(project.facts.map(\.id), [
            "\(memoryDir)/fact-one.md",
            "\(memoryDir)/fact-three.md",
            "\(memoryDir)/fact-two.md",
        ])
        XCTAssertEqual(project.facts.map(\.title), ["Index Title", "fact-three", "Front Two"])
        XCTAssertEqual(project.facts.map(\.subtitle), ["index hook", nil, "front hook two"])
        XCTAssertEqual(project.facts.map(\.kind), [.fact, .fact, .fact])
        XCTAssertTrue(project.facts.allSatisfy(\.isEditable))

        let personal = try XCTUnwrap(sources.last)
        XCTAssertEqual(personal.instructions?.title, "CLAUDE.md")
        XCTAssertTrue(personal.projects.isEmpty)
    }

    func testEmptyGeminiInstructionsFileIsEmptyStatus() throws {
        let scanner = makeScanner(
            files: ["/Users/dev/.gemini/GEMINI.md": "\n"],
            subdirectories: ["/Users/dev/.gemini"]
        )

        let (sources, _) = scanner.scan()

        let source = try XCTUnwrap(sources.first)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(source.harness, "Gemini")
        XCTAssertEqual(source.status, .empty)
        XCTAssertEqual(source.instructions?.kind, .instructions)
    }

    func testMissingGeminiFileWithHomePresentIsMissingFileStatus() throws {
        let scanner = makeScanner(subdirectories: ["/Users/dev/.gemini"])

        let (sources, _) = scanner.scan()

        let source = try XCTUnwrap(sources.first)
        XCTAssertEqual(source.status, .missingFile)
        XCTAssertNil(source.instructions)
    }

    func testGrokHomeWithoutMemoryDirectoryIsDisabled() throws {
        let scanner = makeScanner(subdirectories: ["/Users/dev/.grok"])

        let (sources, notes) = scanner.scan()

        let source = try XCTUnwrap(sources.first)
        XCTAssertEqual(source.harness, "Grok")
        XCTAssertEqual(
            source.status,
            .memoryDisabled(note: "Memory is turned off in Grok (no [memory] section in its config.toml).")
        )
        XCTAssertTrue(source.allDocuments.isEmpty)
        XCTAssertTrue(notes.contains { $0.contains("no memory directory") })
    }

    func testUnreadableInstructionFileIsFlaggedNotTreatedAsMissing() throws {
        let scanner = makeScanner(
            unreadablePaths: ["/Users/dev/.claude/CLAUDE.md"],
            subdirectories: ["/Users/dev/.claude"]
        )

        let (sources, notes) = scanner.scan()

        let source = try XCTUnwrap(sources.first)
        XCTAssertTrue(source.instructionsUnreadable,
                      "an existing-but-unreadable file must not be classified as absent")
        XCTAssertNil(source.instructions)
        XCTAssertTrue(notes.contains { $0.contains("could not read") })
    }

    func testGrokMemoryHeaderToleratesTrailingComment() throws {
        let scanner = makeScanner(
            files: [
                "/Users/dev/.grok/config.toml": "[memory] # enabled last week\n",
                "/Users/dev/.grok/memory/MEMORY.md": "notes",
            ],
            subdirectories: ["/Users/dev/.grok", "/Users/dev/.grok/memory"]
        )

        let (sources, _) = scanner.scan()

        XCTAssertEqual(try XCTUnwrap(sources.first).status, .ready,
                       "a TOML comment after the [memory] header must not read as feature-off")
    }

    func testGrokUnreadableConfigIsUnknownNotDisabled() throws {
        let scanner = makeScanner(
            unreadablePaths: ["/Users/dev/.grok/config.toml"],
            subdirectories: ["/Users/dev/.grok"]
        )

        let (sources, _) = scanner.scan()

        let source = try XCTUnwrap(sources.first)
        XCTAssertEqual(source.status, .missingFile,
                       "an unreadable config must not be claimed as memory-off")
        XCTAssertNotNil(source.footnote, "the unknown state carries an explanation")
    }

    func testClaudeConfigDirPointingAtProjectsIsNormalizedToItsHome() throws {
        let scanner = makeScanner(
            environment: ["CLAUDE_CONFIG_DIR": "/Users/dev/custom-claude/projects"],
            files: ["/Users/dev/custom-claude/CLAUDE.md": "instructions"],
            subdirectories: ["/Users/dev/custom-claude"]
        )

        let (sources, _) = scanner.scan()

        XCTAssertTrue(sources.contains { $0.homePath == "/Users/dev/custom-claude" },
                      "the projects/ spelling ClaudeLogUsageScanner accepts must resolve to its home")
    }

    func testCodexHistoricalConfigHomeIsScanned() throws {
        let scanner = makeScanner(
            files: ["/Users/dev/.config/codex/AGENTS.md": "historical-home instructions"],
            subdirectories: ["/Users/dev/.config", "/Users/dev/.config/codex"]
        )

        let (sources, _) = scanner.scan()

        XCTAssertEqual(sources.map(\.homePath), ["/Users/dev/.config/codex"],
                       "the historical ~/.config/codex default must be visited like CodexHomeDiscovery does")
    }

    func testGrokHomeHonorsGROKHOMEOverride() throws {
        let scanner = makeScanner(
            environment: ["GROK_HOME": "/Users/dev/custom-grok"],
            files: [
                "/Users/dev/custom-grok/config.toml": "[memory]\nenabled = true",
                "/Users/dev/custom-grok/memory/MEMORY.md": "custom-home memory",
            ],
            subdirectories: ["/Users/dev/custom-grok", "/Users/dev/custom-grok/memory"]
        )

        let (sources, _) = scanner.scan()

        XCTAssertEqual(sources.map(\.homePath), ["/Users/dev/custom-grok"],
                       "the memory inventory must look where GROK_HOME points, like the usage scanners do")
        XCTAssertEqual(sources.first?.status, .ready)
    }

    func testListingFailuresAttachOnAPathComponentBoundary() {
        var sources = [
            MemorySource(
                id: "codex:/Users/dev/.codex", harness: "Codex", homePath: "/Users/dev/.codex",
                status: .ready, instructions: nil, projects: [], legacyDocuments: [],
                databaseDocuments: [], footnote: nil
            ),
            MemorySource(
                id: "codex:/Users/dev/.codex-work", harness: "Codex", homePath: "/Users/dev/.codex-work",
                status: .ready, instructions: nil, projects: [], legacyDocuments: [],
                databaseDocuments: [], footnote: nil
            ),
        ]
        var notes: [String] = []

        MemoryInventoryScanner.attachListingFailures(
            [(path: "/Users/dev/.codex-work/memories", message: "denied")],
            to: &sources,
            notes: &notes,
            logPath: { $0 }
        )

        XCTAssertNil(sources[0].footnote, "a shared string prefix is not containment")
        XCTAssertNotNil(sources[1].footnote, "the failure belongs to the home that actually contains the path")
    }

    func testGrokStaleFilesWithFeatureOffAreDisabledButStillListed() throws {
        // The [memory] section was removed while memory/ files remain: the gate wins over the
        // directory, but readable files still list.
        let scanner = makeScanner(
            files: [
                "/Users/dev/.grok/config.toml": "model = \"grok-4\"",
                "/Users/dev/.grok/memory/MEMORY.md": "stale global memory",
            ],
            subdirectories: ["/Users/dev/.grok", "/Users/dev/.grok/memory"]
        )

        let (sources, _) = scanner.scan()

        let source = try XCTUnwrap(sources.first)
        guard case .memoryDisabled = source.status else {
            return XCTFail("stale files must not make a feature-off Grok read as Ready")
        }
        XCTAssertEqual(source.instructions?.title, "MEMORY.md", "the stale file still lists — readable is readable")
    }

    func testGrokWithMemoryConfiguredButNoDirectoryYetIsNoFileNotDisabled() throws {
        // The feature gate is the [memory] section, not the folder: memory turned on in Grok's
        // config with no files yet must offer creation, exactly like a Codex home with no
        // AGENTS.md — creating MEMORY.md there is real, Grok will read it.
        let scanner = makeScanner(
            files: [
                "/Users/dev/.grok/config.toml": """
                model = "grok-4"

                [memory]
                enabled = true
                """,
            ],
            subdirectories: ["/Users/dev/.grok"]
        )

        let (sources, _) = scanner.scan()

        XCTAssertEqual(try XCTUnwrap(sources.first).status, .missingFile)
    }

    func testCodexConfigDisabledNoteAndSqliteRecordedWithoutOpening() throws {
        let scanner = makeScanner(
            files: [
                "/Users/dev/.codex/AGENTS.md": "agents guidance",
                "/Users/dev/.codex/config.toml": """
                model = "gpt-5"
                use_memories = false
                """,
                "/Users/dev/.codex/memories_1.sqlite": "«binary»",
                "/Users/dev/.codex/memories/2025-01-legacy.md": """
                ---
                name: Legacy Note
                description: old-format memory
                ---

                body
                """,
            ],
            subdirectories: ["/Users/dev/.codex"]
        )

        let (sources, notes) = scanner.scan()

        let source = try XCTUnwrap(sources.first)
        XCTAssertEqual(source.harness, "Codex")
        XCTAssertEqual(
            source.status,
            .memoryDisabled(note: "Memory is turned off in Codex (use_memories = false in config.toml).")
        )
        XCTAssertTrue(notes.contains { $0.contains("use_memories = false") })

        // The database is only recorded as present — never opened, and no rows are listed here.
        XCTAssertTrue(notes.contains { $0.contains("memories_1.sqlite present") })
        XCTAssertTrue(source.databaseDocuments.isEmpty)

        XCTAssertEqual(source.instructions?.title, "AGENTS.md")
        XCTAssertEqual(source.legacyDocuments.map(\.title), ["Legacy Note"])
        XCTAssertEqual(source.legacyDocuments.first?.kind, .legacyMemory)
    }

    func testDedupesDuplicateHomesAcrossEnvAndDotDirListing() {
        // CLAUDE_CONFIG_DIR points at the same directory the dot-dir walk finds.
        let scanner = makeScanner(
            environment: ["CLAUDE_CONFIG_DIR": "~/.claude"],
            files: ["/Users/dev/.claude/CLAUDE.md": "instructions"],
            subdirectories: ["/Users/dev/.claude"]
        )

        let (sources, _) = scanner.scan()

        XCTAssertEqual(sources.map(\.homePath), ["/Users/dev/.claude"])
    }

    func testSourcesOrderClaudeCodexThenAlphabetical() {
        let scanner = makeScanner(
            files: [
                "/Users/dev/.claude/CLAUDE.md": "claude",
                "/Users/dev/.codex/AGENTS.md": "codex",
                "/Users/dev/.gemini/GEMINI.md": "gemini",
                "/Users/dev/.grok/config.toml": "[memory]\nenabled = true",
                "/Users/dev/.grok/memory/MEMORY.md": "grok memory",
            ],
            subdirectories: [
                // Deliberately unsorted on disk; the scan order is the harness convention's.
                "/Users/dev/.grok",
                "/Users/dev/.gemini",
                "/Users/dev/.codex",
                "/Users/dev/.claude",
                "/Users/dev/.grok/memory",
            ]
        )

        let (sources, _) = scanner.scan()

        XCTAssertEqual(sources.map(\.harness), ["Claude Code", "Codex", "Gemini", "Grok"])
        XCTAssertEqual(sources.map(\.status), [.ready, .ready, .ready, .ready])
    }

    func testSourcesRankReadyThenNothingYetThenDisabledKeepingHarnessOrderWithin() {
        let scanner = makeScanner(
            files: [
                // Claude: an empty CLAUDE.md ("nothing yet") — must sink BELOW the ready Codex
                // despite Claude leading the harness order. Gemini: no file at all ("nothing
                // yet"), after Claude within the bucket. Grok: memory feature off, last.
                "/Users/dev/.claude/CLAUDE.md": "",
                "/Users/dev/.codex/AGENTS.md": "codex",
            ],
            subdirectories: [
                "/Users/dev/.claude",
                "/Users/dev/.codex",
                "/Users/dev/.gemini",
                "/Users/dev/.grok",
            ]
        )

        let (sources, _) = scanner.scan()

        XCTAssertEqual(
            sources.map(\.harness),
            ["Codex", "Claude Code", "Gemini", "Grok"],
            "ready first, then empty/missing in harness order, then memory-disabled"
        )
        XCTAssertEqual(sources[0].status, .ready)
        XCTAssertEqual(sources[1].status, .empty)
        XCTAssertEqual(sources[2].status, .missingFile)
        guard case .memoryDisabled = sources[3].status else {
            return XCTFail("grok with no memory directory must rank last as memory-disabled")
        }
    }

    func testTimeBudgetTruncatesTheScanWithANote() {
        // now() is called once at the start, then before each candidate home: 0.0, 0.6, 1.2, … so
        // the second Claude home already overruns the 1s budget.
        let clock = SteppingClock(step: 0.6)
        let scanner = makeScanner(
            files: [
                "/Users/dev/.claude/CLAUDE.md": "first",
                "/Users/dev/.claude-personal/CLAUDE.md": "second",
            ],
            subdirectories: ["/Users/dev/.claude", "/Users/dev/.claude-personal"],
            timeBudget: 1.0,
            now: { clock.now() }
        )

        let (sources, notes) = scanner.scan()

        XCTAssertEqual(sources.map(\.homePath), ["/Users/dev/.claude"])
        XCTAssertTrue(notes.contains { $0.contains("1000ms budget") })
    }
}
