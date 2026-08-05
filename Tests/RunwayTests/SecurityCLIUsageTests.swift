import Foundation
import XCTest

final class SecurityCLIUsageTests: XCTestCase {
    func testSourcesDoNotUseDeprecatedGlobalKeychainInteractionSwitch() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = repository.appendingPathComponent("Sources")
        let forbiddenSymbol = "SecKeychainSetUser" + "InteractionAllowed"
        var violations: [String] = []

        guard let files = FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return XCTFail("Could not enumerate \(sources.path)")
        }
        for case let file as URL in files where file.pathExtension == "swift" {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for (offset, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), line.contains(forbiddenSymbol) else { continue }
                violations.append("\(file.path):\(offset + 1): \(line)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Do not mutate process-global Keychain UI state around blocking calls:\n\(violations.joined(separator: "\n"))"
        )
    }

    func testRepositoryOwnedCodeDoesNotInvokeSecurityCLI() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let roots = [
            repository.appendingPathComponent("Sources"),
            repository.appendingPathComponent("script"),
            repository.appendingPathComponent(".github"),
            repository.appendingPathComponent(".agents/skills"),
        ]
        let executableExtensions = Set(["swift", "sh", "yml", "yaml", "mjs", "md"])
        let detector = try SecurityCLIInvocationDetector()
        var violations: [String] = []

        for root in roots {
            guard let files = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey]
            ) else {
                XCTFail("Could not enumerate \(root.path)")
                continue
            }

            for case let file as URL in files {
                guard
                    executableExtensions.contains(file.pathExtension),
                    file.lastPathComponent != "SecurityCLIUsageTests.swift"
                else {
                    continue
                }
                let contents = try String(contentsOf: file, encoding: .utf8)
                for (offset, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard
                        !trimmed.hasPrefix("//"),
                        !trimmed.hasPrefix("#")
                    else {
                        continue
                    }
                    if detector.isInvocation(String(line)) {
                        violations.append("\(file.path):\(offset + 1): \(line)")
                    }
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Use in-process Security.framework or a purpose-specific tool instead:\n\(violations.joined(separator: "\n"))"
        )
    }

    func testDetectorRecognizesSupportedInvocationShapes() throws {
        let detector = try SecurityCLIInvocationDetector()

        XCTAssertTrue(detector.isInvocation(#"/usr/bin/security find-identity -v"#))
        XCTAssertTrue(detector.isInvocation(#"security cms -D -i profile"#))
        XCTAssertTrue(detector.isInvocation(#"runner.run(executable: "security", arguments: args)"#))
        XCTAssertTrue(detector.isInvocation(#"exec('/usr/bin/security', args)"#))
    }

    func testDetectorDoesNotMatchSecurityFrameworkOrProse() throws {
        let detector = try SecurityCLIInvocationDetector()

        XCTAssertFalse(detector.isInvocation("import Security"))
        XCTAssertFalse(detector.isInvocation("Use the platform security model."))
        XCTAssertFalse(detector.isInvocation("Security.framework performs this read."))
    }
}

private struct SecurityCLIInvocationDetector {
    private let directPath = "/usr/bin/" + "security"
    private let quotedCommandNames = ["\"security\"", "'security'"]
    private let commandPattern: NSRegularExpression

    init() throws {
        commandPattern = try NSRegularExpression(
            pattern: #"\bsecurity[\t ]+(?:[a-z]+(?:-[a-z]+)+|cms|error|export|import)\b"#
        )
    }

    func isInvocation(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return line.contains(directPath)
            || quotedCommandNames.contains(where: line.contains)
            || commandPattern.firstMatch(in: line, range: range) != nil
    }
}
