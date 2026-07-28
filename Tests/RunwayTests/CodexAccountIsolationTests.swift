import XCTest
@testable import Runway

@MainActor
final class CodexAccountIsolationTests: XCTestCase {
    func testAccountProviderPrefixesEveryDescriptorWithItsCardID() {
        let cardID = "codex@abcd1234"
        let provider = CodexProvider(
            provider: CodexProvider.makeProvider(id: cardID, displayName: "Codex — Work")
        )

        XCTAssertEqual(provider.provider.id, cardID)
        XCTAssertEqual(provider.provider.displayName, "Codex — Work")
        XCTAssertFalse(provider.widgetDescriptors.isEmpty)
        XCTAssertTrue(provider.widgetDescriptors.allSatisfy {
            $0.providerID == cardID && $0.id.hasPrefix("\(cardID).")
        })
    }

    func testCatalogReplacesTheLegacyCodexRuntimeWithScopedCards() {
        let cards = [
            CodexAccountCard(
                id: "codex",
                displayName: "Codex",
                credentialHomePath: "/tmp/codex-personal",
                logRoots: [URL(fileURLWithPath: "/tmp/codex-personal")],
                receivesPiUsage: true
            ),
            CodexAccountCard(
                id: "codex@abcd1234",
                displayName: "Codex — Work",
                credentialHomePath: "/tmp/codex-work",
                logRoots: [URL(fileURLWithPath: "/tmp/codex-work")]
            ),
        ]

        let providers = ProviderCatalog.make(
            codexCards: cards,
            hasResolvedCodexDefault: true
        ).compactMap { $0 as? CodexProvider }

        XCTAssertEqual(providers.map(\.provider.id), ["codex", "codex@abcd1234"])
        XCTAssertEqual(providers.map(\.authStore.scope), [
            .home(path: "/tmp/codex-personal"),
            .home(path: "/tmp/codex-work"),
        ])
        XCTAssertEqual(providers.map(\.piUsageCardID), ["codex", nil])
    }

    func testScopedBareCardReplacesLegacyRuntimeEvenWithoutDefaultBadge() {
        let card = CodexAccountCard(
            id: "codex",
            displayName: "Codex",
            credentialHomePath: "/tmp/codex-moved",
            logRoots: [URL(fileURLWithPath: "/tmp/codex-moved")]
        )

        let providers = ProviderCatalog.make(
            codexCards: [card],
            hasResolvedCodexDefault: false
        ).compactMap { $0 as? CodexProvider }

        XCTAssertEqual(providers.map(\.provider.id), ["codex"])
        XCTAssertEqual(providers.first?.authStore.scope, .home(path: "/tmp/codex-moved"))
        XCTAssertNil(providers.first?.piUsageCardID)
    }

    func testScopedProvidersFetchWithOnlyTheirOwnHomeCredentials() async {
        let files = FakeFiles([
            "/tmp/codex-personal/auth.json":
                #"{"tokens":{"access_token":"personal-token","account_id":"personal"}}"#,
            "/tmp/codex-work/auth.json":
                #"{"tokens":{"access_token":"work-token","account_id":"work"}}"#,
        ])
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.resetCreditsURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"credits":[]}"#.utf8))
            }
            let percent = request.headers["Authorization"] == "Bearer personal-token" ? 15 : 70
            return HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(
                    #"{"rate_limit":{"primary_window":{"used_percent":\#(percent),"limit_window_seconds":18000}}}"#.utf8
                )
            )
        }
        let personal = provider(
            id: "codex",
            home: "/tmp/codex-personal",
            files: files,
            http: http
        )
        let work = provider(
            id: "codex@abcd1234",
            home: "/tmp/codex-work",
            files: files,
            http: http
        )

        let personalSnapshot = await personal.refresh()
        let workSnapshot = await work.refresh()

        XCTAssertEqual(personalSnapshot.providerID, "codex")
        XCTAssertEqual(workSnapshot.providerID, "codex@abcd1234")
        XCTAssertEqual(sessionUsage(personalSnapshot), 15)
        XCTAssertEqual(sessionUsage(workSnapshot), 70)
        let usageRequests = http.requests.filter { $0.url == CodexUsageClient.usageURL }
        XCTAssertEqual(
            usageRequests.compactMap { $0.headers["Authorization"] },
            ["Bearer personal-token", "Bearer work-token"]
        )
        XCTAssertEqual(
            usageRequests.compactMap { $0.headers["ChatGPT-Account-Id"] },
            ["personal", "work"]
        )
    }

    func testScopedLogScannersNeverBleedAcrossAccountHomes() async throws {
        let personal = try CodexLogFixture.makeHome(files: [
            "sessions/personal.jsonl": rollout(input: 100, output: 50),
        ])
        let work = try CodexLogFixture.makeHome(files: [
            "sessions/work.jsonl": rollout(input: 400, output: 100),
        ])
        addTeardownBlock {
            try? FileManager.default.removeItem(at: personal)
            try? FileManager.default.removeItem(at: work)
        }
        let personalScanner = CodexLogUsageScanner(
            incrementalScanner: IncrementalJSONLScanner<CodexLogUsageScanner.Event>(),
            cacheIdentityOverride: "codex-account:personal",
            rootsOverride: [personal]
        )
        let workScanner = CodexLogUsageScanner(
            incrementalScanner: IncrementalJSONLScanner<CodexLogUsageScanner.Event>(),
            cacheIdentityOverride: "codex-account:work",
            rootsOverride: [work]
        )
        let now = RunwayISO8601.date(from: "2026-07-22T16:00:00.000Z")!

        let personalScan = await personalScanner.scan(now: now, pricing: TestPricing.bundled)
        let workScan = await workScanner.scan(now: now, pricing: TestPricing.bundled)

        XCTAssertEqual(personalScan?.series.daily.reduce(0) { $0 + $1.totalTokens }, 150)
        XCTAssertEqual(workScan?.series.daily.reduce(0) { $0 + $1.totalTokens }, 500)
    }

    private func provider(
        id: String,
        home: String,
        files: FakeFiles,
        http: RoutingHTTPClient
    ) -> CodexProvider {
        CodexProvider(
            provider: CodexProvider.makeProvider(id: id, displayName: id),
            authStore: CodexAuthStore(
                environment: FakeEnvironment(["CODEX_HOME": "/tmp/other"]),
                files: files,
                keychain: FakeKeychain(#"{"tokens":{"access_token":"wrong-keychain"}}"#),
                scope: .home(path: home)
            ),
            usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogFixture.scanner(home: nil),
            pricing: { TestPricing.bundled }
        )
    }

    private func rollout(input: Int, output: Int) -> String {
        [
            CodexLogFixture.turnContext(
                timestamp: "2026-07-22T14:00:00.000Z",
                model: "gpt-5.2"
            ),
            CodexLogFixture.tokenCount(
                timestamp: "2026-07-22T14:01:00.000Z",
                last: CodexLogFixture.usage(input: input, output: output)
            ),
        ].joined(separator: "\n")
    }

    private func sessionUsage(_ snapshot: ProviderSnapshot) -> Double? {
        guard case .progress(_, let used, _, _, _, _, _) = snapshot.line(label: "Session") else {
            return nil
        }
        return used
    }
}
