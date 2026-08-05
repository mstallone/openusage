import Foundation

protocol ICloudDeviceIDStoring: Sendable {
    func readDeviceID() throws -> String?
    func writeDeviceID(_ deviceID: String) throws
    /// Recover the device id from a legacy login-keychain location and persist it in the
    /// current one, or return nil when there is nothing to migrate. Callers reach for this LAST —
    /// only when both the current store and the saved preference are empty — because the legacy
    /// location may sit behind a prompt-capable Keychain path.
    func migrateLegacyDeviceID() throws -> String?
    /// User-attended counterpart used only when the user explicitly asks Runway to recover an
    /// unresolved legacy identity. Stores without a prompt-capable legacy source use the default.
    func migrateLegacyDeviceID(allowInteraction: Bool) throws -> String?
}

extension ICloudDeviceIDStoring {
    func migrateLegacyDeviceID() throws -> String? {
        nil
    }

    func migrateLegacyDeviceID(allowInteraction: Bool) throws -> String? {
        try migrateLegacyDeviceID()
    }
}

struct KeychainICloudDeviceIDStore: ICloudDeviceIDStoring {
    private let service: String
    private let legacyOwnedService: String
    private let legacyService: String
    private let ownedStore: any RunwayOwnedSecretStoring
    private let legacyKeychain: any KeychainReading

    init(
        ownedStore: any RunwayOwnedSecretStoring = RunwayOwnedFileStore(),
        legacyKeychain: any KeychainReading = SecurityKeychainAccessor(),
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.mattstallone.runway"
    ) {
        self.ownedStore = ownedStore
        self.legacyKeychain = legacyKeychain
        self.service = "\(bundleIdentifier).icloud-sync-device-id.v3"
        self.legacyOwnedService = "\(bundleIdentifier).icloud-sync-device-id.v2"
        self.legacyService = "\(bundleIdentifier).icloud-sync-device-id.v1"
    }

    func readDeviceID() throws -> String? {
        try ownedStore.read(service: service)
    }

    func writeDeviceID(_ deviceID: String) throws {
        try ownedStore.write(service: service, value: deviceID)
    }

    /// One-time recovery from either prior login-keychain location: v2 was owned by Runway, while
    /// v1 was created through `/usr/bin/security`. A saved preference normally seeds the current
    /// private file without touching either item; these reads are only needed after a preferences
    /// reset. Automatic attempts inspect metadata/cache only, while Recover Identity may read the
    /// old value interactively. Copying it keeps this device's existing iCloud record instead of
    /// minting a duplicate. The old items remain orphaned once the current file exists; Runway does
    /// not modify or silently delete them.
    func migrateLegacyDeviceID() throws -> String? {
        try migrateLegacyDeviceID(allowInteraction: false)
    }

    func migrateLegacyDeviceID(allowInteraction: Bool) throws -> String? {
        if allowInteraction {
            // Go straight through the coordinator's interactive path. The automatic attempt that
            // made this identity provisional deliberately tripped the item's breaker; routing a
            // public existence probe through that breaker would answer `nil` locally and prevent
            // the user-requested recovery read from ever running. A missing item is reported by
            // the interactive read itself without presenting an ACL prompt.
            if let legacy = try legacyKeychain.readGenericPasswordAllowingUserInteraction(
                service: legacyOwnedService,
                account: "runway"
            ) {
                try ownedStore.write(service: service, value: legacy)
                return legacy
            }
            guard let legacy = try legacyKeychain
                .readGenericPasswordForCurrentUserAllowingUserInteraction(service: legacyService)
            else { return nil }
            try ownedStore.write(service: service, value: legacy)
            return legacy
        }

        // Prefer the newer v2 item. Its account is fixed and distinct from the current-user account
        // used by v1, so each query joins the coordinator flight for the exact item it represents.
        switch legacyKeychain.genericPasswordExists(service: legacyOwnedService, account: "runway") {
        case false:
            break
        case nil:
            throw KeychainError.readFailed("Keychain could not be checked for this Mac's previous sync identity.")
        case true?:
            switch legacyKeychain.readGenericPasswordWithoutUserInteraction(
                service: legacyOwnedService,
                account: "runway"
            ) {
            case .value(let legacy):
                try ownedStore.write(service: service, value: legacy)
                return legacy
            case .missing:
                break
            case .unavailable:
                throw KeychainError.readFailed(
                    "This Mac's previous sync identity needs your approval. Choose Recover Identity in Settings."
                )
            }
        }

        // Tri-state on purpose. `false` is a confirmed fresh install — nothing to migrate, and the
        // secret read never runs. `nil` means the probe could not answer (locked keychain, a tripped
        // breaker, or a stuck flight): treating that as "absent" would mint a NEW id for a Mac that
        // already has one and publish a duplicate device to iCloud, so fail instead and let the
        // caller surface its existing warning.
        switch legacyKeychain.genericPasswordForCurrentUserExists(service: legacyService) {
        case false:
            return nil
        case nil:
            throw KeychainError.readFailed("Keychain could not be checked for this Mac's previous sync identity.")
        case true?:
            break
        }
        // Launch and retry paths may reuse a value already approved in this process, but never
        // request the legacy secret themselves. The Settings recovery button is the explicit
        // user action that can seed this cache and complete the one-time migration.
        let legacy: String
        switch legacyKeychain.readGenericPasswordForCurrentUserWithoutUserInteraction(service: legacyService) {
        case .value(let value):
            legacy = value
        case .missing:
            return nil
        case .unavailable:
            throw KeychainError.readFailed(
                "This Mac's previous sync identity needs your approval. Choose Recover Identity in Settings."
            )
        }
        try ownedStore.write(service: service, value: legacy)
        return legacy
    }
}
