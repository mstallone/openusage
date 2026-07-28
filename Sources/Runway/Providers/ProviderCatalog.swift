import Foundation

/// The installed provider set and its canonical order. Both the menu-bar app and one-shot CLI build
/// their runtimes here so credentials, refresh behavior, pricing, and normalization can never drift.
@MainActor
enum ProviderCatalog {
    /// The launch account pass supplies scoped Claude and Codex cards. A bare Claude runtime still
    /// represents a resolved default-home account beside scoped extras; otherwise, scoped cards are
    /// the complete family set and no empty unscoped runtime is added beside them.
    static func make(
        defaults: UserDefaults = .standard,
        claudeCards: [ClaudeAccountCard] = [],
        claudeDefaultDisplayName: String? = nil,
        defaultClaudeExtraLogRoots: [URL] = [],
        codexCards: [CodexAccountCard] = [],
        codexIdentityCache: CodexHomeIdentityCache? = nil
    ) -> [ProviderRuntime] {
        // Default provider order (see AGENTS.md "## Providers"): the three established providers first,
        // then every other provider alphabetically by display name. Account cards slot in right after
        // their family's default card.
        //
        // Every baked `Provider.displayName` here is the DERIVED default — renames live only in the
        // account registry and are resolved at render time (`ProviderAccountsStore.resolvedDisplayName`),
        // so a baked name can never be a stale copy of one.
        var runtimes: [ProviderRuntime] = []
        if claudeCards.isEmpty || claudeDefaultDisplayName != nil {
            runtimes.append(ClaudeProvider(
                provider: ClaudeProvider.makeProvider(displayName: claudeDefaultDisplayName ?? "Claude"),
                // Once extra Claude cards exist, an unpinned Desktop fallback could borrow a login that
                // belongs to one of them — fetching that account's usage onto the default card. Desktop
                // returns as its own properly-pinned source kind in Phase 3.
                authStore: ClaudeAuthStore(allowsDesktopFallback: claudeCards.isEmpty),
                logUsageScanner: ClaudeLogUsageScanner(additionalRoots: defaultClaudeExtraLogRoots)
            ))
        }
        for card in claudeCards {
            runtimes.append(claudeAccountRuntime(card: card))
        }
        if codexCards.isEmpty {
            runtimes.append(CodexProvider(
                authStore: CodexAuthStore(identityCache: codexIdentityCache)
            ))
        }
        for card in codexCards {
            runtimes.append(codexAccountRuntime(
                card: card,
                identityCache: codexIdentityCache
            ))
        }
        runtimes += [
            CursorProvider(),
            AntigravityProvider(),
            CopilotProvider(defaults: defaults),
            DevinProvider(),
            GrokProvider(),
            KimiProvider(),
            OpenCodeProvider(),
            OpenRouterProvider(),
            SakanaProvider(),
            ZAIProvider()
        ]
        return runtimes
    }

    /// An extra Claude account card: same provider machinery, credentials and logs pinned to one
    /// login. The scanner's parse cache is partitioned per card so distinct homes never share
    /// records.
    private static func claudeAccountRuntime(card: ClaudeAccountCard) -> ClaudeProvider {
        ClaudeProvider(
            provider: ClaudeProvider.makeProvider(id: card.id, displayName: card.displayName),
            authStore: ClaudeAuthStore(
                scope: .configDir(path: card.configDirPath, keychainLiteral: card.keychainLiteral)
            ),
            logUsageScanner: ClaudeLogUsageScanner(
                cacheIdentityOverride: "claude-account:\(card.id)",
                rootsOverride: [URL(fileURLWithPath: card.configDirPath)] + card.extraLogRoots
            )
        )
    }

    /// A Codex account runtime pinned to one credential home and every same-account log root.
    private static func codexAccountRuntime(
        card: CodexAccountCard,
        identityCache: CodexHomeIdentityCache?
    ) -> CodexProvider {
        CodexProvider(
            provider: CodexProvider.makeProvider(id: card.id, displayName: card.displayName),
            authStore: CodexAuthStore(
                scope: .home(path: card.credentialHomePath),
                identityCache: identityCache
            ),
            logUsageScanner: CodexLogUsageScanner(
                cacheIdentityOverride: "codex-account:\(card.id)",
                rootsOverride: card.logRoots
            ),
            piUsageCardID: card.receivesPiUsage ? "codex" : nil
        )
    }
}
