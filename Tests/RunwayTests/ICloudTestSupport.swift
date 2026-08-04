import XCTest
@testable import Runway

/// Shared fixtures for the iCloud identity and opt-out suites.
@MainActor
func makeDataStore(_ defaults: UserDefaults) -> WidgetDataStore {
    WidgetDataStore(
        registry: WidgetRegistry(providers: [], descriptors: []),
        providers: [],
        cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
        defaults: defaults
    )
}

func makeDefaults(_ name: String, syncEnabled: Bool = true) -> UserDefaults {
    let suite = "RunwayTests.ICloudIdentity.\(name).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defaults.set(syncEnabled, forKey: "runway.icloudSync.enabled.v1")
    return defaults
}
