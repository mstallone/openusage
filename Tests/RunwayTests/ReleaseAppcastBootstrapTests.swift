import Foundation
import XCTest

final class ReleaseAppcastBootstrapTests: XCTestCase {
    func testNormalizerRenamesOnlyTheRSSChannelTitle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let appcast = directory.appendingPathComponent("appcast.xml")
        let original = """
        <?xml version="1.0"?>
        <rss version="2.0">
            <channel>
                <title>OpenUsage</title>
                <item>
                    <title>0.8.1</title>
                    <enclosure url="https://example.com/OpenUsage-0.8.0.dmg"/>
                </item>
            </channel>
        </rss>
        """
        try original.write(to: appcast, atomically: true, encoding: .utf8)

        let script = repositoryRoot
            .appendingPathComponent("script/normalize_appcast_title.sh")
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, appcast.path, "Runway"]
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()

        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: error, as: UTF8.self))
        let updated = try String(contentsOf: appcast, encoding: .utf8)
        XCTAssertTrue(updated.contains("<title>Runway</title>"))
        XCTAssertTrue(updated.contains("<title>0.8.1</title>"))
        XCTAssertTrue(updated.contains("OpenUsage-0.8.0.dmg"))
        XCTAssertFalse(updated.contains("<title>OpenUsage</title>"))
    }

    func testNoReleasesStartsFresh() throws {
        XCTAssertEqual(try classify(existingTags: []), "fresh")
    }

    func testCurrentTagAsSoleReleaseAllowsFirstReleaseRetry() throws {
        XCTAssertEqual(try classify(existingTags: ["v0.8.0"]), "retry")
    }

    func testAnyPriorReleaseHistoryFailsClosed() throws {
        XCTAssertEqual(try classify(existingTags: ["v0.7.9"]), "history")
        XCTAssertEqual(
            try classify(existingTags: ["v0.8.0", "v0.7.9"]),
            "history"
        )
    }

    private func classify(
        existingTags: [String],
        currentTag: String = "v0.8.0"
    ) throws -> String {
        let script = repositoryRoot
            .appendingPathComponent("script/classify_appcast_bootstrap.sh")

        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, currentTag]
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        let input = existingTags.joined(separator: "\n") + (existingTags.isEmpty ? "" : "\n")
        standardInput.fileHandleForWriting.write(Data(input.utf8))
        try standardInput.fileHandleForWriting.close()
        process.waitUntilExit()

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(decoding: error, as: UTF8.self)
        )
        return String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
