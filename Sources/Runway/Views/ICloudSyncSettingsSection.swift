import SwiftUI

struct ICloudSyncSettingsSection: View {
    @Bindable var sync: ICloudUsageSyncStore
    private let density = DensitySetting.compact

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            HStack(spacing: 5) {
                Text("iCloud Sync")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Image(systemName: "info.circle")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .hoverTooltip(
                        "Runway syncs each Mac's calculated usage history and latest usage snapshot "
                            + "through your private iCloud database. Runway never shares your "
                            + "credentials or logs."
                    )
            }
            .padding(.horizontal, 8)

            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Text("Sync Across Macs")
                    if sync.enabled, sync.isSyncing, sync.serviceError == nil {
                        ProgressView()
                            .controlSize(.small)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                            .accessibilityLabel("Syncing usage history")
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $sync.enabled)
                        .settingsSwitchStyle()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, density.controlRowPadding)
                .animation(Motion.spring, value: sync.isSyncing)
                Text("Shares usage history through iCloud, so you can see one combined summary for all your Macs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)

                if sync.enabled {
                    enabledContent
                } else if let error = sync.disabledStateWarning {
                    // A problem that outlives the toggle — e.g. this Mac's record could not be
                    // removed because its identity was unresolvable — must stay visible while sync
                    // is off, or the user never learns the opt-out didn't finish.
                    Divider()
                    inlineNotice(error)
                }
            }
            .cardSurface()
        }
    }

    @ViewBuilder
    private var enabledContent: some View {
        Divider()
        if let error = sync.serviceError { inlineNotice(error) }

        if sync.displayedDocuments.isEmpty, !sync.isSyncing, sync.serviceError == nil {
            Text("Waiting for this Mac’s first iCloud update…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ForEach(sync.displayedDocuments) { document in
                deviceRow(document, isThisMac: document.deviceID == sync.deviceID)
            }
        }
    }

    private func deviceRow(_ document: UsageHistoryDocument, isThisMac: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isThisMac ? "laptopcomputer" : "desktopcomputer")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(document.deviceName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isThisMac {
                        Text("This Mac")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.secondary.opacity(0.12), in: Capsule())
                            .fixedSize()
                    }
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text("Updated \(relativeAge(document.updatedAt, now: context.date))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    private func inlineNotice(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.notice)
            if sync.canRecoverIdentity {
                Button("Recover Identity") {
                    Task { await sync.recoverIdentity() }
                }
                .controlSize(.small)
                .disabled(sync.isSyncing)
            }
        }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func relativeAge(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(max(1, Int(seconds / 60)))m ago" }
        if seconds < 86_400 { return "\(max(1, Int(seconds / 3_600)))h ago" }
        return "\(max(1, Int(seconds / 86_400)))d ago"
    }
}
