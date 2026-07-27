import XCTest
@testable import OpenUsage

@MainActor
final class CodexHomeIdentityCacheTests: XCTestCase {
    func testBindingRequiresTheSameItemFingerprint() {
        let cache = CodexHomeIdentityCache(defaults: scratchDefaults())
        let home = "/Users/dev/.codex-work"
        let identity = DefaultAccountObserver.CodexIdentity(
            key: "ACCOUNT-WORK",
            label: "work@example.com"
        )

        cache.record(
            identity: identity,
            forHome: home,
            keychainItemFingerprint: "item-v1"
        )

        XCTAssertEqual(
            cache.identity(forHome: home, keychainItemFingerprint: "item-v1"),
            .init(key: "account-work", label: "work@example.com")
        )
        XCTAssertNil(
            cache.identity(forHome: home, keychainItemFingerprint: "item-v2"),
            "an in-place keyring replacement invalidates the old account binding"
        )
        XCTAssertNil(cache.identity(
            forHome: "/Users/dev/.codex-other",
            keychainItemFingerprint: "item-v1"
        ))
    }

    func testPersistedCacheContainsNoRawHomePathOrItemFingerprint() throws {
        let defaults = scratchDefaults()
        let cache = CodexHomeIdentityCache(defaults: defaults)
        cache.record(
            identity: .init(key: "account", label: nil),
            forHome: "/Users/dev/Secret Accounts/Codex Work",
            keychainItemFingerprint: "raw-keychain-metadata"
        )

        let data = try XCTUnwrap(defaults.data(forKey: CodexHomeIdentityCache.storageKey))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("Secret Accounts"))
        XCTAssertFalse(text.contains("raw-keychain-metadata"))
    }

    func testLegacyIdentityWithoutFingerprintIsNeverTrusted() throws {
        let defaults = scratchDefaults()
        let legacy = try JSONEncoder().encode(["opaque-home": "account"])
        defaults.set(legacy, forKey: CodexHomeIdentityCache.storageKey)
        let cache = CodexHomeIdentityCache(defaults: defaults)

        XCTAssertNil(cache.identity(
            forHome: "/Users/dev/.codex",
            keychainItemFingerprint: "item-v1"
        ))
    }

    private func scratchDefaults() -> UserDefaults {
        let suite = "CodexHomeIdentityCacheTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
