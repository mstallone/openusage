import Foundation

protocol ICloudDeviceIDStoring: Sendable {
    func readDeviceID() throws -> String?
    func writeDeviceID(_ deviceID: String) throws
    /// Recover the device id from the store's legacy (pre-v2) location and persist it in the
    /// current one, or return nil when there is nothing to migrate. Callers reach for this LAST —
    /// only when both the current store and the saved preference are empty — because the legacy
    /// location may sit behind a prompt-capable Keychain path.
    func migrateLegacyDeviceID() throws -> String?
}

extension ICloudDeviceIDStoring {
    func migrateLegacyDeviceID() throws -> String? {
        nil
    }
}

struct KeychainICloudDeviceIDStore: ICloudDeviceIDStoring {
    private let service: String
    private let legacyService: String
    private let ownedStore: any RunwayOwnedSecretStoring
    private let legacyKeychain: any KeychainReading

    init(
        ownedStore: any RunwayOwnedSecretStoring = RunwayOwnedKeychainStore(),
        legacyKeychain: any KeychainReading = SecurityKeychainAccessor(),
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.mattstallone.runway"
    ) {
        self.ownedStore = ownedStore
        self.legacyKeychain = legacyKeychain
        self.service = "\(bundleIdentifier).icloud-sync-device-id.v2"
        self.legacyService = "\(bundleIdentifier).icloud-sync-device-id.v1"
    }

    func readDeviceID() throws -> String? {
        try ownedStore.read(service: service)
    }

    func writeDeviceID(_ deviceID: String) throws {
        try ownedStore.write(service: service, value: deviceID)
    }

    /// One-time recovery from the v1 item the `/usr/bin/security` subprocess created, for upgrades
    /// where the saved preference is also gone (a preferences reset). Copying it keeps this device's
    /// iCloud record instead of minting a duplicate. The subprocess read can raise a Keychain prompt
    /// when the login keychain is locked, which is why `resolveDeviceID` reaches here last — and why
    /// the prompt-free existence probe gates it: a fresh install has no v1 item and must not spawn
    /// the subprocess at all. The v1 item's ACL belongs to the subprocess, so Runway cannot silently
    /// delete it; it stays behind, orphaned and never read again once the v2 item exists.
    func migrateLegacyDeviceID() throws -> String? {
        // Tri-state on purpose. `false` is a confirmed fresh install — nothing to migrate, and the
        // subprocess never runs. `nil` means the probe could not answer (locked keychain, suppressed
        // UI, a stuck flight): treating that as "absent" would mint a NEW id for a Mac that already
        // has one and publish a duplicate device to iCloud, so fail instead and let the caller
        // surface its existing warning.
        switch legacyKeychain.genericPasswordForCurrentUserExists(service: legacyService) {
        case false:
            return nil
        case nil:
            throw KeychainError.readFailed("Keychain could not be checked for this Mac's previous sync identity.")
        case true?:
            break
        }
        // In-process and prompt-free. The `/usr/bin/security` read this replaced could raise a
        // password dialog on a launch nobody asked for — and would do it again on every retry,
        // because the v1 item's ACL names the `security` helper rather than Runway. A failure here
        // leaves the identity provisional with its existing warning, which is the honest outcome.
        let legacy: String
        switch legacyKeychain.readGenericPasswordForCurrentUserWithoutUserInteraction(service: legacyService) {
        case .value(let value):
            legacy = value
        case .missing:
            return nil
        case .unavailable:
            throw KeychainError.readFailed("This Mac's previous sync identity could not be read.")
        }
        try ownedStore.write(service: service, value: legacy)
        return legacy
    }
}
