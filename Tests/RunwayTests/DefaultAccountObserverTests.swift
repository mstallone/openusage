import XCTest
@testable import Runway

@MainActor
final class DefaultAccountObserverTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/dev")

    private func makeObserver(
        environment: [String: String] = [:],
        files: [String: String] = [:],
        keychainValue: String? = nil
    ) -> DefaultAccountObserver {
        DefaultAccountObserver(
            environment: FakeEnvironment(environment),
            files: FakeFiles(files),
            keychain: FakeKeychain(keychainValue),
            homeDirectory: { [home] in home }
        )
    }

    private func claudeStateJSON(
        uuid: String? = "ACCT-UUID-1",
        email: String? = "dev@example.com",
        orgUuid: String? = nil,
        orgName: String? = nil
    ) -> String {
        var account: [String: String] = [:]
        if let uuid { account["accountUuid"] = uuid }
        if let email { account["emailAddress"] = email }
        if let orgUuid { account["organizationUuid"] = orgUuid }
        if let orgName { account["organizationName"] = orgName }
        let data = try! JSONSerialization.data(withJSONObject: ["oauthAccount": account])
        return String(data: data, encoding: .utf8)!
    }

    // MARK: - Claude

    func testClaudeDefaultHomeResolvesFromUserLevelStateFile() {
        let observer = makeObserver(files: [
            "/Users/dev/.claude.json": claudeStateJSON(),
        ])

        // The default `~/.claude` keeps its state at `~/.claude.json` — next to, not inside, the dir.
        XCTAssertEqual(
            observer.observeClaude(),
            .resolved(identityKey: "acct-uuid-1", label: "dev@example.com", anchor: "/Users/dev/.claude")
        )
    }

    func testClaudeIdentityIsOrgScoped() {
        let observer = makeObserver(files: [
            "/Users/dev/.claude.json": claudeStateJSON(orgUuid: "ORG-9", orgName: "Sunstory"),
        ])

        // One human commonly has a personal Max org and a company Team org under the SAME account —
        // different usage pools, so the org id is part of the identity key.
        XCTAssertEqual(
            observer.observeClaude(),
            .resolved(identityKey: "acct-uuid-1|org-9", label: "dev@example.com (Sunstory)", anchor: "/Users/dev/.claude")
        )
    }

    func testClaudeConfigDirOverrideReadsIdentityInsideTheDir() {
        let observer = makeObserver(
            environment: ["CLAUDE_CONFIG_DIR": "~/claude-work"],
            files: ["/Users/dev/claude-work/.claude.json": claudeStateJSON()]
        )

        XCTAssertEqual(
            observer.observeClaude(),
            .resolved(identityKey: "acct-uuid-1", label: "dev@example.com", anchor: "/Users/dev/claude-work")
        )
    }

    func testClaudeCommaListConfigDirIsUnresolved() {
        // `ClaudeAuthStore` treats the env value as ONE credential path; a scanner-style comma list
        // cannot be assigned a single account identity.
        let observer = makeObserver(
            environment: ["CLAUDE_CONFIG_DIR": "~/a,~/b"],
            files: ["/Users/dev/a/.claude.json": claudeStateJSON()]
        )

        XCTAssertEqual(observer.observeClaude(), .unresolved(reason: "CLAUDE_CONFIG_DIR is a comma-separated list"))
    }

    func testClaudeCredentialsWithoutStateFileAreUnresolvedNotAbsent() {
        let observer = makeObserver(files: [
            "/Users/dev/.claude/.credentials.json":
                #"{"claudeAiOauth":{"accessToken":"file-token"}}"#,
        ])

        XCTAssertEqual(observer.observeClaude(), .unresolved(reason: "credentials present but no identity file"))
    }

    func testClaudeKeychainCredentialsWithoutStateFileAreUnresolvedNotAbsent() {
        let observer = makeObserver(
            keychainValue: #"{"claudeAiOauth":{"accessToken":"keychain-token"}}"#
        )

        XCTAssertEqual(observer.observeClaude(), .unresolved(reason: "credentials present but no identity file"))
    }

    func testClaudeNoFootprintIsAbsent() {
        XCTAssertEqual(makeObserver().observeClaude(), .absent)
    }

    func testClaudeStateFileNamingNoAccountIsUnresolved() {
        let observer = makeObserver(files: [
            "/Users/dev/.claude.json": #"{"someOtherKey": true}"#,
        ])

        XCTAssertEqual(observer.observeClaude(), .unresolved(reason: "identity file present but names no account"))
    }

    func testClaudeAmbientTokenDoesNotInheritAStateFileWithoutStoredCredentials() {
        let observer = makeObserver(
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "ambient-token"],
            files: ["/Users/dev/.claude.json": claudeStateJSON()]
        )

        XCTAssertEqual(observer.observeClaude(), .absent)
    }

    func testClaudeStoredCredentialKeepsStateFileIdentityAheadOfAmbientToken() {
        let observer = makeObserver(
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "ambient-token"],
            files: [
                "/Users/dev/.claude.json": claudeStateJSON(),
                "/Users/dev/.claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"stored-token"}}"#,
            ]
        )

        XCTAssertEqual(
            observer.observeClaude(),
            .resolved(identityKey: "acct-uuid-1", label: "dev@example.com", anchor: "/Users/dev/.claude")
        )
    }

    func testClaudeUsableKeychainCredentialKeepsStateFileIdentityAheadOfAmbientToken() {
        let observer = makeObserver(
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "ambient-token"],
            files: ["/Users/dev/.claude.json": claudeStateJSON()],
            keychainValue: #"{"claudeAiOauth":{"accessToken":"stored-token"}}"#
        )

        XCTAssertEqual(
            observer.observeClaude(),
            .resolved(identityKey: "acct-uuid-1", label: "dev@example.com", anchor: "/Users/dev/.claude")
        )
    }

    func testClaudeAmbientTokenDoesNotInheritStateFileFromUnusableCredentialFiles() {
        for credential in [
            "{ malformed",
            #"{"claudeAiOauth":{}}"#,
            #"{"claudeAiOauth":{"accessToken":"   "}}"#,
        ] {
            let observer = makeObserver(
                environment: ["CLAUDE_CODE_OAUTH_TOKEN": "ambient-token"],
                files: [
                    "/Users/dev/.claude.json": claudeStateJSON(),
                    "/Users/dev/.claude/.credentials.json": credential,
                ]
            )

            XCTAssertEqual(observer.observeClaude(), .absent)
        }
    }

    func testClaudeAmbientTokenDoesNotInheritStateFileFromUnusableKeychainCredentials() {
        for credential in [
            "{ malformed",
            #"{"claudeAiOauth":{}}"#,
            #"{"claudeAiOauth":{"accessToken":"   "}}"#,
        ] {
            let observer = makeObserver(
                environment: ["CLAUDE_CODE_OAUTH_TOKEN": "ambient-token"],
                files: ["/Users/dev/.claude.json": claudeStateJSON()],
                keychainValue: credential
            )

            XCTAssertEqual(observer.observeClaude(), .absent)
        }
    }

    func testClaudeAmbientTokenDoesNotUseStateIdentityWhenKeychainValidationIsUnavailable() {
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "ambient-token"]),
            files: FakeFiles(["/Users/dev/.claude.json": claudeStateJSON()]),
            keychain: ThrowingKeychain(),
            homeDirectory: { [home] in home }
        )

        XCTAssertEqual(
            observer.observeClaude(),
            .unresolved(reason: "credential presence unverifiable")
        )
    }

    // MARK: - Codex

    private func codexAuthJSON(accountID: String? = "codex-acct-1", idToken: String? = nil) -> String {
        var tokens: [String: String] = ["access_token": "at-1"]
        if let accountID { tokens["account_id"] = accountID }
        if let idToken { tokens["id_token"] = idToken }
        let data = try! JSONSerialization.data(withJSONObject: ["tokens": tokens])
        return String(data: data, encoding: .utf8)!
    }

    private func fakeJWT(payload: [String: Any]) -> String {
        func segment(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(segment(["alg": "none"])).\(segment(payload)).sig"
    }

    func testCodexResolvesFromAccountIDInFirstDefaultHome() {
        let observer = makeObserver(files: [
            "/Users/dev/.codex/auth.json": codexAuthJSON(),
        ])

        XCTAssertEqual(
            observer.observeCodex(),
            .resolved(identityKey: "codex-acct-1", label: nil, anchor: "/Users/dev/.codex")
        )
    }

    func testCodexHomeOverrideWinsAndEmailComesFromIDToken() {
        let idToken = fakeJWT(payload: ["email": "dev@example.com"])
        let observer = makeObserver(
            environment: ["CODEX_HOME": "/opt/codex-alt"],
            files: ["/opt/codex-alt/auth.json": codexAuthJSON(idToken: idToken)]
        )

        XCTAssertEqual(
            observer.observeCodex(),
            .resolved(identityKey: "codex-acct-1", label: "dev@example.com", anchor: "/opt/codex-alt")
        )
    }

    func testCodexHomeListSelectsTheFirstHomeThatNamesAnAccount() {
        let observer = makeObserver(
            environment: ["CODEX_HOME": "/opt/codex-one, /opt/codex-two"],
            files: [
                "/opt/codex-one/auth.json": codexAuthJSON(accountID: "first"),
                "/opt/codex-two/auth.json": codexAuthJSON(accountID: "second"),
            ]
        )

        XCTAssertEqual(
            observer.observeCodex(),
            .resolved(identityKey: "first", label: nil, anchor: "/opt/codex-one")
        )
    }

    func testCodexFallsBackToChatGPTAccountClaim() {
        // The id_token's ChatGPT account claim is the value the CLI itself copies into `account_id`.
        let idToken = fakeJWT(payload: [
            "https://api.openai.com/auth": ["chatgpt_account_id": "CLAIM-ACCT-2"],
        ])
        let observer = makeObserver(files: [
            "/Users/dev/.codex/auth.json": codexAuthJSON(accountID: nil, idToken: idToken),
        ])

        XCTAssertEqual(
            observer.observeCodex(),
            .resolved(identityKey: "claim-acct-2", label: nil, anchor: "/Users/dev/.codex")
        )
    }

    func testCodexNamelessAuthFileIsUnresolvedNeverPathKeyed() {
        // The strict identity rule: an auth file that can't name its account NEVER becomes an
        // identity (no path-derived fallback) — it's reported, not guessed.
        let observer = makeObserver(files: [
            "/Users/dev/.codex/auth.json": codexAuthJSON(accountID: nil),
        ])

        XCTAssertEqual(observer.observeCodex(), .unresolved(reason: "credentials present but no account identity"))
    }

    func testCodexNoFootprintIsAbsent() {
        XCTAssertEqual(makeObserver().observeCodex(), .absent)
    }

    func testCodexKeychainCredentialMakesTheFamilyUnresolved() {
        // An exact-home keyring item with no fingerprint-bound identity keeps the family unresolved.
        // The launch path never reads its secret to guess.
        let observer = makeObserver(
            files: ["/Users/dev/.codex/auth.json": codexAuthJSON()],
            keychainValue: #"{"tokens": {"access_token": "kc-at"}}"#
        )

        XCTAssertEqual(
            observer.observeCodex(),
            .unresolved(reason: "account-scoped keyring identity unverified")
        )
    }

    func testCodexUnverifiableKeychainProbeAlsoMakesTheFamilyUnresolved() {
        // A timed-out/failed probe (`nil`) must land on the same side as "item present": resolving
        // from the file while a keychain fallback might exist is the wrong-account stamp risk.
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles(["/Users/dev/.codex/auth.json": codexAuthJSON()]),
            keychain: ThrowingKeychain(),
            homeDirectory: { [home] in home }
        )

        XCTAssertEqual(
            observer.observeCodex(),
            .unresolved(reason: "account-scoped keyring item unverifiable")
        )
    }

    func testUnrelatedServiceLevelItemDoesNotSuppressAFileBackedIdentity() {
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.codex/auth.json": codexAuthJSON(accountID: "file-account"),
            ]),
            keychain: AccountKeychain(serviceValues: [
                CodexAuthStore.keychainService:
                    #"{"tokens":{"access_token":"unaddressed","account_id":"other"}}"#,
            ]),
            homeDirectory: { [home] in home }
        )

        XCTAssertEqual(
            observer.observeCodex(),
            .resolved(
                identityKey: "file-account",
                label: nil,
                anchor: "/Users/dev/.codex"
            )
        )
    }

    func testFingerprintBoundKeyringIdentityResolvesWithoutReadingItsSecret() {
        let codexHome = "/Users/dev/.codex"
        let account = CodexAuthStore.keychainAccountName(forHome: codexHome)
        let key = AccountKeychain.key(
            service: CodexAuthStore.keychainService,
            account: account
        )
        let keychain = AccountKeychain(
            accountValues: [
                key: #"{"tokens":{"access_token":"at","account_id":"keyring-account"}}"#,
            ],
            fingerprints: [key: "item-v1"]
        )
        let cache = CodexHomeIdentityCache(defaults: scratchDefaults())
        cache.record(
            identity: .init(key: "keyring-account", label: "keyring@example.com"),
            forHome: codexHome,
            keychainItemFingerprint: "item-v1"
        )
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles(),
            keychain: keychain,
            codexIdentityCache: cache,
            homeDirectory: { [home] in home }
        )

        XCTAssertEqual(
            observer.observeCodex(),
            .resolved(
                identityKey: "keyring-account",
                label: "keyring@example.com",
                anchor: codexHome
            )
        )
    }

    func testChangedKeyringFingerprintInvalidatesTheCachedDefaultIdentity() {
        let codexHome = "/Users/dev/.codex"
        let account = CodexAuthStore.keychainAccountName(forHome: codexHome)
        let key = AccountKeychain.key(
            service: CodexAuthStore.keychainService,
            account: account
        )
        let keychain = AccountKeychain(
            accountValues: [
                key: #"{"tokens":{"access_token":"at","account_id":"new-account"}}"#,
            ],
            fingerprints: [key: "item-v2"]
        )
        let cache = CodexHomeIdentityCache(defaults: scratchDefaults())
        cache.record(
            identity: .init(key: "old-account", label: nil),
            forHome: codexHome,
            keychainItemFingerprint: "item-v1"
        )
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles(),
            keychain: keychain,
            codexIdentityCache: cache,
            homeDirectory: { [home] in home }
        )

        XCTAssertEqual(
            observer.observeCodex(),
            .unresolved(reason: "account-scoped keyring identity unverified")
        )
    }

    func testCodexXDGConfigHomeOrderMatchesAuthStore() {
        // `CodexAuthStore.authPaths()` probes `~/.config/codex` before `~/.codex`; the observer must
        // attribute the same home the provider actually loads credentials from.
        let observer = makeObserver(files: [
            "/Users/dev/.config/codex/auth.json": codexAuthJSON(accountID: "config-home-acct"),
            "/Users/dev/.codex/auth.json": codexAuthJSON(accountID: "legacy-home-acct"),
        ])

        XCTAssertEqual(
            observer.observeCodex(),
            .resolved(identityKey: "config-home-acct", label: nil, anchor: "/Users/dev/.config/codex")
        )
    }

    private func scratchDefaults() -> UserDefaults {
        let suite = "DefaultAccountObserverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}

private final class ThrowingKeychain: KeychainReading, @unchecked Sendable {
    struct Unavailable: Error {}
    func readGenericPassword(service: String) throws -> String? { throw Unavailable() }
    func writeGenericPassword(service: String, value: String) throws { throw Unavailable() }
}
