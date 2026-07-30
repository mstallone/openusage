import Foundation

/// Metrics enabled on first launch. The most useful live quota meters stay visible above the fold,
/// while usage history and selected reset details are enabled but tucked behind each provider's caret.
/// `LayoutStore` filters this to whatever the active registry actually knows, so registries that don't
/// define an ID (e.g. the test fixtures) silently ignore it. The provider-section order isn't seeded
/// here: an empty saved order reconciles to plain registry order in `LayoutStore`.
enum DefaultLayout {
    static let metricIDs: [String] = [
        "antigravity.geminiPro", "antigravity.geminiWeekly", "antigravity.claude", "antigravity.claudeWeekly",

        "claude.session", "claude.weekly", "claude.fable", "claude.trend",
        "claude.today", "claude.yesterday", "claude.last30",

        "codex.weekly", "codex.rateLimitResets", "codex.trend",
        "codex.today", "codex.yesterday", "codex.last30",

        "cursor.usage", "cursor.auto", "cursor.api", "cursor.trend",
        "cursor.onDemand", "cursor.today", "cursor.yesterday", "cursor.last30",

        "copilot.premium", "copilot.extra", "copilot.orgCredits", "copilot.orgSpend", "copilot.orgManaged",
        "copilot.chat", "copilot.completions",

        "devin.daily", "devin.weekly", "devin.extra",

        "grok.weekly", "grok.trend",
        "grok.today", "grok.yesterday", "grok.last30",

        "kimi.session", "kimi.weekly", "kimi.extraBalance", "kimi.extraMonthly",

        "opencode.session", "opencode.weekly", "opencode.monthly", "opencode.trend",
        "opencode.today", "opencode.yesterday", "opencode.last30",

        "openrouter.credits", "openrouter.balance",
        "openrouter.today", "openrouter.week", "openrouter.month", "openrouter.keyLimit",

        "sakana.session", "sakana.weekly", "sakana.trend",
        "sakana.today", "sakana.yesterday", "sakana.last30",

        "zai.session", "zai.weekly", "zai.webSearches"
    ]

    /// Frozen snapshot of the default-on metrics from the release that introduced default seeding.
    /// Existing users without a seeded-defaults key are treated as if these were already offered, so
    /// past opt-outs stay off while future additions to `metricIDs` can appear automatically once.
    static let migrationBaselineMetricIDs: [String] = [
        "claude.session", "claude.weekly", "claude.trend",
        "claude.extra", "claude.today", "claude.yesterday", "claude.last30",

        "codex.session", "codex.weekly", "codex.trend",
        "codex.credits", "codex.rateLimitResets", "codex.today", "codex.yesterday", "codex.last30",

        "devin.daily", "devin.weekly", "devin.extra",

        "grok.creditsUsed", "grok.trend",
        "grok.payAsYouGo", "grok.today", "grok.yesterday", "grok.last30",

        "cursor.usage", "cursor.auto", "cursor.api", "cursor.trend",
        "cursor.onDemand", "cursor.today", "cursor.yesterday", "cursor.last30"
    ]

    /// Metrics pinned to the menu bar on first launch, so the app shows real numbers out of the box
    /// instead of a lone icon. Up to two per provider, within the `LayoutStore.maxPinsPerProvider`
    /// cap. Every entry must also be enabled in `metricIDs`; `LayoutStore` filters only to the active
    /// registry.
    static let pinnedMetricIDs: [String] = [
        "antigravity.geminiPro", "antigravity.geminiWeekly",
        "claude.session", "claude.weekly",
        "codex.weekly",
        "cursor.auto", "cursor.api",
        "copilot.premium",
        "openrouter.credits",
        "zai.session", "zai.weekly"
    ]

    /// Account-card-aware default list: for every extra account card in the registry
    /// (for example, `claude@ab12cd34` or `codex@ab12cd34`), the family's entries are re-prefixed
    /// onto the card and appended, so a newly discovered account seeds the same metric set, caret
    /// split, and menu-bar pins as its family's default card. `migrationBaselineMetricIDs` is
    /// deliberately NOT translated: account-card ids must always read as never-offered so their
    /// defaults seed the first time the card appears.
    static func translatedForAccountCards(_ ids: [String], providerIDs: [String]) -> [String] {
        let accountCardIDs = providerIDs.filter(ProviderAccountID.isAccountCard)
        guard !accountCardIDs.isEmpty else { return ids }
        var result = ids
        for cardID in accountCardIDs {
            let prefix = ProviderAccountID.family(of: cardID) + "."
            for id in ids where id.hasPrefix(prefix) {
                result.append("\(cardID).\(id.dropFirst(prefix.count))")
            }
        }
        return result
    }

    /// Metrics placed in the per-provider On Demand section on a fresh install. This is
    /// membership, not enablement: optional disabled rows like Sonnet or Cursor Requests/Credits are
    /// listed here so if the user enables them later they appear below the caret by default.
    /// Filtered to the active registry by `LayoutStore`, and only seeded on a genuinely fresh launch
    /// (existing layouts keep everything always-shown unless they reset customization).
    static let expandedMetricIDs: [String] = [
        // Antigravity: the Gemini pool pair (5h + weekly) stays above the fold; the non-Gemini
        // (Claude) pool pair sits below the caret.
        "antigravity.claude", "antigravity.claudeWeekly",
        // Claude: Session, Weekly, and Fable stay above the fold; local history sits below the caret.
        "claude.trend", "claude.today", "claude.yesterday", "claude.last30",
        // Codex: Weekly stays above the fold; reset details and local history sit below the caret.
        "codex.rateLimitResets", "codex.trend", "codex.today", "codex.yesterday", "codex.last30",
        "cursor.onDemand", "cursor.requests", "cursor.credits",
        "cursor.today", "cursor.yesterday", "cursor.last30",
        // Copilot adapts its visible rows to the account: personal Credits/Extra Usage or org-wide
        // credits/spend stay above the fold; free-tier Chat + Completions sit below the caret.
        "copilot.chat", "copilot.completions",
        "devin.extra",
        // Grok: Weekly stays above the fold; local history sits below the caret.
        "grok.trend", "grok.today", "grok.yesterday", "grok.last30",
        // Kimi: Five-Hour Usage stays above the fold; Weekly Usage and the two Extra Usage
        // account/billing rows sit below the caret.
        "kimi.weekly", "kimi.extraBalance", "kimi.extraMonthly",
        // OpenCode: the three Go caps (Session/Weekly/Monthly) and Usage Trend stay above the fold —
        // matching every other provider — with the spend tiles (Today/Yesterday/Last 30 Days) below.
        "opencode.today", "opencode.yesterday", "opencode.last30",
        // OpenRouter: Credits meter + Balance stay above the fold; period spend and the per-key cap
        // sit below the caret.
        "openrouter.today", "openrouter.week", "openrouter.month", "openrouter.keyLimit",
        // Sakana Fugu: Five-Hour Usage and Weekly Usage stay above the fold; local history sits below.
        "sakana.trend", "sakana.today", "sakana.yesterday", "sakana.last30",
        // Z.ai: Session meter stays above the fold; Web Searches (monthly count) sits below the caret.
        "zai.webSearches"
    ]
}
