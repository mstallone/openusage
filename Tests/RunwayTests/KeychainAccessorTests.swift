import Security
import XCTest
@testable import Runway

/// Minimal lock-guarded box for cross-thread event recording in the gate tests.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.withLock { body(&value) }
    }
}

final class KeychainAccessorTests: XCTestCase {
    /// Returns a fixed `ProcessResult` for any invocation — lets us drive the accessor's exit-code
    /// handling without a real `security` subprocess.
    private struct StubRunner: ProcessRunning {
        let result: ProcessResult
        func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
            result
        }
    }

    private final class CountingRunner: ProcessRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var invocations = 0

        var invocationCount: Int {
            lock.withLock { invocations }
        }

        func run(
            executable: String,
            arguments: [String],
            environment: [String: String],
            timeout: TimeInterval
        ) throws -> ProcessResult {
            lock.withLock { invocations += 1 }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }

    func testItemNotFoundExitReturnsNil() throws {
        // Exit 44 (errSecItemNotFound) is the legitimate "no credential stored" case → nil.
        let accessor = SecurityKeychainAccessor(processRunner: StubRunner(
            result: ProcessResult(exitCode: 44, stdout: "", stderr: "The specified item could not be found in the keychain.")
        ))
        XCTAssertNil(try accessor.readGenericPassword(service: "Test"))
    }

    func testNonItemNotFoundFailureThrowsReadFailed() {
        // A non-44 non-zero exit (locked keychain / access denied / cancelled unlock) must throw, not
        // collapse into the same nil as "no credential" — otherwise it gets mislabeled "not signed in".
        let accessor = SecurityKeychainAccessor(processRunner: StubRunner(
            result: ProcessResult(exitCode: 51, stdout: "", stderr: "User interaction is not allowed.")
        ))
        XCTAssertThrowsError(try accessor.readGenericPassword(service: "Test")) { error in
            guard case KeychainError.readFailed = error else {
                return XCTFail("expected KeychainError.readFailed, got \(error)")
            }
        }
    }

    func testFoundValueIsReturnedTrimmed() throws {
        let accessor = SecurityKeychainAccessor(processRunner: StubRunner(
            result: ProcessResult(exitCode: 0, stdout: "secret-token\n", stderr: "")
        ))
        XCTAssertEqual(try accessor.readGenericPassword(service: "Test"), "secret-token")
    }

    func testUISuppressionScopeDisablesClassicKeychainUIAndRestoresIt() {
        // `LAContext.interactionNotAllowed` only governs data-protection keychain items; the classic
        // login-keychain ACL dialog is silenced solely by the process-global
        // `SecKeychainSetUserInteractionAllowed` switch this scope drives. If the scope ever stops
        // flipping that switch, automatic refreshes regress into launch-time password dialogs.
        var allowed = DarwinBoolean(false)

        KeychainUISuppression.withUISuppressed { isSuppressed in
            XCTAssertTrue(isSuppressed, "the disable call should succeed in tests")
            SecKeychainGetUserInteractionAllowed(&allowed)
            XCTAssertFalse(allowed.boolValue, "classic keychain UI must be off inside the scope")
            KeychainUISuppression.withUISuppressed { _ in }
            SecKeychainGetUserInteractionAllowed(&allowed)
            XCTAssertFalse(allowed.boolValue, "an inner scope exit must not re-enable UI early")
        }

        SecKeychainGetUserInteractionAllowed(&allowed)
        XCTAssertTrue(allowed.boolValue, "UI must be re-allowed once the outermost scope exits")
        let start = Date()
        KeychainUISuppression.withUIAllowed {
            SecKeychainGetUserInteractionAllowed(&allowed)
            XCTAssertTrue(allowed.boolValue, "an interactive operation must run with UI allowed")
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            0.5,
            "with no suppression in flight, an interactive caller must not wait"
        )
    }

    func testSuppressedEntrantWaitsOutAnInteractiveOperation() {
        // The interactive gate is held for the operation's WHOLE duration (an approval dialog can
        // sit open for minutes). A suppressed call arriving mid-operation must park until the
        // interactive caller exits — if it ran concurrently, it would flip the process-wide UI flag
        // to false right when the user clicks Always Allow.
        let events = Locked<[String]>([])
        let suppressedDone = expectation(description: "suppressed call completed")

        KeychainUISuppression.withUIAllowed {
            let thread = Thread {
                KeychainUISuppression.withUISuppressed { _ in
                    events.withLock { $0.append("suppressed-ran") }
                }
                suppressedDone.fulfill()
            }
            thread.start()
            // Give the suppressed entrant time to reach the gate; it must still be parked.
            Thread.sleep(forTimeInterval: 0.2)
            events.withLock { $0.append("interactive-exit") }
        }

        wait(for: [suppressedDone], timeout: 5)
        XCTAssertEqual(events.withLock { $0 }, ["interactive-exit", "suppressed-ran"])
    }

    func testNonInteractiveReadStaysSilentForAuthorizedItemsAndDistinguishesMissing() throws {
        // The test process creates this item, so its ACL already authorizes the process — the
        // suppressed read must still return the secret silently (the already-approved default
        // account path). A missing service must stay `.missing`, never bleed into `.unavailable`.
        let accessor = SecurityKeychainAccessor()
        let service = "RunwayTests.keychain-ui.\(UUID().uuidString)"
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "runway-tests",
            kSecValueData as String: Data("stored-secret".utf8),
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw XCTSkip("cannot create a login-keychain item in this environment (status \(addStatus))")
        }
        defer {
            _ = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary)
        }

        XCTAssertEqual(
            accessor.readGenericPasswordWithoutUserInteraction(service: service),
            .value("stored-secret")
        )
        XCTAssertEqual(accessor.genericPasswordExists(service: service), true)
        XCTAssertEqual(
            accessor.readGenericPasswordWithoutUserInteraction(service: "\(service).missing"),
            .missing
        )
        var allowed = DarwinBoolean(false)
        SecKeychainGetUserInteractionAllowed(&allowed)
        XCTAssertTrue(allowed.boolValue, "the process-global UI switch must be restored after reads")
    }

    func testInProcessUpdateNeverInvokesSecurityHelper() {
        let runner = CountingRunner()
        let accessor = SecurityKeychainAccessor(processRunner: runner)

        XCTAssertThrowsError(try accessor.updateGenericPassword(
            service: "RunwayTests.missing.\(UUID().uuidString)",
            value: "rotated-token",
            allowUserInteraction: false
        )) { error in
            guard case KeychainError.writeFailed = error else {
                return XCTFail("expected KeychainError.writeFailed, got \(error)")
            }
        }
        XCTAssertEqual(runner.invocationCount, 0)
    }
}
