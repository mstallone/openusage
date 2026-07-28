import XCTest
@testable import OpenUsage

final class ProcessRunnerTests: XCTestCase {
    /// Regression: a child whose output exceeds the ~64KB OS pipe buffer must not deadlock. Before the
    /// pipes were drained concurrently, this blocked the child on write, so it never exited and tripped
    /// the timeout. (`ps -ax -o command=` — used by language-server discovery — is ~240KB.)
    func testLargeStdoutDoesNotDeadlock() throws {
        let runner = SystemProcessRunner()
        let result = try runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "yes 0123456789 | head -c 200000"],
            environment: [:],
            timeout: 10
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.count, 200_000)
    }

    func testCapturesStdoutAndExitCode() throws {
        let runner = SystemProcessRunner()
        let result = try runner.run(executable: "/bin/echo", arguments: ["hello"], environment: [:], timeout: 5)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    /// A shell can exit after disowning a descendant that inherited its stdout/stderr descriptors.
    /// Pipe draining must share the process deadline instead of waiting for that descendant to exit.
    func testTimeoutIncludesPipeDraining() {
        let runner = SystemProcessRunner()
        let startedAt = Date()

        XCTAssertThrowsError(try runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 1 & printf ready"],
            environment: [:],
            timeout: 0.2
        )) { error in
            XCTAssertEqual(
                error as? ProcessRunnerError,
                .timedOut(executable: "/bin/sh", timeout: 0.2)
            )
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.8)
    }
}
