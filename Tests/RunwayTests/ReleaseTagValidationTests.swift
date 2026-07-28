import Foundation
import XCTest

final class ReleaseTagValidationTests: XCTestCase {
    func testStableSemanticVersionIsAccepted() throws {
        let result = try validate("v0.7.8")

        XCTAssertEqual(result.status, 0, result.error)
        XCTAssertEqual(result.output, "0.7.8")
    }

    func testPrereleaseTagsAreRejected() throws {
        for tag in ["v0.7.8-beta.1", "v0.7.8-rc.1", "v0.7.8-preview"] {
            let result = try validate(tag)

            XCTAssertNotEqual(result.status, 0, tag)
            XCTAssertTrue(result.error.contains("stable form v1.2.3"), result.error)
        }
    }

    func testMalformedTagsAreRejected() throws {
        for tag in ["0.7.8", "v0.7", "v0.7.8.1", "release-v0.7.8"] {
            XCTAssertNotEqual(try validate(tag).status, 0, tag)
        }
    }

    private func validate(_ tag: String) throws -> (status: Int32, output: String, error: String) {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("script/validate_release_tag.sh")

        let standardOutput = Pipe()
        let standardError = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, tag]
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
