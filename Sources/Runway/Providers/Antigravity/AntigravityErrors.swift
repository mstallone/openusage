import Foundation

/// Antigravity surfaces three user-facing failures. Every per-strategy error (LS not running, a decode
/// miss) is swallowed and the next strategy is tried; only when all strategies are exhausted does one of
/// these reach the UI.
enum AntigravityError: Error, LocalizedError, Equatable {
    /// No usable credentials anywhere (no LS running, no keychain token, nothing cached).
    case notSignedIn
    /// The Keychain credential may exist, but macOS would not let Runway read it.
    case credentialStoreUnreadable
    /// The Keychain item is present but automatic refresh has no fresh manually loaded value —
    /// the neutral connect prompt. Distinct from `credentialStoreUnreadable`, where even metadata
    /// could not be inspected, and from `keychainPermissionRequired`, an actual denial.
    case keychainConnectRequired
    /// An attempted (user-attended) read of the Keychain item was denied.
    case keychainPermissionRequired
    /// The Keychain item was present but did not contain usable Antigravity credential data.
    case invalidCredentialData
    /// A token was found but rejected (401/403) and a refresh couldn't recover it.
    case authExpired
    /// Credentials exist and look valid, but every endpoint was unreachable (network / server outage).
    /// Distinct from `notSignedIn` so a signed-in user isn't told to start Antigravity during an outage.
    case unavailable

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Start Antigravity or run `agy` and try again."
        case .credentialStoreUnreadable:
            return "Couldn't read Antigravity credentials from Keychain. Unlock Keychain or sign in to Antigravity again."
        case .keychainConnectRequired:
            return "Antigravity login found in Keychain. Connect to load it; if macOS asks, choose Always Allow to avoid future dialogs."
        case .keychainPermissionRequired:
            return "Keychain access to the Antigravity login was declined. Refresh and choose Always Allow when macOS asks."
        case .invalidCredentialData:
            return "Antigravity credentials are invalid. Open Antigravity or run `agy` to sign in again."
        case .authExpired:
            return "Antigravity sign-in expired. Open Antigravity or run `agy` to refresh."
        case .unavailable:
            return "Antigravity usage is temporarily unavailable. Try again shortly."
        }
    }
}
