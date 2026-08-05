import Foundation

/// Latest normalized output for one provider refresh.
struct ProviderSnapshot: Hashable, Sendable, Codable {
    let providerID: String
    /// The card title at refresh time — always the baked DERIVED name (renames never reach the
    /// cache or iCloud). The CLI/API boundary re-resolves it against the account registry at
    /// respond time (`LocalUsageAPI.State.resolvingDisplayNames`), so human-facing output carries
    /// renames without persisting them.
    var displayName: String
    var plan: String?
    var lines: [MetricLine]
    var refreshedAt: Date
    /// Raw normalized daily history used to build spend rows. This always belongs to this Mac; peer
    /// history is combined only in the in-memory rendered view and is never written into the cache.
    var usageHistory: ProviderUsageHistory?
    /// The metrics that apply to the account represented by this snapshot. `nil` preserves the
    /// provider's traditional behavior (every declared descriptor is applicable); a non-nil set lets
    /// account-type-aware providers hide rows the upstream service does not offer for this plan,
    /// instead of presenting those rows as misleading "No data" placeholders.
    var applicableMetricIDs: Set<String>?
    /// A soft, non-blocking notice carried on a *successful* snapshot — e.g. Claude's "Re-login for live
    /// usage" when the saved login lacks the `user:profile` scope. The refresh succeeded and partial data
    /// (spend tiles) still loads, so this surfaces as the provider header's amber triangle rather than
    /// blanking the provider. Cached with the snapshot; cleared on the next refresh when the condition resolves.
    var warning: String?
    /// What the user can actually do about `warning`, which decides whether the header's amber
    /// triangle is a refresh button or an inert status glyph. Most notices name a fix and then want a
    /// refresh, so `.refresh` is the default; a notice that tells the user to WAIT — Claude's "manual
    /// refreshes will make it worse" during an Anthropic rate limit — must mark itself `.wait`, or the
    /// triangle would offer the exact action its own text warns against.
    ///
    /// Optional because snapshots are cached to disk and synced from peer Macs: one written before
    /// this existed decodes as `nil` and reads as `.refresh` through `resolvedWarningAction`.
    enum WarningAction: String, Hashable, Sendable, Codable {
        /// A manual refresh can clear the notice (a login awaiting Keychain approval, a token the
        /// user just renewed in their terminal, a transient failure).
        case refresh
        /// The notice resolves on its own schedule; refreshing does nothing or actively hurts.
        case wait
    }
    var warningAction: WarningAction?

    /// Whether `warning` is a neutral connect prompt (a credential exists on the machine but hasn't
    /// been loaded into this process yet) rather than something that needs fixing. The dashboard
    /// renders it as a Connect affordance instead of the amber warning triangle.
    ///
    /// Optional for the same cached/synced-snapshot reason as `warningAction`: older snapshots
    /// decode as `nil` and read as `false`.
    var warningIsConnectPrompt: Bool?

    /// `warningAction` with its default applied — see the property.
    var resolvedWarningAction: WarningAction { warningAction ?? .refresh }

    init(
        providerID: String,
        displayName: String,
        plan: String? = nil,
        lines: [MetricLine],
        refreshedAt: Date = Date(),
        usageHistory: ProviderUsageHistory? = nil,
        applicableMetricIDs: Set<String>? = nil,
        warning: String? = nil,
        warningAction: WarningAction? = nil,
        warningIsConnectPrompt: Bool? = nil
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.plan = plan
        self.lines = lines
        self.refreshedAt = refreshedAt
        self.usageHistory = usageHistory
        self.applicableMetricIDs = applicableMetricIDs
        self.warning = warning
        self.warningAction = warningAction
        self.warningIsConnectPrompt = warningIsConnectPrompt
    }

    func line(label: String) -> MetricLine? {
        lines.first { $0.label == label }
    }

    /// The success-path counterpart to `error(provider:message:)`: derives `providerID`/`displayName`
    /// from the provider so every runtime builds its snapshot the same way (`refreshedAt` is required
    /// so each call passes its own `now()`).
    static func make(
        provider: Provider,
        plan: String?,
        lines: [MetricLine],
        refreshedAt: Date,
        usageHistory: ProviderUsageHistory? = nil,
        applicableMetricIDs: Set<String>? = nil,
        warning: String? = nil,
        warningAction: WarningAction? = nil,
        warningIsConnectPrompt: Bool? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: plan,
            lines: lines,
            refreshedAt: refreshedAt,
            usageHistory: usageHistory,
            applicableMetricIDs: applicableMetricIDs,
            warning: warning,
            warningAction: warningAction,
            warningIsConnectPrompt: warningIsConnectPrompt
        )
    }

    /// Build an error snapshot straight from a caught error, preserving its user-facing
    /// `localizedDescription`. Preferred over `error(provider:message:)` wherever an `Error` is in hand.
    static func error(provider: Provider, error: Error) -> ProviderSnapshot {
        Self.error(provider: provider, message: error.localizedDescription)
    }

    static func error(provider: Provider, message: String) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.badge(label: MetricLine.errorBadgeLabel, text: message, colorHex: "#EF4444")]
        )
    }

    /// The neutral counterpart to `error(provider:error:)`: a credential exists on the machine but
    /// hasn't been loaded into this process yet, and only an explicit user action may read it.
    /// Nothing is broken and nothing was denied — the dashboard renders this as a Connect
    /// affordance, not a warning. It still travels the failed-refresh path so last-good data stays
    /// on screen and the prompt is never cached as data.
    static func connectPrompt(provider: Provider, error: Error) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.badge(label: MetricLine.connectBadgeLabel, text: error.localizedDescription)]
        )
    }
}
