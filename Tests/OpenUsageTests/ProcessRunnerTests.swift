import XCTest
import Darwin
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
    /// Pipe draining must share the process deadline and terminate that descendant instead of leaving
    /// either it or blocked drain work behind.
    func testTimeoutIncludesPipeDrainingAndTerminatesDescendant() throws {
        let runner = SystemProcessRunner()
        let startedAt = Date()
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-process-runner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        XCTAssertThrowsError(try runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 30 & echo $! > \"$OPENUSAGE_DESCENDANT_PID_PATH\"; printf ready"],
            environment: ["OPENUSAGE_DESCENDANT_PID_PATH": pidFile.path],
            timeout: 0.2
        )) { error in
            XCTAssertEqual(
                error as? ProcessRunnerError,
                .timedOut(executable: "/bin/sh", timeout: 0.2)
            )
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.8)

        let descendantPID = try XCTUnwrap(
            Int32(String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        defer { kill(descendantPID, SIGKILL) }

        let stopped = expectation(description: "descendant terminated")
        DispatchQueue.global().async {
            for _ in 0 ..< 100 where kill(descendantPID, 0) == 0 {
                usleep(10_000)
            }
            if kill(descendantPID, 0) != 0, errno == ESRCH {
                stopped.fulfill()
            }
        }
        wait(for: [stopped], timeout: 1.1)
    }

    /// A descendant can explicitly leave the process group while its direct parent is still running.
    /// Timeout cleanup must retain parent-child traversal for that case instead of relying on the root
    /// process group alone.
    func testTimeoutTerminatesDescendantThatCreatesOwnSession() throws {
        let runner = SystemProcessRunner()
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-process-runner-session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = """
        use POSIX ();
        my $child = fork();
        die "fork failed" unless defined $child;
        if ($child == 0) {
            my $session = POSIX::setsid();
            die "setsid failed" unless defined $session && $session == $$;
            $SIG{TERM} = "IGNORE";
            open(my $file, ">", $ENV{"OPENUSAGE_DESCENDANT_PID_PATH"}) or die "open failed";
            print $file "$$\\n";
            close($file);
            sleep 30;
            exit 0;
        }
        sleep 30;
        """

        XCTAssertThrowsError(try runner.run(
            executable: "/usr/bin/perl",
            arguments: ["-e", script],
            environment: ["OPENUSAGE_DESCENDANT_PID_PATH": pidFile.path],
            timeout: 0.2
        )) { error in
            XCTAssertEqual(
                error as? ProcessRunnerError,
                .timedOut(executable: "/usr/bin/perl", timeout: 0.2)
            )
        }

        let descendantPID = try XCTUnwrap(
            Int32(String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        defer { kill(descendantPID, SIGKILL) }

        let stopped = expectation(description: "session descendant terminated")
        DispatchQueue.global().async {
            for _ in 0 ..< 100 where kill(descendantPID, 0) == 0 {
                usleep(10_000)
            }
            if kill(descendantPID, 0) != 0, errno == ESRCH {
                stopped.fulfill()
            }
        }
        wait(for: [stopped], timeout: 1.1)
    }
}
