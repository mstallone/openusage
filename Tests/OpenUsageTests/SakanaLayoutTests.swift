import XCTest
@testable import OpenUsage

/// The owner-approved default placement for Sakana Fugu's subscription metrics.
@MainActor
final class SakanaLayoutTests: XCTestCase {
    func testFreshDefaultsSeedApprovedSakanaLayout() {
        let suiteName = "OpenUsageTests.SakanaLayout.FreshDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = LayoutStore(
            registry: .from([SakanaProvider()]),
            defaults: defaults,
            storageKey: "layout"
        )

        XCTAssertEqual(store.placed.map(\.descriptorID), [
            "sakana.session",
            "sakana.weekly",
            "sakana.trend",
            "sakana.today",
            "sakana.yesterday",
            "sakana.last30"
        ])
        XCTAssertTrue(store.pinnedMetricIDs.isEmpty)

        let group = store.customizeGroups.first { $0.provider.id == "sakana" }
        XCTAssertEqual(group?.alwaysShownMetrics.map(\.id), [
            "sakana.session",
            "sakana.weekly"
        ])
        XCTAssertEqual(group?.expandedMetrics.map(\.id), [
            "sakana.trend",
            "sakana.today",
            "sakana.yesterday",
            "sakana.last30"
        ])
    }
}
