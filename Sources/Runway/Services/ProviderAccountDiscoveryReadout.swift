import Foundation

/// The off-main half of the launch account pass: observe each family's default home, then scan its
/// custom homes, with the two family chains running concurrently. Split from
/// `ProviderAccountAssembly` (the main-actor reconciliation half) to keep both files readable —
/// this half is pure filesystem/keychain IO and owns no state.
extension ProviderAccountAssembly {
    /// The Sendable payload the off-main half hands the main-actor assembly: default-home identity
    /// outcomes plus the custom-home scan results (already gated on those outcomes).
    struct DiscoveryReadout: Sendable {
        var claudeOutcome: DefaultAccountObserver.Outcome?
        var codexOutcome: DefaultAccountObserver.Outcome?
        var hasAmbientClaudeToken = false
        var claudeScan: ClaudeConfigDirDiscovery.Result?
        var codexScan: CodexHomeDiscovery.Result?
    }

    /// Run both family chains (observe the default home, then scan custom homes) concurrently off
    /// the caller's actor. Each chain is sequential internally — the scan's gating and exclusions
    /// depend on its family's default-home outcome.
    nonisolated static func observeAndDiscover(
        observer: DefaultAccountObserver,
        families: Set<String>,
        claudeDiscovery: ClaudeConfigDirDiscovery?,
        codexDiscovery: CodexHomeDiscovery?
    ) async -> DiscoveryReadout {
        async let claude = claudeReadout(
            observer: observer, discovery: claudeDiscovery, enabled: families.contains("claude")
        )
        async let codex = codexReadout(
            observer: observer, discovery: codexDiscovery, enabled: families.contains("codex")
        )
        let (claudePart, codexPart) = await (claude, codex)
        return DiscoveryReadout(
            claudeOutcome: claudePart.outcome,
            codexOutcome: codexPart.outcome,
            hasAmbientClaudeToken: claudePart.hasAmbientToken,
            claudeScan: claudePart.scan,
            codexScan: codexPart.scan
        )
    }

    nonisolated static func claudeReadout(
        observer: DefaultAccountObserver,
        discovery: ClaudeConfigDirDiscovery?,
        enabled: Bool
    ) -> (outcome: DefaultAccountObserver.Outcome?, scan: ClaudeConfigDirDiscovery.Result?, hasAmbientToken: Bool) {
        guard enabled else { return (nil, nil, false) }
        let outcome = observer.observeClaude()
        var scan: ClaudeConfigDirDiscovery.Result?
        // Guarded on the default read: when a default login clearly EXISTS but can't be named
        // (`unresolved`), accepting candidates could render the very account the default card shows
        // as a second card — skip them this launch instead. A machine with no default login at all
        // keeps accepting: there is nothing to duplicate, and a custom-dir-only login should still
        // get its card.
        if let discovery {
            if case .unresolved = outcome {
                AppLog.info(.config, "discovery: claude default login present but its identity is unreadable → skipping extra-account candidates this launch")
            } else {
                let result = discovery.run()
                for note in result.notes {
                    AppLog.info(.config, "discovery: \(note)")
                }
                scan = result
            }
        }
        return (outcome, scan, observer.hasAmbientClaudeToken)
    }

    nonisolated static func codexReadout(
        observer: DefaultAccountObserver,
        discovery: CodexHomeDiscovery?,
        enabled: Bool
    ) -> (outcome: DefaultAccountObserver.Outcome?, scan: CodexHomeDiscovery.Result?) {
        guard enabled else { return (nil, nil) }
        let outcome = observer.observeCodex()
        guard let discovery else { return (outcome, nil) }
        let defaultAnchor: String? = if case .resolved(_, _, let anchor) = outcome {
            anchor
        } else {
            nil
        }
        // Run even when the default identity is unresolved: verified findings remain suppressed
        // (the assembly skips them), but unverified exact-item homes still need the post-launch
        // warming plan.
        let scan = discovery.run(excluding: Set(defaultAnchor.map { [$0] } ?? []))
        for note in scan.notes {
            AppLog.info(.config, "discovery: \(note)")
        }
        if case .unresolved = outcome {
            AppLog.info(
                .config,
                "discovery: codex default login present but its identity is unreadable → skipping extra-account candidates this launch"
            )
        }
        return (outcome, scan)
    }
}
