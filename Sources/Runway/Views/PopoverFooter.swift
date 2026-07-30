import SwiftUI

/// Fixed popover footer chrome: a single compact line with the app identity, the next-update
/// countdown, and the gear options menu (plus the transient copy confirmation and pin-limit notice).
/// It uses the destination screen so both pages mounted during a slide draw the same footer.
///
/// The footer is a **fixed-height bar rendered as a bottom-aligned overlay on the animated panel
/// frame** (see `DashboardView.body`), not a bar inside the scroll view's safe area — so its position
/// derives from the same frame whose bottom edge is the visible panel edge, and it stays glued to
/// that edge through every height morph by construction. A clear spacer of the same height inside
/// `pinnedFooter` keeps the scroll inset and the native bottom scroll-edge blur.
struct PopoverFooter: View {
    let screen: PopoverScreen
    let layout: LayoutStore
    let dataStore: WidgetDataStore
    let horizontalPadding: CGFloat
    /// The bar's fixed height — `DashboardView.footerHeight`, the same constant the height
    /// coordinator sums into each screen's morph target and the scroll spacer reserves.
    let height: CGFloat

    @Environment(\.popoverIsVisible) private var popoverIsVisible

    @ViewBuilder
    var body: some View {
        if screen != .customize {
            HStack(alignment: .center, spacing: 10) {
                footerIdentity
                Spacer(minLength: 8)
                nextUpdateButton
                HeaderView(screen: screen)
            }
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .barGlass()
            .overlay(alignment: .top) {
                if screen == .dashboard, layout.shareConfirmation {
                    shareCopiedPill
                        .offset(y: -34)
                }
            }
            .animation(Motion.spring, value: layout.shareConfirmation)
            .animation(Motion.spring, value: layout.shareConfirmationTrigger)
        }
    }

    private var shareCopiedPill: some View {
        TransientPill(
            systemImage: "checkmark.circle.fill",
            text: "Copied to clipboard",
            tint: Theme.positive,
            trigger: layout.shareConfirmationTrigger
        )
    }

    /// The leading identity line — the app version, swapped for the transient pin-limit notice while
    /// one is showing.
    private var footerIdentity: some View {
        Group {
            if let notice = layout.pinLimitNotice {
                Text(notice)
                    .foregroundStyle(Theme.notice)
                    .denyShake(trigger: layout.pinNoticeShakeTrigger, shakeOnAppear: true)
            } else {
                Text("Runway \(AppInfo.version)")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .animation(Motion.spring, value: layout.pinLimitNotice)
    }

    /// The compact countdown — a small refresh glyph plus "3m" / "45s" until the next update, swapped
    /// for a mini spinner while a refresh is in flight. Clicking it (or ⌘R) refreshes immediately.
    private var nextUpdateButton: some View {
        Button {
            refreshNow()
        } label: {
            Group {
                if popoverIsVisible {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        updateStatusLabel(now: context.date)
                    }
                } else {
                    updateStatusLabel(now: Date())
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: .command)
        .hoverTooltip("Refresh now (⌘R)")
        .disabled(isUpdating)
    }

    private func updateStatusLabel(now: Date) -> some View {
        HStack(spacing: 4) {
            if isUpdating {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .semibold))
                Text(countdownText(now: now))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var isUpdating: Bool {
        !dataStore.refreshingProviderIDs.isEmpty
    }

    private func refreshNow() {
        guard !isUpdating else { return }
        Task { await dataStore.refreshAll(force: true) }
    }

    private func countdownText(now: Date) -> String {
        let base = dataStore.lastRefreshAt ?? now
        let remaining = max(0, base.addingTimeInterval(RefreshSetting.interval).timeIntervalSince(now))
        let totalSeconds = Int(remaining.rounded(.up))
        if totalSeconds >= 60 {
            let minutes = Int((Double(totalSeconds) / 60).rounded(.up))
            return "\(minutes)m"
        }
        return "\(totalSeconds)s"
    }
}
