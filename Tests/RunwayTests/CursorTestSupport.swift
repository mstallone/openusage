import XCTest
@testable import Runway

/// Shared Cursor test fixtures used by both credential suites.
func makeSharedCursorJWT(sub: String = "google-oauth2|user", exp: Double = 9_999_999_999) -> String {
    let payload = #"{"sub":"\#(sub)","exp":\#(exp)}"#
    let encoded = Data(payload.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
    return "a.\(encoded).c"
}

final class FakeCursorSQLite: SQLiteAccessing, @unchecked Sendable {
    var values: [String: String]
    private(set) var writtenValues: [String: String] = [:]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func queryValue(path: String, sql: String) throws -> String? {
        let matches = values.filter { sql.contains("'\($0.key)'") }
        guard !matches.isEmpty else { return nil }
        let object = matches.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
        return "{\(object)}"
    }

    func queryJSONRows(path: String, sql: String) throws -> String? { nil }
}

final class EmptySQLite: SQLiteAccessing, @unchecked Sendable {
    func queryValue(path: String, sql: String) throws -> String? { nil }
    func queryJSONRows(path: String, sql: String) throws -> String? { nil }
    func execute(path: String, sql: String) throws {}
}

final class UnavailableCursorKeychain: KeychainReading, @unchecked Sendable {
    func readGenericPassword(service: String) throws -> String? {
        XCTFail("the subprocess-style read path must not be used")
        return nil
    }

    func readGenericPasswordWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        .unavailable
    }

    func genericPasswordExists(service: String) -> Bool? {
        true
    }

    func writeGenericPassword(service: String, value: String) throws {}
}

/// A protected Cursor keychain item that becomes readable once the user approves the prompt.
final class ApprovableCursorKeychain: KeychainReading, @unchecked Sendable {
    private let lock = NSLock()
    private let approvedValue: String
    private var interactive = 0

    init(approvedValue: String) {
        self.approvedValue = approvedValue
    }

    var interactiveReads: Int { lock.withLock { interactive } }

    func readGenericPassword(service: String) throws -> String? {
        XCTFail("the subprocess-style read path must not be used")
        return nil
    }

    func readGenericPasswordWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        .unavailable
    }

    func readGenericPasswordAllowingUserInteraction(service: String) throws -> String? {
        lock.withLock { interactive += 1 }
        return approvedValue
    }

    func genericPasswordExists(service: String) -> Bool? {
        true
    }
}

/// Every interactive read is denied (throws); non-interactive reads report items as protected.
final class DenyingCursorKeychain: KeychainReading, @unchecked Sendable {
    private let lock = NSLock()
    private var interactive = 0

    var interactiveReads: Int { lock.withLock { interactive } }

    func readGenericPassword(service: String) throws -> String? {
        XCTFail("the subprocess-style read path must not be used")
        return nil
    }

    func readGenericPasswordWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        .unavailable
    }

    func readGenericPasswordAllowingUserInteraction(service: String) throws -> String? {
        lock.withLock { interactive += 1 }
        throw KeychainError.readFailed("denied")
    }

    /// The user answered the dialog and refused, which the production accessor records from the
    /// resulting `errSecAuthFailed`/`errSecUserCanceled`. Without this the fake would model a read
    /// that never reached a prompt at all — a different outcome with different advice.
    func lastReadFailure(service: String) -> KeychainReadFailure? {
        .permissionDenied
    }

    func genericPasswordExists(service: String) -> Bool? {
        true
    }
}
