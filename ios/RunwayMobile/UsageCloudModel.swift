import CloudKit
import Foundation
import Observation
import WidgetKit
import os

/// The app's observable face over `UsageSyncReader` (the CloudKit fetch/combine logic shared with
/// the widget extension): it owns refresh lifecycle, error copy, and iCloud account-change safety.
@MainActor
@Observable
final class UsageCloudModel {
    private(set) var devices: [DeviceUsage] = []
    private(set) var combined = CombinedUsage(today: nil, yesterday: nil, last30Cost: nil, last30Tokens: 0, trend: [])
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var lastRefreshAt: Date?
    /// Bumped when the iCloud account changes; a refresh only publishes results if its starting
    /// generation still matches, so an old account's slow fetch can't restore cleared data.
    private var generation = 0

    private let reader = UsageSyncReader()
    private let log = Logger(subsystem: "com.mattstallone.runway.mobile", category: "sync")

    init() {
        // An iCloud account switch must never leave the previous account's private usage on
        // screen — clear before the new account's first fetch, which may itself fail.
        NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Invalidate any fetch already in flight for the old account: its results must
                // never repopulate what this clear removes.
                self.generation += 1
                self.clearLoadedState()
                self.lastError = nil
                await self.refresh()
            }
        }
    }

    private func clearLoadedState() {
        devices = []
        combined = CombinedUsage(today: nil, yesterday: nil, last30Cost: nil, last30Tokens: 0, trend: [])
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        let startGeneration = generation
        await performRefresh(startGeneration)
        isLoading = false
        if startGeneration != generation {
            // The account changed while this fetch was in flight: its results were discarded and
            // the change handler's own refresh() bailed on isLoading — fetch the new account now.
            await refresh()
            return
        }
        // The widgets render the same synced data with their own budgeted refresh cadence; nudge
        // them whenever the app just pulled fresher state.
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func performRefresh(_ startGeneration: Int) async {
        do {
            let status = try await reader.accountStatus()
            guard startGeneration == generation else { return }
            if let message = UsageSyncReader.accountMessage(for: status) {
                // The account is gone or unreachable: the prior account's private usage must not
                // keep rendering beneath the notice.
                clearLoadedState()
                lastError = message
                return
            }
            let result = try await reader.fetchUsage()
            guard startGeneration == generation else { return }
            devices = result.devices
            combined = result.combined
            lastError = result.unreadableNotice
            lastRefreshAt = Date()
        } catch {
            log.error("CloudKit refresh failed: \(String(describing: error), privacy: .public)")
            guard startGeneration == generation else { return }
            lastError = error.localizedDescription
        }
    }
}
