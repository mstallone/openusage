import Charts
import SwiftUI

struct DashboardView: View {
    var model: UsageCloudModel

    var body: some View {
        NavigationStack {
            List {
                if let error = model.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                if model.devices.isEmpty, !model.combined.hasData, model.lastError == nil, model.lastRefreshAt != nil {
                    Section {
                        ContentUnavailableView(
                            "Waiting for Your Macs",
                            systemImage: "icloud",
                            description: Text("Turn on Sync Across Macs in Runway on a Mac signed into this iCloud account.")
                        )
                    }
                }

                // Combined totals stand on the history payloads alone — they must show even when
                // no snapshot decoded (and hide when no history did, instead of hollow tiles).
                // An all-unpriced window has an empty trend but still needs its warning shown.
                if model.combined.hasData {
                    combinedSection
                }

                ForEach(model.devices) { device in
                    deviceSection(device)
                }
            }
            .navigationTitle("Runway")
            .refreshable { await model.refresh() }
            .overlay(alignment: .bottom) {
                if model.isLoading, model.devices.isEmpty {
                    ProgressView()
                        .padding()
                }
            }
        }
    }

    private var combinedSection: some View {
        Section("Across Your Macs") {
            HStack {
                spendTile("Today", day: model.combined.today)
                Divider()
                spendTile("Yesterday", day: model.combined.yesterday)
                Divider()
                spendTile(
                    "Last 30 Days",
                    cost: model.combined.last30Cost,
                    tokens: model.combined.last30Tokens,
                    empty: model.combined.last30Cost == nil && model.combined.last30Tokens == 0
                )
            }
            if model.combined.trend.count > 1 {
                Chart(Array(model.combined.trend.enumerated()), id: \.element.id) { index, day in
                    BarMark(
                        x: .value("Day", index),
                        y: .value("Tokens", day.tokens)
                    )
                    .foregroundStyle(.tint)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 64)
                .padding(.vertical, 4)
            }
            if model.combined.last30Cost != nil {
                // State the rule, not a blanket claim: some synced providers impute spend from
                // token counts (Claude, Codex), others report billed costs (OpenCode).
                Text("Where providers don’t report billed costs, dollars are estimated at API rates.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !model.combined.unknownModels.isEmpty {
                Label(
                    "Spend for unpriced models isn’t included: \(model.combined.unknownModels.joined(separator: ", "))",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
            }
        }
    }

    private func spendTile(_ title: String, day: CombinedUsage.Day?) -> some View {
        spendTile(title, cost: day?.cost, tokens: day?.tokens ?? 0, empty: day == nil)
    }

    private func spendTile(_ title: String, cost: Double?, tokens: Int, empty: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if empty {
                Text("No data")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // A day can have measured tokens with no priced cost — never claim "$0.00" then.
                Text(cost.map(UsageFormat.dollars) ?? "\(UsageFormat.tokens(Double(tokens))) tokens")
                    .font(.headline)
                    .monospacedDigit()
                if cost != nil {
                    Text("\(UsageFormat.tokens(Double(tokens))) tokens")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deviceSection(_ device: DeviceUsage) -> some View {
        // A provider whose first refresh failed has an error entry but no last-good snapshot —
        // it must still appear, with its actionable message, like the Mac's error card.
        let orphanErrors = device.snapshot.providerErrors
            .filter { device.snapshot.snapshots[$0.key] == nil }
            .sorted { $0.key < $1.key }
        return Section {
            ForEach(device.snapshot.snapshots.values.sorted(by: { $0.displayName < $1.displayName }), id: \.providerID) { provider in
                ProviderCard(provider: provider, error: device.snapshot.providerErrors[provider.providerID])
            }
            ForEach(orphanErrors, id: \.key) { providerID, message in
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.snapshot.providerNames?[providerID] ?? providerID)
                        .font(.body.weight(.medium))
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            HStack {
                Label(device.snapshot.deviceName, systemImage: "desktopcomputer")
                Spacer()
                Text(device.snapshot.updatedAt, format: .relative(presentation: .named))
            }
        }
    }
}

private struct ProviderCard: View {
    var provider: ProviderSnapshotWire
    var error: String?

    var body: some View {
        DisclosureGroup {
            ForEach(Array(provider.lines.enumerated()), id: \.offset) { _, line in
                MetricLineRow(line: line)
            }
            if let warning = provider.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } label: {
            HStack(spacing: 8) {
                Text(provider.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if let plan = provider.plan {
                    Text(plan)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if provider.warning != nil || error != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .imageScale(.small)
                }
                Spacer()
                // The headline number while the card is collapsed. Providers without a weekly meter
                // leave the trailing edge empty rather than showing a different window's number.
                if let weekly = provider.weeklyRemainingPercent {
                    Text(String(format: "%.0f%%", weekly))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }
}
