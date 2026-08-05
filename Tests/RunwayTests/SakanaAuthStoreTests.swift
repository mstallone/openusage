import CommonCrypto
import CryptoKit
import XCTest
@testable import Runway

final class SakanaAuthStoreTests: XCTestCase {
    private let token = String(repeating: "signed-in-session-", count: 4)

    func testPlaintextCookieIsLoadedWithoutKeychainAccess() throws {
        let fixture = makeStore(rows: [
            "/arc/Cookies": cookieRow(token: token, updatedAt: 42)
        ])

        let session = try fixture.store.loadSession(allowInteraction: false)

        XCTAssertEqual(session.token, token)
        XCTAssertEqual(session.browserName, "Arc (Profile 1)")
        XCTAssertTrue(fixture.keyReader.calls.isEmpty)
    }

    func testNewestCookieAcrossBrowserProfilesWins() throws {
        let fixture = makeStore(rows: [
            "/chrome/Cookies": cookieRow(token: String(repeating: "older", count: 8), updatedAt: 1),
            "/arc/Cookies": cookieRow(token: token, updatedAt: 99)
        ])

        let session = try fixture.store.loadSession(allowInteraction: false)

        XCTAssertEqual(session.token, token)
        XCTAssertEqual(session.browserName, "Arc (Profile 1)")
    }

    func testChromiumV10HostBoundCookieDecryptsWithSafeStorageKey() throws {
        let password = "fixture-safe-storage-password"
        let encrypted = try encryptedCookie(token: token, password: password)
        let fixture = makeStore(
            rows: ["/arc/Cookies": cookieRow(encrypted: encrypted, updatedAt: 42)],
            password: password
        )

        let session = try fixture.store.loadSession(allowInteraction: true)

        XCTAssertEqual(session.token, token)
        XCTAssertEqual(fixture.keyReader.calls, [
            .init(service: "Arc Safe Storage", allowInteraction: true)
        ])
    }

    func testPromptFreeCredentialProbeNeverReadsKeychain() {
        let fixture = makeStore(rows: [
            "/arc/Cookies": cookieRow(encrypted: Data("v10ciphertext".utf8), updatedAt: 42)
        ])

        XCTAssertTrue(fixture.store.hasBrowserSessionFootprint())
        XCTAssertTrue(fixture.keyReader.calls.isEmpty)
    }

    func testNoCookieIsNotLoggedIn() {
        let fixture = makeStore(rows: [:])

        XCTAssertThrowsError(try fixture.store.loadSession(allowInteraction: false)) {
            XCTAssertEqual($0 as? SakanaAuthError, .notLoggedIn)
        }
        XCTAssertFalse(fixture.store.hasBrowserSessionFootprint())
    }

    func testUnreadableCookieDatabaseIsCredentialAccessFailureNotLogout() {
        let fixture = makeStore(
            rows: ["/arc/Cookies": ""],
            errorPaths: ["/arc/Cookies"]
        )

        XCTAssertThrowsError(try fixture.store.loadSession(allowInteraction: false)) {
            XCTAssertEqual($0 as? SakanaAuthError, .credentialsUnreadable)
        }
    }

    func testMalformedCookieRowFailsLoudly() {
        let fixture = makeStore(rows: ["/arc/Cookies": "not-a-cookie-row"])

        XCTAssertThrowsError(try fixture.store.loadSession(allowInteraction: false)) {
            XCTAssertEqual($0 as? SakanaAuthError, .invalidCookie)
        }
    }

    func testDeferredNewestCookieStillFallsThroughToAUsablePlaintextCookie() throws {
        // The newest cookie's Safe Storage read being deferred must not end the scan: an older
        // plaintext cookie (or an already-connected browser's key) serves without any user
        // action, and showing Connect there would ask for a step nothing needs.
        let keyReader = SakanaKeyReaderDouble(error: .manualReadDeferred)
        let fixture = makeStore(
            rows: [
                "/arc/Cookies": cookieRow(encrypted: Data("v10ciphertext".utf8), updatedAt: 99),
                "/chrome/Cookies": cookieRow(token: token, updatedAt: 1)
            ],
            keyReader: keyReader
        )

        let session = try fixture.store.loadSession(allowInteraction: false)

        XCTAssertEqual(session.token, token)
        XCTAssertEqual(session.browserName, "Chrome (Default)")
    }

    func testConnectPromptSurfacesOnlyAfterEveryCandidateWasTried() {
        // With no usable fallback, the deferral does surface as the connect prompt — but only
        // after every candidate was given its chance.
        let keyReader = SakanaKeyReaderDouble(error: .manualReadDeferred)
        let fixture = makeStore(
            rows: [
                "/arc/Cookies": cookieRow(encrypted: Data("v10ciphertext".utf8), updatedAt: 99),
                "/chrome/Cookies": cookieRow(encrypted: Data("v10ciphertext".utf8), updatedAt: 1)
            ],
            keyReader: keyReader
        )

        XCTAssertThrowsError(try fixture.store.loadSession(allowInteraction: false)) {
            XCTAssertEqual($0 as? SakanaAuthError, .connectRequired)
        }
        XCTAssertEqual(keyReader.calls.count, 2, "both candidates must be tried before Connect is offered")
    }

    func testBackgroundReadSurfacesPermissionRequired() {
        let keyReader = SakanaKeyReaderDouble(error: .permissionRequired)
        let fixture = makeStore(
            rows: ["/arc/Cookies": cookieRow(encrypted: Data("v10ciphertext".utf8), updatedAt: 42)],
            keyReader: keyReader
        )

        XCTAssertThrowsError(try fixture.store.loadSession(allowInteraction: false)) {
            XCTAssertEqual($0 as? SakanaAuthError, .permissionRequired)
        }
        XCTAssertEqual(keyReader.calls.first?.allowInteraction, false)
    }

    func testWrongSafeStorageKeyIsRejected() throws {
        let encrypted = try encryptedCookie(token: token, password: "correct-password")
        let fixture = makeStore(
            rows: ["/arc/Cookies": cookieRow(encrypted: encrypted, updatedAt: 42)],
            password: "wrong-password"
        )

        XCTAssertThrowsError(try fixture.store.loadSession(allowInteraction: true)) {
            XCTAssertEqual($0 as? SakanaAuthError, .invalidCookie)
        }
    }

    func testDiscoversCookieDatabasesAcrossSupportedChromiumProfiles() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("runway-sakana-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let chrome = home.appendingPathComponent(
            "Library/Application Support/Google/Chrome/Default/Network/Cookies"
        )
        let arc = home.appendingPathComponent(
            "Library/Application Support/Arc/User Data/Profile 1/Cookies"
        )
        for url in [chrome, arc] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        }

        let sources = SakanaAuthStore.discoverSources(homeDirectory: home)

        let actualPaths = Set(sources.map {
            URL(fileURLWithPath: $0.databasePath).resolvingSymlinksInPath().path
        })
        let expectedPaths = Set([chrome, arc].map { $0.resolvingSymlinksInPath().path })
        XCTAssertEqual(actualPaths, expectedPaths)
        XCTAssertEqual(Set(sources.map(\.safeStorageService)), Set([
            "Chrome Safe Storage", "Arc Safe Storage"
        ]))
    }

    private struct Fixture {
        var store: SakanaAuthStore
        var keyReader: SakanaKeyReaderDouble
    }

    private func makeStore(
        rows: [String: String],
        password: String? = nil,
        keyReader: SakanaKeyReaderDouble? = nil,
        errorPaths: Set<String> = []
    ) -> Fixture {
        let reader = keyReader ?? SakanaKeyReaderDouble(password: password)
        let sources = [
            SakanaBrowserCookieSource(
                browserName: "Chrome (Default)",
                databasePath: "/chrome/Cookies",
                safeStorageService: "Chrome Safe Storage"
            ),
            SakanaBrowserCookieSource(
                browserName: "Arc (Profile 1)",
                databasePath: "/arc/Cookies",
                safeStorageService: "Arc Safe Storage"
            )
        ]
        let store = SakanaAuthStore(
            sqlite: SakanaSQLiteDouble(rows: rows, errorPaths: errorPaths),
            files: FakeFiles(Dictionary(uniqueKeysWithValues: rows.keys.map { ($0, "database") })),
            keyReader: reader,
            sources: { sources }
        )
        return Fixture(store: store, keyReader: reader)
    }

    private func cookieRow(token: String, updatedAt: UInt64) -> String {
        "\(Data(SakanaAuthStore.cookieHost.utf8).hex)|\(updatedAt)|plain:\(Data(token.utf8).hex)"
    }

    private func cookieRow(encrypted: Data, updatedAt: UInt64) -> String {
        "\(Data(SakanaAuthStore.cookieHost.utf8).hex)|\(updatedAt)|encrypted:\(encrypted.hex)"
    }

    private func encryptedCookie(token: String, password: String) throws -> Data {
        let key = try SakanaAuthStore.deriveKey(password: password)
        let hostHash = Data(SHA256.hash(data: Data(SakanaAuthStore.cookieHost.utf8)))
        let plaintext = hostHash + Data(token.utf8)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: plaintext.count + kCCBlockSizeAES128)
        var outputLength = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            plaintext.withUnsafeBytes { plaintextBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            plaintextBytes.baseAddress,
                            plaintext.count,
                            outputBytes.baseAddress,
                            capacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        XCTAssertEqual(Int32(status), Int32(kCCSuccess))
        output.count = outputLength
        return Data("v10".utf8) + output
    }
}

private struct SakanaSQLiteDouble: SQLiteAccessing {
    var rows: [String: String]
    var errorPaths: Set<String>

    func queryValue(path: String, sql: String) throws -> String? {
        XCTAssertTrue(sql.contains(SakanaAuthStore.cookieName))
        XCTAssertTrue(sql.contains(SakanaAuthStore.cookieHost))
        if errorPaths.contains(path) { throw SakanaSQLiteDoubleError.unreadable }
        return rows[path]
    }

    // JSON row queries are not exercised here.
    func queryJSONRows(path: String, sql: String) throws -> String? { nil }

    func execute(path: String, sql: String) throws {}
}

private enum SakanaSQLiteDoubleError: Error {
    case unreadable
}

private final class SakanaKeyReaderDouble: SakanaSafeStorageKeyReading, @unchecked Sendable {
    struct Call: Equatable {
        var service: String
        var allowInteraction: Bool
    }

    var password: String?
    var error: SakanaBrowserCredentialError?
    var calls: [Call] = []

    init(password: String? = nil, error: SakanaBrowserCredentialError? = nil) {
        self.password = password
        self.error = error
    }

    func readPassword(service: String, allowInteraction: Bool) throws -> String? {
        calls.append(.init(service: service, allowInteraction: allowInteraction))
        if let error { throw error }
        return password
    }
}

private extension Data {
    var hex: String {
        map { String(format: "%02X", $0) }.joined()
    }
}
