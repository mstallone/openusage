import XCTest
@testable import Runway

/// The owner-approved default placement for Kimi's subscription metrics.
@MainActor
final class KimiLayoutTests: XCTestCase {

    func testFreshDefaultsSeedApprovedKimiLayout() {
        let suiteName = "RunwayTests.KimiLayout.FreshDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = LayoutStore(
            registry: .from([KimiProvider()]),
            defaults: defaults,
            storageKey: "layout"
        )

        XCTAssertEqual(store.placed.map(\.descriptorID), [
            "kimi.session",
            "kimi.weekly",
            "kimi.extraBalance",
            "kimi.extraMonthly"
        ])
        XCTAssertTrue(store.pinnedMetricIDs.isEmpty)

        let group = store.customizeGroups.first { $0.provider.id == "kimi" }
        XCTAssertEqual(group?.alwaysShownMetrics.map(\.id), ["kimi.session"])
        XCTAssertEqual(group?.expandedMetrics.map(\.id), [
            "kimi.weekly",
            "kimi.extraBalance",
            "kimi.extraMonthly"
        ])
    }
}
