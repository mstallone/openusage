import XCTest
@testable import Runway

/// A runtime that hangs until cancelled (a dead network call), then returns a snapshot the store
/// must never publish.
@MainActor
private final class StallingProviderRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor]
    let snapshot: ProviderSnapshot

    init(provider: Provider, descriptors: [WidgetDescriptor], snapshot: ProviderSnapshot) {
        self.provider = provider
        self.widgetDescriptors = descriptors
        self.snapshot = snapshot
    }

    func refresh() async -> ProviderSnapshot {
        // Sleeps far beyond any test timeout; exits early only via the watchdog's cancellation.
        try? await Task.sleep(for: .seconds(60))
        return snapshot
    }
}

@MainActor
final class WidgetDataStoreTimeoutTests: XCTestCase {
    func testHungProviderRefreshTimesOutIntoErrorAndBackoff() async {
        let provider = Provider(id: "hung", displayName: "Hung", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "hung.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = StallingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: 42, limit: 100, format: .percent)]
            )
        )
        let registry = WidgetRegistry(providers: [provider], descriptors: [descriptor])
        let store = WidgetDataStore(
            registry: registry,
            providers: [runtime],
            defaults: makeUserDefaults("refresh-timeout"),
            providerRefreshTimeout: 0.05
        )

        let outcome = await store.refresh(providerID: provider.id, force: true)

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(store.providerErrors[provider.id], "Refresh timed out after 0s")
        // The hung provider's late snapshot must not have been published.
        XCTAssertNil(store.localSnapshots[provider.id])
        // Timed-out providers back off like any failure, so a wake burst can't re-probe in a loop.
        let backedOff = await store.refresh(providerID: provider.id)
        XCTAssertEqual(backedOff, .backedOff)
    }

    func testFastProviderIsUntouchedByTheTimeout() async {
        let provider = Provider(id: "fast", displayName: "Fast", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "fast.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: 42, limit: 100, format: .percent)]
            )
        )
        let registry = WidgetRegistry(providers: [provider], descriptors: [descriptor])
        let store = WidgetDataStore(
            registry: registry,
            providers: [runtime],
            defaults: makeUserDefaults("refresh-timeout-fast"),
            providerRefreshTimeout: 5
        )

        let outcome = await store.refresh(providerID: provider.id, force: true)

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertNil(store.providerErrors[provider.id])
    }

    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suiteName = "RunwayTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
