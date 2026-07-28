import XCTest
@testable import Runway

private let kimiNow = Date(timeIntervalSince1970: 1_800_000_000)
private let kimiCredentialPath = "~/.kimi-code/credentials/kimi-code.json"

// MARK: - Auth

final class KimiAuthStoreTests: XCTestCase {
    func testLoadsOfficialCredentialAndDefaultEndpoints() throws {
        let store = makeKimiAuthStore()

        let auth = try store.loadAuth()

        XCTAssertEqual(auth.token.accessToken, "access-old")
        XCTAssertEqual(auth.credentialPath, kimiCredentialPath)
        XCTAssertEqual(auth.usageURL.absoluteString, "https://api.kimi.com/coding/v1/usages")
        XCTAssertEqual(auth.refreshURL.absoluteString, "https://auth.kimi.com/api/oauth/token")
    }

    func testHonorsKimiHomeAndEndpointOverrides() throws {
        let path = "/tmp/kimi-work/credentials/kimi-code-env-31aeeb1500100059.json"
        let store = KimiAuthStore(
            environment: FakeEnvironment([
                "KIMI_CODE_HOME": "/tmp/kimi-work/",
                "KIMI_CODE_BASE_URL": "https://gateway.example.test/kimi/",
                "KIMI_CODE_OAUTH_HOST": "http://127.0.0.1:8080/"
            ]),
            files: FakeFiles([path: kimiTokenJSON()]),
            now: { kimiNow }
        )

        let auth = try store.loadAuth()

        XCTAssertEqual(auth.credentialPath, path)
        XCTAssertEqual(auth.usageURL.absoluteString, "https://gateway.example.test/kimi/usages")
        XCTAssertEqual(auth.refreshURL.absoluteString, "http://127.0.0.1:8080/api/oauth/token")
    }

    func testRejectsInsecureRemoteAndCredentialedEndpoints() {
        for endpoint in [
            "http://api.example.test",
            "https://user:password@api.example.test",
            "https://api.example.test?token=secret"
        ] {
            let store = KimiAuthStore(
                environment: FakeEnvironment(["KIMI_CODE_BASE_URL": endpoint]),
                files: FakeFiles([kimiCredentialPath: kimiTokenJSON()]),
                now: { kimiNow }
            )
            XCTAssertThrowsError(try store.loadAuth()) { error in
                XCTAssertEqual(error as? KimiAuthError, .invalidEndpoint("KIMI_CODE_BASE_URL"))
            }
        }
    }

    func testMissingMalformedAndRevokedCredentialsAreDistinct() {
        XCTAssertThrowsError(try makeKimiAuthStore(files: FakeFiles()).loadAuth()) {
            XCTAssertEqual($0 as? KimiAuthError, .notLoggedIn)
        }
        XCTAssertThrowsError(try makeKimiAuthStore(files: FakeFiles([
            kimiCredentialPath: "not-json"
        ])).loadAuth()) {
            XCTAssertEqual($0 as? KimiAuthError, .invalidCredentials)
        }
        XCTAssertThrowsError(try makeKimiAuthStore(files: FakeFiles([
            kimiCredentialPath: kimiTokenJSON(accessToken: "")
        ])).loadAuth()) {
            XCTAssertEqual($0 as? KimiAuthError, .sessionExpired)
        }
    }

    func testRefreshThresholdMatchesKimiDynamicWindow() throws {
        let store = makeKimiAuthStore()
        let token = try store.loadAuth().token

        var outside = token
        outside.expiresIn = 3_600
        outside.expiresAt = kimiNow.timeIntervalSince1970 + 1_801
        XCTAssertFalse(store.needsRefresh(outside))

        var inside = outside
        inside.expiresAt = kimiNow.timeIntervalSince1970 + 1_799
        XCTAssertTrue(store.needsRefresh(inside))

        var shortLived = outside
        shortLived.expiresIn = 120
        shortLived.expiresAt = kimiNow.timeIntervalSince1970 + 299
        XCTAssertTrue(store.needsRefresh(shortLived), "the minimum refresh window is five minutes")
    }

    func testAPIKeyAloneDoesNotMasqueradeAsSubscriptionLogin() {
        let store = KimiAuthStore(
            environment: FakeEnvironment(["KIMI_API_KEY": "sk-pay-as-you-go"]),
            files: FakeFiles(),
            now: { kimiNow }
        )

        XCTAssertFalse(store.hasUsableCredentials())
    }
}

// MARK: - Mapping

final class KimiUsageMapperTests: XCTestCase {
    func testMapsQuotaWindowsResetsAndCNYExtraUsage() throws {
        let lines = try KimiUsageMapper.map(Data(kimiUsageJSON.utf8), now: kimiNow)

        let session = try XCTUnwrap(kimiProgress(lines, "Five-Hour Usage"))
        XCTAssertEqual(session.used, 25)
        XCTAssertEqual(session.limit, 100)
        XCTAssertEqual(session.format, .percent)
        XCTAssertEqual(session.periodDurationMs, 5 * 60 * 60 * 1_000)
        XCTAssertEqual(
            session.resetsAt?.timeIntervalSince1970,
            kimiNow.addingTimeInterval(3_600).timeIntervalSince1970
        )

        let weekly = try XCTUnwrap(kimiProgress(lines, "Weekly Usage"))
        XCTAssertEqual(weekly.used, 25)
        XCTAssertEqual(weekly.periodDurationMs, 7 * 24 * 60 * 60 * 1_000)
        XCTAssertEqual(
            weekly.resetsAt?.timeIntervalSince1970,
            RunwayISO8601.date(from: "2027-01-16T08:00:00Z")?.timeIntervalSince1970
        )

        let balance = try XCTUnwrap(kimiValues(lines, "Extra Usage Balance").first)
        XCTAssertEqual(balance.number, 23.4, accuracy: 0.000_001)
        XCTAssertEqual(balance.kind, .count)
        XCTAssertEqual(balance.label, "CNY")

        let monthly = try XCTUnwrap(kimiProgress(lines, "Monthly Extra Usage"))
        XCTAssertEqual(monthly.used, 12.5)
        XCTAssertEqual(monthly.limit, 50)
        XCTAssertEqual(monthly.format, .count(suffix: "CNY"))
        XCTAssertEqual(monthly.periodDurationMs, 30 * 24 * 60 * 60 * 1_000)
    }

    func testMapsUSDUncappedExtraUsageAndMinimumPositiveCent() throws {
        let body = #"""
        {
          "boosterWallet": {
            "balance": {"type":"BOOSTER","amount":1,"amountLeft":1},
            "monthlyChargeLimitEnabled": false,
            "monthlyUsed": {"priceInCents":1234,"currency":"USD"}
          }
        }
        """#

        let lines = try KimiUsageMapper.map(Data(body.utf8), now: kimiNow)

        let balance = try XCTUnwrap(kimiValues(lines, "Extra Usage Balance").first)
        XCTAssertEqual(balance.number, 0.01)
        XCTAssertEqual(balance.kind, .dollars)
        let monthly = try XCTUnwrap(kimiValues(lines, "Monthly Extra Usage").first)
        XCTAssertEqual(monthly.number, 12.34)
        XCTAssertEqual(monthly.kind, .dollars)
    }

    func testExplicitSessionDoesNotConsumeWeeklyFallbackRow() throws {
        let body = #"""
        {
          "limits": [
            {"name":"5-hour limit","detail":{"limit":100,"used":10}},
            {"detail":{"limit":200,"used":50}}
          ]
        }
        """#

        let lines = try KimiUsageMapper.map(Data(body.utf8), now: kimiNow)

        XCTAssertEqual(try XCTUnwrap(kimiProgress(lines, "Five-Hour Usage")).used, 10)
        XCTAssertEqual(try XCTUnwrap(kimiProgress(lines, "Weekly Usage")).used, 25)
    }

    func testNumericStringsRemainingAliasAndClampingAreAccepted() throws {
        let body = #"""
        {
          "usage": {"limit":"100","remaining":"-20","reset_in":"60"},
          "limits": [{"window":{"duration":"5","timeUnit":"HOUR"},"detail":{"limit":"10","used":"20"}}]
        }
        """#

        let lines = try KimiUsageMapper.map(Data(body.utf8), now: kimiNow)

        XCTAssertEqual(try XCTUnwrap(kimiProgress(lines, "Five-Hour Usage")).used, 100)
        XCTAssertNil(kimiProgress(lines, "Weekly Usage"), "negative remaining is rejected")
    }

    func testEmptyPayloadGetsNoDataAndMalformedJSONThrows() throws {
        XCTAssertEqual(
            try KimiUsageMapper.map(Data(#"{"limits":[]}"#.utf8), now: kimiNow),
            [.noUsageData]
        )
        XCTAssertThrowsError(try KimiUsageMapper.map(Data("not-json".utf8), now: kimiNow)) {
            XCTAssertEqual($0 as? KimiUsageError, .invalidResponse)
        }
    }
}

// MARK: - Runtime

@MainActor
final class KimiProviderTests: XCTestCase {
    func testOAuthRefreshRetriesTransientStatuses() async throws {
        let counter = KimiCallCounter()
        let client = KimiUsageClient(
            http: RoutingHTTPClient { _ in
                if counter.next() < 2 {
                    return kimiJSONResponse("{}", status: 503)
                }
                return kimiJSONResponse(#"""
                {"access_token":"new","refresh_token":"rotated","expires_in":3600}
                """#)
            },
            sleep: { _ in }
        )

        let response = try await client.refreshToken(
            "old",
            url: URL(string: "https://auth.kimi.com/api/oauth/token")!
        )

        XCTAssertEqual(response.accessToken, "new")
        XCTAssertEqual(counter.count, 3)
    }

    func testFreshLoginFetchesUsageWithBearerToken() async {
        let http = RoutingHTTPClient { request in
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.url.absoluteString, "https://api.kimi.com/coding/v1/usages")
            XCTAssertEqual(request.headers["Authorization"], "Bearer access-old")
            XCTAssertEqual(request.headers["Accept"], "application/json")
            return kimiJSONResponse(kimiUsageJSON)
        }
        let provider = makeKimiProvider(http: http)

        let snapshot = await provider.refresh()

        XCTAssertNotNil(snapshot.line(label: "Five-Hour Usage"))
        XCTAssertNotNil(snapshot.line(label: "Weekly Usage"))
        XCTAssertEqual(http.requests.count, 1)
    }

    func testExpiredLoginRefreshesRotatingTokenThenFetchesAndSaves() async throws {
        let files = FakeFiles([kimiCredentialPath: kimiTokenJSON(
            expiresAt: kimiNow.timeIntervalSince1970 - 1
        )])
        let http = RoutingHTTPClient { request in
            if request.method == "POST" {
                XCTAssertEqual(request.url.absoluteString, "https://auth.kimi.com/api/oauth/token")
                XCTAssertEqual(request.headers["Content-Type"], "application/x-www-form-urlencoded")
                let body = String(decoding: request.body ?? Data(), as: UTF8.self)
                XCTAssertTrue(body.contains("client_id=\(KimiAuthStore.clientID)"))
                XCTAssertTrue(body.contains("grant_type=refresh_token"))
                XCTAssertTrue(body.contains("refresh_token=refresh-old"))
                return kimiJSONResponse(#"""
                {
                  "access_token":"access-new",
                  "refresh_token":"refresh-new",
                  "expires_in":3600,
                  "scope":"openid",
                  "token_type":"Bearer"
                }
                """#)
            }
            XCTAssertEqual(request.headers["Authorization"], "Bearer access-new")
            return kimiJSONResponse(kimiUsageJSON)
        }
        let provider = makeKimiProvider(http: http, files: files)

        let snapshot = await provider.refresh()

        XCTAssertEqual(http.requests.map(\.method), ["POST", "GET"])
        let saved = try JSONDecoder().decode(
            KimiOAuthToken.self,
            from: Data(try XCTUnwrap(files.files[kimiCredentialPath]).utf8)
        )
        XCTAssertEqual(saved.accessToken, "access-new")
        XCTAssertEqual(saved.refreshToken, "refresh-new")
        XCTAssertEqual(saved.expiresAt, kimiNow.timeIntervalSince1970 + 3_600)
    }

    func test401RetriesOnlyWhenAnotherProcessRotatedCredential() async {
        let files = FakeFiles([kimiCredentialPath: kimiTokenJSON()])
        let http = RoutingHTTPClient { request in
            if request.headers["Authorization"] == "Bearer access-old" {
                files.files[kimiCredentialPath] = kimiTokenJSON(
                    accessToken: "access-new",
                    refreshToken: "refresh-new"
                )
                return kimiJSONResponse("{}", status: 401)
            }
            XCTAssertEqual(request.headers["Authorization"], "Bearer access-new")
            return kimiJSONResponse(kimiUsageJSON)
        }
        let provider = makeKimiProvider(http: http, files: files)

        let snapshot = await provider.refresh()

        XCTAssertEqual(http.requests.count, 2)
    }

    func testMissingCredentialsAreDetectedWithoutNetwork() async {
        let http = RoutingHTTPClient { _ in
            XCTFail("missing credentials must not call the network")
            return kimiJSONResponse("{}")
        }
        let provider = makeKimiProvider(http: http, files: FakeFiles())

        let hasCredentials = await provider.hasLocalCredentials()
        _ = await provider.refresh()
        XCTAssertFalse(hasCredentials)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testDescriptorsAndCatalogOrderAreStable() {
        let provider = KimiProvider()
        XCTAssertEqual(provider.widgetDescriptors.map(\.id), [
            "kimi.session", "kimi.weekly", "kimi.extraBalance", "kimi.extraMonthly"
        ])
        XCTAssertEqual(
            provider.widgetDescriptors.flatMap(\.limitResources).map(\.key),
            ["session", "weekly"]
        )

        let ids = ProviderCatalog.make(
            defaults: UserDefaults(suiteName: "KimiProviderTests.\(UUID().uuidString)")!
        ).map(\.provider.id)
        let grok = ids.firstIndex(of: "grok")
        let kimi = ids.firstIndex(of: "kimi")
        let openCode = ids.firstIndex(of: "opencode")
        XCTAssertEqual(kimi, grok.map { $0 + 1 })
        XCTAssertEqual(openCode, kimi.map { $0 + 1 })
    }
}

private struct ImmediateKimiRefreshLock: KimiRefreshLocking {
    func acquire(
        homeDirectory: String,
        credentialName: String
    ) async throws -> KimiRefreshLockLease {
        KimiRefreshLockLease()
    }
}

private final class KimiCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        defer { value += 1 }
        return value
    }
}

private func makeKimiAuthStore(files: FakeFiles? = nil) -> KimiAuthStore {
    KimiAuthStore(
        environment: FakeEnvironment(),
        files: files ?? FakeFiles([kimiCredentialPath: kimiTokenJSON()]),
        now: { kimiNow }
    )
}

@MainActor
private func makeKimiProvider(
    http: RoutingHTTPClient,
    files: FakeFiles = FakeFiles([kimiCredentialPath: kimiTokenJSON()])
) -> KimiProvider {
    KimiProvider(
        authStore: KimiAuthStore(environment: FakeEnvironment(), files: files, now: { kimiNow }),
        usageClient: KimiUsageClient(http: http),
        refreshLock: ImmediateKimiRefreshLock(),
        now: { kimiNow }
    )
}

private func kimiTokenJSON(
    accessToken: String = "access-old",
    refreshToken: String = "refresh-old",
    expiresAt: Double = kimiNow.timeIntervalSince1970 + 7_200
) -> String {
    #"""
    {
      "access_token":"\#(accessToken)",
      "refresh_token":"\#(refreshToken)",
      "expires_at":\#(expiresAt),
      "expires_in":3600,
      "scope":"openid",
      "token_type":"Bearer"
    }
    """#
}

private func kimiJSONResponse(_ body: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(statusCode: status, headers: [:], body: Data(body.utf8))
}

private func kimiProgress(
    _ lines: [MetricLine],
    _ label: String
) -> (used: Double, limit: Double, format: ProgressFormat, resetsAt: Date?, periodDurationMs: Int?)? {
    guard case .progress(
        _, let used, let limit, let format, let resetsAt, let periodDurationMs, _
    ) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return (used, limit, format, resetsAt, periodDurationMs)
}

private func kimiValues(_ lines: [MetricLine], _ label: String) -> [MetricValue] {
    guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
        return []
    }
    return values
}

private let kimiUsageJSON = #"""
{
  "usage": {
    "limit": "1000",
    "used": "250",
    "resetAt": "2027-01-16T08:00:00Z"
  },
  "limits": [
    {
      "window": {"duration": 300, "timeUnit": "MINUTE"},
      "detail": {"limit": 200, "remaining": 150, "reset_in": 3600}
    }
  ],
  "boosterWallet": {
    "balance": {"type":"BOOSTER","amount":5000000000,"amountLeft":2340000000},
    "monthlyChargeLimitEnabled": true,
    "monthlyChargeLimit": {"priceInCents":5000,"currency":"CNY"},
    "monthlyUsed": {"priceInCents":1250,"currency":"CNY"}
  }
}
"""#
