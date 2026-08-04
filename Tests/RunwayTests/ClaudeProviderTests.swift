import XCTest
@testable import Runway

final class ClaudeAuthStoreTests: XCTestCase {
    func testParsesHexEncodedCredentials() {
        let raw = #"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"pro"}}"#
        let hex = raw.utf8.map { String(format: "%02x", $0) }.joined()

        let credentials = ClaudeAuthStore.parseCredentials(hex)

        XCTAssertEqual(credentials?.claudeAiOauth?.accessToken, "token")
        XCTAssertEqual(credentials?.claudeAiOauth?.subscriptionType, "pro")
    }

    func testCredentialDiagnosticsLabelIsTokenFreeWithSourceAndExpiredFlag() {
        // The info-level "refresh start" / fallback diagnostics must name the source kind and whether each
        // candidate is already expired — never any token value.
        let now = Date(timeIntervalSince1970: 1_000_000) // 1_000_000_000 ms

        let fresh = ClaudeCredentialState(
            oauth: ClaudeOAuth(accessToken: "ACCESS_SECRET", refreshToken: "REFRESH_SECRET", expiresAt: 2_000_000_000_000),
            source: .keychainCurrentUser(service: "Claude Code-credentials"),
            inferenceOnly: false
        )
        XCTAssertEqual(fresh.diagnosticsLabel(now: now), "keychainCurrentUser expired=no")
        XCTAssertFalse(fresh.diagnosticsLabel(now: now).contains("SECRET")) // never leaks token values

        // An already-expired access token: Runway never refreshes it, so this explains the renewal notice.
        let lockedOut = ClaudeCredentialState(
            oauth: ClaudeOAuth(accessToken: "a", refreshToken: nil, expiresAt: 1),
            source: .file,
            inferenceOnly: false
        )
        XCTAssertEqual(lockedOut.diagnosticsLabel(now: now), "file expired=yes")

        // Missing expiry is reported as unknown, not assumed fresh.
        let unknownExpiry = ClaudeCredentialState(
            oauth: ClaudeOAuth(accessToken: "a", refreshToken: "", expiresAt: nil),
            source: .keychainLegacy(service: "svc"),
            inferenceOnly: false
        )
        XCTAssertEqual(unknownExpiry.diagnosticsLabel(now: now), "keychainLegacy expired=unknown")
    }

    func testPrefersCurrentUserKeychainCredentialsBeforeFile() {
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"file-token","subscriptionType":"pro"}}"#
        ])
        let keychain = ServiceKeychain()
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: keychain
        )
        let hashedService = store.keychainServiceCandidates().first!
        keychain.currentUserValues[hashedService] = #"{"claudeAiOauth":{"accessToken":"keychain-token","subscriptionType":"max"}}"#

        let credentials = store.loadCredentialCandidates().first

        XCTAssertTrue(hashedService.hasPrefix("Claude Code-credentials-"))
        XCTAssertEqual(credentials?.oauth.accessToken, "keychain-token")
        XCTAssertEqual(credentials?.oauth.subscriptionType, "max")
    }

    func testPrefersKeychainOverFileEvenWhenFileTokenExpiresLater() {
        // #738 regression: the keychain is Claude Code's live source of truth, so it must win even when a
        // stale `~/.claude/.credentials.json` carries a *later* expiry. Ranking purely by expiry (the old
        // #694 behavior) let that stale file outrank the live keychain and starved token refresh. Both
        // candidates stay available so the refresh loop can still fall back keychain → file on auth expiry.
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"file-token","expiresAt":4102444800000,"subscriptionType":"pro"}}"#
        ])
        let keychain = ServiceKeychain()
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: keychain
        )
        let hashedService = store.keychainServiceCandidates().first!
        keychain.currentUserValues[hashedService] = #"{"claudeAiOauth":{"accessToken":"keychain-token","expiresAt":4070908800000,"subscriptionType":"max"}}"#

        let candidates = store.loadCredentialCandidates()

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["keychain-token", "file-token"])
        XCTAssertEqual(store.loadCredentialCandidates().first?.oauth.accessToken, "keychain-token")
    }

    func testPlanBadgeUsesStateFileTierWhenLoginBlobTierIsStale() {
        // The credential blob's rateLimitTier is written at login and never updated on a plan change,
        // so after an upgrade (Max 5x → 20x) it keeps saying 5x. Claude Code's state file profile is
        // refetched regularly and carries the current tier — the badge must trust it.
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"file-token","subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}"#,
            "/tmp/claude/.claude.json": #"{"oauthAccount":{"accountUuid":"a","organizationRateLimitTier":"default_claude_max_20x"}}"#
        ])
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: FakeKeychain()
        )

        let state = store.loadCredentialCandidates().first

        XCTAssertEqual(state?.displayOAuth.rateLimitTier, "default_claude_max_20x")
        // The blob itself stays untouched so a token rotation can never persist the override.
        XCTAssertEqual(state?.oauth.rateLimitTier, "default_claude_max_5x")
        XCTAssertEqual(
            ClaudeUsageMapper.formatPlan(
                subscriptionType: state?.displayOAuth.subscriptionType,
                rateLimitTier: state?.displayOAuth.rateLimitTier
            ),
            "Max 20x"
        )
    }

    func testPlanBadgeFollowsFamilyChangeFromStateFileOrganizationType() {
        // Upgrading Pro → Max without a re-login: the blob still says "pro", but the state file's
        // plan-shaped organizationType carries the current family, so the badge must read "Max 20x" —
        // never the contradictory "Pro 20x".
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"file-token","subscriptionType":"pro"}}"#,
            "/tmp/claude/.claude.json": #"{"oauthAccount":{"accountUuid":"a","organizationType":"claude_max","organizationRateLimitTier":"default_claude_max_20x"}}"#
        ])
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: FakeKeychain()
        )

        let state = store.loadCredentialCandidates().first

        XCTAssertEqual(
            ClaudeUsageMapper.formatPlan(
                subscriptionType: state?.displayOAuth.subscriptionType,
                rateLimitTier: state?.displayOAuth.rateLimitTier
            ),
            "Max 20x"
        )
    }

    func testPlanBadgeDropsStaleTierWhenProfileFamilyChangesWithoutOne() {
        // Max 20x → Pro downgrade: the profile names the new family but no tier (Pro has no
        // multiplier). The profile applies as one snapshot — the blob's old "20x" must not survive
        // next to the new family as a contradictory "Pro 20x".
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"file-token","subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}"#,
            "/tmp/claude/.claude.json": #"{"oauthAccount":{"accountUuid":"a","organizationType":"claude_pro"}}"#
        ])
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: FakeKeychain()
        )

        let state = store.loadCredentialCandidates().first

        XCTAssertEqual(
            ClaudeUsageMapper.formatPlan(
                subscriptionType: state?.displayOAuth.subscriptionType,
                rateLimitTier: state?.displayOAuth.rateLimitTier
            ),
            "Pro"
        )
    }

    func testPlanBadgeKeepsBlobValuesWhenStateFileIsMalformed() {
        // A corrupt state file must not break credential loading or the badge — the login-time
        // values stand (and the failure is logged rather than silently swallowed).
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"file-token","subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}"#,
            "/tmp/claude/.claude.json": "not json {"
        ])
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: FakeKeychain()
        )

        let state = store.loadCredentialCandidates().first

        XCTAssertEqual(state?.oauth.accessToken, "file-token")
        XCTAssertEqual(state?.displayOAuth.rateLimitTier, "default_claude_max_5x")
        XCTAssertEqual(state?.displayOAuth.subscriptionType, "max")
    }

    func testPlanBadgeKeepsBlobFamilyForUnrecognizedOrganizationType() {
        // A Team seat can ride a `claude_max_*` rate-limit bucket while its organizationType isn't
        // plan-shaped. The blob's subscriptionType must stand — "Team 5x", never "Max 5x".
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"file-token","subscriptionType":"team","rateLimitTier":"default_claude_max_5x"}}"#,
            "/tmp/claude/.claude.json": #"{"oauthAccount":{"accountUuid":"a","organizationType":"team_org","organizationRateLimitTier":"default_claude_max_5x"}}"#
        ])
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: FakeKeychain()
        )

        let state = store.loadCredentialCandidates().first

        XCTAssertNil(state?.profileSubscriptionType)
        XCTAssertEqual(
            ClaudeUsageMapper.formatPlan(
                subscriptionType: state?.displayOAuth.subscriptionType,
                rateLimitTier: state?.displayOAuth.rateLimitTier
            ),
            "Team 5x"
        )
    }

    func testProfilePlanAppliesOnlyToTheHighestPriorityCandidate() {
        // Keychain and file can hold DIFFERENT accounts (the refresh fall-through exists for exactly
        // that case), while the state file describes only the login Claude Code last wrote — the
        // highest-priority source. A fallback candidate served after the first fails auth must show
        // its own blob plan, never the other account's profile plan.
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"file-token","subscriptionType":"pro"}}"#,
            "/tmp/claude/.claude.json": #"{"oauthAccount":{"accountUuid":"a","organizationType":"claude_max","organizationRateLimitTier":"default_claude_max_20x"}}"#
        ])
        let keychain = ServiceKeychain()
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: keychain
        )
        let service = store.keychainServiceCandidates().first!
        keychain.currentUserValues[service] = #"{"claudeAiOauth":{"accessToken":"keychain-token","subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}"#

        let candidates = store.loadCredentialCandidates()

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["keychain-token", "file-token"])
        XCTAssertEqual(candidates.first?.displayOAuth.rateLimitTier, "default_claude_max_20x")
        XCTAssertNil(candidates.last?.profileSubscriptionType)
        XCTAssertNil(candidates.last?.profileRateLimitTier)
        XCTAssertEqual(candidates.last?.displayOAuth.subscriptionType, "pro")
    }

    func testPlanBadgeUserTierOutranksOrganizationTier() {
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"file-token","subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}"#,
            "/tmp/claude/.claude.json": #"{"oauthAccount":{"accountUuid":"a","organizationRateLimitTier":"default_claude_max_20x","userRateLimitTier":"custom_claude_max_5x"}}"#
        ])
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: FakeKeychain()
        )

        XCTAssertEqual(
            store.loadCredentialCandidates().first?.displayOAuth.rateLimitTier,
            "custom_claude_max_5x"
        )
    }

    func testPlanBadgeKeepsBlobTierWithoutStateFileTier() {
        // No state file (or one that names no tier) must not blank the badge — the blob tier stands.
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"file-token","subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}"#
        ])
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: FakeKeychain()
        )

        XCTAssertEqual(
            store.loadCredentialCandidates().first?.displayOAuth.rateLimitTier,
            "default_claude_max_5x"
        )
    }

    func testConfigDirScopeReadsStateFileInsideItsOwnDir() {
        // A `.configDir` card keeps its state INSIDE the dir (only the default home keeps it next
        // door at `~/.claude.json`), and must never borrow the default account's tier.
        let files = FakeFiles([
            "/Users/dev/.claude-personal/.credentials.json": #"{"claudeAiOauth":{"accessToken":"file-token","subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}"#,
            "/Users/dev/.claude-personal/.claude.json": #"{"oauthAccount":{"accountUuid":"a","organizationRateLimitTier":"default_claude_max_20x"}}"#
        ])
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(),
            files: files,
            keychain: FakeKeychain(),
            scope: .configDir(path: "/Users/dev/.claude-personal", keychainLiteral: "/Users/dev/.claude-personal")
        )

        XCTAssertEqual(
            store.loadCredentialCandidates().first?.displayOAuth.rateLimitTier,
            "default_claude_max_20x"
        )
    }

    func testMalformedReadableKeychainItemDoesNotCountAsCredentialFootprint() {
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(),
            files: FakeFiles(),
            keychain: FakeKeychain(#"{"claudeAiOauth":{"accessToken":"   "}}"#)
        )

        XCTAssertFalse(store.hasCredentialFootprint())
    }

    func testEnvironmentTokenIsInferenceOnly() {
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "env-token"]),
            files: FakeFiles(),
            keychain: FakeKeychain()
        )

        let credentials = store.loadCredentialCandidates().first

        XCTAssertEqual(credentials?.oauth.accessToken, "env-token")
        XCTAssertEqual(store.liveUsageAvailability(credentials!), .inferenceOnlyToken)
    }

    func testEnvTokenDoesNotShadowProfileScopedStoredLogin() {
        // An inference-only CLAUDE_CODE_OAUTH_TOKEN (often just ambiently exported and captured from the
        // login shell) must not shadow a real stored login that CAN read usage. The profile-scoped login
        // is preferred for the live usage call; the env token trails as an inference-only fallback.
        let keychain = ServiceKeychain()
        keychain.currentUserValues["Claude Code-credentials"] =
            #"{"claudeAiOauth":{"accessToken":"keychain-token","subscriptionType":"max","scopes":["user:inference","user:profile"]}}"#
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "env-token"]),
            files: FakeFiles(),
            keychain: keychain
        )

        let candidates = store.loadCredentialCandidates()

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["keychain-token", "env-token"])
        // The keychain login (first) can fetch live usage; the env token is the inference-only fallback.
        XCTAssertEqual(store.liveUsageAvailability(candidates[0]), .available)
        XCTAssertFalse(candidates[0].inferenceOnly)
        XCTAssertEqual(store.liveUsageAvailability(candidates[1]), .inferenceOnlyToken)
    }

    func testEnvTokenIsSoleCandidateWhenStoredLoginCannotReadUsage() {
        // A stored login that itself lacks user:profile can't read usage either, so it is not preferred
        // over the env token; the env token stays the sole inference-only candidate (spend tiles still
        // load) — the headless/no-usable-login behavior is unchanged.
        let keychain = ServiceKeychain()
        keychain.currentUserValues["Claude Code-credentials"] =
            #"{"claudeAiOauth":{"accessToken":"inference-login","subscriptionType":"max","scopes":["user:inference"]}}"#
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "env-token"]),
            files: FakeFiles(),
            keychain: keychain
        )

        let candidates = store.loadCredentialCandidates()

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["env-token"])
        XCTAssertEqual(store.liveUsageAvailability(candidates[0]), .inferenceOnlyToken)
    }

    func testEnvFallbackBorrowsMetadataFromThePreferredLiveCapableLogin() {
        // When the first stored login is NOT live-capable but a later one is (an inference-only keychain
        // login plus a profile-scoped file login), the env fallback should inherit its display metadata
        // from the credential actually preferred (the file login), not from the keychain login we skipped.
        let files = FakeFiles([
            "/tmp/claude/.credentials.json":
                #"{"claudeAiOauth":{"accessToken":"file-token","subscriptionType":"max","scopes":["user:inference","user:profile"]}}"#
        ])
        let keychain = ServiceKeychain()
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude", "CLAUDE_CODE_OAUTH_TOKEN": "env-token"]),
            files: files,
            keychain: keychain
        )
        keychain.currentUserValues[store.keychainServiceCandidates().first!] =
            #"{"claudeAiOauth":{"accessToken":"keychain-token","subscriptionType":"pro","scopes":["user:inference"]}}"#

        let candidates = store.loadCredentialCandidates()

        // Keychain login (no user:profile) is dropped from the usage-capable set; the file login is
        // preferred and the env token trails.
        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["file-token", "env-token"])
        // The env fallback borrows the preferred (file) login's plan, not the skipped keychain login's.
        XCTAssertEqual(candidates[1].oauth.subscriptionType, "max")
    }

    func testLiveUsageAvailabilityReflectsProfileScope() {
        let store = ClaudeAuthStore(environment: FakeEnvironment(), files: FakeFiles(), keychain: FakeKeychain())
        func state(_ scopes: [String]?, inferenceOnly: Bool = false) -> ClaudeCredentialState {
            ClaudeCredentialState(
                oauth: ClaudeOAuth(accessToken: "token", scopes: scopes),
                source: .keychainCurrentUser(service: "Claude Code-credentials"),
                    inferenceOnly: inferenceOnly
            )
        }

        // Older credentials predate the scopes field; an absent/empty list is "unknown, allow".
        XCTAssertEqual(store.liveUsageAvailability(state(nil)), .available)
        XCTAssertEqual(store.liveUsageAvailability(state([])), .available)
        XCTAssertEqual(store.liveUsageAvailability(state(["user:inference", "user:profile"])), .available)
        // An inference-only token (e.g. from `claude setup-token`) lacks user:profile → can't read usage.
        XCTAssertEqual(store.liveUsageAvailability(state(["user:inference"])), .missingProfileScope)
        // An explicit env token is inference-only by design: silent, not a missing-scope notice.
        XCTAssertEqual(store.liveUsageAvailability(state(["user:inference"], inferenceOnly: true)), .inferenceOnlyToken)
    }

    func testMalformedCustomOAuthURLThrowsInsteadOfCrashing() {
        // A malformed custom OAuth URL is system-boundary input: usageEndpoint() must fail loudly
        // rather than force-unwrap a nil URL (which crashes) or silently fall back to prod.
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_CUSTOM_OAUTH_URL": "http://exa mple.com"]),
            files: FakeFiles(),
            keychain: FakeKeychain()
        )

        XCTAssertThrowsError(try store.usageEndpoint()) { error in
            guard case ClaudeAuthError.invalidOAuthURL = error else {
                return XCTFail("expected ClaudeAuthError.invalidOAuthURL, got \(error)")
            }
        }

        // The forgiving credential-load path only needs the file suffix, so a malformed URL must not
        // break keychain candidate resolution.
        XCTAssertEqual(store.keychainServiceCandidates(), ["Claude Code-custom-oauth-credentials"])
    }
}

final class ClaudeUsageMapperTests: XCTestCase {
    func testMapsUsageWindowsExtraUsageAndPlan() throws {
        let response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data("""
            {
              "five_hour": { "utilization": 10, "resets_at": "2099-01-01T00:00:00.000Z" },
              "seven_day": { "utilization": 20, "resets_at": "2099-01-01T00:00:00.000Z" },
              "seven_day_sonnet": { "utilization": 5, "resets_at": "2099-01-01T00:00:00.000Z" },
              "extra_usage": { "is_enabled": true, "used_credits": 500, "monthly_limit": 1000 }
            }
            """.utf8)
        )

        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            response,
            credentials: ClaudeOAuth(subscriptionType: "max", rateLimitTier: "claude_max_subscription_20x")
        )

        XCTAssertEqual(mapped.plan, "Max 20x")
        XCTAssertEqual(progress(mapped.lines, "Session")?.used, 10)
        XCTAssertEqual(progress(mapped.lines, "Weekly")?.periodDurationMs, ClaudeUsageMapper.weeklyPeriodMs)
        XCTAssertEqual(progress(mapped.lines, "Sonnet")?.used, 5)
        XCTAssertEqual(progress(mapped.lines, "Extra usage spent")?.used, 5)
        XCTAssertEqual(progress(mapped.lines, "Extra usage spent")?.limit, 10)
    }

    func testMapsFableScopedWeeklyLimitFromLimitsArray() throws {
        // Anthropic moved per-model weekly windows into `limits[]` as `weekly_scoped` rows keyed by
        // `scope.model.display_name`; the legacy `seven_day_<model>` top-level keys now come back null.
        let response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data("""
            {
              "five_hour": { "utilization": 10, "resets_at": "2099-01-01T00:00:00.000Z" },
              "seven_day": { "utilization": 20, "resets_at": "2099-01-01T00:00:00.000Z" },
              "seven_day_sonnet": null,
              "limits": [
                { "kind": "session", "group": "session", "percent": 10, "resets_at": "2099-01-01T00:00:00.000Z" },
                { "kind": "weekly_all", "group": "weekly", "percent": 20, "resets_at": "2099-01-08T00:00:00.000Z" },
                { "kind": "weekly_scoped", "group": "weekly", "percent": 7,
                  "resets_at": "2099-01-08T00:00:00.000Z",
                  "scope": { "model": { "display_name": "Fable", "id": null }, "surface": null } }
              ]
            }
            """.utf8)
        )

        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            response,
            credentials: ClaudeOAuth(subscriptionType: "max")
        )

        XCTAssertEqual(progress(mapped.lines, "Fable")?.used, 7)
        XCTAssertEqual(progress(mapped.lines, "Fable")?.limit, 100)
        XCTAssertEqual(progress(mapped.lines, "Fable")?.periodDurationMs, ClaudeUsageMapper.weeklyPeriodMs)
    }

    func testUncappedExtraUsageIsAnUnboundedValuesRow() throws {
        // No `monthly_limit`: the spend has no cap, so it's an unbounded `.values` row (which formats
        // through `MetricFormatter`, matching the spend tiles) rather than a baked full-currency `.text`.
        let response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"extra_usage":{"is_enabled":true,"used_credits":123456}}"#.utf8)
        )

        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            response,
            credentials: ClaudeOAuth(subscriptionType: "max")
        )

        guard case .values(_, let values, _, _, _, _)? = mapped.lines.first(where: { $0.label == "Extra usage spent" }) else {
            return XCTFail("Expected an Extra usage spent .values line")
        }
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.kind, .dollars)
        XCTAssertEqual(try XCTUnwrap(values.first?.number), 1234.56, accuracy: 0.0001)
        XCTAssertNil(progress(mapped.lines, "Extra usage spent"))
    }

    func testMapsResetsAtFromMicrosecondTimestampWithoutTimezone() throws {
        let response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"five_hour":{"utilization":0,"resets_at":"2099-06-01T12:00:00.123456"}}"#.utf8)
        )

        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            response,
            credentials: ClaudeOAuth(subscriptionType: "pro")
        )

        let resetsAt = try XCTUnwrap(progress(mapped.lines, "Session")?.resetsAt)
        XCTAssertEqual(RunwayISO8601.string(from: resetsAt), "2099-06-01T12:00:00.123Z")
    }

    func testMapsResetsAtFromUnixEpochNumber() throws {
        let epochSeconds = 2_099_010_100.0
        let response = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"five_hour":{"utilization":0,"resets_at":2099010100}}"#.utf8)
        )

        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            response,
            credentials: ClaudeOAuth(subscriptionType: "pro")
        )

        let resetsAt = try XCTUnwrap(progress(mapped.lines, "Session")?.resetsAt)
        XCTAssertEqual(resetsAt.timeIntervalSince1970, epochSeconds, accuracy: 1)
    }

    func testPlanFamilyIsNeverInferredFromTheTierString() {
        // Rate-limit buckets don't have to track the subscription family: a Team seat can ride a
        // `claude_max_*` bucket, and must stay "Team 5x", never "Max 5x". Family freshness comes from
        // the state file's explicit `organizationType`, not from parsing the tier.
        XCTAssertEqual(
            ClaudeUsageMapper.formatPlan(subscriptionType: "team", rateLimitTier: "default_claude_max_5x"),
            "Team 5x"
        )
        XCTAssertEqual(ClaudeUsageMapper.formatPlan(subscriptionType: "pro", rateLimitTier: nil), "Pro")
    }

    func testRateLimitRetryAfterBadge() {
        let mapped = ClaudeUsageMapper.rateLimitedUsage(
            credentials: ClaudeOAuth(subscriptionType: "pro"),
            retryAfterSeconds: 600
        )

        XCTAssertEqual(mapped.plan, "Pro")
        XCTAssertEqual(badge(mapped.lines, "Status"), "Rate limited, retry in ~10m")
        XCTAssertEqual(text(mapped.lines, "Note"), "Live usage rate limited - retry in ~10m")
    }

    func testRateLimitedWarningTellsTheHeaderNotToOfferARefresh() {
        // The header triangle is a refresh button, and this warning's own text is "manual refreshes
        // will make it worse" — so the snapshot carrying it must mark itself `.wait`, or the app
        // would offer the exact action the tooltip warns against.
        let mapped = ClaudeUsageMapper.rateLimitedUsage(
            credentials: ClaudeOAuth(subscriptionType: "pro"),
            retryAfterSeconds: 600
        )

        XCTAssertEqual(
            mapped.warning,
            "Updates blocked by Anthropic. Be patient — manual refreshes will make it worse. Retrying in ~10m."
        )
        XCTAssertEqual(mapped.warningAction, .wait)
        // The scope notice is the opposite case: the user re-logs in, then refreshes to pick it up.
        XCTAssertEqual(ClaudeMappedUsage(lines: []).warningAction, .refresh)
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, resetsAt, periodDurationMs)
    }

    private func badge(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .badge(_, let text, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return text
    }

    private func text(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .text(_, let value, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return value
    }
}

@MainActor
final class ClaudeProviderTests: XCTestCase {
    func testLaunchDetectionAndAutomaticRefreshNeverReadKeychainInteractively() async {
        let keychain = InteractionTrackingKeychain()
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(),
                files: FakeFiles(),
                keychain: keychain
            ),
            usageClient: ClaudeUsageClient(httpClient: FakeHTTPClient(
                response: HTTPResponse(statusCode: 200, headers: [:], body: Data())
            )),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            pricing: { TestPricing.bundled }
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected, "attributes-only detection should see the login")
        let snapshot = await provider.refresh()

        XCTAssertEqual(
            badge(snapshot.lines, "Error"),
            ClaudeAuthError.codePermissionRequired.localizedDescription
        )
        XCTAssertEqual(keychain.interactiveReadCount, 0)
        XCTAssertGreaterThan(keychain.nonInteractiveReadCount, 0)
    }

    func testManualRefreshUsesRunwayInteractiveReadInsteadOfSecurityHelper() async {
        let keychain = InteractionTrackingKeychain(
            approvedValue: #"""
            {"claudeAiOauth":{"accessToken":"keychain-token","subscriptionType":"pro","scopes":["user:profile"]}}
            """#
        )
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(),
                files: FakeFiles(),
                keychain: keychain
            ),
            usageClient: ClaudeUsageClient(httpClient: FakeHTTPClient(
                response: HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            )),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            pricing: { TestPricing.bundled }
        )

        let snapshot = await ProviderRefreshContext.$isManual.withValue(true) {
            await provider.refresh()
        }

        XCTAssertNil(badge(snapshot.lines, "Error"))
        XCTAssertGreaterThan(keychain.runwayInteractiveReadCount, 0)
        XCTAssertEqual(
            keychain.interactiveReadCount,
            0,
            "manual approval must not be delegated to /usr/bin/security"
        )
    }

    func testAutomaticRefreshDoesNotMaskUnreadableKeychainWithFileFallback() async {
        let keychain = InteractionTrackingKeychain()
        let httpClient = FakeHTTPClient(response: HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
        ))
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(),
                files: FakeFiles([
                    "~/.claude/.credentials.json":
                        #"""
                        {"claudeAiOauth":{"accessToken":"file-token","subscriptionType":"pro","scopes":["user:profile"]}}
                        """#
                ]),
                keychain: keychain
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(
            badge(snapshot.lines, "Error"),
            ClaudeAuthError.codePermissionRequired.localizedDescription
        )
        XCTAssertEqual(keychain.interactiveReadCount, 0)
        XCTAssertGreaterThan(keychain.nonInteractiveReadCount, 0)
        XCTAssertTrue(httpClient.requests.isEmpty)
    }

    func testAutomaticRefreshBlocksFallbackWhenKeychainExistenceIsUnknown() async {
        let keychain = InteractionTrackingKeychain(existence: nil)
        let httpClient = FakeHTTPClient(response: HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
        ))
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(),
                files: FakeFiles([
                    "~/.claude/.credentials.json":
                        #"""
                        {"claudeAiOauth":{"accessToken":"file-token","subscriptionType":"pro","scopes":["user:profile"]}}
                        """#
                ]),
                keychain: keychain
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(
            badge(snapshot.lines, "Error"),
            ClaudeAuthError.codeCredentialsUnavailable.localizedDescription
        )
        XCTAssertEqual(keychain.interactiveReadCount, 0)
        XCTAssertGreaterThan(keychain.nonInteractiveReadCount, 0)
        XCTAssertTrue(httpClient.requests.isEmpty)
    }

    func testScopedAccountAutomaticRefreshReportsPermissionRequiredWithoutFileFallback() async {
        // An extra `CLAUDE_CONFIG_DIR` account follows the same policy as the default card: a
        // protected scoped keychain item makes an automatic refresh fail fast as Permission
        // Required — never an interactive read, and never a fallback to the config dir's
        // possibly-stale credentials file.
        let keychain = InteractionTrackingKeychain()
        let httpClient = FakeHTTPClient(response: HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
        ))
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(),
                files: FakeFiles([
                    "/Users/dev/.claude-personal/.credentials.json":
                        #"""
                        {"claudeAiOauth":{"accessToken":"stale-file-token","subscriptionType":"pro","scopes":["user:profile"]}}
                        """#
                ]),
                keychain: keychain,
                scope: .configDir(path: "/Users/dev/.claude-personal", keychainLiteral: "~/.claude-personal")
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            pricing: { TestPricing.bundled }
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected, "scoped detection should see the login without keychain interaction")
        let snapshot = await provider.refresh()

        XCTAssertEqual(
            badge(snapshot.lines, "Error"),
            ClaudeAuthError.codePermissionRequired.localizedDescription
        )
        XCTAssertEqual(keychain.interactiveReadCount, 0)
        XCTAssertEqual(keychain.runwayInteractiveReadCount, 0)
        XCTAssertGreaterThan(keychain.nonInteractiveReadCount, 0)
        XCTAssertTrue(
            httpClient.requests.isEmpty,
            "a protected scoped keychain item must not fall back to the config dir's credentials file"
        )
    }

    func testScopedAccountManualRefreshUsesRunwayInteractiveRead() async {
        let keychain = InteractionTrackingKeychain(
            approvedValue: #"""
            {"claudeAiOauth":{"accessToken":"scoped-keychain-token","subscriptionType":"pro","scopes":["user:profile"]}}
            """#
        )
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(),
                files: FakeFiles(),
                keychain: keychain,
                scope: .configDir(path: "/Users/dev/.claude-personal", keychainLiteral: "~/.claude-personal")
            ),
            usageClient: ClaudeUsageClient(httpClient: FakeHTTPClient(
                response: HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            )),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            pricing: { TestPricing.bundled }
        )

        let snapshot = await ProviderRefreshContext.$isManual.withValue(true) {
            await provider.refresh()
        }

        XCTAssertNil(badge(snapshot.lines, "Error"))
        XCTAssertGreaterThan(keychain.runwayInteractiveReadCount, 0)
        XCTAssertEqual(
            keychain.interactiveReadCount,
            0,
            "scoped manual approval must not be delegated to /usr/bin/security"
        )
    }

    func testExpiredKeychainTokenNeverRefreshesOrWritesAndDegradesToRenewalNotice() async {
        // Regression for the 2026-08-03 incident: Runway rotating Claude Code's refresh token (and
        // writing it back to Claude's Keychain item) can strand a concurrently running Claude process
        // and trip OAuth reuse detection. Runway is a read-only consumer: an expired token means NO
        // token-endpoint call, NO credential write, and a renewal notice over the local spend tiles.
        let keychain = WriteTrackingKeychain(
            value: #"""
            {"claudeAiOauth":{"accessToken":"stale-token","refreshToken":"refresh-1","expiresAt":1,"subscriptionType":"pro","scopes":["user:profile"]}}
            """#
        )
        let httpClient = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data()))
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(),
                files: FakeFiles(),
                keychain: keychain
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        // The expired stamp short-circuits before any network call: no usage call, and above all no
        // POST to any /oauth/token endpoint.
        XCTAssertTrue(httpClient.requests.isEmpty)
        XCTAssertEqual(keychain.writeCount, 0, "Claude's credential stores are never written by Runway")
        XCTAssertNil(badge(snapshot.lines, "Error"))
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertEqual(snapshot.warning, ClaudeAuthError.loginRenewalRequired.localizedDescription)
        XCTAssertEqual(snapshot.plan, "Pro")
    }

    func testRefreshFetchesLiveUsageAndScansConfigDirLogs() async throws {
        let now = RunwayISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let httpClient = FakeHTTPClient(response: HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
        ))
        // The spend tiles come from the scanner reading `CLAUDE_CONFIG_DIR/projects/**/*.jsonl` —
        // the fixture line carries costUSD so the tile is a carried (not computed) dollar figure.
        let home = try ClaudeLogFixture.makeHome(files: [
            "project-a/session.jsonl": ClaudeLogFixture.usageLine(
                timestamp: "2026-02-20T16:00:00.000Z", input: 100, output: 50, costUSD: 0.25
            )
        ])
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: FakeFiles([
                    "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"pro","scopes":["user:profile"]}}"#
                ]),
                keychain: FakeKeychain(),
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: home),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertNotNil(snapshot.lines.first(where: { $0.label == "Session" }))
        XCTAssertEqual(values(snapshot.lines, "Today"),
                       [MetricValue(number: 0.25, kind: .dollars, estimated: true),
                        MetricValue(number: 150, kind: .count, label: "tokens")])
        XCTAssertTrue(httpClient.requests.contains { $0.url.absoluteString == "https://api.anthropic.com/api/oauth/usage" })
    }

    func testInferenceOnlyScopeSurfacesReloginWarningAndSkipsUsageCallButKeepsSpendTiles() async throws {
        // A credential that authenticates for inference but lacks the `user:profile` scope (e.g. a
        // `claude setup-token` token) can't read the usage endpoint. The provider must NOT silently leave
        // Session/Weekly blank: it surfaces a soft provider warning (the header's amber triangle, like
        // Z.ai's "no coding plan" notice) telling the user to re-login, skips the usage HTTP call, and
        // still loads the local log-scanned spend tiles.
        let now = RunwayISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let httpClient = FakeHTTPClient(response: HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
        ))
        let home = try ClaudeLogFixture.makeHome(files: [
            "project-a/session.jsonl": ClaudeLogFixture.usageLine(
                timestamp: "2026-02-20T16:00:00.000Z", input: 100, output: 50, costUSD: 0.25
            )
        ])
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: FakeFiles([
                    "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"max","rateLimitTier":"default_claude_max_5x","scopes":["user:inference"]}}"#
                ]),
                keychain: FakeKeychain(),
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: home),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        // A soft provider warning explains the missing scope — not a hard error badge, and the live-usage
        // meters stay blank (no "Session" line) rather than silently loading nothing.
        XCTAssertEqual(snapshot.warning, ClaudeUsageMapper.missingProfileScopeWarning)
        XCTAssertNil(badge(snapshot.lines, "Error"))
        XCTAssertNil(snapshot.line(label: "Session"))
        // The usage endpoint was never called — that's the whole point of the scope gate.
        XCTAssertFalse(httpClient.requests.contains { $0.url.absoluteString.hasSuffix("/api/oauth/usage") })
        // Local spend tiles are unaffected and still load.
        XCTAssertNotNil(values(snapshot.lines, "Today"))
        XCTAssertEqual(snapshot.plan, "Max 5x")
    }

    func testLiveClaudeUsageReportsResetFields() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUNWAY_LIVE_CLAUDE"] == "1")

        let store = ClaudeAuthStore()
        guard let state = store.loadCredentialCandidates().first else {
            throw XCTSkip("No Claude credentials on this machine")
        }

        let response = try await ClaudeUsageClient().fetchUsage(
            accessToken: state.oauth.accessToken ?? "",
            usageURL: store.usageEndpoint()
        )
        XCTAssertTrue((200..<300).contains(response.statusCode))
        let resetHeaders = response.headers.filter { $0.key.localizedCaseInsensitiveContains("reset") }
        print("LIVE response reset headers:", resetHeaders)

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        for key in ["five_hour", "seven_day", "seven_day_sonnet"] {
            guard let window = body[key] as? [String: Any] else { continue }
            print("LIVE \(key)=", window)
        }

        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            response,
            credentials: state.oauth
        )
        for label in ["Session", "Weekly", "Sonnet"] {
            let resetsAt = Self.progress(mapped.lines, label)?.resetsAt
            print("LIVE mapped \(label) resetsAt=", resetsAt as Any)
        }
    }

    func testUsage401NeverRetriesWithARefreshAndNeverWritesTheCredentialsFile() async {
        // A 401 on the usage endpoint means the token lapsed server-side. Runway must not try to
        // refresh it (Claude Code owns rotation) and must not touch `.credentials.json`: one usage
        // call, then the renewal notice.
        let now = RunwayISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let originalBlob = #"{"claudeAiOauth":{"accessToken":"stale-token","refreshToken":"refresh-1","expiresAt":4102444800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        let files = FakeFiles(["/tmp/claude/.credentials.json": originalBlob])
        let httpClient = RoutingHTTPClient { request in
            XCTAssertTrue(request.url.absoluteString.hasSuffix("/api/oauth/usage"))
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: files,
                keychain: FakeKeychain(),
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(httpClient.requests.count, 1)
        XCTAssertEqual(files.files["/tmp/claude/.credentials.json"], originalBlob)
        XCTAssertNil(badge(snapshot.lines, "Error"))
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertEqual(snapshot.warning, ClaudeAuthError.loginRenewalRequired.localizedDescription)
    }

    func testFallsBackToFileWhenKeychainTokenIsLockedOut() async {
        // #687: a stale/locked-out token sits in the keychain (the usage endpoint rejects it) while a
        // fresh external `claude` re-login wrote a working token to the file. The refresh must fall
        // through to the file source and recover instead of surfacing the stale keychain error until
        // the app is restarted.
        let now = RunwayISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"fresh-access","refreshToken":"fresh-refresh","expiresAt":4070908800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let keychain = ServiceKeychain()
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: keychain,
            now: { now }
        )
        // The keychain is always probed first (it's the source of truth), so this exercises the
        // auth-failure fallback: the stale keychain token is rejected server-side, and recovery comes
        // from falling through to the fresh file token — not from any expiry-based reordering.
        let hashedService = authStore.keychainServiceCandidates().first!
        keychain.currentUserValues[hashedService] = #"{"claudeAiOauth":{"accessToken":"stale-access","refreshToken":"stale-refresh","expiresAt":4102444800000,"subscriptionType":"max","scopes":["user:profile"]}}"#

        let httpClient = RoutingHTTPClient { request in
            XCTAssertTrue(request.url.absoluteString.hasSuffix("/api/oauth/usage"))
            let authorization = request.headers["Authorization"] ?? ""
            guard authorization.contains("fresh-access") else {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"five_hour":{"utilization":42,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
            )
        }
        let provider = ClaudeProvider(
            authStore: authStore,
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        // Recovered from the file source: plan + usage reflect the fresh token, with no error badge.
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(Self.progress(snapshot.lines, "Session")?.used, 42)
        XCTAssertNil(badge(snapshot.lines, "Error"))
    }

    func testAllSourcesExpiredServesLocalSpendTilesUnderARenewalNotice() async throws {
        // When every stored login is rejected server-side there is nothing left to try live — but the
        // local spend tiles are computed from Claude's own session logs and stay trustworthy. The card
        // must degrade to those tiles under the renewal notice (amber triangle), not a hard error.
        let now = RunwayISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let home = try ClaudeLogFixture.makeHome(files: [
            "project-a/session.jsonl": ClaudeLogFixture.usageLine(
                timestamp: "2026-02-20T16:00:00.000Z", input: 100, output: 50, costUSD: 0.25
            )
        ])
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"file-stale","refreshToken":"file-refresh","expiresAt":4070908800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let keychain = ServiceKeychain()
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: keychain,
            now: { now }
        )
        let hashedService = authStore.keychainServiceCandidates().first!
        keychain.currentUserValues[hashedService] = #"{"claudeAiOauth":{"accessToken":"keychain-stale","refreshToken":"keychain-refresh","expiresAt":4102444800000,"subscriptionType":"max","scopes":["user:profile"]}}"#

        // Every usage call 401s → both sources are dead; no other endpoint is ever contacted.
        let httpClient = RoutingHTTPClient { request in
            XCTAssertTrue(request.url.absoluteString.hasSuffix("/api/oauth/usage"))
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let provider = ClaudeProvider(
            authStore: authStore,
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: home),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(badge(snapshot.lines, "Error"))
        XCTAssertEqual(snapshot.warning, ClaudeAuthError.loginRenewalRequired.localizedDescription)
        XCTAssertNil(snapshot.line(label: "Session"))
        // The renewal snapshot keeps the preferred (keychain) login's plan badge and the local tiles.
        XCTAssertEqual(snapshot.plan, "Max")
        XCTAssertEqual(values(snapshot.lines, "Today"),
                       [MetricValue(number: 0.25, kind: .dollars, estimated: true),
                        MetricValue(number: 150, kind: .count, label: "tokens")])
    }

    func testNoCredentialsReportsNotLoggedIn() async {
        func makeProvider(files: FakeFiles) -> ClaudeProvider {
            ClaudeProvider(
                authStore: ClaudeAuthStore(
                    environment: FakeEnvironment(),
                    files: files,
                    keychain: FakeKeychain()
                ),
                usageClient: ClaudeUsageClient(httpClient: FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data()))),
                logUsageScanner: ClaudeLogFixture.scanner(home: nil),
                pricing: { TestPricing.bundled }
            )
        }

        let noneAtAll = makeProvider(files: FakeFiles())
        let plainSnapshot = await noneAtAll.refresh()
        XCTAssertEqual(badge(plainSnapshot.lines, "Error"), ClaudeAuthError.notLoggedIn.localizedDescription)

        // A stored-but-blank CLI token (whitespace accessToken survives the store's isEmpty check but is
        // dropped by the provider's trim filter) is still unusable.
        let corruptCLI = makeProvider(files: FakeFiles([
            "~/.claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"   "}}"#
        ]))
        let corruptSnapshot = await corruptCLI.refresh()
        XCTAssertEqual(badge(corruptSnapshot.lines, "Error"), ClaudeAuthError.notLoggedIn.localizedDescription)
    }

    func testRateLimitedResponseMapsToRetryBadgeNotError() async {
        let now = RunwayISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let httpClient = FakeHTTPClient(response: HTTPResponse(
            statusCode: 429,
            headers: ["retry-after": "600"],
            body: Data()
        ))
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: FakeFiles([
                    "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"pro","scopes":["user:profile"]}}"#
                ]),
                keychain: FakeKeychain(),
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(badge(snapshot.lines, "Status")?.hasPrefix("Rate limited"), true)
        // The badge/note lines only render when enabled in the layout, so the state must also reach the
        // provider header warning (amber triangle) — without it the default dashboard is silently blank.
        XCTAssertEqual(
            snapshot.warning,
            "Updates blocked by Anthropic. Be patient — manual refreshes will make it worse. Retrying in ~10m."
        )
    }

    func testRateLimitServesLastGoodUsageThenBacksOff() async {
        // Tier 2: once a live fetch succeeds, a subsequent 429 keeps showing the cached bars (with a
        // staleness note) instead of a bare badge, and the cooldown then skips the live call entirely so
        // a constantly-limited endpoint isn't hammered.
        let t0 = RunwayISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let clock = TestClock(t0)
        let usageCalls = CallCounter()
        let httpClient = RoutingHTTPClient { request in
            guard request.url.absoluteString.hasSuffix("/api/oauth/usage") else {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data())
            }
            if usageCalls.next() == 1 {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            }
            return HTTPResponse(statusCode: 429, headers: ["retry-after": "600"], body: Data())
        }
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: FakeFiles([
                    "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"pro","scopes":["user:profile"]}}"#
                ]),
                keychain: FakeKeychain(),
                now: { clock.now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { clock.now },
            pricing: { TestPricing.bundled }
        )

        // 1) Live fetch succeeds and is cached; no warning rides along.
        let first = await provider.refresh()
        XCTAssertEqual(Self.progress(first.lines, "Session")?.used, 25)
        XCTAssertNil(first.warning)
        XCTAssertEqual(first.resolvedWarningAction, .refresh)

        // 2) 429: still shows the cached Session bar plus the staleness note, not a bare "Status" badge —
        // and the header warning flags the rate-limited state even when the note line isn't in the layout.
        let second = await provider.refresh()
        XCTAssertEqual(Self.progress(second.lines, "Session")?.used, 25)
        XCTAssertEqual(text(second.lines, "Note")?.contains("rate limited"), true)
        XCTAssertNil(badge(second.lines, "Status"))
        XCTAssertEqual(second.warning?.hasPrefix("Updates blocked by Anthropic"), true)
        // Cached bars from a clean fetch, but the notice on top of them is the rate limit's — the
        // header must not offer a refresh while this snapshot is on screen.
        XCTAssertEqual(second.resolvedWarningAction, .wait)

        // 3) Within the cooldown the live call is skipped entirely; the cached bar is still shown and the
        // warning persists.
        clock.set(t0.addingTimeInterval(60))
        let third = await provider.refresh()
        XCTAssertEqual(Self.progress(third.lines, "Session")?.used, 25)
        XCTAssertEqual(third.warning?.hasPrefix("Updates blocked by Anthropic"), true)
        XCTAssertEqual(third.resolvedWarningAction, .wait)
        XCTAssertEqual(httpClient.requests.filter { $0.url.absoluteString.hasSuffix("/api/oauth/usage") }.count, 2)
    }

    func testRateLimitedSnapshotPicksUpTierChangeFromStateFile() async {
        // A plan change during a rate-limit cooldown must still reach the badge: the cached last-good
        // usage carries its fetch-time plan, so the 429 and cooldown paths re-derive it from the
        // freshly loaded credentials (which include the state file's current tier).
        let t0 = RunwayISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let clock = TestClock(t0)
        let usageCalls = CallCounter()
        let httpClient = RoutingHTTPClient { request in
            guard request.url.absoluteString.hasSuffix("/api/oauth/usage") else {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data())
            }
            if usageCalls.next() == 1 {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            }
            return HTTPResponse(statusCode: 429, headers: ["retry-after": "600"], body: Data())
        }
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"max","rateLimitTier":"default_claude_max_5x","scopes":["user:profile"]}}"#,
            "/tmp/claude/.claude.json": #"{"oauthAccount":{"accountUuid":"a","organizationRateLimitTier":"default_claude_max_5x"}}"#
        ])
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: files,
                keychain: FakeKeychain(),
                now: { clock.now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { clock.now },
            pricing: { TestPricing.bundled }
        )

        let first = await provider.refresh()
        XCTAssertEqual(first.plan, "Max 5x")

        // The user upgrades: Claude Code's profile refetch rewrites the state file tier.
        files.files["/tmp/claude/.claude.json"] =
            #"{"oauthAccount":{"accountUuid":"a","organizationRateLimitTier":"default_claude_max_20x"}}"#

        // 429 serving the cached bars: the badge still moves to the new tier.
        let second = await provider.refresh()
        XCTAssertEqual(Self.progress(second.lines, "Session")?.used, 25)
        XCTAssertEqual(second.plan, "Max 20x")

        // Inside the cooldown (live call skipped entirely) the fresh tier also holds.
        clock.set(t0.addingTimeInterval(60))
        let third = await provider.refresh()
        XCTAssertEqual(third.plan, "Max 20x")
    }

    func testUsageServerErrorSurfacesRequestFailureNotARenewalNotice() async {
        // A 5xx from the usage endpoint is an infra failure the user can't fix by opening Claude —
        // it must stay a loud request-failure error, never be softened into the renewal notice.
        let now = RunwayISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let files = FakeFiles([
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token","refreshToken":"refresh-1","expiresAt":4102444800000,"subscriptionType":"pro","scopes":["user:profile"]}}"#
        ])
        let httpClient = FakeHTTPClient(response: HTTPResponse(statusCode: 500, headers: [:], body: Data()))
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: files,
                keychain: FakeKeychain(),
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(badge(snapshot.lines, "Error"), ProviderUsageErrorText.requestFailed(statusCode: 500))
        XCTAssertNil(snapshot.warning)
    }

    private func badge(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .badge(_, let value, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return value
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values
    }

    private func text(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .text(_, let value, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return value
    }

    private static func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, resetsAt, periodDurationMs)
    }
}

/// Models an existing Claude Code item that Runway has not been authorized to read yet. The launch
/// path may inspect its attributes and attempt an interaction-forbidden read, but must never call either
/// interactive secret API — those are what cause macOS to present the password dialog.
private final class InteractionTrackingKeychain: KeychainReading, @unchecked Sendable {
    private let lock = NSLock()
    private let approvedValue: String?
    private let existence: Bool?
    private var interactiveReads = 0
    private var runwayInteractiveReads = 0
    private var nonInteractiveReads = 0

    init(approvedValue: String? = nil, existence: Bool? = true) {
        self.approvedValue = approvedValue
        self.existence = existence
    }

    var interactiveReadCount: Int {
        lock.withLock { interactiveReads }
    }

    var runwayInteractiveReadCount: Int {
        lock.withLock { runwayInteractiveReads }
    }

    var nonInteractiveReadCount: Int {
        lock.withLock { nonInteractiveReads }
    }

    func readGenericPassword(service: String) throws -> String? {
        lock.withLock { interactiveReads += 1 }
        return nil
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        lock.withLock { interactiveReads += 1 }
        return nil
    }

    func readGenericPasswordAllowingUserInteraction(service: String) throws -> String? {
        lock.withLock { runwayInteractiveReads += 1 }
        return nil
    }

    func readGenericPasswordForCurrentUserAllowingUserInteraction(service: String) throws -> String? {
        lock.withLock { runwayInteractiveReads += 1 }
        return approvedValue
    }

    func readGenericPasswordWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        lock.withLock { nonInteractiveReads += 1 }
        return .unavailable
    }

    func readGenericPasswordForCurrentUserWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        lock.withLock { nonInteractiveReads += 1 }
        return .unavailable
    }

    func genericPasswordExists(service: String) -> Bool? {
        existence
    }

    func writeGenericPassword(service: String, value: String) throws {}

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {}
}


/// Models a readable Claude Code item and counts every write-capable call. Runway is a read-only
/// consumer of Claude's credentials, so tests assert the count stays zero.
private final class WriteTrackingKeychain: KeychainReading, @unchecked Sendable {
    private let lock = NSLock()
    private let value: String
    private var writes = 0

    init(value: String) {
        self.value = value
    }

    var writeCount: Int {
        lock.withLock { writes }
    }

    func readGenericPassword(service: String) throws -> String? {
        nil
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        value
    }

    func readGenericPasswordWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        .missing
    }

    func readGenericPasswordForCurrentUserWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        .value(value)
    }

    func genericPasswordExists(service: String) -> Bool? {
        true
    }

    func writeGenericPassword(service: String, value: String) throws {
        lock.withLock { writes += 1 }
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        lock.withLock { writes += 1 }
    }

    func writeGenericPassword(service: String, account: String, value: String) throws {
        lock.withLock { writes += 1 }
    }
}

/// A monotonic call counter for stateful `RoutingHTTPClient` handlers (e.g. "succeed once, then 429").
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

/// A mutable clock so a test can advance `now` between refreshes to exercise time-based gates.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set(_ value: Date) {
        lock.lock(); defer { lock.unlock() }
        self.value = value
    }
}
