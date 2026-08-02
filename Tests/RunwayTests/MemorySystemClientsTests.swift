import Darwin
import XCTest
@testable import Runway

final class MemorySystemClientsTests: XCTestCase {
    // MARK: - writeTextPreservingMode

    func testOverwritePreservesExistingFileMode() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("CLAUDE.md").path
        for mode in [0o644, 0o600] {
            try "original".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)

            try LocalTextFileAccessor().writeTextPreservingMode(path, "updated")

            XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "updated")
            XCTAssertEqual(try posixMode(of: path), mode)
        }
    }

    func testNewFileDefaultsToSharedMode() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("new-fact.md").path

        let previousUmask = umask(0o022)
        defer { umask(previousUmask) }
        try LocalTextFileAccessor().writeTextPreservingMode(path, "fact body")

        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "fact body")
        XCTAssertEqual(try posixMode(of: path), 0o644)
    }

    func testNewFileHonorsARestrictiveUmask() throws {
        // A 077 umask (a hardened multi-user Mac) must strip group/other bits from brand-new
        // memory files; only *preserving* an existing file's mode may ignore the umask.
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("new-fact.md").path

        let previousUmask = umask(0o077)
        defer { umask(previousUmask) }
        try LocalTextFileAccessor().writeTextPreservingMode(path, "fact body")

        XCTAssertEqual(try posixMode(of: path), 0o600)
    }

    func testPreservingWriteLeavesNoTemporaryFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("MEMORY.md").path
        try "one".write(toFile: path, atomically: true, encoding: .utf8)

        try LocalTextFileAccessor().writeTextPreservingMode(path, "two")

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            ["MEMORY.md"]
        )
    }

    func testWritingThroughSymlinkUpdatesTargetAndKeepsTheLink() throws {
        // CLAUDE.md / AGENTS.md are commonly symlinks into a dotfiles repo. The atomic-rename
        // publish must land in the link's target, not replace the link with a regular file.
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("dotfiles-CLAUDE.md").path
        let link = directory.appendingPathComponent("CLAUDE.md").path
        try "original".write(toFile: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        try LocalTextFileAccessor().writeTextPreservingMode(link, "updated")

        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "updated")
        let linkType = try FileManager.default.attributesOfItem(atPath: link)[.type] as? FileAttributeType
        XCTAssertEqual(linkType, .typeSymbolicLink)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link),
            target
        )
    }

    func testWriteTextStillWritesPrivateMode() throws {
        // Regression guard for the shared write path: the credential write must stay 0600.
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("credentials.json").path

        try LocalTextFileAccessor().writeText(path, "secret")

        XCTAssertEqual(try posixMode(of: path), 0o600)
    }

    func testProtocolDefaultDelegatesToWriteText() throws {
        let fake = FakeFiles()
        let files: any TextFileAccessing = fake

        try files.writeTextPreservingMode("/tmp/fake.md", "text")

        XCTAssertEqual(fake.files["/tmp/fake.md"], "text")
    }

    // MARK: - queryJSONRows

    func testQueryJSONRowsDoesNotLaunchForMissingDatabase() throws {
        let runner = MemoryRecordingProcessRunner()
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunwayTests.missing.\(UUID().uuidString).sqlite")

        XCTAssertNil(
            try SQLiteCLIAccessor(processRunner: runner)
                .queryJSONRows(path: path.path, sql: "SELECT thread_id FROM stage1_outputs")
        )
        XCTAssertEqual(runner.callCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testQueryJSONRowsOpensExistingDatabaseReadOnlyAsJSON() throws {
        let database = try makeEmptyDatabase()
        defer { try? FileManager.default.removeItem(at: database) }
        let runner = MemoryRecordingProcessRunner()
        runner.result = ProcessResult(exitCode: 0, stdout: "[{\"thread_id\":\"t1\"}]\n", stderr: "")

        let rows = try SQLiteCLIAccessor(processRunner: runner)
            .queryJSONRows(path: database.path, sql: "SELECT thread_id FROM stage1_outputs")

        XCTAssertEqual(rows, "[{\"thread_id\":\"t1\"}]")
        XCTAssertEqual(runner.callCount, 1)
        XCTAssertTrue(runner.lastArguments.contains("-readonly"))
        XCTAssertTrue(runner.lastArguments.contains("-json"))
        XCTAssertEqual(runner.lastArguments.suffix(2).first, database.path)
    }

    func testQueryJSONRowsReturnsNilForEmptyOutput() throws {
        let database = try makeEmptyDatabase()
        defer { try? FileManager.default.removeItem(at: database) }
        let runner = MemoryRecordingProcessRunner()

        XCTAssertNil(
            try SQLiteCLIAccessor(processRunner: runner)
                .queryJSONRows(path: database.path, sql: "SELECT thread_id FROM stage1_outputs")
        )
    }

    func testQueryJSONRowsThrowsOnQueryFailure() throws {
        let database = try makeEmptyDatabase()
        defer { try? FileManager.default.removeItem(at: database) }
        let runner = MemoryRecordingProcessRunner()
        runner.result = ProcessResult(exitCode: 1, stdout: "", stderr: "no such table")

        XCTAssertThrowsError(
            try SQLiteCLIAccessor(processRunner: runner)
                .queryJSONRows(path: database.path, sql: "SELECT thread_id FROM stage1_outputs")
        ) { error in
            XCTAssertEqual(error as? SQLiteError, .queryFailed("no such table"))
        }
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunwayTests.memory.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeEmptyDatabase() throws -> URL {
        let database = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunwayTests.existing.\(UUID().uuidString).sqlite")
        try Data().write(to: database)
        return database
    }

    private func posixMode(of path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return permissions.intValue & 0o777
    }
}

private final class MemoryRecordingProcessRunner: ProcessRunning, @unchecked Sendable {
    var result = ProcessResult(exitCode: 0, stdout: "", stderr: "")
    private(set) var callCount = 0
    private(set) var lastArguments: [String] = []

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        callCount += 1
        lastArguments = arguments
        return result
    }
}
