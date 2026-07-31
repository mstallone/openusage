import SwiftUI

/// Shared provider section header used by the dashboard and its lifted provider-reorder preview.
/// The provider mark and name lead, followed by the optional plan badge. Dashboard callers supply a
/// screenshot-copy action, revealed at the trailing edge while the header is hovered. Callers can also
/// supply an optional `warning` — the latest refresh error, rendered as a small amber triangle at the
/// header's trailing edge (beside the hover-revealed copy control) whose hover tooltip carries the
/// message (e.g. "Not logged in. Run `codex` to authenticate."). The
/// optional `staleness` is the dashboard-only hint that the values shown are an aged snapshot still
/// revalidating: a short "Outdated" tag whose hover tooltip carries the precise age ("Last updated 3h
/// 12m ago"), so fossilized plan/limits never pass for current data.
struct ProviderSectionHeader: View {
    let provider: Provider
    var plan: String?
    var warning: String?
    /// Whether this provider's refresh is currently in flight — drives the small spinner beside the name
    /// so the section shows live feedback while values are being fetched (instead of silently sitting on
    /// the previous, possibly stale, numbers).
    var refreshing: Bool = false
    /// A muted "Outdated" hint shown only when the displayed snapshot has aged past its freshness window
    /// (dashboard only; `nil` in the reorder preview, which never surfaces staleness). Its tooltip carries
    /// the precise age.
    var staleness: StalenessHint?
    /// Dashboard-only screenshot action. The reorder preview omits it, while Customize uses its own
    /// row type and is unaffected by this header.
    var onCopyScreenshot: (() -> Bool)?

    /// Header type and icon use the same compact layout definition as the rows beneath them.
    private let density = DensitySetting.compact
    /// Air between the title cluster and the trailing status while the copy glyph is on screen:
    /// the overlaid glyph's 16pt slot plus a single point of breathing room — the glyph is drawn
    /// centered in its slot, so its built-in inset supplies most of the visual air and one extra
    /// point keeps the badge from feeling glued to it. Only held while the glyph shows — see the
    /// gutter comment on the title cluster's trailing padding below.
    private static let copyGutterWidth: CGFloat = 17
    /// Fixed layout slot for the warning triangle (its natural width is ~12pt at this size), so the
    /// copy overlay's trailing offset is a constant rather than a measurement.
    private static let warningSlotWidth: CGFloat = 14
    /// Read for the live card name: a rename lands in the account registry and re-titles the header
    /// without a relaunch (the `Provider`'s own name is baked at launch).
    @Environment(AppContainer.self) private var container
    /// Party easter egg: pulse the provider mark. Off by default everywhere else.
    @Environment(\.popoverPartyMode) private var partyMode
    @Environment(\.popoverIsVisible) private var popoverIsVisible
    @State private var isHovered = false
    /// Mirrors the copy glyph's actual visibility, reported by `CopyFeedbackButton`: hover reveal
    /// plus the post-copy checkmark's linger after the pointer leaves. The trailing gutter keys off
    /// this rather than the raw hover so a lingering checkmark keeps its space until it fades,
    /// instead of the plan badge sliding back underneath it.
    @State private var copyButtonPresent = false

    init(
        provider: Provider,
        plan: String? = nil,
        warning: String? = nil,
        refreshing: Bool = false,
        staleness: StalenessHint? = nil,
        onCopyScreenshot: (() -> Bool)? = nil
    ) {
        self.provider = provider
        self.plan = plan
        self.warning = warning
        self.refreshing = refreshing
        self.staleness = staleness
        self.onCopyScreenshot = onCopyScreenshot
    }

    var body: some View {
        HStack(spacing: 5) {
            // The provider mark replaces the dashboard's visual drag grip. Reordering still belongs
            // to the whole header at the caller, so the logo itself stays presentational.
            ProviderIcon(source: provider.icon, inset: 0.04)
                .frame(width: density.headerIconSize, height: density.headerIconSize)
                .partyPulse(partyMode)
            HStack(spacing: 5) {
                // Baseline-aligned pair: the plan badge (and stale tag) are smaller type and sit on the
                // name's text baseline, so the words line up along the bottom rather than floating centered.
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    // Name + plan keep their width and stay on one line; under width pressure it's the
                    // name that gives (the stale tag below stays whole — see its comment). A name that
                    // truncates (long account labels like "Claude — demo@example.com") marquees to its
                    // ending while the header is hovered — the same reveal the Total Spend legend uses.
                    HoverMarqueeText(
                        text: container.displayName(for: provider),
                        font: .system(size: density.headerPointSize, weight: .semibold),
                        isHovered: isHovered
                    )
                    .foregroundStyle(.primary)
                    .layoutPriority(1)
                    if let plan {
                        ProviderPlanBadge(plan: plan)
                            .layoutPriority(1)
                    }
                    // Tertiary, below the plan in hierarchy: outdated content, not something the user acts on.
                    // Short by design ("Outdated") — the precise age rides in the hover tooltip. Hidden while
                    // a refresh is in flight: the spinner already says "working on it". `fixedSize` keeps the
                    // tag whole under width pressure: as the lowest-priority element it used to absorb the
                    // squeeze from a long account name and render as a clipped glyph fragment (half an "O"
                    // reading as a stray "(" after the plan). It must stay legible rather than sliver or
                    // vanish — staleness can occur with no warning triangle (wake-from-sleep aging), making
                    // this the only signal that the values are fossilized (#582) — so the name yields
                    // instead; its tail stays recoverable through the hover marquee.
                    if let staleness, !refreshing {
                        Text(staleness.label)
                            .font(.system(size: density.planBadgePointSize))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .hoverTooltip(staleness.tooltip)
                    }
                }
                if refreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Refreshing")
                }
            }
            // The title cluster owns the header's flexible width (so the hover target spans the
            // row even with a short title) and pins its content leading. Its trailing padding is
            // the copy gutter: zero at rest, so a long title's plan badge sits flush at the
            // trailing edge — exactly the copy glyph's spot — and the glyph's room only while the
            // glyph is on screen, so the badge slides left in the same beat as the fade-in (the
            // header-level animation below). A Spacer can't get there: the row's 5pt item spacing
            // wraps a Spacer on both sides, leaving the badge floating short of the edge even at
            // minLength zero. Headers with spare room never move — their gutter opens inside
            // empty space.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, copyButtonPresent ? Self.copyGutterWidth : 0)
            // The warning sits at the far trailing edge — a header-level status instead of crowding
            // the name. Fixed slot width so the copy overlay can offset past it without measuring.
            // Hidden while a refresh is in flight: the spinner already says "working on it", and the
            // refresh may be about to clear the error.
            if let warning, !refreshing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.notice)
                    .frame(width: Self.warningSlotWidth, alignment: .trailing)
                    .hoverTooltip(warning)
                    .accessibilityLabel(warning)
            }
        }
        // The copy button overlays the trailing edge (just inside the warning triangle when one is
        // shown) instead of participating in the row: headers with spare room reveal it in place
        // without moving anything. Only a title long enough to fill the cluster's width sees the
        // gutter's animated growth shift the badge left — the deliberate trade over a permanently
        // reserved slot, which read as dead margin at rest.
        .overlay(alignment: .trailing) {
            if let onCopyScreenshot {
                CopyFeedbackButton(
                    accessibilityLabel: "Copy \(container.displayName(for: provider)) Screenshot",
                    isRevealed: isHovered,
                    action: onCopyScreenshot,
                    onPresenceChange: { copyButtonPresent = $0 }
                )
                .padding(.trailing, warning != nil && !refreshing ? Self.warningSlotWidth + 5 : 0)
            }
        }
        // Animate the gutter's grow/collapse in step with the button's 0.12s fade, so the badge's
        // shift and the glyph's appearance read as one motion.
        .animation(.easeOut(duration: 0.12), value: copyButtonPresent)
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // `NSPanel.orderOut` retains this SwiftUI tree and may not deliver a hover exit (the legend
        // row's rule). Clear the hover at the panel's authoritative close signal so a reopened
        // popover can't start with a revealed copy button — or a marquee still holding a scroll
        // position from the previous session, which read as the name "starting from the middle".
        .onChange(of: popoverIsVisible) { _, isVisible in
            if !isVisible { isHovered = false }
        }
    }
}

struct ProviderPlanBadge: View {
    let plan: String

    private let density = DensitySetting.compact

    var body: some View {
        // Plain text — no pill/capsule — for a cleaner header. Secondary (not tertiary): the plan
        // name is information the user reads, and tertiary on glass is reserved for inactive
        // content. The smaller point size alone keeps it subordinate to metric values.
        Text(plan)
            .font(.system(size: density.planBadgePointSize))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

struct ReorderGrip: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 16, height: 22)
            .contentShape(Rectangle())
    }
}
