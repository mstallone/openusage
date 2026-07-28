import XCTest
@testable import Runway

final class SakanaLogUsageScannerTests: XCTestCase {
    private let now = RunwayISO8601.date(from: "2026-07-26T12:00:00.000Z")!

    func testUltraUsesPublishedStandardRatesAndDoesNotDoubleCountReasoning() throws {
        let event = try event(
            model: "fugu-ultra-v1.1",
            input: 100_000,
            cached: 20_000,
            output: 10_000,
            reasoning: 8_000
        )

        // 80k × $5/M + 20k × $0.50/M + 10k × $30/M = $0.71.
        // reasoning_output_tokens is already a subset of output_tokens in Codex's saved usage.
        XCTAssertEqual(
            try XCTUnwrap(SakanaFuguPricing.estimatedCost(for: event)),
            0.71,
            accuracy: 0.000_001
        )
    }

    func testUltraSwitchesWholeRequestToLongContextRatesAbove272K() throws {
        let atThreshold = try event(
            model: "fugu-ultra[1m]",
            input: 272_000,
            cached: 72_000,
            output: 10_000
        )
        let aboveThreshold = try event(
            model: "fugu-ultra-v1.0",
            input: 272_001,
            cached: 72_001,
            output: 10_000
        )

        XCTAssertEqual(
            try XCTUnwrap(SakanaFuguPricing.estimatedCost(for: atThreshold)),
            1.336,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(SakanaFuguPricing.estimatedCost(for: aboveThreshold)),
            2.522_001,
            accuracy: 0.000_001
        )
    }

    func testCyberUsesItsPublishedFixedRates() throws {
        let event = try event(
            model: "fugu-cyber-v1.0[1m]",
            input: 100_000,
            cached: 20_000,
            output: 10_000
        )

        XCTAssertEqual(
            try XCTUnwrap(SakanaFuguPricing.estimatedCost(for: event)),
            0.852,
            accuracy: 0.000_001
        )
    }

    func testPlainFuguIsNotGivenAFalseFixedPrice() throws {
        XCTAssertNil(SakanaFuguPricing.estimatedCost(for: try event(model: "fugu")))
    }

    func testAggregationKeepsUltraDeduplicatedAndFlagsUnpriceableFugu() throws {
        let ultra = try event(
            timestamp: "2026-07-26T10:00:00.000Z",
            model: "fugu-ultra-v1.1",
            input: 100_000,
            cached: 20_000,
            output: 10_000
        )
        let plain = try event(
            timestamp: "2026-07-26T11:00:00.000Z",
            model: "fugu",
            input: 50,
            output: 10
        )
        let unrelated = try event(
            timestamp: "2026-07-26T11:30:00.000Z",
            model: "gpt-5.6-sol",
            input: 50,
            output: 10
        )

        let scan = SakanaLogUsageScanner.aggregate(
            events: [ultra, ultra, plain, unrelated],
            since: RunwayISO8601.date(from: "2026-07-01T00:00:00.000Z")!
        )

        XCTAssertEqual(scan.series.daily.map(\.totalTokens), [110_000])
        XCTAssertEqual(scan.series.daily.first?.costUSD ?? 0, 0.71, accuracy: 0.000_001)
        XCTAssertEqual(scan.unknownModelsByDay["2026-07-26"], ["fugu"])
        XCTAssertEqual(scan.modelUsage?.daily.first?.models.map(\.model), ["fugu-ultra-v1.1"])
    }

    func testScannerReadsConfiguredFuguCodexHomeEndToEnd() async throws {
        let timestamp = "2026-07-26T10:00:00.000Z"
        let home = try CodexLogFixture.makeHome(files: [
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
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = SakanaLogUsageScanner(rootsOverride: [home])

        let scan = await scanner.scan(now: now)

        XCTAssertEqual(scan?.series.daily.map(\.totalTokens), [110_000])
        XCTAssertEqual(scan?.series.daily.first?.costUSD ?? 0, 0.71, accuracy: 0.000_001)
    }

    func testFootprintDiscoveryFindsNonDefaultDotCodexHome() {
        let root = URL(fileURLWithPath: "/test-home", isDirectory: true)
        let fugu = root.appendingPathComponent(".codex-fugu", isDirectory: true)
        let other = root.appendingPathComponent(".codex-personal", isDirectory: true)
        let files = FakeFiles([
            fugu.appendingPathComponent("config.toml").path:
                #"model_provider = "sakana"\n[model_providers.sakana]\nbase_url = "https://api.sakana.ai/v1""#,
            other.appendingPathComponent("config.toml").path:
                #"model_provider = "openai""#
        ])
        let scanner = SakanaLogUsageScanner(
            environment: FakeEnvironment(),
            files: files,
            homeDirectory: { root },
            listSubdirectories: { url in url == root ? [other, fugu] : [] }
        )

        XCTAssertTrue(scanner.hasSakanaFootprint())
    }

    func testParityAgainstRealLocalLogs() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUNWAY_SAKANA_PARITY"] == "1")
        let result = await SakanaLogUsageScanner().scan(now: Date())
        let scan = try XCTUnwrap(result)
        for day in scan.series.daily.sorted(by: { $0.date < $1.date }) {
            print(
                "SAKANA PARITY \(day.date) tokens=\(day.totalTokens) "
                    + "estimated=\(day.costUSD.map { String(format: "%.4f", $0) } ?? "nil")"
            )
        }
    }

    private func event(
        timestamp: String = "2026-07-26T10:00:00.000Z",
        model: String,
        input: Int = 100,
        cached: Int = 0,
        output: Int = 20,
        reasoning: Int = 0
    ) throws -> CodexLogUsageScanner.Event {
        CodexLogUsageScanner.Event(
            timestamp: try XCTUnwrap(RunwayISO8601.date(from: timestamp)),
            model: model,
            input: input,
            cached: cached,
            output: output,
            reasoning: reasoning,
            total: input + output
        )
    }
}
