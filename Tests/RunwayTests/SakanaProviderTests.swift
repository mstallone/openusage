import XCTest
@testable import Runway

@MainActor
final class SakanaProviderTests: XCTestCase {
    private let now = RunwayISO8601.date(from: "2026-07-25T12:00:00.000Z")!
    private let token = String(repeating: "browser-session-", count: 4)

    func testBillingFlightPayloadMapsBothQuotaWindowsAndPlan() throws {
        let response = billingResponse(status: [
            "window_usage": [
                "plan": "pro",
                "usage_percent": 0.0005125,
                "reset_at": "2026-07-26T11:39:23Z"
            ],
            "weekly_usage": [
                "plan": "pro",
                "usage_percent": 79.99969195652173,
                "reset_at": "2026-07-27T00:00:00Z"
            ]
        ])

        let mapped = try SakanaUsageMapper.mapBilling(response)

        XCTAssertEqual(mapped.plan, "Pro")
        let session = progress(mapped.lines, "Five-Hour Usage")
        XCTAssertEqual(session?.used ?? -1, 0.0005125, accuracy: 0.000_000_1)
        XCTAssertEqual(session?.limit, 100)
        XCTAssertEqual(session?.periodDurationMs, 18_000_000)
        XCTAssertEqual(
            session?.resetsAt,
            RunwayISO8601.date(from: "2026-07-26T11:39:23Z")
        )
        let weekly = progress(mapped.lines, "Weekly Usage")
        XCTAssertEqual(weekly?.used ?? -1, 79.99969195652173, accuracy: 0.000_000_1)
        XCTAssertEqual(weekly?.periodDurationMs, 604_800_000)
    }

    func testFlightDecoderHandlesMultiplePushesAndParenthesisInsideString() throws {
        let status: [String: Any] = [
            "window_usage": [
                "plan": "pro) tier",
                "usage_percent": 12.5,
                "reset_at": "2026-07-26T11:39:23Z"
            ],
            "weekly_usage": NSNull()
        ]
        let payload = try flightPayload(status: status)
        let split = payload.index(payload.startIndex, offsetBy: payload.count / 2)
        let html = try flightHTML(strings: [
            String(payload[..<split]),
            String(payload[split...])
        ])

        let mapped = try SakanaUsageMapper.mapBilling(HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(html.utf8)
        ))

        XCTAssertEqual(mapped.plan, "Pro) Tier")
        XCTAssertEqual(progress(mapped.lines, "Five-Hour Usage")?.used, 12.5)
        XCTAssertEqual(progress(mapped.lines, "Weekly Usage")?.used, 0)
        XCTAssertNil(progress(mapped.lines, "Weekly Usage")?.resetsAt)
    }

    func testPercentagesAreClampedAtSystemBoundary() throws {
        let response = billingResponse(status: [
            "window_usage": ["plan": "pro", "usage_percent": -5],
            "weekly_usage": ["plan": "pro", "usage_percent": 150]
        ])

        let mapped = try SakanaUsageMapper.mapBilling(response)

        XCTAssertEqual(progress(mapped.lines, "Five-Hour Usage")?.used, 0)
        XCTAssertEqual(progress(mapped.lines, "Weekly Usage")?.used, 100)
    }

    func testExplicitlyEmptyQuotaWindowsMapToZeroUsage() throws {
        let response = billingResponse(status: [
            "window_usage": NSNull(),
            "weekly_usage": NSNull()
        ])

        let mapped = try SakanaUsageMapper.mapBilling(response)

        XCTAssertNil(mapped.plan)
        XCTAssertEqual(mapped.lines.count, 2)
        XCTAssertEqual(progress(mapped.lines, "Five-Hour Usage")?.used, 0)
        XCTAssertNil(progress(mapped.lines, "Five-Hour Usage")?.resetsAt)
        XCTAssertEqual(progress(mapped.lines, "Weekly Usage")?.used, 0)
        XCTAssertNil(progress(mapped.lines, "Weekly Usage")?.resetsAt)
    }

    func testMissingOrMalformedConsoleContractFailsLoudly() {
        let missingQuotaKey = billingResponse(status: [
            "window_usage": NSNull()
        ]).body
        let malformedQuotaRow = billingResponse(status: [
            "window_usage": ["plan": "pro"],
            "weekly_usage": NSNull()
        ]).body
        for body in [
            Data("<html><script>self.__next_f.push([1,\"no quota\"])</script></html>".utf8),
            Data("<html><script>self.__next_f.push(not-json)</script></html>".utf8),
            missingQuotaKey,
            malformedQuotaRow
        ] {
            XCTAssertThrowsError(try SakanaUsageMapper.mapBilling(HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: body
            ))) {
                XCTAssertEqual($0 as? SakanaUsageError, .invalidResponse)
            }
        }
    }

    func testSessionValidationRejectsLoggedOutAndExpiredAuthJSResponses() {
        let loggedOut = HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        let expired = HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"user":{"id":"user"},"expires":"2026-07-25T11:59:59Z"}"#.utf8)
        )

        for response in [loggedOut, expired] {
            XCTAssertThrowsError(try SakanaUsageMapper.validateSession(response, now: now)) {
                XCTAssertEqual($0 as? SakanaAuthError, .sessionExpired)
            }
        }
    }

    func testUsageClientSendsSessionOnlyAsCookieToExactConsoleRoutes() async throws {
        let http = SakanaRecordingHTTPClient { request in
            HTTPResponse(statusCode: 200, headers: [:], body: Data())
        }
        let client = SakanaUsageClient(http: http)

        _ = try await client.fetchSession(token: token)
        _ = try await client.fetchBilling(token: token)

        XCTAssertEqual(http.requests.map(\.url), [
            SakanaUsageClient.sessionURL, SakanaUsageClient.billingURL
        ])
        XCTAssertEqual(http.requests.map(\.method), ["GET", "GET"])
        XCTAssertEqual(http.requests.map { $0.headers["Cookie"] }, [
            "\(SakanaAuthStore.cookieName)=\(token)",
            "\(SakanaAuthStore.cookieName)=\(token)"
        ])
        XCTAssertEqual(http.requests.map { $0.headers["Accept"] }, [
            "application/json", "text/html"
        ])
        XCTAssertTrue(http.requests.allSatisfy { $0.headers["Authorization"] == nil })
    }

    func testProviderRefreshUsesBrowserSessionAndReturnsBothMeters() async {
        let authStore = plaintextAuthStore(token: token)
        let current = now
        let billing = billingResponse(status: [
            "window_usage": ["plan": "pro", "usage_percent": 10],
            "weekly_usage": ["plan": "pro", "usage_percent": 80]
        ])
        let http = SakanaRecordingHTTPClient { request in
            if request.url == SakanaUsageClient.sessionURL {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"user":{"id":"user"},"expires":"2026-08-25T12:00:00Z"}"#.utf8)
                )
            }
            return billing
        }
        let provider = SakanaProvider(
            authStore: authStore,
            usageClient: SakanaUsageClient(http: http),
            logUsageScanner: emptyLogScanner(),
            now: { current }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(progress(snapshot.lines, "Five-Hour Usage")?.used, 10)
        XCTAssertEqual(progress(snapshot.lines, "Weekly Usage")?.used, 80)
        XCTAssertEqual(http.requests.count, 2)
    }

    func testProviderRefreshTreatsExplicitlyEmptyQuotaAsHealthy() async {
        let current = now
        let billing = billingResponse(status: [
            "window_usage": NSNull(),
            "weekly_usage": NSNull()
        ])
        let http = SakanaRecordingHTTPClient { request in
            if request.url == SakanaUsageClient.sessionURL {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"user":{"id":"user"},"expires":"2026-08-25T12:00:00Z"}"#.utf8)
                )
            }
            return billing
        }
        let provider = SakanaProvider(
            authStore: plaintextAuthStore(token: token),
            usageClient: SakanaUsageClient(http: http),
            logUsageScanner: emptyLogScanner(),
            now: { current }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.warning)
        XCTAssertEqual(progress(snapshot.lines, "Five-Hour Usage")?.used, 0)
        XCTAssertEqual(progress(snapshot.lines, "Weekly Usage")?.used, 0)
        XCTAssertEqual(http.requests.count, 2)
    }

    func testProviderReportsAuthExpiredBeforeRequestingBilling() async {
        let current = now
        let http = SakanaRecordingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }
        let provider = SakanaProvider(
            authStore: plaintextAuthStore(token: token),
            usageClient: SakanaUsageClient(http: http),
            logUsageScanner: emptyLogScanner(),
            now: { current }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(http.requests.count, 1)
    }

    func testProviderKeepsLocalUltraTrendWhenConsoleSessionIsUnavailable() async throws {
        let home = try makeFuguHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let current = now
        let http = SakanaRecordingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }
        let provider = SakanaProvider(
            authStore: plaintextAuthStore(token: token),
            usageClient: SakanaUsageClient(http: http),
            logUsageScanner: SakanaLogUsageScanner(rootsOverride: [home]),
            now: { current }
        )

        let snapshot = await provider.refresh()

        XCTAssertNotNil(snapshot.warning)
        XCTAssertNotNil(snapshot.lines.first(where: { $0.label == "Usage Trend" }))
        XCTAssertNotNil(snapshot.lines.first(where: { $0.label == "Today" }))
        XCTAssertNotNil(snapshot.lines.first(where: { $0.label == "Last 30 Days" }))
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 110_000)
        XCTAssertEqual(http.requests.count, 1)
    }

    func testProviderDescriptorsExportStableLimitResourcesInOrder() {
        let descriptors = SakanaProvider().widgetDescriptors

        XCTAssertEqual(descriptors.map(\.id), [
            "sakana.session", "sakana.weekly", "sakana.trend",
            "sakana.today", "sakana.yesterday", "sakana.last30"
        ])
        XCTAssertEqual(
            descriptors.flatMap(\.limitResources).map(\.key),
            ["session", "weekly"]
        )
        XCTAssertTrue(descriptors[0].sample.isSessionWindow)
        XCTAssertEqual(descriptors[2].historyResource?.scope, .machineLocal)
        XCTAssertEqual(descriptors[2].historyResource?.estimatedCost, true)
        XCTAssertTrue(descriptors[3...].allSatisfy(\.isSpendTile))
    }

    func testCatalogPlacesSakanaInAlphabeticalProviderTail() {
        let defaults = UserDefaults(suiteName: "SakanaProviderTests.\(UUID().uuidString)")!
        let ids = ProviderCatalog.make(defaults: defaults).map(\.provider.id)

        XCTAssertEqual(ids, [
            "claude", "codex", "cursor",
            "antigravity", "copilot", "devin", "grok", "kimi",
            "opencode", "openrouter", "sakana", "zai"
        ])
    }

    private func plaintextAuthStore(token: String) -> SakanaAuthStore {
        let database = "/arc/Cookies"
        let row = "\(Data(SakanaAuthStore.cookieHost.utf8).hex)|42|plain:\(Data(token.utf8).hex)"
        return SakanaAuthStore(
            sqlite: SakanaProviderSQLiteDouble(row: row),
            files: FakeFiles([database: "database"]),
            keyReader: SakanaProviderKeyReaderDouble(),
            sources: {
                [SakanaBrowserCookieSource(
                    browserName: "Arc (Profile 1)",
                    databasePath: database,
                    safeStorageService: "Arc Safe Storage"
                )]
            }
        )
    }

    private func emptyLogScanner() -> SakanaLogUsageScanner {
        SakanaLogUsageScanner(rootsOverride: [])
    }

    private func makeFuguHome() throws -> URL {
        let timestamp = "2026-07-25T10:00:00.000Z"
        return try CodexLogFixture.makeHome(files: [
            "sessions/rollout-fugu.jsonl": [
                CodexLogFixture.turnContext(timestamp: timestamp, model: "fugu-ultra-v1.1"),
                CodexLogFixture.tokenCount(
                    timestamp: timestamp,
                    last: CodexLogFixture.usage(
                        input: 100_000,
                        cached: 20_000,
                        output: 10_000
                    )
                )
            ].joined(separator: "\n")
        ])
    }

    private func billingResponse(status: [String: Any]) -> HTTPResponse {
        let payload = try! flightPayload(status: status)
        let html = try! flightHTML(strings: [payload])
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(html.utf8))
    }

    private func flightPayload(status: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["usageLimitStatus": status])
        return "4a:" + String(decoding: data, as: UTF8.self)
    }

    private func flightHTML(strings: [String]) throws -> String {
        try strings.map { string in
            let argument = try JSONSerialization.data(withJSONObject: [1, string])
            return "<script>self.__next_f.push(\(String(decoding: argument, as: UTF8.self)))</script>"
        }.joined()
    }

    private func progress(
        _ lines: [MetricLine],
        _ label: String
    ) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(
            _, let used, let limit, _, let resetsAt, let periodDurationMs, _
        ) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, resetsAt, periodDurationMs)
    }
}

private final class SakanaRecordingHTTPClient: HTTPClient, @unchecked Sendable {
    var requests: [HTTPRequest] = []
    private let handler: (HTTPRequest) throws -> HTTPResponse

    init(handler: @escaping (HTTPRequest) throws -> HTTPResponse) {
        self.handler = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return try handler(request)
    }
}

private struct SakanaProviderSQLiteDouble: SQLiteAccessing {
    var row: String
    func queryValue(path: String, sql: String) throws -> String? { row }
    func execute(path: String, sql: String) throws {}
}

private struct SakanaProviderKeyReaderDouble: SakanaSafeStorageKeyReading {
    func readPassword(service: String, allowInteraction: Bool) throws -> String? { nil }
}

private extension Data {
    var hex: String {
        map { String(format: "%02X", $0) }.joined()
    }
}
