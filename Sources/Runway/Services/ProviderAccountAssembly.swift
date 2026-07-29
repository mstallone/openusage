import Foundation

/// One extra Claude account card to build this launch: a custom-config-dir login found on this
/// computer whose account is distinct from the default card's. Cards render only while their source
/// is found (owner decision 4) — a record with no finding this launch simply builds no card.
struct ClaudeAccountCard: Equatable, Sendable {
    /// The account's stable record id (`claude@ab12cd34`) — the card id everywhere: layout, cache,
    /// CLI/API matching.
    var id: String
    /// The derived card name from `ProviderAccountsStore`, baked into the launch `Provider`. Never
    /// a rename: renames live only in the account registry and are resolved at render time, so a
    /// baked name can never be a stale copy of one.
    var displayName: String
    /// The config dir the card's credentials and spend logs are pinned to.
    var configDirPath: String
    /// The literal string whose hash names the dir's keychain item (see `ClaudeCredentialScope`).
    var keychainLiteral: String
    /// Same-account additional config dirs (rare): extra spend-log roots, never extra credentials.
    var extraLogRoots: [URL] = []
}

/// One Codex account card to build this launch. Unlike the Phase 2 Claude plan, this includes the
/// account occupying the default home: a later login swap can move the default source to an
/// `@`-suffixed record while the original bare-id account remains stable in another home.
struct CodexAccountCard: Equatable, Sendable {
    var id: String
    var displayName: String
    /// The one home whose `auth.json` this card may read and update.
    var credentialHomePath: String
    /// Every home verified to carry this identity, used only for local spend logs.
    var logRoots: [URL]
    /// Pi logs identify the provider family but not its ChatGPT account. Route them only to the
    /// record currently holding the default-home badge; without a badge they remain unattributed.
    var receivesPiUsage = false
}

/// The launch-time account pass: read which account is signed in at each family's default home,
/// scan for extra Claude/Codex logins in custom homes, reconcile the account registry, and expose
/// what the rest of launch consumes — the per-card identity map (snapshot-cache account stamp) and
/// the extra-card build plan (`ProviderCatalog`). Runs once per launch (app) or per invocation
/// (one-shot CLI); a mid-run swap is caught on the next launch.
@MainActor
struct ProviderAccountAssembly {
    /// Card id → the account identity signed in there this launch. A card whose identity didn't
    /// resolve is absent; cards that must reject an old account stamp are tracked separately below.
    let identityKeysByCard: [String: String]
    /// Cards whose current source cannot inherit a previous account's cache stamp. This is distinct
    /// from an unresolved identity: an ambient-token launch rejects an old account-stamped snapshot,
    /// while an unreadable login keeps its last-good cache until its identity can be verified again.
    var cardsRejectingAccountStampedCache: Set<String> = []
    /// Extra Claude account cards found on this computer this launch, in stable id order.
    var claudeCards: [ClaudeAccountCard] = []
    /// The standard Claude runtime's title. A resolved default account uses its derived account
    /// title; an identity-less ambient token gets an explicit source title instead.
    var claudeDefaultDisplayName: String?
    /// Same-account custom config dirs discovered for the DEFAULT card's login: extra spend-log
    /// roots for the default scanner, never extra credentials.
    var defaultClaudeExtraLogRoots: [URL] = []
    /// Codex cards found this launch, including the resolved default-home account when there is one.
    var codexCards: [CodexAccountCard] = []
    /// Shared cache used by scoped keyring stores and the post-launch warming task.
    var codexIdentityCache: CodexHomeIdentityCache?
    /// Same accessor discovery probed; retained so warming reads the exact items from that source.
    var codexIdentityWarmKeychain: (any KeychainAccessing)?
    /// Homes kept hidden because their exact keyring item hasn't been safely identity-bound yet.
    var unverifiedCodexKeyringHomes: Set<String> = []

    /// `waitsForLoginShell`: true for the menu-bar app (a Finder/Dock launch inherits no shell
    /// exports, so the pass leans on the login-shell layers), false for the one-shot CLI (a terminal
    /// launch's process environment already carries the user's exports). The app passes its own
    /// `accountsStore` so the registry the pass reconciles is the same instance the UI observes for
    /// renames; the CLI omits it and gets a throwaway.
    static func make(
        defaults: UserDefaults = .standard,
        accountsStore: ProviderAccountsStore? = nil,
        waitsForLoginShell: Bool
    ) -> ProviderAccountAssembly {
        // The identity read needs the login shell's exports (CLAUDE_CONFIG_DIR/CODEX_HOME name the
        // default homes), and it reads them through the very same reader the provider auth stores
        // use — `ProcessEnvironmentReader`, which pins identity-relevant keys to the persisted
        // shell-environment snapshot for the whole session, so identity and usage resolve the same
        // homes no matter when the async capture lands. The one unreadable state is a genuinely
        // FIRST Finder/Dock launch: capture still cold and no snapshot persisted yet — a
        // shell-exported home override would be invisible, so that family's read must be skipped
        // rather than misread as "no override". The skip is per family: a family whose home override
        // is already visible in the process environment (a terminal launch, `launchctl setenv`)
        // doesn't need the shell layers at all and still resolves.
        let shellFactsReadable = !waitsForLoginShell
            || LoginShellEnvironment.shared.capturedSuccessfully
            || ShellEnvironmentSnapshotStore.launchSnapshot != nil
        let families = shellFactsReadable
            ? ProviderAccountID.families
            : ProviderAccountID.families.filter { family in
                guard let key = Self.homeOverrideKeys[family] else { return false }
                return ProcessInfo.processInfo.environment[key]?.nilIfEmpty != nil
            }
        if families.count < ProviderAccountID.families.count {
            AppLog.info(.config, "account identity read skipped for \(ProviderAccountID.families.subtracting(families).sorted().joined(separator: ", ")): login shell cold and no shell-environment snapshot exists yet")
        }
        guard !families.isEmpty else {
            return ProviderAccountAssembly(identityKeysByCard: [:])
        }
        let codexIdentityCache = CodexHomeIdentityCache(defaults: defaults)
        var assembly = make(
            observer: DefaultAccountObserver(codexIdentityCache: codexIdentityCache),
            accountsStore: accountsStore ?? ProviderAccountsStore(defaults: defaults),
            families: families,
            claudeDiscovery: ClaudeConfigDirDiscovery(),
            codexDiscovery: CodexHomeDiscovery(identityCache: codexIdentityCache)
        )
        assembly.codexIdentityCache = codexIdentityCache
        return assembly
    }

    /// The environment variable that relocates each family's default home — the fact whose
    /// invisibility (shell layers unreadable AND not in the process environment) makes that family's
    /// identity read unsafe on a first launch.
    private static let homeOverrideKeys: [String: String] = [
        "claude": "CLAUDE_CONFIG_DIR",
        "codex": "CODEX_HOME",
    ]

    /// The environment-independent core, separated so tests inject a fixed observer, discovery, and
    /// scratch store. `families` limits the pass to the families whose home facts are readable this
    /// launch (see `make(defaults:waitsForLoginShell:)`); a family left out is simply not observed —
    /// no identity key, no reconciliation, exactly as if the pass never ran for it. `claudeDiscovery`
    /// is skipped alongside the claude family (its exclusion set needs the same home facts).
    static func make(
        observer: DefaultAccountObserver,
        accountsStore: ProviderAccountsStore,
        families: Set<String> = ProviderAccountID.families,
        claudeDiscovery: ClaudeConfigDirDiscovery? = nil,
        codexDiscovery: CodexHomeDiscovery? = nil
    ) -> ProviderAccountAssembly {
        var identityKeys: [String: String] = [:]
        var observations: [ProviderAccountsStore.AccountObservation] = []

        let outcomes: [(family: String, outcome: DefaultAccountObserver.Outcome)] = [
            ("claude", { observer.observeClaude() }),
            ("codex", { observer.observeCodex() }),
        ].compactMap { family, observe in
            families.contains(family) ? (family, observe()) : nil
        }
        for (family, outcome) in outcomes {
            switch outcome {
            case .resolved(let identityKey, let label, let anchor):
                identityKeys[family] = identityKey
                observations.append(ProviderAccountsStore.AccountObservation(
                    family: family,
                    identityKey: identityKey,
                    label: label,
                    sources: [ProviderAccountSource(kind: .defaultHome, anchor: anchor, holdsDefaultSource: true)]
                ))
                AppLog.info(.config, "accounts: \(family) default identity resolved (\(ProviderAccountID.make(family: family, identityKey: identityKey)))")
            case .unresolved(let reason):
                // The soak signal for later phases: how often a real login can't name its account.
                AppLog.info(.config, "accounts: \(family) default identity unresolved — \(reason)")
            case .absent:
                AppLog.debug(.config, "accounts: \(family) has no default login")
            }
        }

        // Extra Claude logins in custom config dirs. Guarded on the default read: when a default
        // login clearly EXISTS but can't be named (`unresolved`), accepting candidates could render
        // the very account the default card shows as a second card — skip them this launch instead.
        // A machine with no default login at all keeps accepting: there is nothing to duplicate,
        // and a custom-dir-only login should still get its card.
        var foundClaudeAccounts: [(identityKey: String, label: String?, dirs: [ClaudeConfigDirDiscovery.Finding])] = []
        var defaultClaudeExtraLogRoots: [URL] = []
        let claudeOutcome = outcomes.first { $0.family == "claude" }?.outcome
        if let claudeDiscovery, let claudeOutcome {
            if case .unresolved = claudeOutcome {
                AppLog.info(.config, "discovery: claude default login present but its identity is unreadable → skipping extra-account candidates this launch")
            } else {
                let defaultKey = identityKeys["claude"]
                let scan = claudeDiscovery.run()
                for note in scan.notes {
                    AppLog.info(.config, "discovery: \(note)")
                }
                var order: [String] = []
                var grouped: [String: [ClaudeConfigDirDiscovery.Finding]] = [:]
                for finding in scan.findings {
                    if grouped[finding.identityKey] == nil { order.append(finding.identityKey) }
                    grouped[finding.identityKey, default: []].append(finding)
                }
                for identityKey in order {
                    let findings = grouped[identityKey] ?? []
                    let sources = findings.map {
                        ProviderAccountSource(
                            kind: .configDir,
                            anchor: $0.anchorPath,
                            holdsDefaultSource: false,
                            keychainLiteral: $0.keychainLiteral
                        )
                    }
                    if identityKey == defaultKey {
                        // Same account as the default card: its dirs are extra spend-log roots on
                        // that card, never a second card — duplicate cards are structurally
                        // impossible because identity routes the source to the existing record.
                        defaultClaudeExtraLogRoots += findings.map { URL(fileURLWithPath: $0.anchorPath) }
                        if let index = observations.firstIndex(where: { $0.family == "claude" && $0.identityKey == identityKey }) {
                            observations[index].sources += sources
                        }
                        AppLog.info(.config, "discovery: \(findings.count) config dir(s) fold onto the default claude card (same account)")
                    } else {
                        observations.append(ProviderAccountsStore.AccountObservation(
                            family: "claude",
                            identityKey: identityKey,
                            label: findings.first?.label,
                            sources: sources
                        ))
                        foundClaudeAccounts.append((identityKey, findings.first?.label, findings))
                    }
                }
            }
        }

        // Codex homes use the same identity routing, but every observed account — including the
        // default-home holder — gets a scoped build plan. That lets a later login swap move the
        // default source to a different stable record without moving either card's id or history.
        var foundCodexAccounts: [
            (identityKey: String, label: String?, credentialHomePath: String, logRoots: [URL])
        ] = []
        var hasScopedCodexDefault = false
        var unverifiedCodexKeyringHomes: Set<String> = []
        let codexOutcome = outcomes.first { $0.family == "codex" }?.outcome
        if let codexDiscovery, let codexOutcome {
            let defaultAnchor: String? = if case .resolved(_, _, let anchor) = codexOutcome {
                anchor
            } else {
                nil
            }
            // Run even when the default identity is unresolved: verified findings remain suppressed,
            // but unverified exact-item homes still need the post-launch warming plan.
            let scan = codexDiscovery.run(
                excluding: Set(defaultAnchor.map { [$0] } ?? [])
            )
            unverifiedCodexKeyringHomes = scan.unverifiedKeyringHomes
            for note in scan.notes {
                AppLog.info(.config, "discovery: \(note)")
            }
            if case .unresolved = codexOutcome {
                AppLog.info(
                    .config,
                    "discovery: codex default login present but its identity is unreadable → skipping extra-account candidates this launch"
                )
            } else {
                let defaultKey = identityKeys["codex"]

                var order: [String] = []
                var grouped: [String: [CodexHomeDiscovery.Finding]] = [:]
                for finding in scan.findings {
                    if grouped[finding.identityKey] == nil { order.append(finding.identityKey) }
                    grouped[finding.identityKey, default: []].append(finding)
                }

                if let defaultKey, let defaultAnchor {
                    let sameAccountHomes = grouped.removeValue(forKey: defaultKey) ?? []
                    order.removeAll { $0 == defaultKey }
                    let sources = sameAccountHomes.map {
                        ProviderAccountSource(
                            kind: .codexHome,
                            anchor: $0.anchorPath,
                            holdsDefaultSource: false
                        )
                    }
                    if let index = observations.firstIndex(where: {
                        $0.family == "codex" && $0.identityKey == defaultKey
                    }) {
                        observations[index].sources += sources
                    }
                    foundCodexAccounts.append((
                        identityKey: defaultKey,
                        label: {
                            guard case .resolved(_, let label, _) = codexOutcome else { return nil }
                            return label
                        }(),
                        credentialHomePath: defaultAnchor,
                        logRoots: [URL(fileURLWithPath: defaultAnchor)]
                            + sameAccountHomes.map { URL(fileURLWithPath: $0.anchorPath) }
                    ))
                    hasScopedCodexDefault = true
                    if !sameAccountHomes.isEmpty {
                        AppLog.info(
                            .config,
                            "discovery: \(sameAccountHomes.count) Codex home(s) fold onto the default account"
                        )
                    }
                }

                for identityKey in order {
                    let findings = grouped[identityKey] ?? []
                    guard let primary = findings.first else { continue }
                    observations.append(ProviderAccountsStore.AccountObservation(
                        family: "codex",
                        identityKey: identityKey,
                        label: primary.label,
                        sources: findings.map {
                            ProviderAccountSource(
                                kind: .codexHome,
                                anchor: $0.anchorPath,
                                holdsDefaultSource: false
                            )
                        }
                    ))
                    foundCodexAccounts.append((
                        identityKey: identityKey,
                        label: primary.label,
                        credentialHomePath: primary.anchorPath,
                        logRoots: findings.map { URL(fileURLWithPath: $0.anchorPath) }
                    ))
                }
            }
        }

        let records = accountsStore.reconcile(with: observations)
        let resolvedClaudeDefaultDisplayName: String?
        if let identityKey = identityKeys["claude"],
           accountsStore.record(backingCardID: "claude")?.identityKey == identityKey
        {
            resolvedClaudeDefaultDisplayName = accountsStore.derivedDisplayName(cardID: "claude")
        } else {
            resolvedClaudeDefaultDisplayName = nil
        }

        // The extra-card build plan: one card per distinct account found this launch, under its
        // reconciled record id.
        var claudeCards: [ClaudeAccountCard] = []
        for account in foundClaudeAccounts {
            guard let record = records.first(where: { $0.family == "claude" && $0.identityKey == account.identityKey }) else {
                continue
            }
            guard record.id != "claude" else {
                // The bare record's account has moved out of the default home into a config dir
                // while another login occupies the default. The bare CARD is the default home's
                // runtime, so this record can't render under its own id this launch. Proper swap
                // support re-points this in Phase 4; until then the parked account stays hidden.
                AppLog.warn(.config, "discovery: the claude record's account now lives in a config dir; its card is unavailable until swap support lands")
                continue
            }
            guard let primary = account.dirs.first else { continue }
            claudeCards.append(ClaudeAccountCard(
                id: record.id,
                displayName: accountsStore.derivedDisplayName(cardID: record.id) ?? record.family.capitalized,
                configDirPath: primary.anchorPath,
                keychainLiteral: primary.keychainLiteral,
                extraLogRoots: account.dirs.dropFirst().map { URL(fileURLWithPath: $0.anchorPath) }
            ))
            identityKeys[record.id] = account.identityKey
            AppLog.info(.config, "accounts: extra claude card \(record.id) from \(account.dirs.count) config dir(s)")
        }
        claudeCards.sort { $0.id < $1.id }

        let claudeDefaultDisplayName: String?
        var cardsRejectingAccountStampedCache: Set<String> = []
        if claudeOutcome == .absent, observer.hasAmbientClaudeToken {
            // The ambient token cannot prove it belongs to the state file's former account. Even
            // when Desktop fallback remains possible, force one refresh rather than serving that
            // account's cached limits under an unverified runtime source.
            cardsRejectingAccountStampedCache.insert("claude")
        }
        if let resolvedClaudeDefaultDisplayName {
            claudeDefaultDisplayName = resolvedClaudeDefaultDisplayName
        } else if claudeOutcome == .absent,
                  observer.hasAmbientClaudeToken,
                  !claudeCards.isEmpty
        {
            // With scoped cards present, Desktop fallback is disabled so an identity-less standard
            // runtime can only represent the ambient token and its default-home logs. Without a
            // scoped sibling, keep the neutral title because a higher-priority Desktop login may
            // actually supply live usage.
            claudeDefaultDisplayName = "Claude — Environment Token"
        } else {
            claudeDefaultDisplayName = nil
        }

        // The provisional default identity was keyed by family before reconciliation. Codex can
        // legitimately put that login on an @-suffixed stable record after a swap, so publish only
        // the actual runtime-card ids assembled below.
        if hasScopedCodexDefault {
            identityKeys.removeValue(forKey: "codex")
        }
        var codexCards: [CodexAccountCard] = []
        for account in foundCodexAccounts {
            guard let record = records.first(where: {
                $0.family == "codex" && $0.identityKey == account.identityKey
            }) else {
                continue
            }
            codexCards.append(CodexAccountCard(
                id: record.id,
                displayName: accountsStore.derivedDisplayName(cardID: record.id) ?? record.family.capitalized,
                credentialHomePath: account.credentialHomePath,
                logRoots: account.logRoots,
                receivesPiUsage: record.sources.contains(where: \.holdsDefaultSource)
            ))
            identityKeys[record.id] = account.identityKey
            AppLog.info(
                .config,
                "accounts: codex card \(record.id) from \(account.logRoots.count) home(s)"
            )
        }
        codexCards.sort { $0.id < $1.id }

        return ProviderAccountAssembly(
            identityKeysByCard: identityKeys,
            cardsRejectingAccountStampedCache: cardsRejectingAccountStampedCache,
            claudeCards: claudeCards,
            claudeDefaultDisplayName: claudeDefaultDisplayName,
            defaultClaudeExtraLogRoots: defaultClaudeExtraLogRoots,
            codexCards: codexCards,
            codexIdentityWarmKeychain: codexDiscovery?.keychain,
            unverifiedCodexKeyringHomes: unverifiedCodexKeyringHomes
        )
    }

    /// An unverified keyring home stays hidden this launch. Read its exact item once, off the launch
    /// path, so a valid provider-owned identity can be fingerprint-bound for the next launch.
    func startCodexIdentityWarmTask() -> Task<Void, Never>? {
        guard let codexIdentityCache,
              let codexIdentityWarmKeychain,
              !unverifiedCodexKeyringHomes.isEmpty
        else {
            return nil
        }
        let homes = unverifiedCodexKeyringHomes.sorted()
        return Task.detached(priority: .utility) {
            for home in homes {
                guard !Task.isCancelled else { return }
                let store = CodexAuthStore(
                    keychain: codexIdentityWarmKeychain,
                    scope: .home(path: home),
                    identityCache: codexIdentityCache
                )
                guard let state = store.loadKeychainAuth(),
                      store.recordSelectedIdentity(state) != nil
                else {
                    AppLog.warn(
                        .keychain,
                        "could not bind one Codex keyring home; its account card remains hidden"
                    )
                    continue
                }
                AppLog.info(
                    .config,
                    "discovery: warmed Codex keyring identity for home \(ProviderAccountID.hash8(home))"
                )
            }
        }
    }
}
