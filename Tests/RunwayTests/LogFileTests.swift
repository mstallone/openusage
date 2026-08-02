import XCTest
@testable import Runway

/// Covers the resolved path suffix and the 10 MB single-archive rotation / launch-time trim. All
/// file I/O is confined to a per-test temp directory — never touches `~/Library/Logs`.
final class LogFileTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunwayTests.LogFile.\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    func testResolvedPathEndsWithExpectedSuffix() {
        // Under XCTest the shared sink deliberately redirects to a per-process temp folder so test
        // logging never pollutes the user's real file; the production default stays observable
        // through `defaultDirectory()`.
        XCTAssertTrue(
            LogFile.url.path.hasSuffix("/Runway.log"),
            "unexpected log path: \(LogFile.url.path)"
        )
        XCTAssertFalse(
            LogFile.url.path.hasSuffix("Library/Logs/Runway/Runway.log"),
            "a test run must not write into the user's real log file: \(LogFile.url.path)"
        )
        XCTAssertTrue(
            LogFile.defaultDirectory().path.hasSuffix("Logs/Runway"),
            "unexpected production log directory: \(LogFile.defaultDirectory().path)"
        )
    }

    func testAdvertisedURLMatchesSharedSinkPath() {
        // `LogFile.url` is what the app advertises (startup log, Settings copy/reveal); it must equal
        // where the shared sink actually writes so the two can never drift to different files.
        XCTAssertEqual(LogFile.url, LogFile.shared.fileURL)
    }

    func testAppendCreatesFileAndWritesLine() throws {
        let log = LogFile(directory: tempDir, fileName: "Runway.log")
        log.open()
        log.append("2026-01-01T00:00:00Z [INFO] [config] hello")

        let fileURL = tempDir.appendingPathComponent("Runway.log")
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("[config] hello"), contents)
        XCTAssertTrue(contents.hasSuffix("\n"))
    }

    func testRotationCreatesBackupWhenCapExceeded() throws {
        // Small cap so a few lines trip rotation.
        let cap = 200
        let log = LogFile(directory: tempDir, fileName: "Runway.log", maxBytes: cap)
        log.open()
        let line = String(repeating: "a", count: 80) // 81 bytes with newline
        log.append(line) // 81
        log.append(line) // 162
        log.append(line) // would be 243 > 200 -> rotate first, then write to fresh file

        let mainURL = tempDir.appendingPathComponent("Runway.log")
        let archiveURL = tempDir.appendingPathComponent("Runway.1.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path), "archive should exist after rotation")

        let archiveSize = (try FileManager.default.attributesOfItem(atPath: archiveURL.path)[.size] as? Int) ?? 0
        let mainSize = (try FileManager.default.attributesOfItem(atPath: mainURL.path)[.size] as? Int) ?? 0
        XCTAssertEqual(archiveSize, 162, "archive holds the two pre-rotation lines")
        XCTAssertEqual(mainSize, 81, "fresh main file holds only the post-rotation line")
    }

    func testRotationKeepsOnlyOneArchive() throws {
        let cap = 200
        let log = LogFile(directory: tempDir, fileName: "Runway.log", maxBytes: cap)
        log.open()
        let line = String(repeating: "b", count: 80)
        // Enough lines to force two rotations; only one .1 archive should survive.
        for _ in 0..<10 { log.append(line) }

        let archiveURL = tempDir.appendingPathComponent("Runway.1.log")
        let secondArchiveURL = tempDir.appendingPathComponent("Runway.2.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondArchiveURL.path), "only one archive is retained")
    }

    func testLaunchTrimRotatesOversizeFileOnOpen() throws {
        let cap = 100
        let mainURL = tempDir.appendingPathComponent("Runway.log")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // Leftover oversize file from a long-dead session.
        try Data(repeating: 0x61, count: cap + 50).write(to: mainURL)

        let log = LogFile(directory: tempDir, fileName: "Runway.log", maxBytes: cap)
        log.open()

        let archiveURL = tempDir.appendingPathComponent("Runway.1.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path), "oversize file should be rotated on open")
        let mainSize = (try FileManager.default.attributesOfItem(atPath: mainURL.path)[.size] as? Int) ?? -1
        XCTAssertEqual(mainSize, 0, "fresh main file starts empty after launch trim")
    }
}
