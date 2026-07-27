import CryptoKit
import Foundation

/// Local bridge from an account-scoped keyring read to the next launch's no-secret home scan.
///
/// Codex keyring mode hides the provider-owned account id inside the Keychain. After a runtime reads
/// one exact home's item, this cache stores that identity under an opaque home digest and binds it to
/// an opaque digest of the item's non-secret attributes. Discovery can then place the home on the next
/// launch without requesting its secret. Replacing the item changes its modification metadata, so an
/// A → B login cannot inherit A's cached identity.
protocol CodexHomeIdentityCaching: Sendable {
    func identity(
        forHome path: String,
        keychainItemFingerprint: String
    ) -> DefaultAccountObserver.CodexIdentity?

    func record(
        identity: DefaultAccountObserver.CodexIdentity,
        forHome path: String,
        keychainItemFingerprint: String
    )
}

final class CodexHomeIdentityCache: CodexHomeIdentityCaching, @unchecked Sendable {
    static let storageKey = "openusage.codexHomeIdentities.v1"

    private struct Entry: Codable {
        var identityKey: String
        var identityLabel: String?
        var keychainItemFingerprint: String?
    }

    private static let lock = NSLock()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func identity(
        forHome path: String,
        keychainItemFingerprint: String
    ) -> DefaultAccountObserver.CodexIdentity? {
        guard let fingerprint = normalizedFingerprint(keychainItemFingerprint) else { return nil }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let entry = load()[homeKey(path)],
              entry.keychainItemFingerprint == fingerprint
        else {
            return nil
        }
        return DefaultAccountObserver.CodexIdentity(
            key: entry.identityKey,
            label: entry.identityLabel
        )
    }

    func record(
        identity: DefaultAccountObserver.CodexIdentity,
        forHome path: String,
        keychainItemFingerprint: String
    ) {
        let identityKey = identity.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !identityKey.isEmpty else {
            AppLog.error(.config, "refused to cache an empty Codex home identity")
            return
        }
        guard let fingerprint = normalizedFingerprint(keychainItemFingerprint) else {
            AppLog.error(.config, "refused to cache a Codex home identity without an item fingerprint")
            return
        }

        Self.lock.lock()
        defer { Self.lock.unlock() }
        var entries = load()
        let key = homeKey(path)
        let entry = Entry(
            identityKey: identityKey,
            identityLabel: identity.label?.nilIfEmpty,
            keychainItemFingerprint: fingerprint
        )
        guard entries[key]?.identityKey != entry.identityKey
            || entries[key]?.identityLabel != entry.identityLabel
            || entries[key]?.keychainItemFingerprint != entry.keychainItemFingerprint
        else {
            return
        }
        entries[key] = entry
        do {
            defaults.set(try JSONEncoder().encode(entries), forKey: Self.storageKey)
        } catch {
            AppLog.error(
                .config,
                "failed to encode the Codex home-identity cache: \(error.localizedDescription)"
            )
        }
    }

    private func homeKey(_ path: String) -> String {
        let canonical = URL(fileURLWithPath: expandHome(path))
            .resolvingSymlinksInPath().standardizedFileURL.path
        let digest = SHA256.hash(data: Data(canonical.precomposedStringWithCanonicalMapping.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        // Matches the opaque representation used by the earlier provider-instance prototype, so a
        // developer build that already warmed this cache keeps its safe binding.
        return "codex-home:\(digest)"
    }

    private func normalizedFingerprint(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // The production accessor already returns SHA-256. Hash again at the persistence boundary so
        // a custom accessor can never cause raw attributes to reach UserDefaults.
        return SHA256.hash(data: Data(trimmed.precomposedStringWithCanonicalMapping.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func load() -> [String: Entry] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [:] }
        do {
            return try JSONDecoder().decode([String: Entry].self, from: data)
        } catch {
            // Very early prototypes stored only `[opaqueHome: identity]`. Keep those entries
            // explicitly untrusted until a fresh account-scoped read records a fingerprint.
            if let legacy = try? JSONDecoder().decode([String: String].self, from: data) {
                return legacy.mapValues {
                    Entry(
                        identityKey: $0,
                        identityLabel: nil,
                        keychainItemFingerprint: nil
                    )
                }
            }
            AppLog.error(
                .config,
                "failed to decode the Codex home-identity cache: \(error.localizedDescription)"
            )
            return [:]
        }
    }
}
