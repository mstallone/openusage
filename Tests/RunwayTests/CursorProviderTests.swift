import XCTest
@testable import Runway

final class CursorAuthStoreTests: XCTestCase {
    func testExpiredSQLiteTokenYieldsToAUsableSameAccountKeychainToken() {
        // Read-only means a lapsed selected token ends the refresh, so a usable token for the SAME
        // account must win instead of reporting renewal while a working credential sits unread.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredSQLite = makeCursorJWT(sub: "auth0|same-user", exp: now.timeIntervalSince1970 - 60)
        let liveKeychain = makeCursorJWT(sub: "auth0|same-user", exp: now.timeIntervalSince1970 + 3_600)
        let store = CursorAuthStore(
            sqlite: FakeSQLite(values: [
                CursorAuthStore.accessTokenKey: expiredSQLite,
                CursorAuthStore.membershipTypeKey: "free"
            ]),
            keychain: ServiceKeychain(values: [
                CursorAuthStore.keychainAccessTokenService: liveKeychain
            ]),
            now: { now }
        )

        let state = store.loadCredentials().state

        XCTAssertEqual(state?.source, .keychain)
        XCTAssertEqual(state?.accessToken, liveKeychain)
    }

    func testExpiredPaidSQLiteLoginCanStillReachAProtectedKeychainToken() {
        // A usable paid SQLite login suppresses keychain prompts, but an EXPIRED one must not: the
        // protected item may hold this account's still-valid token, and it is the only thing that
        // can save the refresh. Automatic passes stay silent and report the approval need.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredSQLite = makeCursorJWT(sub: "auth0|same-user", exp: now.timeIntervalSince1970 - 60)
        let liveKeychain = makeCursorJWT(sub: "auth0|same-user", exp: now.timeIntervalSince1970 + 3_600)
        let keychain = ApprovableCursorKeychain(approvedValue: liveKeychain)
        let store = CursorAuthStore(
            sqlite: FakeSQLite(values: [
                CursorAuthStore.accessTokenKey: expiredSQLite,
                CursorAuthStore.membershipTypeKey: "pro"
            ]),
            keychain: keychain,
            now: { now }
        )

        // Automatic: silent, and the protected item is surfaced as needing approval.
        XCTAssertEqual(store.loadCredentials(), .keychainPermissionRequired)
        XCTAssertEqual(keychain.interactiveReads, 0)

        // Manual: the prompt is allowed, and the same-account token wins over the dead one.
        let approved = store.loadCredentials(allowKeychainInteraction: true).state
        XCTAssertEqual(approved?.source, .keychain)
        XCTAssertEqual(approved?.accessToken, liveKeychain)
        XCTAssertEqual(keychain.interactiveReads, 1)
    }

    func testExpiredSQLiteTokenNeverCrossesToADifferentAccountsKeychainToken() {
        // The same fallback must not bridge accounts: a different subject keeps SQLite selected (a
        // paid membership here), so the card reports renewal for its own account instead of
        // silently showing another account's usage.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredSQLite = makeCursorJWT(sub: "auth0|user-a", exp: now.timeIntervalSince1970 - 60)
        let otherAccount = makeCursorJWT(sub: "auth0|user-b", exp: now.timeIntervalSince1970 + 3_600)
        let store = CursorAuthStore(
            sqlite: FakeSQLite(values: [
                CursorAuthStore.accessTokenKey: expiredSQLite,
                CursorAuthStore.membershipTypeKey: "pro"
            ]),
            keychain: ServiceKeychain(values: [
                CursorAuthStore.keychainAccessTokenService: otherAccount
            ]),
            now: { now }
        )

        let state = store.loadCredentials().state

        XCTAssertEqual(state?.source, .sqlite)
        XCTAssertEqual(state?.accessToken, expiredSQLite)
    }

    func testPrefersKeychainWhenSQLiteLooksFreeAndSubjectsDiffer() {
        let sqliteToken = makeCursorJWT(sub: "google-oauth2|sqlite-user")
        let keychainToken = makeCursorJWT(sub: "auth0|keychain-user")
        let sqlite = FakeSQLite(values: [
            CursorAuthStore.accessTokenKey: sqliteToken,
            CursorAuthStore.membershipTypeKey: "free"
        ])
        let keychain = ServiceKeychain(values: [
            CursorAuthStore.keychainAccessTokenService: keychainToken
        ])
        let store = CursorAuthStore(sqlite: sqlite, keychain: keychain)

        let state = store.loadCredentials().state

        XCTAssertEqual(state?.source, .keychain)
        XCTAssertEqual(state?.accessToken, keychainToken)
    }

}

final class CursorUsageMapperTests: XCTestCase {
    func testMapsCreditsUsageBreakdownAndOnDemand() throws {
        let mapped = try CursorUsageMapper.mapUsage(
            usage: [
                "enabled": true,
                "billingCycleStart": 1_770_000_000_000,
                "billingCycleEnd": 1_772_592_000_000,
                "planUsage": [
                    "limit": 40_000,
                    "remaining": 32_000,
                    "totalPercentUsed": 20,
                    "autoPercentUsed": 12.5,
                    "apiPercentUsed": 7.5
                ],
                "spendLimitUsage": [
                    "individualLimit": 5_000,
                    "individualRemaining": 1_000
                ]
            ],
            planName: "pro plan",
            creditGrants: [
                "hasCreditGrants": true,
                "totalCents": "1000000",
                "usedCents": "264729"
            ],
            stripeBalanceCents: 991_544
        )

        XCTAssertEqual(mapped.plan, "Pro Plan")
        XCTAssertEqual(try XCTUnwrap(dollarValue(mapped.lines, "Credits")), 17268.15, accuracy: 0.001)
        XCTAssertEqual(progress(mapped.lines, "Total usage")?.used, 20)
        XCTAssertEqual(progress(mapped.lines, "Auto usage")?.used, 12.5)
        XCTAssertEqual(progress(mapped.lines, "API usage")?.used, 7.5)
        XCTAssertEqual(progress(mapped.lines, "On-demand")?.used, 40)
    }

    func testBoundedOnDemandDoesNotLetZeroSpendMaskPositiveUsage() throws {
        let mapped = try CursorUsageMapper.mapUsage(
            usage: [
                "enabled": true,
                "billingCycleStart": 1_770_000_000_000,
                "billingCycleEnd": 1_772_592_000_000,
                "planUsage": [
                    "limit": 40_000,
                    "totalPercentUsed": 20
                ],
                "spendLimitUsage": [
                    "individualLimit": 5_000,
                    "individualRemaining": 4_500,
                    "individualUsed": 0,
                    "totalSpend": 1_200
                ]
            ],
            planName: "Ultra",
            creditGrants: nil,
            stripeBalanceCents: 0
        )

        XCTAssertEqual(progress(mapped.lines, "On-demand")?.used, 12)
    }

    func testMapsSpendOnlyOnDemandAsUnboundedUsage() throws {
        let mapped = try CursorUsageMapper.mapUsage(
            usage: [
                "enabled": true,
                "billingCycleStart": 1_781_438_541_000,
                "billingCycleEnd": 1_784_030_541_000,
                "planUsage": [
                    "limit": 40_000,
                    "totalPercentUsed": 26.346,
                    "totalSpend": 52_692
                ],
                "spendLimitUsage": [
                    "individualUsed": 16_474,
                    "limitType": "user",
                    "totalSpend": 16_474
                ]
            ],
            planName: "Ultra",
            creditGrants: nil,
            stripeBalanceCents: 790_964
        )

        XCTAssertNil(progress(mapped.lines, "On-demand"))
        XCTAssertEqual(try XCTUnwrap(dollarValue(mapped.lines, "On-demand")), 164.74, accuracy: 0.001)
    }

    func testMapsRequestBasedFallback() throws {
        let mapped = try CursorUsageMapper.mapRequestBasedUsage(
            [
                "gpt-4": [
                    "numRequests": 39,
                    "maxRequestUsage": 500
                ],
                "startOfMonth": "2026-02-09T17:36:37.000Z"
            ],
            planName: "Team",
            unavailableMessage: "unavailable"
        )

        XCTAssertEqual(mapped.plan, "Team")
        XCTAssertEqual(progress(mapped.lines, "Requests")?.used, 39)
        XCTAssertEqual(progress(mapped.lines, "Requests")?.limit, 500)
        XCTAssertEqual(progress(mapped.lines, "Requests")?.periodDurationMs, CursorUsageMapper.billingPeriodMs)
    }

    func testTeamAccountEmitsDollarTotalUsageAndNoOrphanedBonusSpendLine() throws {
        // Team accounts report Total usage as a dollar meter and may carry a `bonusSpend` field. No
        // widget descriptor matches a "Bonus spend" label, so emitting one produced a line that could
        // never render. Regression: the mapper must not emit that orphaned line even when bonusSpend > 0.
        let mapped = try CursorUsageMapper.mapUsage(
            usage: [
                "enabled": true,
                "billingCycleStart": 1_770_000_000_000,
                "billingCycleEnd": 1_772_592_000_000,
                "planUsage": [
                    "limit": 40_000,
                    "totalSpend": 10_000,
                    "bonusSpend": 2_500
                ]
            ],
            planName: "Team",
            creditGrants: nil,
            stripeBalanceCents: 0
        )

        XCTAssertEqual(mapped.plan, "Team")
        let total = try XCTUnwrap(progress(mapped.lines, "Total usage"))
        XCTAssertEqual(total.used, 100, accuracy: 0.001)    // $100.00 spent (totalSpend, cents → dollars)
        XCTAssertEqual(total.limit, 400, accuracy: 0.001)   // of a $400.00 limit
        XCTAssertFalse(mapped.lines.contains { $0.label == "Bonus spend" })
    }

    func testTeamBooleanTotalSpendFallsBackToLimitMinusRemaining() throws {
        let mapped = try CursorUsageMapper.mapUsage(
            usage: [
                "enabled": true,
                "planUsage": [
                    "limit": 40_000,
                    "remaining": 32_000,
                    "totalSpend": true
                ]
            ],
            planName: "Team",
            creditGrants: nil,
            stripeBalanceCents: 0
        )

        let total = try XCTUnwrap(progress(mapped.lines, "Total usage"))
        XCTAssertEqual(total.used, 80, accuracy: 0.001)
        XCTAssertEqual(total.limit, 400, accuracy: 0.001)
    }
}

@MainActor
final class CursorProviderTests: XCTestCase {
    func testRefreshFetchesLiveCursorUsage() async {
        let accessToken = makeCursorJWT(sub: "google-oauth2|user_abc123")
        let http = RoutingHTTPClient { request in
            let url = request.url.absoluteString
            if url.contains("GetCurrentPeriodUsage") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {
                  "enabled": true,
                  "billingCycleEnd": 1772592000000,
                  "planUsage": {
                    "limit": 40000,
                    "remaining": 32000,
                    "totalPercentUsed": 20,
                    "autoPercentUsed": 12.5,
                    "apiPercentUsed": 7.5
                  },
                  "spendLimitUsage": {
                    "individualLimit": 5000,
                    "individualRemaining": 1000
                  }
                }
                """.utf8))
            }
            if url.contains("GetPlanInfo") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":"pro plan"}}"#.utf8))
            }
            if url.contains("GetCreditGrantsBalance") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"hasCreditGrants":false}"#.utf8))
            }
            if url.contains("/api/auth/stripe") {
                XCTAssertEqual(request.headers["Cookie"], "WorkosCursorSessionToken=user_abc123%3A%3A\(accessToken)")
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"customerBalance":"-50000"}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: FakeSQLite(values: [CursorAuthStore.accessTokenKey: accessToken]),
                keychain: FakeKeychain()
            ),
            usageClient: CursorUsageClient(http: http),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Pro Plan")
        XCTAssertEqual(dollarValue(snapshot.lines, "Credits") ?? -1, 500)
        XCTAssertEqual(progress(snapshot.lines, "Total usage")?.used, 20)
        XCTAssertEqual(progress(snapshot.lines, "Auto usage")?.used, 12.5)
        XCTAssertEqual(progress(snapshot.lines, "API usage")?.used, 7.5)
        XCTAssertEqual(progress(snapshot.lines, "On-demand")?.used, 40)
    }
}

private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
    guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return (used, limit, resetsAt, periodDurationMs)
}

private func dollarValue(_ lines: [MetricLine], _ label: String) -> Double? {
    guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return values.first { $0.kind == .dollars }?.number
}

private func makeCursorJWT(sub: String = "google-oauth2|user", exp: Double = 9_999_999_999) -> String {
    let payload = #"{"sub":"\#(sub)","exp":\#(exp)}"#
    let encoded = Data(payload.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
    return "a.\(encoded).c"
}

private final class FakeSQLite: SQLiteAccessing, @unchecked Sendable {
    var values: [String: String]
    var writtenValues: [String: String] = [:]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func queryValue(path: String, sql: String) throws -> String? {
        // The batched read folds matching keys into one JSON object, like sqlite's
        // `json_group_object` does.
        if sql.contains("json_group_object") {
            var object: [String: String] = [:]
            for (key, value) in values where sql.contains("'\(key)'") { object[key] = value }
            guard !object.isEmpty else { return nil }
            let data = try JSONSerialization.data(withJSONObject: object)
            return String(decoding: data, as: UTF8.self)
        }
        for (key, value) in values where sql.contains(key) {
            return value
        }
        return nil
    }

    // JSON row queries are not exercised here.
    func queryJSONRows(path: String, sql: String) throws -> String? { nil }

    func execute(path: String, sql: String) throws {
        guard let key = sqlValue(after: "(key, value) VALUES ('", in: sql),
              let value = sqlValue(after: "', '", in: sql)
        else {
            return
        }
        writtenValues[key] = value
    }

    private func sqlValue(after marker: String, in sql: String) -> String? {
        guard let start = sql.range(of: marker)?.upperBound,
              let end = sql[start...].range(of: "'")?.lowerBound
        else {
            return nil
        }
        return String(sql[start..<end]).replacingOccurrences(of: "''", with: "'")
    }
}

// RoutingHTTPClient lives in TestSupport.swift (shared, records requests).

@MainActor
final class CursorKeychainReadModeTests: XCTestCase {
    func testAutomaticKeychainLoadIsPromptFreeAndManualLoadMayPrompt() {
        // Regression for the 2026-08-03 prompt loop: Cursor's keychain items must never be read
        // through a prompt-capable path on an automatic refresh or at launch. Only a manual refresh
        // may use the interactive read (which prompts once, for Runway itself).
        let keychain = ReadModeTrackingKeychain(value: "cursor-token")
        let store = CursorAuthStore(sqlite: EmptySQLite(), keychain: keychain)

        XCTAssertEqual(store.loadCredentials().state?.accessToken, "cursor-token")
        XCTAssertEqual(keychain.interactiveReads, 0)
        XCTAssertGreaterThan(keychain.nonInteractiveReads, 0)
        XCTAssertEqual(keychain.plainReads, 0, "the subprocess-style read path must not be used")

        XCTAssertEqual(store.loadCredentials(allowKeychainInteraction: true).state?.accessToken, "cursor-token")
        XCTAssertGreaterThan(keychain.interactiveReads, 0)
        XCTAssertEqual(keychain.plainReads, 0)
    }

    func testProtectedKeychainItemsCountAsPermissionRequiredNotLoggedOut() {
        // A Cursor login stored only in protected Keychain items must be reported as
        // permission-required — a real footprint the user connects via manual refresh — never
        // silently collapsed into "not logged in".
        let store = CursorAuthStore(sqlite: EmptySQLite(), keychain: UnavailableCursorKeychain())

        XCTAssertEqual(store.loadCredentials(), .keychainPermissionRequired)
    }

    func testFreeSQLiteTokenDoesNotSilentlyBypassAProtectedKeychainLogin() {
        // The keychain (agent CLI) login can be the real paid account; with its items protected the
        // free-vs-different-subject comparison is impossible, so the load surfaces the approval need
        // instead of silently showing the free SQLite account. A paid SQLite login keeps winning.
        let sqlite = FakeSQLite(values: [
            CursorAuthStore.accessTokenKey: "sqlite-free-token",
            CursorAuthStore.membershipTypeKey: "free"
        ])
        let protected = CursorAuthStore(sqlite: sqlite, keychain: UnavailableCursorKeychain())
        XCTAssertEqual(protected.loadCredentials(), .keychainPermissionRequired)

        let paidSqlite = FakeSQLite(values: [
            CursorAuthStore.accessTokenKey: "sqlite-pro-token",
            CursorAuthStore.membershipTypeKey: "pro"
        ])
        let paid = CursorAuthStore(sqlite: paidSqlite, keychain: UnavailableCursorKeychain())
        XCTAssertEqual(paid.loadCredentials().state?.accessToken, "sqlite-pro-token")
    }

    func testManualRefreshWithAPaidSQLiteLoginNeverPromptsForStaleKeychainEntries() {
        // A paid SQLite login is returned unconditionally, so a manual refresh must not raise
        // approval dialogs for keychain entries it would then ignore.
        let sqlite = FakeSQLite(values: [
            CursorAuthStore.accessTokenKey: "sqlite-pro-token",
            CursorAuthStore.membershipTypeKey: "pro"
        ])
        let keychain = ReadModeTrackingKeychain(value: "stale-agent-token")
        let store = CursorAuthStore(sqlite: sqlite, keychain: keychain)

        let state = store.loadCredentials(allowKeychainInteraction: true).state

        XCTAssertEqual(state?.accessToken, "sqlite-pro-token")
        XCTAssertEqual(keychain.interactiveReads, 0, "keychain entries that cannot win must not prompt")
    }

}

private final class EmptySQLite: SQLiteAccessing, @unchecked Sendable {
    func queryValue(path: String, sql: String) throws -> String? { nil }
    func queryJSONRows(path: String, sql: String) throws -> String? { nil }
    func execute(path: String, sql: String) throws {}
}

/// Cursor keychain items Runway isn't authorized to read prompt-free: non-interactive reads report
/// `.unavailable` while the attributes-only existence probe still confirms the items.
private final class UnavailableCursorKeychain: KeychainReading, @unchecked Sendable {
    func readGenericPassword(service: String) throws -> String? {
        XCTFail("the subprocess-style read path must not be used")
        return nil
    }

    func readGenericPasswordWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        .unavailable
    }

    func genericPasswordExists(service: String) -> Bool? {
        true
    }

    func writeGenericPassword(service: String, value: String) throws {}
}

@MainActor
final class CursorReadOnlyCredentialTests: XCTestCase {
    func testExpiredTokenNeverRefreshesOrWritesAndReportsRenewal() async {
        // Runway is a read-only consumer of Cursor's credentials: an expired token means NO
        // token-endpoint call, NO state-database or keychain write, and a renewal notice.
        let sqlite = FakeSQLite(values: [
            CursorAuthStore.accessTokenKey: makeCursorJWT(exp: 1),
            CursorAuthStore.membershipTypeKey: "pro"
        ])
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data()))
        let provider = CursorProvider(
            authStore: CursorAuthStore(sqlite: sqlite, keychain: FakeKeychain()),
            usageClient: CursorUsageClient(http: http)
        )

        let snapshot = await provider.refresh()

        XCTAssertTrue(http.requests.isEmpty, "an expired token short-circuits before any network call")
        XCTAssertTrue(sqlite.writtenValues.isEmpty, "Cursor's state database is never written by Runway")
        XCTAssertEqual(
            snapshot.lines.compactMap { line -> String? in
                guard case .badge(_, let text, _, _) = line, line.label == "Error" else { return nil }
                return text
            }.first,
            CursorAuthError.loginRenewalRequired.localizedDescription
        )
    }

    func testUsage401ReportsRenewalWithoutARetryOrTokenEndpointCall() async {
        let sqlite = FakeSQLite(values: [
            CursorAuthStore.accessTokenKey: makeCursorJWT(),
            CursorAuthStore.membershipTypeKey: "pro"
        ])
        let http = RoutingHTTPClient { request in
            XCTAssertFalse(
                request.url.absoluteString.contains("token"),
                "the token endpoint must never be contacted"
            )
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(sqlite: sqlite, keychain: FakeKeychain()),
            usageClient: CursorUsageClient(http: http)
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(http.requests.count, 1, "no refresh-and-retry: one usage call, then renewal")
        XCTAssertEqual(
            snapshot.lines.compactMap { line -> String? in
                guard case .badge(_, let text, _, _) = line, line.label == "Error" else { return nil }
                return text
            }.first,
            CursorAuthError.loginRenewalRequired.localizedDescription
        )
    }
}

@MainActor
final class CursorPromptBoundTests: XCTestCase {
    func testDeniedAccessPromptDoesNotRaiseTheRefreshPromptToo() {
        // Approval is per item, but a denial of the first prompt means "no" — the companion item's
        // prompt must not follow in the same pass.
        let keychain = DenyingCursorKeychain()
        let store = CursorAuthStore(sqlite: EmptySQLite(), keychain: keychain)

        XCTAssertEqual(store.loadCredentials(allowKeychainInteraction: true), .keychainPermissionRequired)
        XCTAssertEqual(keychain.interactiveReads, 1, "a denial must not chain into a second prompt")
    }
}

/// Every interactive read is denied (throws); non-interactive reads report items as protected.
private final class DenyingCursorKeychain: KeychainReading, @unchecked Sendable {
    private let lock = NSLock()
    private var interactive = 0

    var interactiveReads: Int { lock.withLock { interactive } }

    func readGenericPassword(service: String) throws -> String? {
        XCTFail("the subprocess-style read path must not be used")
        return nil
    }

    func readGenericPasswordWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        .unavailable
    }

    func readGenericPasswordAllowingUserInteraction(service: String) throws -> String? {
        lock.withLock { interactive += 1 }
        throw KeychainError.readFailed("denied")
    }

    func genericPasswordExists(service: String) -> Bool? {
        true
    }
}

/// A protected Cursor keychain item that becomes readable once the user approves the prompt.
private final class ApprovableCursorKeychain: KeychainReading, @unchecked Sendable {
    private let lock = NSLock()
    private let approvedValue: String
    private var interactive = 0

    init(approvedValue: String) {
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

    func readGenericPasswordAllowingUserInteraction(service: String) throws -> String? {
        lock.withLock { interactive += 1 }
        return approvedValue
    }

    func genericPasswordExists(service: String) -> Bool? {
        true
    }
}

@MainActor
final class CursorRevokedTokenFallbackTests: XCTestCase {
    func testServerRejectionRetriesTheSameAccountKeychainTokenOnce() async {
        // An unexpired SQLite token that the server revoked (signed out elsewhere). Runway can't
        // refresh it, but the agent CLI's keychain copy for the SAME account is still live — it must
        // be tried once instead of reporting renewal while a working credential sits unread.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let revoked = makeCursorJWT(sub: "auth0|same-user", exp: now.timeIntervalSince1970 + 3_600)
        let live = makeCursorJWT(sub: "auth0|same-user", exp: now.timeIntervalSince1970 + 3_600)
        let http = RoutingHTTPClient { request in
            XCTAssertFalse(request.url.absoluteString.contains("oauth/token"), "no OAuth token-endpoint call may be made")
            guard request.headers["Authorization"]?.contains(live) == true else {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"enabled":true,"planUsage":{"limit":40000,"totalPercentUsed":20}}"#.utf8)
            )
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: FakeSQLite(values: [
                    CursorAuthStore.accessTokenKey: revoked,
                    CursorAuthStore.membershipTypeKey: "pro"
                ]),
                keychain: ServiceKeychain(values: [
                    CursorAuthStore.keychainAccessTokenService: live
                ]),
                now: { now }
            ),
            usageClient: CursorUsageClient(http: http),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(
            snapshot.lines.compactMap { line -> String? in
                guard case .badge(_, let text, _, _) = line, line.label == "Error" else { return nil }
                return text
            }.first,
            "the live same-account token should have served this refresh"
        )
    }

    func testAlternativeCredentialsNetworkFailureIsNotReportedAsRenewal() async {
        // The selected token was rejected and the same-account alternative hit a server error.
        // Telling the user to sign in again over a Cursor outage would send them down the wrong
        // path — the alternative may be perfectly valid.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let revoked = makeCursorJWT(sub: "auth0|same-user", exp: now.timeIntervalSince1970 + 3_600)
        let live = makeCursorJWT(sub: "auth0|same-user", exp: now.timeIntervalSince1970 + 3_600)
        let http = RoutingHTTPClient { request in
            guard request.headers["Authorization"]?.contains(live) == true else {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 503, headers: [:], body: Data())
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: FakeSQLite(values: [
                    CursorAuthStore.accessTokenKey: revoked,
                    CursorAuthStore.membershipTypeKey: "pro"
                ]),
                keychain: ServiceKeychain(values: [
                    CursorAuthStore.keychainAccessTokenService: live
                ]),
                now: { now }
            ),
            usageClient: CursorUsageClient(http: http),
            now: { now }
        )

        let snapshot = await provider.refresh()

        let error = snapshot.lines.compactMap { line -> String? in
            guard case .badge(_, let text, _, _) = line, line.label == "Error" else { return nil }
            return text
        }.first
        XCTAssertEqual(error, ProviderUsageErrorText.requestFailed(statusCode: 503))
        XCTAssertNotEqual(error, CursorAuthError.loginRenewalRequired.localizedDescription)
    }

    func testServerRejectionDoesNotRetryADifferentAccountsToken() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let revoked = makeCursorJWT(sub: "auth0|user-a", exp: now.timeIntervalSince1970 + 3_600)
        let otherAccount = makeCursorJWT(sub: "auth0|user-b", exp: now.timeIntervalSince1970 + 3_600)
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 401, headers: [:], body: Data()) }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: FakeSQLite(values: [
                    CursorAuthStore.accessTokenKey: revoked,
                    CursorAuthStore.membershipTypeKey: "pro"
                ]),
                keychain: ServiceKeychain(values: [
                    CursorAuthStore.keychainAccessTokenService: otherAccount
                ]),
                now: { now }
            ),
            usageClient: CursorUsageClient(http: http),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(http.requests.count, 1, "another account's token must never be tried")
        XCTAssertEqual(
            snapshot.lines.compactMap { line -> String? in
                guard case .badge(_, let text, _, _) = line, line.label == "Error" else { return nil }
                return text
            }.first,
            CursorAuthError.loginRenewalRequired.localizedDescription
        )
    }
}
