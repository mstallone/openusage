import XCTest
@testable import Runway

@MainActor
final class CodexHomeDiscoveryTests: XCTestCase {
    private func discovery(
        environment: [String: String] = [:],
        files: [String: String],
        keychain: KeychainReading = AccountKeychain(),
        identityCache: (any CodexHomeIdentityCaching)? = nil,
        subdirectories: [String] = []
    ) -> CodexHomeDiscovery {
        CodexHomeDiscovery(
            environment: FakeEnvironment(environment),
            files: FakeFiles(files),
            keychain: keychain,
            identityCache: identityCache,
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") },
            listSubdirectories: { url in
                subdirectories
                    .map { URL(fileURLWithPath: $0) }
                    .filter { $0.deletingLastPathComponent().path == url.path }
            }
        )
    }

    func testFindsStrictFileBackedHomesAcrossConfiguredAndBoundedCandidates() {
        let configured = "/Volumes/accounts/codex-work"
        let scan = discovery(
            environment: ["CODEX_HOME": "/Users/dev/.codex,\(configured)"],
            files: [
                "\(configured)/auth.json": auth(accountID: "WORK", email: "work@example.com"),
                "/Users/dev/.codex-side/auth.json": auth(accountID: "SIDE"),
                "/Users/dev/.config/codex-client/auth.json": auth(accountID: "CLIENT"),
            ],
            subdirectories: [
                "/Users/dev/.codex",
                "/Users/dev/.codex-side",
                "/Users/dev/.config/codex-client",
            ]
        ).run(excluding: ["/Users/dev/.codex"])

        XCTAssertEqual(
            Set(scan.findings.map(\.identityKey)),
            ["work", "side", "client"]
        )
        XCTAssertEqual(
            scan.findings.first { $0.identityKey == "work" }?.label,
            "work@example.com"
        )
        XCTAssertFalse(scan.findings.contains { $0.anchorPath == "/Users/dev/.codex" })
    }

    func testAcceptsChatGPTAccountClaimWhenAccountIDFieldIsAbsent() throws {
        let token = idToken(accountID: "CLAIM-ACCOUNT", email: "claim@example.com")
        let scan = discovery(files: [
            "/Users/dev/.codex-claim/auth.json":
                #"{"tokens":{"access_token":"at","id_token":"\#(token)"}}"#,
        ], subdirectories: ["/Users/dev/.codex-claim"]).run()

        let finding = try XCTUnwrap(scan.findings.first)
        XCTAssertEqual(finding.identityKey, "claim-account")
        XCTAssertEqual(finding.label, "claim@example.com")
    }

    func testRejectsTokenlessAPIKeyAndNamelessOAuthHomes() {
        let scan = discovery(
            files: [
                "/Users/dev/.codex-api/auth.json": #"{"OPENAI_API_KEY":"sk-test"}"#,
                "/Users/dev/.codex-empty/auth.json": #"{"tokens":{"access_token":""}}"#,
                "/Users/dev/.codex-nameless/auth.json": #"{"tokens":{"access_token":"at"}}"#,
            ],
            subdirectories: [
                "/Users/dev/.codex-api",
                "/Users/dev/.codex-empty",
                "/Users/dev/.codex-nameless",
            ]
        ).run()

        XCTAssertTrue(scan.findings.isEmpty)
        XCTAssertEqual(scan.notes.count, 3)
        XCTAssertTrue(scan.notes.contains { $0.contains("no usable OAuth token") })
        XCTAssertTrue(scan.notes.contains { $0.contains("names no account") })
    }

    func testConfiguredHomeOutsideDirectoryWalkIsStillDiscovered() {
        let path = "/opt/accounts/codex-personal"
        let scan = discovery(
            environment: ["CODEX_HOME": path],
            files: ["\(path)/auth.json": auth(accountID: "PERSONAL")]
        ).run()

        XCTAssertEqual(scan.findings.map(\.anchorPath), [path])
    }

    func testUnverifiedKeyringHomeStaysHiddenUntilItsExactItemIsBound() throws {
        let home = "/Users/dev/.codex-keyring"
        let account = CodexAuthStore.keychainAccountName(forHome: home)
        let key = AccountKeychain.key(
            service: CodexAuthStore.keychainService,
            account: account
        )
        let keychain = AccountKeychain(
            accountValues: [key: auth(accountID: "KEYRING", email: "keyring@example.com")],
            fingerprints: [key: "item-v1"]
        )
        let defaults = scratchDefaults()
        let cache = CodexHomeIdentityCache(defaults: defaults)
        let unverified = discovery(
            files: ["\(home)/config.toml": ""],
            keychain: keychain,
            identityCache: cache,
            subdirectories: [home]
        ).run()

        XCTAssertTrue(unverified.findings.isEmpty)
        XCTAssertEqual(unverified.unverifiedKeyringHomes, [home])

        cache.record(
            identity: .init(key: "keyring", label: "keyring@example.com"),
            forHome: home,
            keychainItemFingerprint: "item-v1"
        )
        let verified = discovery(
            files: ["\(home)/config.toml": ""],
            keychain: keychain,
            identityCache: cache,
            subdirectories: [home]
        ).run()

        let finding = try XCTUnwrap(verified.findings.first)
        XCTAssertEqual(finding.identityKey, "keyring")
        XCTAssertEqual(finding.label, "keyring@example.com")
        XCTAssertTrue(verified.unverifiedKeyringHomes.isEmpty)
    }

    func testFileAndCachedKeyringIdentityDisagreementSuppressesTheHome() {
        let home = "/Users/dev/.codex-disagrees"
        let account = CodexAuthStore.keychainAccountName(forHome: home)
        let key = AccountKeychain.key(
            service: CodexAuthStore.keychainService,
            account: account
        )
        let keychain = AccountKeychain(
            accountValues: [key: auth(accountID: "KEYRING")],
            fingerprints: [key: "item-v1"]
        )
        let cache = CodexHomeIdentityCache(defaults: scratchDefaults())
        cache.record(
            identity: .init(key: "keyring", label: nil),
            forHome: home,
            keychainItemFingerprint: "item-v1"
        )

        let scan = discovery(
            files: ["\(home)/auth.json": auth(accountID: "FILE")],
            keychain: keychain,
            identityCache: cache,
            subdirectories: [home]
        ).run()

        XCTAssertTrue(scan.findings.isEmpty)
        XCTAssertEqual(scan.unverifiedKeyringHomes, [home])
        XCTAssertTrue(scan.notes.contains { $0.contains("identities disagree") })
    }

    private func auth(accountID: String, email: String? = nil) -> String {
        var tokens: [String: Any] = ["access_token": "at", "account_id": accountID]
        if let email {
            tokens["id_token"] = idToken(accountID: accountID, email: email)
        }
        let data = try! JSONSerialization.data(withJSONObject: ["tokens": tokens], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func idToken(accountID: String, email: String) -> String {
        let payload: [String: Any] = [
            "email": email,
            "https://api.openai.com/auth": ["chatgpt_account_id": accountID],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return "header.\(base64URL(data)).signature"
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func scratchDefaults() -> UserDefaults {
        let suite = "CodexHomeDiscoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
