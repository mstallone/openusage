import XCTest
@testable import Runway

@MainActor
final class CodexKeyringAssemblyTests: XCTestCase {
    func testUnverifiedHomeWarmsThenBecomesACardNextLaunch() async throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let cache = CodexHomeIdentityCache(defaults: defaults)
        let home = "/Users/dev/.codex-keyring"
        let account = CodexAuthStore.keychainAccountName(forHome: home)
        let key = AccountKeychain.key(
            service: CodexAuthStore.keychainService,
            account: account
        )
        let keychain = AccountKeychain(
            accountValues: [
                key: #"{"tokens":{"access_token":"at","account_id":"KEYRING"}}"#,
            ],
            fingerprints: [key: "item-v1"]
        )
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles(),
            keychain: keychain,
            codexIdentityCache: cache,
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = makeDiscovery(
            home: home,
            keychain: keychain,
            identityCache: cache
        )

        var first = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            families: ["codex"],
            codexDiscovery: discovery
        )
        first.codexIdentityCache = cache

        XCTAssertTrue(first.codexCards.isEmpty)
        XCTAssertEqual(first.unverifiedCodexKeyringHomes, [home])
        let warmTask = try XCTUnwrap(first.startCodexIdentityWarmTask())
        await warmTask.value

        let second = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            families: ["codex"],
            codexDiscovery: discovery
        )
        let card = try XCTUnwrap(second.codexCards.first)
        XCTAssertEqual(card.credentialHomePath, home)
        XCTAssertEqual(second.identityKeysByCard[card.id], "keyring")
        XCTAssertTrue(second.unverifiedCodexKeyringHomes.isEmpty)
    }

    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "RunwayTests.CodexKeyringAssembly.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func makeDiscovery(
        home: String,
        keychain: KeychainAccessing,
        identityCache: any CodexHomeIdentityCaching
    ) -> CodexHomeDiscovery {
        CodexHomeDiscovery(
            environment: FakeEnvironment([:]),
            files: FakeFiles(["\(home)/config.toml": ""]),
            keychain: keychain,
            identityCache: identityCache,
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") },
            listSubdirectories: { url in
                url.path == "/Users/dev" ? [URL(fileURLWithPath: home)] : []
            },
            timeBudget: 1,
            now: Date.init
        )
    }
}
