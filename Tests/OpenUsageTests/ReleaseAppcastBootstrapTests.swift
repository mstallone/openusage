import Foundation
import XCTest

final class ReleaseAppcastBootstrapTests: XCTestCase {
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
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
}
