import XCTest
@testable import Runway

@MainActor
final class ClaudeAccountIsolationTests: XCTestCase {
    private let path = "/tmp/claude/.credentials.json"

    func testNewLoginBypassesPreviousLoginCacheAndCooldown() async {
        let calls = IsolationCallCounter()
        let fixture = makeFixture(
            credentials: credentials(access: "account-a", refresh: "refresh-a", plan: "pro")
        ) { request in
            if request.headers["Authorization"] == "Bearer account-a" {
                return calls.next() == 1
                    ? Self.usageResponse(percent: 25)
                    : HTTPResponse(statusCode: 429, headers: ["retry-after": "600"], body: Data())
            }
            return Self.usageResponse(percent: 70)
        }

        let initial = await fixture.provider.refresh()
        let limited = await fixture.provider.refresh()
        XCTAssertEqual(sessionUsage(initial), 25)
        XCTAssertEqual(sessionUsage(limited), 25)

        fixture.files.files[path] = credentials(
            access: "account-b", refresh: "refresh-b", plan: "max"
        )
        let switched = await fixture.provider.refresh()

        XCTAssertEqual(switched.plan, "Max")
        XCTAssertEqual(sessionUsage(switched), 70)
        XCTAssertEqual(usageRequests(fixture.http).count, 3)
    }

    func testRefreshTokenChangeSeparatesCacheWhenAccessTokenIsShared() async {
        let calls = IsolationCallCounter()
        let fixture = makeFixture(
            credentials: credentials(access: "shared", refresh: "refresh-a", plan: "pro")
        ) { request in
            guard request.url.absoluteString.hasSuffix("/api/oauth/usage") else {
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
            return calls.next() == 1
                ? Self.usageResponse(percent: 25)
                : HTTPResponse(statusCode: 429, headers: ["retry-after": "600"], body: Data())
        }

        let initial = await fixture.provider.refresh()
        XCTAssertEqual(sessionUsage(initial), 25)
        fixture.files.files[path] = credentials(
            access: "shared", refresh: "refresh-b", plan: "max"
        )

        let switched = await fixture.provider.refresh()

        XCTAssertNil(sessionUsage(switched), "account A usage must not cross into account B")
        XCTAssertEqual(status(switched)?.hasPrefix("Rate limited"), true)
    }


    func testReloginDuringUsageRequestIsPickedUpOnTheNextRefresh() async {
        // A re-login landing while account A's usage request is in flight publishes A's result for
        // this one cycle (each refresh reads credentials exactly once — no mid-flight reload), and
        // the next refresh switches to account B with a clean cache. The one-cycle lag is the
        // accepted cost of Runway being a strictly read-only credential consumer.
        let accountA = credentials(access: "account-a", refresh: "refresh-a", plan: "pro")
        let accountB = credentials(access: "account-b", refresh: "refresh-b", plan: "max")
        let files = FakeFiles([path: accountA])
        let fixture = makeFixture(files: files) { [path] request in
            if request.headers["Authorization"] == "Bearer account-a" {
                files.files[path] = accountB
                return Self.usageResponse(percent: 25)
            }
            return Self.usageResponse(percent: 75)
        }

        let first = await fixture.provider.refresh()
        XCTAssertEqual(first.plan, "Pro")
        XCTAssertEqual(sessionUsage(first), 25)
        XCTAssertEqual(usageRequests(fixture.http).count, 1)

        let second = await fixture.provider.refresh()
        XCTAssertEqual(second.plan, "Max")
        XCTAssertEqual(sessionUsage(second), 75, "account A usage must not survive into account B")
        XCTAssertEqual(usageRequests(fixture.http).count, 2)
    }

    func testRejectedKeychainCandidateFallsBackToNextSourceWithoutARefreshAttempt() async {
        let fileAccount = credentials(access: "file-b", refresh: "file-refresh", plan: "pro")
        let keychainAccount = credentials(
            access: "keychain-a", refresh: "keychain-refresh", plan: "max"
        )
        let files = FakeFiles([path: fileAccount])
        let keychain = ServiceKeychain()
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: keychain
        )
        let service = store.keychainServiceCandidates().first!
        keychain.currentUserValues[service] = keychainAccount
        let fixture = makeFixture(files: files, keychain: keychain) { request in
            XCTAssertTrue(
                request.url.absoluteString.hasSuffix("/api/oauth/usage"),
                "a rejected token must fall through to the next source, never to the token endpoint"
            )
            if request.headers["Authorization"] == "Bearer file-b" {
                return Self.usageResponse(percent: 75)
            }
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }

        let snapshot = await fixture.provider.refresh()

        XCTAssertEqual(sessionUsage(snapshot), 75)
        XCTAssertEqual(
            usageRequests(fixture.http).compactMap { $0.headers["Authorization"] },
            ["Bearer keychain-a", "Bearer file-b"]
        )
    }

    private struct Fixture {
        var provider: ClaudeProvider
        var files: FakeFiles
        var http: RoutingHTTPClient
    }

    private func makeFixture(
        credentials: String,
        handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse
    ) -> Fixture {
        makeFixture(files: FakeFiles([path: credentials]), handler: handler)
    }

    private func makeFixture(
        files: FakeFiles,
        keychain: any KeychainAccessing = FakeKeychain(),
        handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse
    ) -> Fixture {
        let http = RoutingHTTPClient(handler: handler)
        let now = Date(timeIntervalSince1970: 1_771_603_200)
        return Fixture(
            provider: ClaudeProvider(
                authStore: ClaudeAuthStore(
                    environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                    files: files,
                    keychain: keychain,
                    now: { now }
                ),
                usageClient: ClaudeUsageClient(httpClient: http),
                logUsageScanner: ClaudeLogFixture.scanner(home: nil),
                now: { now },
                pricing: { TestPricing.bundled }
            ),
            files: files,
            http: http
        )
    }

    private func credentials(
        access: String,
        refresh: String,
        plan: String,
        expiresAt: Double = 4_102_444_800_000
    ) -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(access)","refreshToken":"\#(refresh)","expiresAt":\#(expiresAt),"subscriptionType":"\#(plan)","scopes":["user:profile"]}}"#
    }

    private nonisolated static func usageResponse(percent: Double) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"five_hour":{"utilization":\#(percent),"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
        )
    }

    private func usageRequests(_ http: RoutingHTTPClient) -> [HTTPRequest] {
        http.requests.filter { $0.url.absoluteString.hasSuffix("/api/oauth/usage") }
    }

    private func sessionUsage(_ snapshot: ProviderSnapshot) -> Double? {
        guard case .progress(_, let used, _, _, _, _, _) = snapshot.line(label: "Session") else {
            return nil
        }
        return used
    }

    private func status(_ snapshot: ProviderSnapshot) -> String? {
        guard case .badge(_, let text, _, _) = snapshot.line(label: "Status") else { return nil }
        return text
    }
}

private final class IsolationCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
