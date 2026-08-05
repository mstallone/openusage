import XCTest
@testable import Runway

final class CopilotAuthStoreTests: XCTestCase {
    func testReadsEditorAppsJSON() {
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.editorAppsPath: """
                { "github.com:Iv1.abc123": { "user": "octocat", "oauth_token": "gho_editor" } }
                """
            ]),
            keychain: FakeKeychain()
        )

        let token = store.loadCredentials().token

        XCTAssertEqual(token?.value, "gho_editor")
    }

    func testReadsGhHostsOAuthToken() {
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.ghHostsPath: """
                github.com:
                    git_protocol: https
                    user: octocat
                    oauth_token: gho_ghconfig
                """
            ]),
            keychain: FakeKeychain()
        )

        let token = store.loadCredentials().token

        XCTAssertEqual(token?.value, "gho_ghconfig")
    }

    func testDecodesGoKeyringWrappedGhKeychainToken() {
        let wrapped = "go-keyring-base64:" + Data("gho_keychain".utf8).base64EncodedString()
        let store = CopilotAuthStore(files: FakeFiles(), keychain: FakeKeychain(wrapped))

        let token = store.loadCredentials().token

        XCTAssertEqual(token?.value, "gho_keychain")
    }

    func testAutomaticLoadUsesOnlyPromptFreeKeychainReadsAndManualLoadMayPrompt() {
        // Regression for the 2026-08-03 prompt loop: the gh keychain item must never be read through
        // a prompt-capable path on an automatic refresh or at launch. Only a manual refresh may use
        // the interactive read (which prompts once, for Runway itself).
        let keychain = ReadModeTrackingKeychain(value: "gho_keychain")
        let store = CopilotAuthStore(files: FakeFiles(), keychain: keychain)

        XCTAssertEqual(store.loadCredentials().token?.value, "gho_keychain")
        XCTAssertEqual(keychain.interactiveReads, 0)
        XCTAssertGreaterThan(keychain.nonInteractiveReads, 0)
        XCTAssertEqual(keychain.plainReads, 0, "the subprocess-style read path must not be used")

        XCTAssertEqual(store.loadCredentials(allowKeychainInteraction: true).token?.value, "gho_keychain")
        XCTAssertGreaterThan(keychain.interactiveReads, 0)
        XCTAssertEqual(keychain.plainReads, 0)
    }

    func testUnloadedKeychainItemCountsAsAFootprintNeedingConnect() {
        // A gh token stored only in the Keychain, not yet loaded into this process: detection must
        // still see the login (so seeding enables the card) and the load must report the neutral
        // connect state — not "not logged in", and not a permission warning (nothing was denied).
        let store = CopilotAuthStore(files: FakeFiles(), keychain: UnauthorizedItemKeychain())

        XCTAssertEqual(store.loadCredentials(), .connectRequired)
    }

    func testBillingCandidatesReportWhenThePreferredCredentialNeedsApproval() {
        // Editor config supplies the usage token; the preferred GitHub CLI token hasn't been
        // loaded into this process. The candidate list must carry that fact, or an org-managed
        // card blames billing access when the real fix is connecting a credential that exists.
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.editorAppsPath: #"{ "github.com": { "oauth_token": "gho_editor" } }"#
            ]),
            keychain: UnauthorizedItemKeychain()
        )

        let candidates = store.loadBillingTokenCandidates(usageToken: CopilotToken(value: "gho_editor"))

        XCTAssertEqual(candidates.tokens.map(\.value), ["gho_editor"])
        XCTAssertEqual(candidates.keychainError, .keychainConnectRequired)
    }

    func testUnknownExistenceProbeIsTreatedAsUnreadableNotLoggedOut() {
        // A locked keychain (or a probe suppressed behind a stuck flight) answers `nil` — "cannot
        // check". Collapsing that into "not logged in" would disable Copilot at first-run detection
        // and show a misleading sign-in error, so the unreadable state must survive. It is
        // `.unreadable` and not an approval request: nothing examined the item, so asking the user
        // to choose Always Allow could be pointing at an item that is already authorized.
        let store = CopilotAuthStore(files: FakeFiles(), keychain: IndeterminateKeychain())

        XCTAssertEqual(store.loadCredentials(), .unreadable)
        XCTAssertNotEqual(store.loadCredentials(), .none, "first-run detection must still see a login")
    }

    func testUnreadableKeychainIsNotReportedAsNeedingApproval() {
        // "Choose Always Allow" cannot fix a locked login keychain or a failing securityd. The
        // read's own status told the two apart, so the load must carry that distinction rather
        // than collapsing both into an approval request.
        let store = CopilotAuthStore(
            files: FakeFiles(),
            keychain: UnreadableItemKeychain()
        )

        XCTAssertEqual(store.loadCredentials(), .unreadable)
    }

    func testProtectedScopedItemNeverBroadensToAnotherAccountsToken() {
        // hosts.yml names the intended account, whose Keychain item is protected — but another
        // (authorized) gh:github.com item exists for a different account. The load must report
        // the intended item's connect state, never silently pick up the other account's token
        // through the account-less lookup.
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.ghHostsPath: """
                github.com:
                    user: octocat
                """
            ]),
            keychain: CrossAccountKeychain(otherAccountsValue: "gho_other_account")
        )

        XCTAssertEqual(store.loadCredentials(), .connectRequired)
    }

    func testManualRefreshBillingLookupDoesNotPromptASecondTime() throws {
        // A keychain-only org-managed account on a manual refresh: the usage token's interactive
        // read may prompt once; the billing candidate lookup tries the prompt-free read first
        // (served by the coordinator's cache in production), so it never raises a second prompt.
        let keychain = ReadModeTrackingKeychain(value: "gho_keychain")
        let store = CopilotAuthStore(files: FakeFiles(), keychain: keychain)

        let usageToken = try XCTUnwrap(store.loadCredentials(allowKeychainInteraction: true).token)
        XCTAssertEqual(keychain.interactiveReads, 1)

        let billing = store.loadBillingTokenCandidates(usageToken: usageToken, allowKeychainInteraction: true)

        XCTAssertEqual(billing.tokens.map(\.value), ["gho_keychain"])
        XCTAssertEqual(keychain.interactiveReads, 1, "billing must not raise a second prompt")
        XCTAssertEqual(keychain.plainReads, 0)
    }

    func testManualRefreshCanApproveAProtectedBillingCredentialBehindAnEditorToken() {
        // Editor config supplies the usage token, but the gh billing token sits in a Keychain item
        // Runway isn't authorized for yet — billing is the FIRST Keychain touch. A manual refresh
        // must be able to approve it (one interactive read); automatic refreshes must not prompt.
        let keychain = UnauthorizedItemKeychain(approvedValue: "gho_billing")
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.editorAppsPath: #"{ "github.com": { "oauth_token": "gho_editor" } }"#
            ]),
            keychain: keychain
        )
        let usageToken = CopilotToken(value: "gho_editor")

        // Automatic: the protected item is skipped silently; only the usage token remains.
        XCTAssertEqual(
            store.loadBillingTokenCandidates(usageToken: usageToken).tokens.map(\.value),
            ["gho_editor"]
        )
        XCTAssertEqual(keychain.interactiveReads, 0)

        // Manual: exactly one interactive read approves and returns the billing token.
        XCTAssertEqual(
            store.loadBillingTokenCandidates(usageToken: usageToken, allowKeychainInteraction: true).tokens.map(\.value),
            ["gho_billing", "gho_editor"]
        )
        XCTAssertEqual(keychain.interactiveReads, 1)
    }

    func testEditorConfigWinsOverKeychain() {
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.editorAppsPath: #"{ "github.com": { "oauth_token": "gho_editor" } }"#
            ]),
            keychain: FakeKeychain("go-keyring-base64:" + Data("gho_keychain".utf8).base64EncodedString())
        )

        // Editor config wins over the keychain: the editor token is returned, not the keychain one.
        XCTAssertEqual(store.loadCredentials().token?.value, "gho_editor")
    }

    func testBillingTokensPreferGitHubCLIAndDeduplicateUsageToken() throws {
        let wrappedBillingToken = "go-keyring-base64:"
            + Data("gho_billing".utf8).base64EncodedString()
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.editorAppsPath: #"{ "github.com": { "oauth_token": "gho_editor" } }"#
            ]),
            keychain: FakeKeychain(wrappedBillingToken)
        )
        let usageToken = try XCTUnwrap(store.loadCredentials().token)

        XCTAssertEqual(
            store.loadBillingTokenCandidates(usageToken: usageToken).tokens.map(\.value),
            ["gho_billing", "gho_editor"]
        )
        XCTAssertEqual(
            store.loadBillingTokenCandidates(usageToken: CopilotToken(value: "gho_billing")).tokens.map(\.value),
            ["gho_billing"]
        )
    }

    func testReturnsNilWhenNoCredentials() {
        let store = CopilotAuthStore(files: FakeFiles(), keychain: FakeKeychain())
        XCTAssertNil(store.loadCredentials().token)
    }

    func testEditorConfigIgnoresNonGithubDotComHost() {
        // An Enterprise-only editor config must not yield a token for api.github.com; the chain should
        // fall through to the gh keychain (which here holds the real github.com token).
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.editorAppsPath: #"{ "ghe.corp.example:Iv1.x": { "oauth_token": "gho_enterprise" } }"#
            ]),
            keychain: FakeKeychain("go-keyring-base64:" + Data("gho_dotcom".utf8).base64EncodedString())
        )

        let token = store.loadCredentials().token

        XCTAssertEqual(token?.value, "gho_dotcom")
    }

    func testEditorConfigPicksGithubDotComAmongHosts() {
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.editorAppsPath: #"{ "ghe.corp.example:Iv1.x": { "oauth_token": "gho_ent" }, "github.com:Iv1.y": { "oauth_token": "gho_dotcom" } }"#
            ]),
            keychain: FakeKeychain()
        )

        XCTAssertEqual(store.loadCredentials().token?.value, "gho_dotcom")
    }

    func testYamlValueIgnoresNestedUsersMap() {
        let hosts = """
        github.com:
            users:
                octocat:
            user: octocat
        """
        XCTAssertEqual(CopilotAuthStore.yamlValue(hosts, key: "user"), "octocat")
    }

    func testYamlValueScopesToGithubDotComHost() {
        // A GitHub Enterprise block precedes github.com; the github.com token must win.
        let hosts = """
        ghe.corp.example:
            oauth_token: gho_enterprise
            user: ent
        github.com:
            oauth_token: gho_dotcom
            user: octocat
        """
        XCTAssertEqual(CopilotAuthStore.yamlValue(hosts, key: "oauth_token"), "gho_dotcom")
        XCTAssertEqual(CopilotAuthStore.yamlValue(hosts, key: "user"), "octocat")
    }

    func testGhConfigPrefersGithubDotComTokenOverEnterprise() {
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.ghHostsPath: """
                ghe.corp.example:
                    oauth_token: gho_enterprise
                github.com:
                    oauth_token: gho_dotcom
                """
            ]),
            keychain: FakeKeychain()
        )

        XCTAssertEqual(store.loadCredentials().token?.value, "gho_dotcom")
    }
}

final class CopilotUsageMapperTests: XCTestCase {
    func testMapsPaidCreditsAndChatAsPercentUsed() throws {
        let mapped = try CopilotUsageMapper.map(body: makePaidBody())

        XCTAssertEqual(mapped.plan, "Pro")
        XCTAssertEqual(progress(mapped.lines, "Credits")?.used, 59)
        XCTAssertEqual(progress(mapped.lines, "Chat")?.used, 5)
        XCTAssertNotNil(progress(mapped.lines, "Credits")?.resetsAt)
        XCTAssertEqual(progress(mapped.lines, "Credits")?.periodDurationMs, CopilotUsageMapper.periodMs)
    }

    func testSuppressesUnlimitedAndSentinelBuckets() throws {
        // Paid plans report chat/completions as unlimited — both the explicit flag and the `-1`
        // entitlement/remaining sentinel — which carry no real meter and must be suppressed, leaving
        // just Credits.
        var body = makePaidBody()
        var quota = body["quota_snapshots"] as! [String: Any]
        quota["chat"] = ["unlimited": true, "entitlement": 0, "remaining": 0, "quota_id": "chat"]
        quota["completions"] = ["entitlement": -1, "remaining": -1, "quota_id": "completions"]
        body["quota_snapshots"] = quota

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertNil(progress(mapped.lines, "Chat"))
        XCTAssertNil(progress(mapped.lines, "Completions"))
        XCTAssertEqual(progress(mapped.lines, "Credits")?.used, 59)
    }

    func testEmitsExtraUsageWhenOveragePermitted() throws {
        var body = makePaidBody()
        var quota = body["quota_snapshots"] as! [String: Any]
        var premium = quota["premium_interactions"] as! [String: Any]
        premium["overage_permitted"] = true
        premium["overage_count"] = 36
        quota["premium_interactions"] = premium
        body["quota_snapshots"] = quota

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(countValue(mapped.lines, "Extra Usage"), 36)
    }

    func testShowsExtraUsageZeroWhenPermittedButUnused() throws {
        var body = makePaidBody()
        var quota = body["quota_snapshots"] as! [String: Any]
        var premium = quota["premium_interactions"] as! [String: Any]
        premium["overage_permitted"] = true
        premium["overage_count"] = 0
        quota["premium_interactions"] = premium
        body["quota_snapshots"] = quota

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(countValue(mapped.lines, "Extra Usage"), 0)
    }

    func testSuppressesExtraUsageWhenNotPermitted() throws {
        // makePaidBody's premium has no overage flag → extra usage is genuinely N/A.
        let mapped = try CopilotUsageMapper.map(body: makePaidBody())
        XCTAssertNil(mapped.lines.first(where: { $0.label == "Extra Usage" }))
    }

    func testIgnoresLegacyLimitedQuotasWhenSnapshotsPresent() throws {
        // A paid response with Credits present and chat/completions unlimited (-1) must NOT fall back to
        // the legacy limited_user_quotas path, even if the payload still carries it — doing so would show
        // free-tier Chat/Completions meters on a paid account alongside Credits.
        var body = makePaidBody()
        var quota = body["quota_snapshots"] as! [String: Any]
        quota["chat"] = ["entitlement": -1, "remaining": -1, "quota_id": "chat"]
        quota["completions"] = ["entitlement": -1, "remaining": -1, "quota_id": "completions"]
        body["quota_snapshots"] = quota
        body["limited_user_quotas"] = ["chat": 100, "completions": 1000]
        body["monthly_quotas"] = ["chat": 500, "completions": 4000]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertNotNil(progress(mapped.lines, "Credits"))
        XCTAssertNil(progress(mapped.lines, "Chat"))
        XCTAssertNil(progress(mapped.lines, "Completions"))
    }

    func testSuppressesZeroEntitlementPlaceholder() throws {
        let body: [String: Any] = [
            "copilot_plan": "business",
            "quota_snapshots": [
                "premium_interactions": ["entitlement": 0, "remaining": 0, "percent_remaining": 100, "quota_id": "premium"],
                "chat": ["entitlement": 1000, "remaining": 800, "percent_remaining": 80, "quota_id": "chat"]
            ]
        ]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertNil(progress(mapped.lines, "Credits"))
        XCTAssertEqual(progress(mapped.lines, "Chat")?.used, 20)
    }

    func testMapsLiveFreeAccountSnapshots() throws {
        // The exact shape a free `individual` account returns today: real chat/completions counts in
        // `quota_snapshots`, a zero-entitlement premium bucket, and `token_based_billing` on every bucket.
        // Credits + Extra Usage suppress (no allotment / overage off); Chat + Completions render.
        let body: [String: Any] = [
            "copilot_plan": "individual",
            "access_type_sku": "free_limited_copilot",
            "token_based_billing": true,
            "quota_reset_date": "2099-07-01",
            "quota_snapshots": [
                "chat": ["entitlement": 200, "remaining": 182, "percent_remaining": 91.0, "overage_permitted": false, "token_based_billing": true],
                "completions": ["entitlement": 2000, "remaining": 1989, "percent_remaining": 99.4, "overage_permitted": false, "token_based_billing": true],
                "premium_interactions": ["entitlement": 0, "remaining": 0, "percent_remaining": 0.0, "overage_permitted": false, "token_based_billing": true]
            ]
        ]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(mapped.plan, "Individual")
        XCTAssertNil(progress(mapped.lines, "Credits"))
        XCTAssertNil(mapped.lines.first(where: { $0.label == "Extra Usage" }))
        XCTAssertEqual(progress(mapped.lines, "Chat")?.used ?? -1, 9, accuracy: 0.0001)
        XCTAssertEqual(progress(mapped.lines, "Completions")?.used ?? -1, 0.6, accuracy: 0.0001)
    }

    func testMapsFreeTierLimitedQuotas() throws {
        let body: [String: Any] = [
            "copilot_plan": "individual",
            "limited_user_quotas": ["chat": 250, "completions": 2000],
            "monthly_quotas": ["chat": 500, "completions": 4000],
            "limited_user_reset_date": "2099-02-15"
        ]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(mapped.plan, "Individual")
        XCTAssertEqual(progress(mapped.lines, "Chat")?.used, 50)
        XCTAssertEqual(progress(mapped.lines, "Completions")?.used, 50)
        XCTAssertNotNil(progress(mapped.lines, "Chat")?.resetsAt)
    }

    func testTokenBasedBillingReturnsPlanWithoutMeters() throws {
        let body: [String: Any] = [
            "copilot_plan": "business",
            "token_based_billing": true,
            "organization_login_list": ["seat-org"],
            "organization_list": [["login": "seat-org", "name": "Seat Org"]],
            "quota_snapshots": [
                "premium_interactions": ["entitlement": 0, "remaining": 0, "quota_id": "premium"]
            ]
        ]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(mapped.plan, "Business")
        XCTAssertTrue(mapped.lines.isEmpty)
        XCTAssertEqual(mapped.organizationLogins, ["seat-org"])
        XCTAssertTrue(mapped.isOrgManagedSeat)
    }

    func testEnterpriseTokenBillingUsesOrganizationScope() throws {
        var body = makeBusinessPlaceholderBody()
        body["copilot_plan"] = "enterprise"

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(mapped.plan, "Enterprise")
        XCTAssertTrue(mapped.lines.isEmpty)
        XCTAssertTrue(mapped.isOrgManagedSeat)
    }

    func testPlaceholderOveragePermittedDoesNotEmitExtraUsageOrBlockOrgFlag() throws {
        // Regression for issue #839's second report: the org-managed placeholder carries
        // `overage_permitted: true` on a zero-entitlement premium bucket. That must not render a
        // meaningless "Extra Usage: 0" row — and must still flag the seat as org-managed so the
        // provider runs the org-billing lookup.
        var body: [String: Any] = [
            "copilot_plan": "business",
            "token_based_billing": true,
            "quota_snapshots": [
                "premium_interactions": [
                    "entitlement": 0, "remaining": 0, "unlimited": true,
                    "overage_permitted": true, "overage_count": 0, "token_based_billing": true
                ]
            ]
        ]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertNil(mapped.lines.first(where: { $0.label == "Extra Usage" }))
        XCTAssertTrue(mapped.lines.isEmpty)
        XCTAssertTrue(mapped.isOrgManagedSeat)

        // A paid account with a real credit pool keeps its Extra Usage row.
        body = makePaidBody()
        var quota = body["quota_snapshots"] as! [String: Any]
        var premium = quota["premium_interactions"] as! [String: Any]
        premium["overage_permitted"] = true
        premium["overage_count"] = 12
        quota["premium_interactions"] = premium
        body["quota_snapshots"] = quota

        let paid = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(countValue(paid.lines, "Extra Usage"), 12)
        XCTAssertFalse(paid.isOrgManagedSeat)
    }

    func testThrowsQuotaUnavailableWhenEmpty() {
        XCTAssertThrowsError(try CopilotUsageMapper.map(body: ["copilot_plan": "pro"])) { error in
            XCTAssertEqual(error as? CopilotUsageError, .quotaUnavailable)
        }
    }
}

final class CopilotOrgBillingMapperTests: XCTestCase {
    func testParsesOrgLogins() {
        let body: [[String: Any]] = [["login": "acme", "id": 1], ["login": "globex"], ["id": 3]]
        let response = HTTPResponse(statusCode: 200, headers: [:], body: try! JSONSerialization.data(withJSONObject: body))

        XCTAssertEqual(CopilotOrgBillingMapper.orgLogins(response), ["acme", "globex"])
    }

    func testOrgLoginsEmptyForGarbledBody() {
        let response = HTTPResponse(statusCode: 200, headers: [:], body: Data("<html>".utf8))
        XCTAssertEqual(CopilotOrgBillingMapper.orgLogins(response), [])
    }

    func testEnterpriseMembershipPageIncludesOnlyEnterpriseOwningSeatOrganization() throws {
        let response = ok(makeEnterpriseMembershipBody(
            enterprises: [
                ("octo-enterprise", ["acme", "other"]),
                ("unrelated-enterprise", ["unrelated"])
            ]
        ))

        XCTAssertEqual(
            CopilotOrgBillingMapper.enterpriseMembershipPage(response, organization: "ACME"),
            .init(
                targets: [.init(enterprise: "octo-enterprise", organization: "acme")],
                organizationContinuations: [],
                nextEnterpriseCursor: nil
            )
        )
    }

    func testEnterpriseMembershipPageReturnsBothConnectionCursors() throws {
        let response = ok(makeEnterpriseMembershipBody(
            enterprises: [("octo-enterprise", ["other"])],
            nextEnterpriseCursor: "enterprise-page-2",
            nextOrganizationCursors: ["octo-enterprise": "organization-page-2"]
        ))

        XCTAssertEqual(
            CopilotOrgBillingMapper.enterpriseMembershipPage(response, organization: "acme"),
            .init(
                targets: [],
                organizationContinuations: [
                    .init(enterprise: "octo-enterprise", cursor: "organization-page-2")
                ],
                nextEnterpriseCursor: "enterprise-page-2"
            )
        )
    }

    func testEnterpriseOrganizationPageFindsSeatOrganizationAndCursor() throws {
        let response = ok(makeEnterpriseOrganizationBody(
            organizations: ["acme"],
            nextCursor: "organization-page-3"
        ))

        XCTAssertEqual(
            CopilotOrgBillingMapper.enterpriseOrganizationPage(
                response,
                enterprise: "octo-enterprise",
                organization: "ACME"
            ),
            .init(
                target: .init(enterprise: "octo-enterprise", organization: "acme"),
                nextCursor: "organization-page-3"
            )
        )
    }

    func testEnterpriseMembershipPageRejectsGraphQLErrors() {
        let response = ok(["errors": [["message": "Resource not accessible"]]])
        XCTAssertNil(CopilotOrgBillingMapper.enterpriseMembershipPage(response, organization: "acme"))
    }

    func testMapsAICreditUsageFromSummary() throws {
        // The exact shape reported in issue #839: one Copilot AI-unit item, fully covered by included
        // credits (netAmount 0).
        let lines = try XCTUnwrap(CopilotOrgBillingMapper.usageLines(body: makeOrgSummaryBody()))

        XCTAssertEqual(orgCount(lines, "Org Credits") ?? -1, 298.698546, accuracy: 0.0001)
        XCTAssertEqual(orgCount(lines, "Org Credits", valueLabel: "included") ?? -1, 298.698546, accuracy: 0.0001)
        XCTAssertEqual(orgCount(lines, "Org Credits", valueLabel: "additional"), 0)
        XCTAssertEqual(orgDollars(lines, "Org Spend"), 0)
    }

    func testSumsMultipleCreditItemsAndBilledSpend() throws {
        var body = makeOrgSummaryBody()
        body["usageItems"] = [
            [
                "product": "Copilot", "sku": "copilot_ai_unit", "unitType": "ai-units",
                "grossQuantity": 100.5, "discountQuantity": 100, "netQuantity": 0.5, "netAmount": 1.25
            ],
            [
                "product": "Copilot", "sku": "Copilot AI Credits", "unitType": "credits",
                "grossQuantity": 50, "discountQuantity": 20, "netQuantity": 30, "netAmount": 0.5
            ]
        ]

        let lines = try XCTUnwrap(CopilotOrgBillingMapper.usageLines(body: body))

        XCTAssertEqual(orgCount(lines, "Org Credits") ?? -1, 150.5, accuracy: 0.0001)
        XCTAssertEqual(orgCount(lines, "Org Credits", valueLabel: "included"), 120)
        XCTAssertEqual(orgCount(lines, "Org Credits", valueLabel: "additional"), 30.5)
        XCTAssertEqual(orgDollars(lines, "Org Spend") ?? -1, 1.75, accuracy: 0.0001)
    }

    @MainActor
    func testCreditDescriptorShowsGrossTotalWithIncludedAndAdditionalSubtitle() throws {
        let lines = try XCTUnwrap(CopilotOrgBillingMapper.usageLines(body: makeOrgSummaryBody()))
        let descriptor = try XCTUnwrap(
            CopilotProvider().widgetDescriptors.first { $0.id == "copilot.orgCredits" }
        )
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == "Org Credits" }) else {
            return XCTFail("expected organization credit values")
        }
        var data = descriptor.sample
        data.values = values

        XCTAssertEqual(data.title, "AI Credits Used")
        XCTAssertEqual(data.selectedValues.map(\.label), ["credits"])
        XCTAssertEqual(data.unboundedDetail, "298.7 credits")
        XCTAssertEqual(data.unboundedSubtitle, "298.7 included · 0 additional")
    }

    func testNilWhenReportContainsOnlyNonAICreditItems() {
        // Actions minutes and Copilot seat fees (non-credit units) must not produce org meters.
        var body = makeOrgSummaryBody()
        body["usageItems"] = [
            ["product": "Actions", "sku": "actions_linux", "unitType": "minutes", "grossQuantity": 120, "netAmount": 0.96],
            ["product": "Copilot", "sku": "copilot_business_seat", "unitType": "user-months", "grossQuantity": 10, "netAmount": 190]
        ]

        XCTAssertNil(CopilotOrgBillingMapper.usageLines(body: body))
    }

    func testPremiumRequestRowsDoNotEnterAICreditMetrics() {
        // GitHub exposes legacy premium-request usage through a separate endpoint. A request row must
        // not be relabeled as AI credits or folded into the usage-based Additional Spend figure.
        let body: [String: Any] = [
            "usageItems": [[
                "product": "Copilot",
                "sku": "Copilot Premium Request",
                "unitType": "requests",
                "grossQuantity": 100,
                "netAmount": 4
            ]]
        ]

        XCTAssertNil(CopilotOrgBillingMapper.usageLines(body: body))
    }

    func testNilWhenSummaryHasNoUsageItems() {
        XCTAssertNil(CopilotOrgBillingMapper.usageLines(body: ["organization": "acme"]))
    }

    func testEmptyUsageItemsMapsToZeroTotals() throws {
        let report = try XCTUnwrap(CopilotOrgBillingMapper.usageReport(body: ["usageItems": []]))

        XCTAssertFalse(report.hasUsage)
        XCTAssertEqual(orgCount(report.lines, "Org Credits"), 0)
        XCTAssertEqual(orgCount(report.lines, "Org Credits", valueLabel: "included"), 0)
        XCTAssertEqual(orgCount(report.lines, "Org Credits", valueLabel: "additional"), 0)
        XCTAssertEqual(orgDollars(report.lines, "Org Spend"), 0)
    }

    func testOtherAICreditProductsMapToZeroCopilotTotals() throws {
        let report = try XCTUnwrap(CopilotOrgBillingMapper.usageReport(body: makeOtherAICreditBody()))

        XCTAssertFalse(report.hasUsage)
        XCTAssertEqual(orgCount(report.lines, "Org Credits"), 0)
        XCTAssertEqual(orgDollars(report.lines, "Org Spend"), 0)
    }
}

@MainActor
final class CopilotProviderTests: XCTestCase {
    func testNotLoggedInWhenNoToken() async {
        let provider = CopilotProvider(
            authStore: CopilotAuthStore(files: FakeFiles(), keychain: FakeKeychain()),
            usageClient: CopilotUsageClient(http: FakeHTTPClient(response: ok(makePaidBody())))
        )

        let snapshot = await provider.refresh()

        XCTAssertTrue(snapshot.lines.contains { $0.isError })
    }

    func testTokenInvalidOn401() async {
        let provider = CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: FakeHTTPClient(response: HTTPResponse(statusCode: 401, headers: [:], body: Data())))
        )

        let snapshot = await provider.refresh()

        XCTAssertTrue(snapshot.lines.contains { $0.isError })
    }

    func testMapsLinesAndSendsTokenHeaderOnSuccess() async throws {
        let http = FakeHTTPClient(response: ok(makePaidBody()))
        let provider = CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: http),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.line(label: "Credits")?.label, "Credits")
        XCTAssertEqual(snapshot.applicableMetricIDs, ["copilot.premium", "copilot.chat"])
        XCTAssertEqual(http.requests.first?.headers["Authorization"], "token gho_editor")
    }

    func testFreeAccountExposesOnlyFreeQuotaMetrics() async {
        let body: [String: Any] = [
            "copilot_plan": "individual",
            "token_based_billing": true,
            "quota_snapshots": [
                "premium_interactions": ["entitlement": 0, "remaining": 0],
                "chat": ["entitlement": 200, "remaining": 180],
                "completions": ["entitlement": 2000, "remaining": 1500]
            ]
        ]
        let provider = CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: FakeHTTPClient(response: ok(body)))
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Individual")
        XCTAssertEqual(snapshot.applicableMetricIDs, ["copilot.chat", "copilot.completions"])
    }

    func testPartialFreeResponseKeepsBothFreeQuotaMetricsApplicable() async {
        let body: [String: Any] = [
            "copilot_plan": "individual",
            "access_type_sku": "free_limited_copilot",
            "token_based_billing": true,
            "quota_snapshots": [
                "premium_interactions": ["entitlement": 0, "remaining": 0],
                "chat": ["entitlement": 200, "remaining": 180]
            ]
        ]
        let provider = CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: FakeHTTPClient(response: ok(body)))
        )

        let snapshot = await provider.refresh()

        XCTAssertNotNil(snapshot.line(label: "Chat"))
        XCTAssertNil(snapshot.line(label: "Completions"))
        XCTAssertEqual(snapshot.applicableMetricIDs, ["copilot.chat", "copilot.completions"])
    }

    func testFreeAccountWithAllQuotaBucketsOmittedShowsBothAsNoData() async {
        let body: [String: Any] = [
            "copilot_plan": "individual",
            "access_type_sku": "free_limited_copilot",
            "token_based_billing": true,
            "quota_snapshots": [:]
        ]
        let provider = CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: FakeHTTPClient(response: ok(body)))
        )

        let snapshot = await provider.refresh()

        XCTAssertFalse(snapshot.lines.contains { $0.label == "Organization Usage" })
        XCTAssertEqual(snapshot.applicableMetricIDs, ["copilot.chat", "copilot.completions"])
    }

    func testTokenBasedBillingShowsPlanWithoutError() async {
        let body: [String: Any] = [
            "copilot_plan": "business",
            "token_based_billing": true,
            "quota_snapshots": ["premium_interactions": ["entitlement": 0, "remaining": 0]]
        ]
        let forbidden = HTTPResponse(statusCode: 403, headers: [:], body: Data())
        let provider = CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: FakeHTTPClient(response: ok(body))),
            orgBillingClient: CopilotOrgBillingClient(http: FakeHTTPClient(response: forbidden))
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Business")
        XCTAssertEqual(snapshot.line(label: "Organization Usage")?.label, "Organization Usage")
        XCTAssertEqual(snapshot.applicableMetricIDs, ["copilot.orgManaged"])
    }

    func testOrgManagedSeatShowsOrgBillingLines() async {
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody())),
            ("/user/orgs", okJSON([["login": "acme"]])),
            ("/organizations/acme/settings/billing/ai_credit/usage", ok(makeOrgSummaryBody()))
        ])
        let defaults = freshDefaults()
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Business")
        XCTAssertEqual(orgCount(snapshot.lines, "Org Credits") ?? -1, 298.698546, accuracy: 0.0001)
        XCTAssertEqual(orgDollars(snapshot.lines, "Org Spend"), 0)
        XCTAssertEqual(snapshot.applicableMetricIDs, ["copilot.orgCredits", "copilot.orgSpend"])
        // Positive org-local usage needs no enterprise caveat.
        XCTAssertNil(snapshot.warning)
        // The placeholder's `overage_permitted: true` must not leave a meaningless Extra Usage row.
        XCTAssertNil(snapshot.lines.first(where: { $0.label == "Extra Usage" }))
        XCTAssertEqual(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey), "acme")
        let billingRequest = http.requests.first {
            $0.url.path == "/organizations/acme/settings/billing/ai_credit/usage"
        }
        XCTAssertEqual(billingRequest?.headers["X-GitHub-Api-Version"], "2026-03-10")
    }

    func testOrgBillingPrefersGitHubCLITokenOverEditorUsageToken() async {
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/copilot_internal/user":
                return ok(makeBusinessPlaceholderBody(seatOrgs: ["acme"]))
            case "/organizations/acme/settings/billing/ai_credit/usage":
                return request.headers["Authorization"] == "token gho_billing"
                    ? ok(makeOrgSummaryBody())
                    : HTTPResponse(statusCode: 403, headers: [:], body: Data())
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = CopilotProvider(
            authStore: editorAndGhTokenStore(),
            usageClient: CopilotUsageClient(http: http),
            orgBillingClient: CopilotOrgBillingClient(http: http),
            defaults: freshDefaults()
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(orgCount(snapshot.lines, "Org Credits") ?? -1, 298.698546, accuracy: 0.0001)
        XCTAssertEqual(http.requests.first?.headers["Authorization"], "token gho_editor")
        let billingRequests = http.requests.filter {
            $0.url.path == "/organizations/acme/settings/billing/ai_credit/usage"
        }
        XCTAssertEqual(billingRequests.map { $0.headers["Authorization"] }, ["token gho_billing"])
    }

    func testOrgBillingFallsBackToEditorWhenGitHubCLITokenLacksAccess() async {
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/copilot_internal/user":
                return ok(makeBusinessPlaceholderBody(seatOrgs: ["acme"]))
            case "/organizations/acme/settings/billing/ai_credit/usage":
                return request.headers["Authorization"] == "token gho_editor"
                    ? ok(makeOrgSummaryBody())
                    : HTTPResponse(statusCode: 403, headers: [:], body: Data())
            case "/graphql":
                return HTTPResponse(statusCode: 403, headers: [:], body: Data())
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = CopilotProvider(
            authStore: editorAndGhTokenStore(),
            usageClient: CopilotUsageClient(http: http),
            orgBillingClient: CopilotOrgBillingClient(http: http),
            defaults: freshDefaults()
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(orgCount(snapshot.lines, "Org Credits") ?? -1, 298.698546, accuracy: 0.0001)
        let billingRequests = http.requests.filter {
            $0.url.path == "/organizations/acme/settings/billing/ai_credit/usage"
        }
        XCTAssertEqual(
            billingRequests.map { $0.headers["Authorization"] },
            ["token gho_billing", "token gho_editor"]
        )
    }

    func testOrgBillingContinuesPastGitHubCLIEmptyReportToEditorEnterpriseUsage() async {
        let http = RoutingHTTPClient { request in
            let authorization = request.headers["Authorization"]
            switch request.url.path {
            case "/copilot_internal/user":
                return ok(makeBusinessPlaceholderBody(seatOrgs: ["acme"]))
            case "/organizations/acme/settings/billing/ai_credit/usage":
                return ok(["usageItems": []])
            case "/graphql":
                return authorization == "token gho_editor"
                    ? ok(makeEnterpriseMembershipBody(
                        enterprises: [("octo-enterprise", ["acme"])]
                    ))
                    : ok(makeEnterpriseMembershipBody(enterprises: []))
            case "/enterprises/octo-enterprise/settings/billing/ai_credit/usage":
                return ok(makeOrgSummaryBody())
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = CopilotProvider(
            authStore: editorAndGhTokenStore(),
            usageClient: CopilotUsageClient(http: http),
            orgBillingClient: CopilotOrgBillingClient(http: http),
            defaults: freshDefaults()
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(orgCount(snapshot.lines, "Org Credits") ?? -1, 298.698546, accuracy: 0.0001)
        XCTAssertEqual(
            http.requests.filter { $0.url.path == "/graphql" }
                .map { $0.headers["Authorization"] },
            ["token gho_billing", "token gho_editor"]
        )
        XCTAssertEqual(
            http.requests.first {
                $0.url.path == "/enterprises/octo-enterprise/settings/billing/ai_credit/usage"
            }?.headers["Authorization"],
            "token gho_editor"
        )
    }

    func testUnknownSeatOrgDoesNotUseAnotherAccountsGitHubCLIToken() async {
        let forbidden = HTTPResponse(statusCode: 403, headers: [:], body: Data())
        let http = RoutingHTTPClient { request in
            let authorization = request.headers["Authorization"]
            switch request.url.path {
            case "/copilot_internal/user":
                return ok(makeBusinessPlaceholderBody())
            case "/user/orgs":
                return authorization == "token gho_editor"
                    ? okJSON([["login": "seat-org"]])
                    : okJSON([["login": "unrelated"]])
            case "/organizations/seat-org/settings/billing/ai_credit/usage":
                return forbidden
            case "/organizations/unrelated/settings/billing/ai_credit/usage":
                return ok(makeOrgSummaryBody())
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = CopilotProvider(
            authStore: editorAndGhTokenStore(),
            usageClient: CopilotUsageClient(http: http),
            orgBillingClient: CopilotOrgBillingClient(http: http),
            defaults: freshDefaults()
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.line(label: "Organization Usage")?.label, "Organization Usage")
        XCTAssertNil(snapshot.line(label: "Org Credits"))
        XCTAssertFalse(http.requests.contains {
            $0.url.path.contains("/organizations/unrelated/")
        })
        XCTAssertTrue(http.requests.dropFirst().allSatisfy {
            $0.headers["Authorization"] == "token gho_editor"
        })
    }

    func testOrgBillingForbiddenKeepsPlanOnlyCard() async {
        // A plain org member (not owner/billing manager) gets 403 on org billing — the expected state,
        // which must keep today's plan-only card rather than erroring the provider.
        let forbidden = HTTPResponse(statusCode: 403, headers: [:], body: Data())
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody())),
            ("/user/orgs", okJSON([["login": "acme"]])),
            ("/organizations/acme/settings/billing/ai_credit/usage", forbidden)
        ])
        let defaults = freshDefaults()
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Business")
        XCTAssertEqual(snapshot.line(label: "Organization Usage")?.label, "Organization Usage")
        XCTAssertEqual(snapshot.applicableMetricIDs, ["copilot.orgManaged"])
        XCTAssertNil(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey))
    }

    func testConsolidatedEnterpriseBillingFallsBackFromOrganization404() async {
        let notFound = HTTPResponse(statusCode: 404, headers: [:], body: Data())
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody(seatOrgs: ["acme"]))),
            ("/organizations/acme/settings/billing/ai_credit/usage", notFound),
            ("/graphql", ok(makeEnterpriseMembershipBody(
                enterprises: [("octo-enterprise", ["acme"])]
            ))),
            ("/enterprises/octo-enterprise/settings/billing/ai_credit/usage", ok(makeOrgSummaryBody()))
        ])
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        XCTAssertEqual(orgCount(snapshot.lines, "Org Credits") ?? -1, 298.698546, accuracy: 0.0001)
        XCTAssertNil(snapshot.line(label: "Organization Usage"))
        let graphqlRequest = http.requests.first { $0.url.path == "/graphql" }
        XCTAssertEqual(graphqlRequest?.method, "POST")
        XCTAssertNotNil(graphqlRequest?.body)
        let enterpriseRequest = http.requests.first {
            $0.url.path == "/enterprises/octo-enterprise/settings/billing/ai_credit/usage"
        }
        XCTAssertEqual(
            URLComponents(url: try! XCTUnwrap(enterpriseRequest?.url), resolvingAgainstBaseURL: false)?
                .queryItems?
                .reduce(into: [:]) { $0[$1.name] = $1.value },
            ["organization": "acme", "product": "Copilot"]
        )
    }

    func testConsolidatedEnterpriseBillingOverridesEmptyOrganizationReport() async {
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody(seatOrgs: ["acme"]))),
            ("/organizations/acme/settings/billing/ai_credit/usage", ok(["usageItems": []])),
            ("/graphql", ok(makeEnterpriseMembershipBody(
                enterprises: [("octo-enterprise", ["acme"])]
            ))),
            ("/enterprises/octo-enterprise/settings/billing/ai_credit/usage", ok(makeOrgSummaryBody()))
        ])
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        XCTAssertEqual(orgCount(snapshot.lines, "Org Credits") ?? -1, 298.698546, accuracy: 0.0001)
        XCTAssertTrue(http.requests.contains {
            $0.url.path == "/enterprises/octo-enterprise/settings/billing/ai_credit/usage"
        })
    }

    func testEnterpriseBillingManagerFallsBackFromOrganization403() async {
        let forbidden = HTTPResponse(statusCode: 403, headers: [:], body: Data())
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody(seatOrgs: ["acme"]))),
            ("/organizations/acme/settings/billing/ai_credit/usage", forbidden),
            ("/graphql", ok(makeEnterpriseMembershipBody(
                enterprises: [("octo-enterprise", ["acme"])]
            ))),
            ("/enterprises/octo-enterprise/settings/billing/ai_credit/usage", ok(makeOrgSummaryBody()))
        ])
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        XCTAssertEqual(orgCount(snapshot.lines, "Org Credits") ?? -1, 298.698546, accuracy: 0.0001)
        XCTAssertNil(snapshot.line(label: "Organization Usage"))
        XCTAssertTrue(http.requests.contains {
            $0.url.path == "/enterprises/octo-enterprise/settings/billing/ai_credit/usage"
        })
    }

    func testTransientGraphQLErrorFailsRefreshInsteadOfReplacingData() async {
        var rateLimited = ok([
            "errors": [[
                "type": "RATE_LIMITED",
                "message": "Something went wrong while executing your query."
            ]]
        ])
        rateLimited.headers["x-ratelimit-remaining"] = "0"
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody(seatOrgs: ["acme"]))),
            ("/organizations/acme/settings/billing/ai_credit/usage", ok(["usageItems": []])),
            ("/graphql", rateLimited)
        ])
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        // A transient outage fails the refresh (the store keeps the previous snapshot) rather than
        // publishing an "unavailable" placeholder over good numbers.
        XCTAssertTrue(snapshot.lines.contains { $0.isError })
        XCTAssertNil(snapshot.line(label: "Organization Usage"))
        XCTAssertNil(snapshot.line(label: "Org Credits"))
    }

    func testRateLimitedGraphQL403FailsRefreshInsteadOfReplacingData() async {
        let rateLimited = HTTPResponse(
            statusCode: 403,
            headers: ["x-ratelimit-remaining": "0"],
            body: Data()
        )
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody(seatOrgs: ["acme"]))),
            ("/organizations/acme/settings/billing/ai_credit/usage", ok(["usageItems": []])),
            ("/graphql", rateLimited)
        ])
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        XCTAssertTrue(snapshot.lines.contains { $0.isError })
        XCTAssertNil(snapshot.line(label: "Organization Usage"))
        XCTAssertNil(snapshot.line(label: "Org Credits"))
    }

    func testRateLimitedGraphQLOrganizationPageFailsRefreshInsteadOfReplacingData() async {
        let notFound = HTTPResponse(statusCode: 404, headers: [:], body: Data())
        let rateLimited = HTTPResponse(
            statusCode: 403,
            headers: ["retry-after": "60"],
            body: Data()
        )
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/copilot_internal/user":
                return ok(makeBusinessPlaceholderBody(seatOrgs: ["acme"]))
            case "/organizations/acme/settings/billing/ai_credit/usage":
                return notFound
            case "/graphql":
                return graphQLVariables(request)["organizationCursor"] as? String == "next-org-page"
                    ? rateLimited
                    : ok(makeEnterpriseMembershipBody(
                        enterprises: [("octo-enterprise", ["unrelated"])],
                        nextOrganizationCursors: ["octo-enterprise": "next-org-page"]
                    ))
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        XCTAssertTrue(snapshot.lines.contains { $0.isError })
        XCTAssertNil(snapshot.line(label: "Organization Usage"))
        XCTAssertEqual(http.requests.filter { $0.url.path == "/graphql" }.count, 2)
    }

    func testGraphQLAuthorizationErrorFallsBackToSeatOrgEmptyReport() async {
        // The month-rollover regression: at the start of a billing month the seat org legitimately
        // reports zero usage. A token that can't see enterprise associations at all must not turn
        // that readable zero report into "Managed by Your Organization" — consolidated billing would
        // have made the org endpoint 404 instead of answering.
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody(seatOrgs: ["acme"]))),
            ("/organizations/acme/settings/billing/ai_credit/usage", ok(["usageItems": []])),
            ("/graphql", ok([
                "errors": [[
                    "type": "FORBIDDEN",
                    "message": "Resource not accessible by integration"
                ]]
            ]))
        ])
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        XCTAssertEqual(orgCount(snapshot.lines, "Org Credits"), 0)
        XCTAssertEqual(orgDollars(snapshot.lines, "Org Spend"), 0)
        XCTAssertNil(snapshot.line(label: "Organization Usage"))
        XCTAssertEqual(snapshot.applicableMetricIDs, ["copilot.orgCredits", "copilot.orgSpend"])
        // No warning even though the zero couldn't be enterprise-verified: real usage under the same
        // login surfaces in the org report on the next refresh, so the zero corrects itself.
        XCTAssertNil(snapshot.warning)
    }

    func testEnterpriseSeatWithDeniedDiscoveryKeepsManagedState() async {
        // A Copilot Enterprise seat guarantees an owning enterprise exists. When the token can't
        // read enterprise associations, an empty org report can't rule out consolidated usage —
        // unlike the business seat above, this must stay in the managed state, not read as zero.
        var body = makeBusinessPlaceholderBody(seatOrgs: ["acme"])
        body["copilot_plan"] = "enterprise"
        let http = routedClient([
            ("/copilot_internal/user", ok(body)),
            ("/organizations/acme/settings/billing/ai_credit/usage", ok(["usageItems": []])),
            ("/graphql", ok([
                "errors": [[
                    "type": "FORBIDDEN",
                    "message": "Resource not accessible by integration"
                ]]
            ]))
        ])
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        guard case .badge(_, let text, _, _) = snapshot.line(label: "Organization Usage") else {
            return XCTFail("expected organization status")
        }
        XCTAssertEqual(text, "Managed by Your Organization")
        XCTAssertNil(snapshot.line(label: "Org Credits"))
    }

    func testProvenEnterpriseWithUnreadableUsageKeepsManagedState() async {
        // GraphQL proves octo-enterprise owns the seat org, but its usage endpoint is forbidden. The
        // org-level empty report cannot rule out consolidated enterprise usage here, so the honest
        // managed state must survive the empty-report fallback above.
        let forbidden = HTTPResponse(statusCode: 403, headers: [:], body: Data())
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody(seatOrgs: ["acme"]))),
            ("/organizations/acme/settings/billing/ai_credit/usage", ok(["usageItems": []])),
            ("/graphql", ok(makeEnterpriseMembershipBody(
                enterprises: [("octo-enterprise", ["acme"])]
            ))),
            ("/enterprises/octo-enterprise/settings/billing/ai_credit/usage", forbidden)
        ])
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        guard case .badge(_, let text, _, _) = snapshot.line(label: "Organization Usage") else {
            return XCTFail("expected organization status")
        }
        XCTAssertEqual(text, "Managed by Your Organization")
        XCTAssertNil(snapshot.line(label: "Org Credits"))
    }

    func testProvenAssociationFromSecondCredentialOverridesUnverifiedZero() async {
        // The GitHub CLI credential can't see enterprise associations (its empty org report is only
        // provisional), but the editor credential proves octo-enterprise owns the seat org and can't
        // read its usage. The proof is an account-level fact: the unverified zero must yield to the
        // managed state instead of being published with a warning.
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/copilot_internal/user":
                return ok(makeBusinessPlaceholderBody(seatOrgs: ["acme"]))
            case "/organizations/acme/settings/billing/ai_credit/usage":
                return ok(["usageItems": []])
            case "/graphql":
                return request.headers["Authorization"] == "token gho_billing"
                    ? ok(["errors": [["type": "FORBIDDEN", "message": "Resource not accessible by integration"]]])
                    : ok(makeEnterpriseMembershipBody(enterprises: [("octo-enterprise", ["acme"])]))
            case "/enterprises/octo-enterprise/settings/billing/ai_credit/usage":
                return HTTPResponse(statusCode: 403, headers: [:], body: Data())
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = CopilotProvider(
            authStore: editorAndGhTokenStore(),
            usageClient: CopilotUsageClient(http: http),
            orgBillingClient: CopilotOrgBillingClient(http: http),
            defaults: freshDefaults()
        )

        let snapshot = await provider.refresh()

        guard case .badge(_, let text, _, _) = snapshot.line(label: "Organization Usage") else {
            return XCTFail("expected organization status")
        }
        XCTAssertEqual(text, "Managed by Your Organization")
        XCTAssertNil(snapshot.line(label: "Org Credits"))
    }

    func testProvenAssociationFromFirstCredentialBlocksLaterUnverifiedZero() async {
        // Same combination in the other order: the proof arrives before the unverified empty report,
        // which must then be rejected rather than stored.
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/copilot_internal/user":
                return ok(makeBusinessPlaceholderBody(seatOrgs: ["acme"]))
            case "/organizations/acme/settings/billing/ai_credit/usage":
                return ok(["usageItems": []])
            case "/graphql":
                return request.headers["Authorization"] == "token gho_billing"
                    ? ok(makeEnterpriseMembershipBody(enterprises: [("octo-enterprise", ["acme"])]))
                    : ok(["errors": [["type": "FORBIDDEN", "message": "Resource not accessible by integration"]]])
            case "/enterprises/octo-enterprise/settings/billing/ai_credit/usage":
                return HTTPResponse(statusCode: 403, headers: [:], body: Data())
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = CopilotProvider(
            authStore: editorAndGhTokenStore(),
            usageClient: CopilotUsageClient(http: http),
            orgBillingClient: CopilotOrgBillingClient(http: http),
            defaults: freshDefaults()
        )

        let snapshot = await provider.refresh()

        guard case .badge(_, let text, _, _) = snapshot.line(label: "Organization Usage") else {
            return XCTFail("expected organization status")
        }
        XCTAssertEqual(text, "Managed by Your Organization")
        XCTAssertNil(snapshot.line(label: "Org Credits"))
    }

    func testPartialDiscoveryDenialKeepsProofFromEarlierPages() async {
        // Page one proves octo-enterprise owns the seat org; the next enterprise page is denied.
        // The proof must survive the partial denial: with the proven enterprise's usage unreadable,
        // the card stays managed instead of publishing the empty org report as zero.
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/copilot_internal/user":
                return ok(makeBusinessPlaceholderBody(seatOrgs: ["acme"]))
            case "/organizations/acme/settings/billing/ai_credit/usage":
                return ok(["usageItems": []])
            case "/graphql":
                return graphQLVariables(request)["enterpriseCursor"] as? String == "enterprise-page-2"
                    ? ok(["errors": [["type": "FORBIDDEN", "message": "Resource not accessible by integration"]]])
                    : ok(makeEnterpriseMembershipBody(
                        enterprises: [("octo-enterprise", ["acme"])],
                        nextEnterpriseCursor: "enterprise-page-2"
                    ))
            case "/enterprises/octo-enterprise/settings/billing/ai_credit/usage":
                return HTTPResponse(statusCode: 403, headers: [:], body: Data())
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        guard case .badge(_, let text, _, _) = snapshot.line(label: "Organization Usage") else {
            return XCTFail("expected organization status")
        }
        XCTAssertEqual(text, "Managed by Your Organization")
        XCTAssertNil(snapshot.line(label: "Org Credits"))
        XCTAssertTrue(http.requests.contains {
            $0.url.path == "/enterprises/octo-enterprise/settings/billing/ai_credit/usage"
        })
    }

    func testPartialDiscoveryDenialKeepsOtherSeatOrgsProvisional() async {
        // Two seat orgs: discovery proves acme's enterprise, then the denial cuts scanning short
        // before beta's association is known. Acme's enterprise report is a readable zero, but that
        // must not publish as a verified zero — beta may have an unseen enterprise carrying usage.
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/copilot_internal/user":
                return ok(makeBusinessPlaceholderBody(seatOrgs: ["acme", "beta"]))
            case "/organizations/acme/settings/billing/ai_credit/usage",
                 "/organizations/beta/settings/billing/ai_credit/usage":
                return ok(["usageItems": []])
            case "/graphql":
                return graphQLVariables(request)["enterpriseCursor"] as? String == "enterprise-page-2"
                    ? ok(["errors": [["type": "FORBIDDEN", "message": "Resource not accessible by integration"]]])
                    : ok(makeEnterpriseMembershipBody(
                        enterprises: [("octo-enterprise", ["acme"])],
                        nextEnterpriseCursor: "enterprise-page-2"
                    ))
            case "/enterprises/octo-enterprise/settings/billing/ai_credit/usage":
                return ok(["usageItems": []])
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        guard case .badge(_, let text, _, _) = snapshot.line(label: "Organization Usage") else {
            return XCTFail("expected organization status")
        }
        XCTAssertEqual(text, "Managed by Your Organization")
        XCTAssertNil(snapshot.line(label: "Org Credits"))
    }

    func testPartialDiscoveryDenialStillVerifiesFullyResolvedSeatOrg() async {
        // Single seat org with a proven enterprise: the org is fully resolved by its target (an org
        // has one owning enterprise), so a denial on a later discovery page changes nothing — the
        // enterprise's readable zero still renders as zero usage.
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/copilot_internal/user":
                return ok(makeBusinessPlaceholderBody(seatOrgs: ["acme"]))
            case "/organizations/acme/settings/billing/ai_credit/usage":
                return ok(["usageItems": []])
            case "/graphql":
                return graphQLVariables(request)["enterpriseCursor"] as? String == "enterprise-page-2"
                    ? ok(["errors": [["type": "FORBIDDEN", "message": "Resource not accessible by integration"]]])
                    : ok(makeEnterpriseMembershipBody(
                        enterprises: [("octo-enterprise", ["acme"])],
                        nextEnterpriseCursor: "enterprise-page-2"
                    ))
            case "/enterprises/octo-enterprise/settings/billing/ai_credit/usage":
                return ok(["usageItems": []])
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        XCTAssertEqual(orgCount(snapshot.lines, "Org Credits"), 0)
        XCTAssertEqual(orgDollars(snapshot.lines, "Org Spend"), 0)
        XCTAssertNil(snapshot.line(label: "Organization Usage"))
    }

    func testProvenAssociationDisplacesOrgOnlyNoAssociationZero() async {
        // The GitHub CLI credential sees no enterprises at all (its zero is org-only — "no visible
        // association" is viewer-relative), while the editor credential proves octo-enterprise owns
        // the seat org but can't read its usage. The positive proof must displace the org-only zero.
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/copilot_internal/user":
                return ok(makeBusinessPlaceholderBody(seatOrgs: ["acme"]))
            case "/organizations/acme/settings/billing/ai_credit/usage":
                return ok(["usageItems": []])
            case "/graphql":
                return request.headers["Authorization"] == "token gho_billing"
                    ? ok(makeEnterpriseMembershipBody(enterprises: []))
                    : ok(makeEnterpriseMembershipBody(enterprises: [("octo-enterprise", ["acme"])]))
            case "/enterprises/octo-enterprise/settings/billing/ai_credit/usage":
                return HTTPResponse(statusCode: 403, headers: [:], body: Data())
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = CopilotProvider(
            authStore: editorAndGhTokenStore(),
            usageClient: CopilotUsageClient(http: http),
            orgBillingClient: CopilotOrgBillingClient(http: http),
            defaults: freshDefaults()
        )

        let snapshot = await provider.refresh()

        guard case .badge(_, let text, _, _) = snapshot.line(label: "Organization Usage") else {
            return XCTFail("expected organization status")
        }
        XCTAssertEqual(text, "Managed by Your Organization")
        XCTAssertNil(snapshot.line(label: "Org Credits"))
    }

    func testEnterpriseVerifiedZeroSurvivesLaterOwnershipProof() async {
        // The GitHub CLI credential reads the owning enterprise's own zero report — the one zero no
        // ownership proof can displace. The editor credential proving the same enterprise without
        // usage access must not downgrade that verified zero to the managed state.
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/copilot_internal/user":
                return ok(makeBusinessPlaceholderBody(seatOrgs: ["acme"]))
            case "/organizations/acme/settings/billing/ai_credit/usage":
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            case "/graphql":
                return ok(makeEnterpriseMembershipBody(enterprises: [("octo-enterprise", ["acme"])]))
            case "/enterprises/octo-enterprise/settings/billing/ai_credit/usage":
                return request.headers["Authorization"] == "token gho_billing"
                    ? ok(["usageItems": []])
                    : HTTPResponse(statusCode: 403, headers: [:], body: Data())
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = CopilotProvider(
            authStore: editorAndGhTokenStore(),
            usageClient: CopilotUsageClient(http: http),
            orgBillingClient: CopilotOrgBillingClient(http: http),
            defaults: freshDefaults()
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(orgCount(snapshot.lines, "Org Credits"), 0)
        XCTAssertEqual(orgDollars(snapshot.lines, "Org Spend"), 0)
        XCTAssertNil(snapshot.line(label: "Organization Usage"))
    }

    func testEnterpriseDiscoveryPaginatesViewerEnterprises() async {
        let notFound = HTTPResponse(statusCode: 404, headers: [:], body: Data())
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/copilot_internal/user":
                ok(makeBusinessPlaceholderBody(seatOrgs: ["acme"]))
            case "/organizations/acme/settings/billing/ai_credit/usage":
                notFound
            case "/graphql":
                if graphQLVariables(request)["enterpriseCursor"] as? String == "enterprise-page-2" {
                    ok(makeEnterpriseMembershipBody(
                        enterprises: [("octo-enterprise", ["acme"])]
                    ))
                } else {
                    ok(makeEnterpriseMembershipBody(
                        enterprises: [("unrelated-enterprise", ["unrelated"])],
                        nextEnterpriseCursor: "enterprise-page-2"
                    ))
                }
            case "/enterprises/octo-enterprise/settings/billing/ai_credit/usage":
                ok(makeOrgSummaryBody())
            default:
                HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        XCTAssertEqual(orgCount(snapshot.lines, "Org Credits") ?? -1, 298.698546, accuracy: 0.0001)
        let graphqlRequests = http.requests.filter { $0.url.path == "/graphql" }
        XCTAssertEqual(graphqlRequests.count, 2)
        XCTAssertEqual(
            graphQLVariables(graphqlRequests[1])["enterpriseCursor"] as? String,
            "enterprise-page-2"
        )
    }

    func testEnterpriseDiscoveryPaginatesOrganizationsWithinEnterprise() async {
        let notFound = HTTPResponse(statusCode: 404, headers: [:], body: Data())
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/copilot_internal/user":
                ok(makeBusinessPlaceholderBody(seatOrgs: ["acme"]))
            case "/organizations/acme/settings/billing/ai_credit/usage":
                notFound
            case "/graphql":
                if graphQLVariables(request)["organizationCursor"] as? String == "organization-page-2" {
                    ok(makeEnterpriseOrganizationBody(organizations: ["acme"]))
                } else {
                    ok(makeEnterpriseMembershipBody(
                        enterprises: [("octo-enterprise", ["unrelated"])],
                        nextOrganizationCursors: ["octo-enterprise": "organization-page-2"]
                    ))
                }
            case "/enterprises/octo-enterprise/settings/billing/ai_credit/usage":
                ok(makeOrgSummaryBody())
            default:
                HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        XCTAssertEqual(orgCount(snapshot.lines, "Org Credits") ?? -1, 298.698546, accuracy: 0.0001)
        let graphqlRequests = http.requests.filter { $0.url.path == "/graphql" }
        XCTAssertEqual(graphqlRequests.count, 2)
        XCTAssertEqual(
            graphQLVariables(graphqlRequests[1])["organizationCursor"] as? String,
            "organization-page-2"
        )
    }

    func testConsolidatedEnterpriseEmptyReportShowsZeroUsage() async {
        let notFound = HTTPResponse(statusCode: 404, headers: [:], body: Data())
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody(seatOrgs: ["acme"]))),
            ("/organizations/acme/settings/billing/ai_credit/usage", notFound),
            ("/graphql", ok(makeEnterpriseMembershipBody(
                enterprises: [("octo-enterprise", ["acme"])]
            ))),
            ("/enterprises/octo-enterprise/settings/billing/ai_credit/usage", ok(["usageItems": []]))
        ])
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        XCTAssertEqual(orgCount(snapshot.lines, "Org Credits"), 0)
        XCTAssertEqual(orgDollars(snapshot.lines, "Org Spend"), 0)
        XCTAssertNil(snapshot.line(label: "Organization Usage"))
        // The enterprise itself reported the zero — verified, so no caveat.
        XCTAssertNil(snapshot.warning)
    }

    func testOrganizationBillingRequestsOnlyCopilotProduct() async {
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody(seatOrgs: ["acme"]))),
            ("/organizations/acme/settings/billing/ai_credit/usage", ok(makeOrgSummaryBody()))
        ])
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        _ = await provider.refresh()

        guard let request = http.requests.first(where: {
            $0.url.path == "/organizations/acme/settings/billing/ai_credit/usage"
        }) else {
            return XCTFail("expected organization AI-credit request")
        }
        XCTAssertEqual(
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "product", value: "Copilot")]
        )
    }

    func testUsesCachedOrgWithoutReprobing() async {
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody())),
            ("/organizations/acme/settings/billing/ai_credit/usage", ok(makeOrgSummaryBody()))
        ])
        let defaults = freshDefaults()
        defaults.set("acme", forKey: CopilotProvider.billingOrgDefaultsKey)
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertNotNil(orgCount(snapshot.lines, "Org Credits"))
        XCTAssertFalse(http.requests.contains { $0.url.absoluteString.contains("/user/orgs") })
    }

    func testCachedOrgWithEmptyUsageRediscoversAnotherOrgWithActualUsage() async {
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody())),
            ("/organizations/emptyorg/settings/billing/ai_credit/usage", ok(["usageItems": []])),
            ("/user/orgs", okJSON([["login": "emptyorg"], ["login": "acme"]])),
            ("/organizations/acme/settings/billing/ai_credit/usage", ok(makeOrgSummaryBody()))
        ])
        let defaults = freshDefaults()
        defaults.set("emptyorg", forKey: CopilotProvider.billingOrgDefaultsKey)
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertEqual(orgCount(snapshot.lines, "Org Credits") ?? -1, 298.698546, accuracy: 0.0001)
        XCTAssertEqual(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey), "acme")
        XCTAssertTrue(http.requests.contains { $0.url.absoluteString.contains("/user/orgs") })
        XCTAssertEqual(
            http.requests.filter {
                $0.url.path == "/organizations/emptyorg/settings/billing/ai_credit/usage"
            }.count,
            1
        )
    }

    func testUnknownSeatOrgDoesNotPublishCachedOrgEmptyReportAsZero() async {
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody())),
            ("/organizations/oldorg/settings/billing/ai_credit/usage", ok(["usageItems": []])),
            ("/user/orgs", okJSON([["login": "oldorg"]]))
        ])
        let defaults = freshDefaults()
        defaults.set("oldorg", forKey: CopilotProvider.billingOrgDefaultsKey)
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.line(label: "Organization Usage")?.label, "Organization Usage")
        XCTAssertNil(snapshot.line(label: "Org Credits"))
        XCTAssertNil(snapshot.line(label: "Org Spend"))
        XCTAssertNil(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey))
        XCTAssertTrue(http.requests.contains { $0.url.path == "/user/orgs" })
    }

    func testDiscoveryUsesAccessibleEmptyReportAsZeroUsage() async {
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody(seatOrgs: ["acme"]))),
            ("/organizations/acme/settings/billing/ai_credit/usage", ok(["usageItems": []])),
            ("/graphql", ok(makeEnterpriseMembershipBody(enterprises: [])))
        ])
        let defaults = freshDefaults()
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertEqual(orgCount(snapshot.lines, "Org Credits"), 0)
        XCTAssertEqual(orgDollars(snapshot.lines, "Org Spend"), 0)
        XCTAssertNil(snapshot.line(label: "Organization Usage"))
        // Discovery answered (no owning enterprise), so this zero is verified — no warning.
        XCTAssertNil(snapshot.warning)
        XCTAssertNil(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey))
        XCTAssertFalse(http.requests.contains { $0.url.absoluteString.contains("/user/orgs") })
        XCTAssertTrue(http.requests.contains { $0.url.path == "/graphql" })
    }

    func testAssociatedEmptyDoesNotHideAnotherUnreadableOrganization() async {
        let forbidden = HTTPResponse(statusCode: 403, headers: [:], body: Data())
        let http = routedClient([
            (
                "/copilot_internal/user",
                ok(makeBusinessPlaceholderBody(seatOrgs: ["empty-org", "blocked-org"]))
            ),
            ("/organizations/empty-org/settings/billing/ai_credit/usage", ok(["usageItems": []])),
            ("/organizations/blocked-org/settings/billing/ai_credit/usage", forbidden),
            ("/graphql", ok(makeEnterpriseMembershipBody(enterprises: [])))
        ])
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.line(label: "Organization Usage")?.label, "Organization Usage")
        XCTAssertNil(snapshot.line(label: "Org Credits"))
    }

    func testEnterpriseEmptyDoesNotHideAnotherUnreadableTarget() async {
        let notFound = HTTPResponse(statusCode: 404, headers: [:], body: Data())
        let forbidden = HTTPResponse(statusCode: 403, headers: [:], body: Data())
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/copilot_internal/user":
                return ok(makeBusinessPlaceholderBody(seatOrgs: ["acme"]))
            case "/organizations/acme/settings/billing/ai_credit/usage":
                return notFound
            case "/graphql":
                return ok(makeEnterpriseMembershipBody(enterprises: [
                    ("empty-enterprise", ["acme"]),
                    ("blocked-enterprise", ["acme"])
                ]))
            case "/enterprises/empty-enterprise/settings/billing/ai_credit/usage":
                return ok(["usageItems": []])
            case "/enterprises/blocked-enterprise/settings/billing/ai_credit/usage":
                return forbidden
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.line(label: "Organization Usage")?.label, "Organization Usage")
        XCTAssertNil(snapshot.line(label: "Org Credits"))
    }

    func testUnassociatedEmptyOrgDoesNotBecomeSeatUsage() async {
        // The Copilot response identifies `seatorg` as the seat source. The user can read unrelated
        // org billing but not seatorg billing, so unrelated's empty report must never become zero totals.
        let forbidden = HTTPResponse(statusCode: 403, headers: [:], body: Data())
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody(seatOrgs: ["seatorg"]))),
            ("/user/orgs", okJSON([["login": "unrelated"], ["login": "seatorg"]])),
            ("/organizations/unrelated/settings/billing/ai_credit/usage", ok(["usageItems": []])),
            ("/organizations/seatorg/settings/billing/ai_credit/usage", forbidden)
        ])
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.line(label: "Organization Usage")?.label, "Organization Usage")
        XCTAssertNil(snapshot.line(label: "Org Credits"))
        XCTAssertFalse(http.requests.contains { $0.url.absoluteString.contains("/user/orgs") })
        XCTAssertFalse(http.requests.contains { $0.url.path.contains("/organizations/unrelated/") })
    }

    func testUnassociatedEmptyFallbackIsNotAuthoritative() async {
        // Older Copilot responses may lack a seat-org signal. In that fallback mode, positive Copilot
        // usage can identify an org, but an arbitrary accessible empty report cannot.
        let forbidden = HTTPResponse(statusCode: 403, headers: [:], body: Data())
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody())),
            ("/user/orgs", okJSON([["login": "unrelated"], ["login": "seatorg"]])),
            ("/organizations/unrelated/settings/billing/ai_credit/usage", ok(["usageItems": []])),
            ("/organizations/seatorg/settings/billing/ai_credit/usage", forbidden)
        ])
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.line(label: "Organization Usage")?.label, "Organization Usage")
        XCTAssertNil(snapshot.line(label: "Org Credits"))
    }

    func testDiscoveryPrefersActualUsageOverEarlierAccessibleEmptyOrg() async {
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody())),
            ("/user/orgs", okJSON([["login": "emptyorg"], ["login": "acme"]])),
            ("/organizations/emptyorg/settings/billing/ai_credit/usage", ok(makeOtherAICreditBody())),
            ("/organizations/acme/settings/billing/ai_credit/usage", ok(makeOrgSummaryBody()))
        ])
        let defaults = freshDefaults()
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertEqual(orgCount(snapshot.lines, "Org Credits") ?? -1, 298.698546, accuracy: 0.0001)
        XCTAssertEqual(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey), "acme")
    }

    func testEvictsStaleCachedOrgAndReprobes() async {
        // The cached org answers without Copilot usage (e.g. the user changed orgs) — it must be
        // forgotten and discovery re-run.
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody())),
            ("/organizations/oldorg/settings/billing/ai_credit/usage", HTTPResponse(statusCode: 404, headers: [:], body: Data())),
            ("/user/orgs", okJSON([["login": "acme"]])),
            ("/organizations/acme/settings/billing/ai_credit/usage", ok(makeOrgSummaryBody()))
        ])
        let defaults = freshDefaults()
        defaults.set("oldorg", forKey: CopilotProvider.billingOrgDefaultsKey)
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertNotNil(orgCount(snapshot.lines, "Org Credits"))
        XCTAssertEqual(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey), "acme")
    }

    func testDiscoveryKeepsProbingPastAFailingOrg() async {
        // One org's billing endpoint having an outage (5xx) must not abort discovery — the next org's
        // usage should still be found and cached.
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody())),
            ("/user/orgs", okJSON([["login": "brokenorg"], ["login": "acme"]])),
            ("/organizations/brokenorg/settings/billing/ai_credit/usage", HTTPResponse(statusCode: 503, headers: [:], body: Data())),
            ("/organizations/acme/settings/billing/ai_credit/usage", ok(makeOrgSummaryBody()))
        ])
        let defaults = freshDefaults()
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertNotNil(orgCount(snapshot.lines, "Org Credits"))
        XCTAssertEqual(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey), "acme")
    }

    func testTransientBillingFailureKeepsCachedOrgAndFailsRefresh() async {
        // A 5xx from the cached org's billing endpoint is a brief outage, not a stale org: the cache
        // must survive (no re-discovery), and the refresh fails so the store keeps the last-good
        // snapshot instead of replacing it with a placeholder.
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody())),
            ("/organizations/acme/settings/billing/ai_credit/usage", HTTPResponse(statusCode: 503, headers: [:], body: Data()))
        ])
        let defaults = freshDefaults()
        defaults.set("acme", forKey: CopilotProvider.billingOrgDefaultsKey)
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertTrue(snapshot.lines.contains { $0.isError })
        XCTAssertNil(snapshot.line(label: "Organization Usage"))
        XCTAssertEqual(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey), "acme")
        XCTAssertFalse(http.requests.contains { $0.url.absoluteString.contains("/user/orgs") })
    }

    func testRateLimitedBilling403KeepsCachedOrgAndFailsRefresh() async {
        let rateLimited = HTTPResponse(
            statusCode: 403,
            headers: ["x-ratelimit-remaining": "0"],
            body: Data()
        )
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody())),
            ("/organizations/acme/settings/billing/ai_credit/usage", rateLimited)
        ])
        let defaults = freshDefaults()
        defaults.set("acme", forKey: CopilotProvider.billingOrgDefaultsKey)
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertTrue(snapshot.lines.contains { $0.isError })
        XCTAssertNil(snapshot.line(label: "Organization Usage"))
        XCTAssertEqual(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey), "acme")
        XCTAssertFalse(http.requests.contains { $0.url.absoluteString.contains("/user/orgs") })
    }

    func testRateLimitedOrgList403FailsRefreshInsteadOfReplacingData() async {
        let rateLimited = HTTPResponse(
            statusCode: 403,
            headers: ["retry-after": "60"],
            body: Data()
        )
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody())),
            ("/user/orgs", rateLimited)
        ])
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        XCTAssertTrue(snapshot.lines.contains { $0.isError })
        XCTAssertNil(snapshot.line(label: "Organization Usage"))
        XCTAssertNil(snapshot.line(label: "Org Credits"))
    }

    func testPersonalPaidAccountMakesNoOrgCalls() async {
        let http = routedClient([
            ("/copilot_internal/user", ok(makePaidBody()))
        ])
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        _ = await provider.refresh()

        XCTAssertEqual(http.requests.count, 1)
    }

    private func makeOrgProvider(http: RoutingHTTPClient, defaults: UserDefaults) -> CopilotProvider {
        CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: http),
            orgBillingClient: CopilotOrgBillingClient(http: http),
            defaults: defaults
        )
    }

    private func freshDefaults() -> UserDefaults {
        let suiteName = "CopilotProviderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func editorTokenStore() -> CopilotAuthStore {
        CopilotAuthStore(
            files: FakeFiles([CopilotAuthStore.editorAppsPath: #"{ "github.com": { "oauth_token": "gho_editor" } }"#]),
            keychain: FakeKeychain()
        )
    }

    private func editorAndGhTokenStore() -> CopilotAuthStore {
        let wrappedBillingToken = "go-keyring-base64:"
            + Data("gho_billing".utf8).base64EncodedString()
        return CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.editorAppsPath: #"{ "github.com": { "oauth_token": "gho_editor" } }"#
            ]),
            keychain: FakeKeychain(wrappedBillingToken)
        )
    }
}

// MARK: - Helpers

/// A `RoutingHTTPClient` answering with the first response whose URL-substring key matches; unmatched
/// URLs 404.
private func routedClient(_ routes: [(substring: String, response: HTTPResponse)]) -> RoutingHTTPClient {
    RoutingHTTPClient { request in
        routes.first(where: { request.url.absoluteString.contains($0.substring) })?.response
            ?? HTTPResponse(statusCode: 404, headers: [:], body: Data())
    }
}

/// The exact `/copilot_internal/user` shape of an org-managed Copilot Business seat from issue #839:
/// plan is reported but every quota bucket is a zero-entitlement token-based-billing placeholder.
/// Crucially, the premium bucket carries `overage_permitted: true` — the field that used to sneak an
/// "Extra Usage: 0" row into the mapped lines and block the org-billing fallback.
private func makeBusinessPlaceholderBody(seatOrgs: [String]? = nil) -> [String: Any] {
    func bucket(_ id: String, overagePermitted: Bool) -> [String: Any] {
        [
            "overage_count": 0, "overage_entitlement": 0, "overage_permitted": overagePermitted,
            "percent_remaining": 100.0, "quota_id": id, "quota_remaining": 0.0, "unlimited": true,
            "has_quota": true, "quota_reset_at": 0, "token_based_billing": true,
            "remaining": 0, "entitlement": 0
        ]
    }
    var body: [String: Any] = [
        "copilot_plan": "business",
        "token_based_billing": true,
        "quota_snapshots": [
            "chat": bucket("chat", overagePermitted: false),
            "completions": bucket("completions", overagePermitted: false),
            "premium_interactions": bucket("premium_interactions", overagePermitted: true)
        ]
    ]
    if let seatOrgs {
        body["organization_login_list"] = seatOrgs
    }
    return body
}

/// The org billing usage summary from issue #839: one Copilot AI-unit item, fully covered by the
/// included credits.
private func makeOrgSummaryBody() -> [String: Any] {
    [
        "timePeriod": ["year": 2026, "month": 7],
        "organization": "acme",
        "usageItems": [
            [
                "product": "Copilot",
                "sku": "copilot_ai_unit",
                "unitType": "ai-units",
                "pricePerUnit": 0.01,
                "grossQuantity": 298.698546,
                "grossAmount": 2.98698546,
                "discountQuantity": 298.698546,
                "discountAmount": 2.98698546,
                "netQuantity": 0.0,
                "netAmount": 0.0
            ]
        ]
    ]
}

private func makeOtherAICreditBody() -> [String: Any] {
    [
        "usageItems": [
            [
                "product": "GitHub Models",
                "sku": "Models AI Credits",
                "unitType": "credits",
                "grossQuantity": 25,
                "netAmount": 0.25
            ]
        ]
    ]
}

private func makeEnterpriseMembershipBody(
    enterprises: [(slug: String, organizations: [String])],
    nextEnterpriseCursor: String? = nil,
    nextOrganizationCursors: [String: String] = [:]
) -> [String: Any] {
    [
        "data": [
            "viewer": [
                "enterprises": [
                    "nodes": enterprises.map { enterprise in
                        [
                            "slug": enterprise.slug,
                            "organizations": [
                                "nodes": enterprise.organizations.map { ["login": $0] },
                                "pageInfo": makePageInfo(
                                    nextCursor: nextOrganizationCursors[enterprise.slug]
                                )
                            ]
                        ]
                    },
                    "pageInfo": makePageInfo(nextCursor: nextEnterpriseCursor)
                ]
            ]
        ]
    ]
}

private func makeEnterpriseOrganizationBody(
    organizations: [String],
    nextCursor: String? = nil
) -> [String: Any] {
    [
        "data": [
            "enterprise": [
                "organizations": [
                    "nodes": organizations.map { ["login": $0] },
                    "pageInfo": makePageInfo(nextCursor: nextCursor)
                ]
            ]
        ]
    ]
}

private func makePageInfo(nextCursor: String?) -> [String: Any] {
    [
        "hasNextPage": nextCursor != nil,
        "endCursor": nextCursor as Any? ?? NSNull()
    ]
}

private func graphQLVariables(_ request: HTTPRequest) -> [String: Any] {
    guard
        let body = request.body,
        let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
        let variables = payload["variables"] as? [String: Any]
    else {
        return [:]
    }
    return variables
}

private func okJSON(_ array: [[String: Any]]) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: try! JSONSerialization.data(withJSONObject: array))
}

private func orgCount(_ lines: [MetricLine], _ label: String, valueLabel: String = "credits") -> Double? {
    value(lines, label: label, kind: .count, valueLabel: valueLabel)
}

private func orgDollars(_ lines: [MetricLine], _ label: String) -> Double? {
    value(lines, label: label, kind: .dollars)
}

private func value(
    _ lines: [MetricLine],
    label: String,
    kind: MetricKind,
    valueLabel: String? = nil
) -> Double? {
    guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return values.first {
        $0.kind == kind && (valueLabel == nil || $0.label == valueLabel)
    }?.number
}

private func makePaidBody() -> [String: Any] {
    [
        "copilot_plan": "pro",
        "quota_reset_date": "2099-01-15T00:00:00Z",
        "quota_snapshots": [
            "premium_interactions": ["entitlement": 300, "remaining": 123, "percent_remaining": 41, "quota_id": "premium"],
            "chat": ["entitlement": 1000, "remaining": 950, "percent_remaining": 95, "quota_id": "chat"]
        ]
    ]
}

private func ok(_ body: [String: Any]) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: try! JSONSerialization.data(withJSONObject: body))
}

private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
    guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return (used, limit, resetsAt, periodDurationMs)
}

private func countValue(_ lines: [MetricLine], _ label: String) -> Double? {
    guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return values.first?.number
}

/// Records which read mode each Keychain call used, so tests can prove automatic loads stay on the
/// prompt-free in-process path and only manual loads use the prompt-capable one. Conforms to the
/// full writing protocol (with a no-op write) so writer stores like Codex/Cursor accept it too.
final class ReadModeTrackingKeychain: KeychainReading, @unchecked Sendable {
    private let lock = NSLock()
    private let value: String
    private var plain = 0
    private var nonInteractive = 0
    private var interactive = 0

    init(value: String) {
        self.value = value
    }

    var plainReads: Int { lock.withLock { plain } }
    var nonInteractiveReads: Int { lock.withLock { nonInteractive } }
    var interactiveReads: Int { lock.withLock { interactive } }

    func readGenericPassword(service: String) throws -> String? {
        lock.withLock { plain += 1 }
        return value
    }

    func readGenericPassword(service: String, account: String) throws -> String? {
        lock.withLock { plain += 1 }
        return value
    }

    func readGenericPasswordWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        lock.withLock { nonInteractive += 1 }
        return .value(value)
    }

    func readGenericPasswordWithoutUserInteraction(service: String, account: String) -> NonInteractiveKeychainRead {
        lock.withLock { nonInteractive += 1 }
        return .value(value)
    }

    func readGenericPasswordForCurrentUserWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        lock.withLock { nonInteractive += 1 }
        return .value(value)
    }

    func readGenericPasswordAllowingUserInteraction(service: String) throws -> String? {
        lock.withLock { interactive += 1 }
        return value
    }

    func readGenericPasswordAllowingUserInteraction(service: String, account: String) throws -> String? {
        lock.withLock { interactive += 1 }
        return value
    }

    func readGenericPasswordForCurrentUserAllowingUserInteraction(service: String) throws -> String? {
        lock.withLock { interactive += 1 }
        return value
    }

    /// Attributes-only probes are not secret reads — model them explicitly so they don't fall
    /// through the protocol default onto the subprocess path this fake asserts against.
    func genericPasswordExists(service: String) -> Bool? {
        true
    }

    func genericPasswordExists(service: String, account: String) -> Bool? {
        true
    }

    func writeGenericPassword(service: String, value: String) throws {}
}

/// A Keychain holding a gh item Runway isn't authorized to read prompt-free: non-interactive reads
/// report `.unavailable` while the attributes-only existence probe still confirms the item. An
/// interactive read models the user approving the prompt.
/// The item could not be read for a reason approval cannot fix: the recorded category says the
/// failure was NOT an ACL denial.
private final class UnreadableItemKeychain: KeychainReading, @unchecked Sendable {
    func readGenericPassword(service: String) throws -> String? {
        XCTFail("the subprocess-style read path must not be used")
        return nil
    }

    func readGenericPasswordWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        .unavailable
    }

    func readGenericPasswordWithoutUserInteraction(service: String, account: String) -> NonInteractiveKeychainRead {
        .unavailable
    }

    func lastReadFailure(service: String) -> KeychainReadFailure? {
        .unreadable
    }

    func genericPasswordExists(service: String) -> Bool? {
        XCTFail("the recorded category answers this; no probe should be needed")
        return nil
    }
}

private final class UnauthorizedItemKeychain: KeychainReading, @unchecked Sendable {
    private let lock = NSLock()
    private let approvedValue: String?
    private var interactive = 0

    init(approvedValue: String? = nil) {
        self.approvedValue = approvedValue
    }

    var interactiveReads: Int { lock.withLock { interactive } }

    func readGenericPassword(service: String) throws -> String? {
        XCTFail("the subprocess-style read path must not be used")
        return nil
    }

    func readGenericPasswordWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        .unavailable
    }

    func readGenericPasswordWithoutUserInteraction(service: String, account: String) -> NonInteractiveKeychainRead {
        .unavailable
    }

    func readGenericPasswordAllowingUserInteraction(service: String) throws -> String? {
        lock.withLock { interactive += 1 }
        return approvedValue
    }

    func readGenericPasswordAllowingUserInteraction(service: String, account: String) throws -> String? {
        lock.withLock { interactive += 1 }
        return approvedValue
    }

    func genericPasswordExists(service: String) -> Bool? {
        true
    }
}

/// Models two `gh:github.com` items: the intended account's item is protected, while a different
/// account's item would be readable through the account-less lookup. Tests use it to prove the load
/// never crosses accounts.
private final class CrossAccountKeychain: KeychainReading, @unchecked Sendable {
    private let otherAccountsValue: String

    init(otherAccountsValue: String) {
        self.otherAccountsValue = otherAccountsValue
    }

    func readGenericPassword(service: String) throws -> String? {
        XCTFail("the subprocess-style read path must not be used")
        return nil
    }

    func readGenericPasswordWithoutUserInteraction(service: String, account: String) -> NonInteractiveKeychainRead {
        .unavailable
    }

    func readGenericPasswordWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        .value(otherAccountsValue)
    }

    func genericPasswordExists(service: String) -> Bool? {
        true
    }

    func genericPasswordExists(service: String, account: String) -> Bool? {
        true
    }
}

/// Reads are unavailable AND the existence probe itself fails (`nil`) — the locked-keychain shape,
/// where item existence is genuinely unknown.
private final class IndeterminateKeychain: KeychainReading, @unchecked Sendable {
    func readGenericPassword(service: String) throws -> String? {
        XCTFail("the subprocess-style read path must not be used")
        return nil
    }

    func readGenericPasswordWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        .unavailable
    }

    func readGenericPasswordWithoutUserInteraction(service: String, account: String) -> NonInteractiveKeychainRead {
        .unavailable
    }

    func genericPasswordExists(service: String) -> Bool? {
        nil
    }

    func genericPasswordExists(service: String, account: String) -> Bool? {
        nil
    }
}
