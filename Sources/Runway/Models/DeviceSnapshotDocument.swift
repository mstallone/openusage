import Foundation

/// One Mac's rendered live state, published beside its history document in the same per-device
/// CloudKit record. Macs only write this payload; the iOS companion reads it to show current
/// quotas, plans, balances, and refresh errors without ever holding provider credentials. Only
/// locally produced snapshots are included, so a device's record never republishes peer data.
struct DeviceSnapshotDocument: Hashable, Sendable, Codable {
    static let currentSchema = "runway.snapshot.v1"

    var schema: String = currentSchema
    var deviceID: String
    var deviceName: String
    var updatedAt: Date
    /// Enabled providers' last-good local snapshots, keyed by card id.
    var snapshots: [String: ProviderSnapshot]
    /// Latest refresh error per enabled provider, mirroring the dashboard's warning indicators.
    var providerErrors: [String: String]
    /// Resolved display names for providers that appear in `providerErrors` with no snapshot (a
    /// provider whose first refresh ever failed) — otherwise consumers would have only the card id
    /// to label the error with. Additive in schema v1; absent from older records.
    var providerNames: [String: String]? = nil
    /// The `providerErrors` entries that are the neutral connect prompt (a credential exists on
    /// that Mac but hasn't been loaded into its app session) rather than a real failure, so
    /// consumers can render them neutrally instead of as warnings. Additive in schema v1; absent
    /// from older records, and older consumers ignore it.
    var providerConnectPrompts: Set<String>? = nil
}
