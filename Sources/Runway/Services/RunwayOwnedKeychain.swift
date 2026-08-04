import Foundation
import Security

/// Storage for the secrets Runway itself owns (currently the iCloud-sync device id). This is the
/// only Keychain surface Runway is allowed to write — every provider credential store is another
/// app's property and is read-only (see `KeychainReading`).
protocol RunwayOwnedSecretStoring: Sendable {
    func read(service: String) throws -> String?
    func write(service: String, value: String) throws
}

/// In-process `SecItemAdd`/`SecItemCopyMatching`/`SecItemUpdate` against the login keychain. Items
/// created here are ACL-bound to Runway itself, so reads stay silent forever, no subprocess is
/// spawned, and the value never appears in an argument list the way the `/usr/bin/security` path
/// exposed it.
///
/// Not the data-protection Keychain, but not because the entitlement is missing: release builds —
/// and dev builds that find an iCloud provisioning profile — are signed with
/// `com.apple.application-identifier` and `keychain-access-groups` (see
/// `script/render_icloud_entitlements.sh`), so `kSecUseDataProtectionKeychain` would work there.
/// A plain local build without that profile signs with `Runway.local.entitlements.plist`, which
/// carries neither, and the call would fail with `errSecMissingEntitlement`. Choosing per build
/// flavor would split this item across two stores — the same device would mint a second iCloud sync
/// identity depending on how it was built — so both use the login keychain, which behaves
/// identically everywhere. Every property that motivated the move is already met here: no
/// subprocess, no secret in an argument list, and an ACL bound to Runway itself. Migrating to the
/// data-protection keychain (entitlement-gated, with a copy-forward) is viable follow-up work.
struct RunwayOwnedKeychainStore: RunwayOwnedSecretStoring {
    /// Fixed account name marking items as Runway's own, distinct from the `$USER` account the
    /// legacy subprocess writes used.
    static let account = "runway"

    func read(service: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = KeychainUISuppression.withUISuppressed { isSuppressed in
            isSuppressed ? SecItemCopyMatching(query as CFDictionary, &item) : errSecInteractionNotAllowed
        }
        switch status {
        case errSecSuccess:
            // A present-but-undecodable item must NOT read as absent. For the sync device id that
            // would mint a fresh UUID and publish a second record for a Mac that already has one,
            // so an unreadable value has to surface as an error and leave the identity provisional.
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.readFailed("The stored value for '\(service)' is not readable text.")
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw Self.error(status, service: service, operation: "read")
        }
    }

    func write(service: String, value: String) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecValueData as String: Data(value.utf8),
        ]
        let status = KeychainUISuppression.withUISuppressed { isSuppressed -> OSStatus in
            guard isSuppressed else { return errSecInteractionNotAllowed }
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecDuplicateItem else { return addStatus }
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: Self.account,
            ]
            return SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: Data(value.utf8)] as CFDictionary
            )
        }
        guard status == errSecSuccess else {
            throw Self.error(status, service: service, operation: "write")
        }
    }

    private static func error(_ status: OSStatus, service: String, operation: String) -> KeychainError {
        let message = SecCopyErrorMessageString(status, nil) as String?
            ?? "Keychain \(operation) failed with status \(status)."
        AppLog.warn(.keychain, "runway-owned \(operation) failed for service '\(service)' (status \(status))")
        return operation == "read" ? .readFailed(message) : .writeFailed(message)
    }
}
