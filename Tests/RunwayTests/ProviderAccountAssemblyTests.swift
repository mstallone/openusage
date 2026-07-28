import XCTest
@testable import Runway

/// The launch account pass end to end: observer outcomes → account registry records → the per-card
/// identity map consumed by the snapshot cache stamp and the bare-id resolver.
@MainActor
final class ProviderAccountAssemblyTests: XCTestCase {
    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "RunwayTests.ProviderAccountAssembly.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testResolvedFamiliesFeedIdentityKeysAndTheRegistry() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                // Claude resolved at the default home; Codex has credentials that name no account.
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1", "emailAddress": "dev@example.com"}}"#,
                "/Users/dev/.codex/auth.json": #"{"tokens": {"access_token": "at-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(observer: observer, accountsStore: store)

        XCTAssertEqual(assembly.identityKeysByCard, ["claude": "acct-1"])
        // The registry recorded the resolved account under the bare id, holding the default badge.
        let record = try XCTUnwrap(store.defaultBadgeHolder(family: "claude"))
        XCTAssertEqual(record.id, "claude")
        XCTAssertEqual(record.label, "dev@example.com")
        XCTAssertEqual(record.sources.map(\.kind), [.defaultHome])
        // An unresolved family claims no account: no record, no identity key.
        XCTAssertNil(store.defaultBadgeHolder(family: "codex"))
    }

    /// A family whose home facts aren't readable this launch (first Finder/Dock launch racing a
    /// slow shell) is left out of the pass entirely: not observed, not reconciled — while a family
    /// whose home override is already in the process environment still resolves.
    func testFamiliesOutsideThePassAreNeitherObservedNorReconciled() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1"}}"#,
                "/Users/dev/.codex/auth.json": #"{"tokens": {"access_token": "at-1", "account_id": "CODEX-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(observer: observer, accountsStore: store, families: ["codex"])

        XCTAssertEqual(assembly.identityKeysByCard, ["codex": "codex-1"])
        XCTAssertNil(store.defaultBadgeHolder(family: "claude"), "an out-of-pass family must not be reconciled")
    }

    private func makeDiscovery(
        files: [String: String],
        subdirectories: [String]
    ) -> ClaudeConfigDirDiscovery {
        ClaudeConfigDirDiscovery(
            environment: FakeEnvironment([:]),
            files: FakeFiles(files),
            keychain: ServiceKeychain(),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") },
            listSubdirectories: { url in
                subdirectories
                    .map { URL(fileURLWithPath: $0) }
                    .filter { $0.deletingLastPathComponent().path == url.path }
            }
        )
    }

    private func makeCodexDiscovery(
        files: [String: String],
        subdirectories: [String],
        environment: [String: String] = [:],
        keychain: KeychainAccessing = AccountKeychain(),
        identityCache: (any CodexHomeIdentityCaching)? = nil
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

    func testADistinctConfigDirAccountMintsAHashedRecordAndAnExtraCard() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1", "emailAddress": "dev@example.com"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-work/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2", "emailAddress": "work@example.com", "organizationName": "Sunstory"}}"#,
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-2"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-work"]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, claudeDiscovery: discovery
        )

        let card = try XCTUnwrap(assembly.claudeCards.first)
        XCTAssertEqual(assembly.claudeCards.count, 1)
        XCTAssertTrue(card.id.hasPrefix("claude@"), "a config-dir account never claims the bare id")
        XCTAssertEqual(assembly.claudeDefaultDisplayName, "Claude — dev@example.com")
        XCTAssertEqual(card.displayName, "Claude — work@example.com (Sunstory)")
        XCTAssertEqual(card.configDirPath, "/Users/dev/.claude-work")
        XCTAssertEqual(assembly.identityKeysByCard["claude"], "acct-1")
        XCTAssertEqual(assembly.identityKeysByCard[card.id], "acct-2")
        // The registry recorded both: the default holder under the bare id, the extra account with
        // its config-dir source.
        let record = try XCTUnwrap(store.records.first { $0.id == card.id })
        XCTAssertEqual(record.sources.map(\.kind), [.configDir])
        XCTAssertEqual(record.label, "work@example.com (Sunstory)")
        XCTAssertTrue(assembly.defaultClaudeExtraLogRoots.isEmpty)
    }

    func testClaudeDefaultSwapResolvesAndRenamesTheAccountBackingTheBareRuntime() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let firstObserver = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1", "emailAddress": "first@example.com"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        _ = ProviderAccountAssembly.make(
            observer: firstObserver,
            accountsStore: store,
            claudeDiscovery: makeDiscovery(files: [:], subdirectories: [])
        )

        let secondObserver = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2", "emailAddress": "second@example.com"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let movedFirstAccount = makeDiscovery(
            files: [
                "/Users/dev/.claude-first/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1", "emailAddress": "first@example.com"}}"#,
                "/Users/dev/.claude-first/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-1"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-first"]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: secondObserver,
            accountsStore: store,
            claudeDiscovery: movedFirstAccount
        )

        let currentDefault = try XCTUnwrap(store.defaultBadgeHolder(family: "claude"))
        XCTAssertNotEqual(currentDefault.id, "claude", "the new account keeps its stable hashed record id")
        XCTAssertEqual(currentDefault.identityKey, "acct-2")
        XCTAssertEqual(assembly.identityKeysByCard["claude"], "acct-2")
        XCTAssertEqual(assembly.claudeDefaultDisplayName, "Claude — second@example.com")
        XCTAssertEqual(store.resolvedDisplayName(cardID: "claude"), "Claude — second@example.com")
        XCTAssertEqual(store.resolvedDisplayNamesByCardID["claude"], "Claude — second@example.com")
        XCTAssertTrue(assembly.claudeCards.isEmpty, "the moved bare-id account remains parked until Claude swap support")

        store.rename(cardID: "claude", to: "Current Default")
        XCTAssertEqual(
            store.records.first { $0.identityKey == "acct-2" }?.customLabel,
            "Current Default",
            "Rename follows the runtime to the account currently supplying its usage"
        )
        XCTAssertNil(store.records.first { $0.identityKey == "acct-1" }?.customLabel)
    }

    func testASameAccountConfigDirFoldsOntoTheDefaultCardAsALogRoot() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-side/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1"}}"#,
                "/Users/dev/.claude-side/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-1"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-side"]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, claudeDiscovery: discovery
        )

        XCTAssertTrue(assembly.claudeCards.isEmpty, "one account never renders as two cards")
        XCTAssertEqual(assembly.defaultClaudeExtraLogRoots.map(\.path), ["/Users/dev/.claude-side"])
        let record = try XCTUnwrap(store.defaultBadgeHolder(family: "claude"))
        XCTAssertEqual(record.id, "claude")
        XCTAssertEqual(Set(record.sources.map(\.kind)), [.defaultHome, .configDir])
    }

    func testAnUnresolvedDefaultLoginSkipsCandidatesThisLaunch() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                // Credentials exist but the state file names no account → unresolved, footprint present.
                "/Users/dev/.claude/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-work/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2"}}"#,
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-2"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-work"]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, claudeDiscovery: discovery
        )

        XCTAssertTrue(
            assembly.claudeCards.isEmpty,
            "with a nameless default login, an accepted candidate could be that very account — skip"
        )
        XCTAssertTrue(store.records.isEmpty)
    }

    func testNoDefaultLoginStillAcceptsAConfigDirOnlyAccount() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-work/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2"}}"#,
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-2"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-work"]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, claudeDiscovery: discovery
        )

        let card = try XCTUnwrap(assembly.claudeCards.first)
        XCTAssertTrue(
            card.id.hasPrefix("claude@"),
            "the bare id stays reserved for a future default-home login even when it is free"
        )
    }

    func testARenameNeverBakesIntoTheCardOnlyTheResolverCarriesIt() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-work/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2"}}"#,
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-2"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-work"]
        )

        // First pass creates the record; the user then renames it.
        let first = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, claudeDiscovery: discovery
        )
        let cardID = try XCTUnwrap(first.claudeCards.first?.id)
        XCTAssertEqual(first.claudeCards.first?.displayName, "Claude", "one account keeps the stock family name")
        store.rename(cardID: cardID, to: "Work Max")

        let reloadedStore = ProviderAccountsStore(defaults: defaults)
        let second = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: reloadedStore,
            claudeDiscovery: discovery
        )
        // The baked card name stays the DERIVED default — a rename lives only in the registry and
        // is resolved at render time, so a baked name can never be a stale copy of it.
        XCTAssertEqual(second.claudeCards.first?.displayName, "Claude")
        XCTAssertEqual(reloadedStore.resolvedDisplayName(cardID: cardID), "Work Max")
    }

    func testDistinctCodexHomesBuildScopedCardsAndIdentityStamps() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let defaultAuth = codexAuth(accountID: "PERSONAL", email: "personal@example.com")
        let workAuth = codexAuth(accountID: "WORK", email: "work@example.com")
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles(["/Users/dev/.codex/auth.json": defaultAuth]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = makeCodexDiscovery(
            files: [
                "/Users/dev/.codex/auth.json": defaultAuth,
                "/Users/dev/.codex-work/auth.json": workAuth,
            ],
            subdirectories: ["/Users/dev/.codex", "/Users/dev/.codex-work"]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            families: ["codex"],
            codexDiscovery: discovery
        )

        XCTAssertTrue(assembly.hasResolvedCodexDefault)
        XCTAssertEqual(assembly.codexCards.count, 2)
        let defaultCard = try XCTUnwrap(assembly.codexCards.first { $0.id == "codex" })
        let workCard = try XCTUnwrap(assembly.codexCards.first { $0.id != "codex" })
        XCTAssertEqual(defaultCard.credentialHomePath, "/Users/dev/.codex")
        XCTAssertEqual(defaultCard.logRoots.map(\.path), ["/Users/dev/.codex"])
        XCTAssertTrue(defaultCard.receivesPiUsage)
        XCTAssertEqual(defaultCard.displayName, "Codex — personal@example.com")
        XCTAssertEqual(workCard.displayName, "Codex — work@example.com")
        XCTAssertEqual(workCard.credentialHomePath, "/Users/dev/.codex-work")
        XCTAssertFalse(workCard.receivesPiUsage)
        XCTAssertEqual(assembly.identityKeysByCard["codex"], "personal")
        XCTAssertEqual(assembly.identityKeysByCard[workCard.id], "work")
        XCTAssertEqual(
            store.records.first { $0.id == workCard.id }?.sources.map(\.kind),
            [.codexHome]
        )
    }

    func testSameCodexAccountAcrossHomesFoldsLogsOntoOneCard() throws {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let auth = codexAuth(accountID: "SAME")
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles(["/Users/dev/.codex/auth.json": auth]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = makeCodexDiscovery(
            files: [
                "/Users/dev/.codex/auth.json": auth,
                "/Users/dev/.codex-side/auth.json": auth,
            ],
            subdirectories: ["/Users/dev/.codex", "/Users/dev/.codex-side"]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            families: ["codex"],
            codexDiscovery: discovery
        )

        let card = try XCTUnwrap(assembly.codexCards.first)
        XCTAssertEqual(assembly.codexCards.count, 1)
        XCTAssertEqual(card.id, "codex")
        XCTAssertEqual(card.displayName, "Codex")
        XCTAssertEqual(card.credentialHomePath, "/Users/dev/.codex")
        XCTAssertEqual(
            card.logRoots.map(\.path),
            ["/Users/dev/.codex", "/Users/dev/.codex-side"]
        )
        XCTAssertEqual(
            Set(try XCTUnwrap(store.defaultBadgeHolder(family: "codex")).sources.map(\.kind)),
            [.defaultHome, .codexHome]
        )
    }

    func testUnresolvedCodexDefaultSuppressesExtraHomes() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.codex/auth.json": #"{"tokens":{"access_token":"nameless"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = makeCodexDiscovery(
            files: [
                "/Users/dev/.codex-work/auth.json": codexAuth(accountID: "WORK"),
            ],
            subdirectories: ["/Users/dev/.codex-work"]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            families: ["codex"],
            codexDiscovery: discovery
        )

        XCTAssertFalse(assembly.hasResolvedCodexDefault)
        XCTAssertTrue(assembly.codexCards.isEmpty)
        XCTAssertTrue(store.records.isEmpty)
    }

    func testCodexDefaultSwapKeepsBothStableRecordIDsAndRepointsSources() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let firstAuth = codexAuth(accountID: "FIRST")
        let firstObserver = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles(["/Users/dev/.codex/auth.json": firstAuth]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let emptyDiscovery = makeCodexDiscovery(files: [:], subdirectories: [])

        let first = ProviderAccountAssembly.make(
            observer: firstObserver,
            accountsStore: store,
            families: ["codex"],
            codexDiscovery: emptyDiscovery
        )
        XCTAssertEqual(first.codexCards.map(\.id), ["codex"])

        let secondAuth = codexAuth(accountID: "SECOND")
        let secondObserver = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles(["/Users/dev/.codex/auth.json": secondAuth]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let secondDiscovery = makeCodexDiscovery(
            files: [
                "/Users/dev/.codex/auth.json": secondAuth,
                "/Users/dev/.codex-first/auth.json": firstAuth,
            ],
            subdirectories: ["/Users/dev/.codex", "/Users/dev/.codex-first"]
        )

        let second = ProviderAccountAssembly.make(
            observer: secondObserver,
            accountsStore: store,
            families: ["codex"],
            codexDiscovery: secondDiscovery
        )

        let original = try XCTUnwrap(second.codexCards.first { $0.id == "codex" })
        let replacement = try XCTUnwrap(second.codexCards.first { $0.id != "codex" })
        XCTAssertEqual(original.credentialHomePath, "/Users/dev/.codex-first")
        XCTAssertEqual(replacement.credentialHomePath, "/Users/dev/.codex")
        XCTAssertFalse(original.receivesPiUsage)
        XCTAssertTrue(replacement.receivesPiUsage)
        XCTAssertEqual(store.defaultBadgeHolder(family: "codex")?.id, replacement.id)
        XCTAssertEqual(second.identityKeysByCard["codex"], "first")
        XCTAssertEqual(second.identityKeysByCard[replacement.id], "second")
    }

    func testNothingObservedLeavesRegistryAndKeysEmpty() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(observer: observer, accountsStore: store)

        XCTAssertTrue(assembly.identityKeysByCard.isEmpty)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(defaults.data(forKey: ProviderAccountsStore.storageKey), "no observations, no write")
    }

    private func codexAuth(accountID: String, email: String? = nil) -> String {
        var tokens: [String: Any] = [
            "access_token": "access-\(accountID)",
            "account_id": accountID,
        ]
        if let email {
            let payload = try! JSONSerialization.data(withJSONObject: ["email": email])
            let encoded = payload.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            tokens["id_token"] = "header.\(encoded).signature"
        }
        let data = try! JSONSerialization.data(withJSONObject: ["tokens": tokens], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
