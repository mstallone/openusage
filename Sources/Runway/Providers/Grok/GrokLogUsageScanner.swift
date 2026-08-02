import Foundation
import os

/// Builds daily token/cost estimates for Grok from the Grok CLI's local log.
///
/// Like the Claude/Codex scanners but simpler: Grok's token data lives in a single global
/// append-only log, `~/.grok/logs/unified.jsonl`, on `shell.turn.inference_done` lines.
/// Those lines carry token counts but no model id, so the scanner attributes each row to a model by
/// tracking the "current model" per CLI process (`pid`) from the model-change events the CLI also
/// logs. The output is the same `DailyUsageSeries` shape the Claude/Codex spend tiles consume, so it
/// flows straight through `SpendTileMapper`.
struct GrokLogUsageScanner: Sendable {
    var files: TextFileAccessing
    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL
    private let readFailureReporter: UsageLogReadFailureReporter

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil
    ) {
        self.files = files
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.readFailureReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("grok"),
            warning: readFailureWarning
        )
    }

    /// `~/.grok/logs/unified.jsonl`, or `$GROK_HOME/logs/unified.jsonl` when that env var is set.
    var logPath: String {
        if let raw = environment.value(for: "GROK_HOME")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return expandHome(raw).trimmingTrailingSlashes + "/logs/unified.jsonl"
        }
        return homeDirectory().appendingPathComponent(".grok/logs/unified.jsonl").path
    }

    /// The last parse, reused while the log's stat (path + size + mtime), history window, calendar
    /// configuration, and pricing snapshot are unchanged. Grok has no per-file incremental cache
    /// like the JSONL scanners — this single-entry memo removes the same steady-state cost (a full
    /// re-read + re-parse of an ever-growing log every 5 minutes) at a fraction of the machinery,
    /// since the whole history is one file. Static because provider refreshes build fresh scanner
    /// values; the retained pricing object pins its instance identity.
    private struct ScanMemo {
        var path: String
        var size: Int
        var mtime: Date
        var since: Date
        var calendarKey: String
        var pricing: ModelPricing
        var scan: LogUsageScan
    }

    private static let memo = OSAllocatedUnfairLock<ScanMemo?>(initialState: nil)

    /// Scan the last `daysBack` days of the log. Returns `nil` when the log is missing/unreadable (the
    /// spend tiles then render "No data"); returns an empty `daily` when the log exists but has no
    /// usable token rows in the window.
    ///
    /// `async` and nonisolated (this is a plain `Sendable` struct, not `@MainActor`), so the whole-file
    /// read + parse runs off the main actor when a `@MainActor` provider `await`s it.
    func scan(daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        let path = logPath
        guard files.exists(path) else {
            await readFailureReporter.update(checkedPaths: [path], failingPaths: [])
            return nil
        }
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let calendarKey = DailyUsageAccumulator.calendarMemoKey
        // Stat through FileManager: the memo is an optimization layered over the injectable file
        // accessor, so a test double without real files simply never hits it.
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = attributes?[.size] as? Int
        let mtime = attributes?[.modificationDate] as? Date
        if let size, let mtime,
           let cached = Self.memo.withLock({ $0 }),
           cached.path == path, cached.size == size, cached.mtime == mtime,
           cached.since == since, cached.calendarKey == calendarKey, cached.pricing === pricing
        {
            await readFailureReporter.update(checkedPaths: [path], failingPaths: [])
            return cached.scan
        }

        let text: String
        do {
            text = try files.readText(path)
            await readFailureReporter.update(checkedPaths: [path], failingPaths: [])
        } catch {
            await readFailureReporter.update(checkedPaths: [path], failingPaths: [path])
            return nil
        }
        let scan = Self.parse(text, since: since, pricing: pricing)
        if let size, let mtime {
            Self.memo.withLock {
                $0 = ScanMemo(
                    path: path, size: size, mtime: mtime, since: since,
                    calendarKey: calendarKey, pricing: pricing, scan: scan
                )
            }
        }
        return scan
    }

    /// Single chronological pass over the append-only log. Model-carrying events update a per-`pid`
    /// "current model" (tracked regardless of date, so a session straddling the `since` boundary stays
    /// attributed); each in-window `inference_done` row is priced against its `pid`'s current model and
    /// bucketed by local calendar day.
    static func parse(_ text: String, since: Date, pricing: ModelPricing) -> LogUsageScan {
        var modelByPID: [Int: String] = [:]
        var accumulator = DailyUsageAccumulator()
        var dayKeys = DailyUsageAccumulator.DayKeyCache()

        text.enumerateLines { line, _ in
            // Cheap pre-filter before JSON parsing: only model-carrying events and token rows matter
            // (token rows contain "inference_done"; every model event's `msg` contains "model").
            guard line.contains("inference_done") || line.contains("model") else { return }
            guard let data = line.data(using: .utf8),
                  let object = ProviderParse.jsonObject(data),
                  let msg = object["msg"] as? String
            else { return }

            let ctx = object["ctx"] as? [String: Any] ?? [:]
            let pid = ProviderParse.number(object["pid"]).map { Int($0) }

            if let model = modelID(msg: msg, ctx: ctx) {
                if let pid { modelByPID[pid] = model }
                return
            }

            guard msg == "shell.turn.inference_done",
                  let promptTokens = ProviderParse.number(ctx["prompt_tokens"]),
                  let timestamp = (object["ts"] as? String).flatMap(RunwayISO8601.date(from:)),
                  timestamp >= since
            else { return }

            let completion = Int(ProviderParse.number(ctx["completion_tokens"]) ?? 0)
            let reasoning = Int(ProviderParse.number(ctx["reasoning_tokens"]) ?? 0)
            // `cached_prompt_tokens` is a subset of `prompt_tokens`, so total counts prompt once.
            let cached = min(ProviderParse.number(ctx["cached_prompt_tokens"]) ?? 0, promptTokens)
            let cacheRead = Int(cached)
            let inputNoCache = Int(max(0, promptTokens - cached))
            let output = completion + reasoning

            let day = dayKeys.key(for: timestamp)
            let totalTokens = Int(promptTokens) + output

            // Grok's token rows lack a model id; attribute via the row's process. Rows that can't be
            // priced (no attributable model, or a model no source can price) are excluded from every
            // displayed total — tokens, dollars, the trend, and the model breakdown — because mixing
            // measured tokens with unpriceable ones makes the figures incoherent. An unknown model's
            // name lands in `unknownModelsByDay` (the tile's warning triangle), the only place
            // unpriceable usage surfaces; unattributed rows have no name to warn about.
            guard let model = pid.flatMap({ modelByPID[$0] }) else { return }
            let tokenBreakdown = TokenBreakdown(input: inputNoCache, cacheRead: cacheRead, output: output)
            guard let cost = pricing.estimatedCostDollars(model: model, tokens: tokenBreakdown) else {
                if totalTokens > 0 {
                    accumulator.addUnknownModel(day: day, model: model)
                }
                return
            }
            accumulator.add(day: day, tokens: totalTokens, cost: cost, model: model)
        }

        return accumulator.build()
    }

    /// The model id carried by a model-change event, or `nil` for any other line. The Grok CLI signals
    /// the active model through several event shapes, all keyed by `pid`.
    private static func modelID(msg: String, ctx: [String: Any]) -> String? {
        let raw: Any?
        switch msg {
        case "model changed":
            raw = ctx["model"]
        case "model catalog: notifying clients":
            raw = ctx["current_model_id"]
        case "backend_search: model switch":
            raw = ctx["model"] ?? ctx["current_model_id"] ?? ctx["model_id"]
        case "subagent model resolved":
            raw = ctx["model_id"] ?? ctx["model"]
        default:
            return nil
        }
        guard let model = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty
        else { return nil }
        return model
    }

}
