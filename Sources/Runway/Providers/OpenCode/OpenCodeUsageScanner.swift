import Foundation

/// The result of a local OpenCode scan: the combined-hosted daily series (for the spend tiles + trend,
/// via `SpendTileMapper`) and the Go-only plan windows (for the meters). `goWindows` is `nil` when the
/// machine has no `opencode-go` footprint at all, so a Zen-only user sees spend tiles without empty caps.
struct OpenCodeUsageScan: Sendable {
    var logScan: LogUsageScan
    var goWindows: OpenCodeGoWindows?
}

/// Reads OpenCode's local SQLite logs (`~/.local/share/opencode/opencode*.db`, all release channels) and
/// builds the usage the provider renders. Cookie-free and network-free: the per-message `cost` OpenCode
/// writes for its own hosted gateways is authoritative (Zen models aren't in our pricing snapshots), so
/// it is summed directly rather than re-priced.
///
/// A `Sendable` struct (like the Grok scanner), `async` and nonisolated, so the SQLite reads run off the
/// main actor when the `@MainActor` provider `await`s it.
struct OpenCodeUsageScanner: Sendable {
    /// The OpenCode-hosted providerIDs we track: the Go subscription and the Zen pay-as-you-go gateway.
    /// Both write an authoritative `cost`; other (BYO-key) providerIDs log `cost: 0` and are out of scope.
    static let hostedProviderIDs = ["opencode-go", "opencode"]
    static let goProviderID = "opencode-go"

    var sqlite: SQLiteAccessing
    var databasePaths: @Sendable () throws -> [String]
    private let readFailureReporter: UsageLogReadFailureReporter

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        databasePaths: @escaping @Sendable () throws -> [String] = OpenCodeUsageScanner.defaultDatabasePaths,
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil
    ) {
        self.sqlite = sqlite
        self.databasePaths = databasePaths
        self.readFailureReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("opencode"),
            warning: readFailureWarning
        )
    }

    static let defaultDatabasePaths: @Sendable () throws -> [String] = {
        let dir = OpenCodePaths.dataDirectory(
            environment: ProcessEnvironmentReader(),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        return try OpenCodePaths.databaseFiles(in: dir)
    }

    /// Scan the last `daysBack` days. Returns `nil` only when there is no OpenCode database at all (→ the
    /// provider shows "No data"); a present-but-empty database yields an empty scan (idle tiles collapse
    /// to "No data" via `SpendTileMapper`). Throws `databaseUnreadable` when databases exist but none
    /// could be read — an all-failed refresh has no data source and must not render as zero usage.
    /// 33 days covers the widest meter window (anchored month) plus slack; the tiles/trend are
    /// re-bounded to 31 calendar days below.
    func scan(now: Date, daysBack: Int = 33, hasGoKey: Bool = false) async throws -> OpenCodeUsageScan? {
        let paths: [String]
        do {
            paths = try databasePaths()
        } catch {
            // The data directory exists but couldn't be enumerated — same failure class as unreadable
            // databases, edge-logged through the reporter so a persistent failure doesn't spam.
            let marker = "<data directory>"
            let newlyFailing = await readFailureReporter.update(checkedPaths: [marker], failingPaths: [marker])
            if !newlyFailing.isEmpty {
                AppLog.warn(LogTag.plugin("opencode"), "data directory unreadable: \(error.localizedDescription)")
            }
            throw OpenCodeUsageError.databaseUnreadable
        }
        guard !paths.isEmpty else {
            await readFailureReporter.update(checkedPaths: [], failingPaths: [])
            return nil
        }

        let cutoffMs = Int((now.timeIntervalSince1970 - Double(daysBack) * 86_400) * 1000)
        var rows: [Row] = []
        var anchorMs: Double?
        var checked: Set<String> = []
        var failures: [String: String] = [:]

        for path in paths {
            checked.insert(path)
            do {
                if let json = try sqlite.queryValue(path: path, sql: Self.dataSQL(cutoffMs: cutoffMs)) {
                    rows.append(contentsOf: Self.parseRows(json))
                }
            } catch {
                failures[path] = error.localizedDescription
                continue
            }
            // Monthly cycle anchor: the earliest-ever local Go usage (unbounded, so it survives the
            // day-window cutoff). Cheap and best-effort — a failure just falls back to the calendar month.
            if let text = (try? sqlite.queryValue(path: path, sql: Self.anchorSQL)) ?? nil,
               let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                anchorMs = Swift.min(anchorMs ?? value, value)
            }
        }
        // Per-path detail is logged only for newly failing paths (the reporter edge-triggers), so a
        // persistently locked database warns once, not on every 5-minute refresh.
        let newlyFailing = await readFailureReporter.update(checkedPaths: checked, failingPaths: Set(failures.keys))
        for path in newlyFailing.sorted() {
            AppLog.warn(LogTag.plugin("opencode"), "usage query failed for \(path): \(failures[path] ?? "unknown error")")
        }
        if failures.count == checked.count {
            throw OpenCodeUsageError.databaseUnreadable
        }

        // Combined hosted daily series (opencode-go + opencode) → the spend tiles + usage trend. Cost is
        // authoritative, so every row is "priced": feed it straight into the shared accumulator.
        let tileSince = JSONLScanning.sinceDate(daysBack: 30, now: now)
        var accumulator = DailyUsageAccumulator()
        for row in rows {
            let date = Date(timeIntervalSince1970: row.ms / 1000)
            guard date >= tileSince else { continue }
            accumulator.add(
                day: DailyUsageAccumulator.dayKey(from: date),
                tokens: row.tokens, cost: row.cost, model: row.model
            )
        }
        let logScan = accumulator.build()

        // Go-only windows → the Session / Weekly / Monthly caps. Shown only on a CURRENT Go signal: the
        // user is logged into Go (`hasGoKey`), or has spent on Go within the window. A stale anchor from
        // old usage must NOT resurrect the caps or the "Go" plan for a lapsed or Zen-only user — the
        // anchor only sets the monthly-cycle boundary once we've decided to show the meters.
        let goCosts = rows
            .filter { $0.providerID == Self.goProviderID }
            .map { (ms: $0.ms, cost: $0.cost) }
        let goWindows: OpenCodeGoWindows? = (hasGoKey || !goCosts.isEmpty)
            ? OpenCodeGoWindowMath.compute(costs: goCosts, anchorMs: anchorMs, now: now)
            : nil

        return OpenCodeUsageScan(logScan: logScan, goWindows: goWindows)
    }

    /// Cheap local probe for `hasLocalCredentials()`: does any tracked database hold at least one hosted
    /// assistant row with a numeric cost? Read-only, no network. Failures are logged (this runs only
    /// during first-run / new-provider detection, so there's no refresh spam to throttle); an unreadable
    /// data directory counts as an OpenCode footprint so `refresh()` gets to surface the real error.
    func hasHostedUsage() -> Bool {
        let paths: [String]
        do {
            paths = try databasePaths()
        } catch {
            AppLog.warn(LogTag.plugin("opencode"), "usage probe: data directory unreadable: \(error.localizedDescription)")
            return true
        }
        for path in paths {
            do {
                if let value = try sqlite.queryValue(path: path, sql: Self.probeSQL), !value.isEmpty {
                    return true
                }
            } catch {
                AppLog.warn(LogTag.plugin("opencode"), "usage probe failed for \(path): \(error.localizedDescription)")
            }
        }
        return false
    }

    // MARK: - Parsing

    private struct Row {
        var ms: Double
        var cost: Double
        var tokens: Int
        var model: String
        var providerID: String
    }

    /// Parse the `json_group_array(json_array(...))` payload: an array of
    /// `[time_created, cost, tokensTotal, modelID, providerID]`. Rows with a missing timestamp/cost or a
    /// non-string providerID are skipped at this boundary.
    private static func parseRows(_ json: String) -> [Row] {
        guard let data = json.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return [] }

        var rows: [Row] = []
        rows.reserveCapacity(parsed.count)
        for element in parsed {
            guard let entry = element as? [Any], entry.count >= 5,
                  let ms = ProviderParse.number(entry[0]),
                  let cost = ProviderParse.number(entry[1]), cost >= 0,
                  let providerID = entry[4] as? String
            else { continue }
            // Clamp before the Int conversion so a corrupt, absurdly large token count can't trap
            // (Int(Double) crashes above Int.max). 1e15 is far above any real token total.
            let tokens = Int(min(max(ProviderParse.number(entry[2]) ?? 0, 0), 1e15))
            let model = (entry[3] as? String) ?? ""
            rows.append(Row(
                ms: ms,
                cost: cost,
                tokens: tokens,
                model: model,
                providerID: providerID
            ))
        }
        return rows
    }

    // MARK: - SQL

    /// SQL literal built from `hostedProviderIDs`, so the tracked list has one source of truth.
    private static let providerFilter = "(" + hostedProviderIDs.map { "'\($0)'" }.joined(separator: ",") + ")"

    static func dataSQL(cutoffMs: Int) -> String {
        """
        SELECT json_group_array(json_array(
                 time_created,
                 json_extract(data,'$.cost'),
                 COALESCE(json_extract(data,'$.tokens.total'),0),
                 json_extract(data,'$.modelID'),
                 json_extract(data,'$.providerID')))
        FROM message
        WHERE time_created >= \(cutoffMs)
          AND json_valid(data)
          AND json_extract(data,'$.role') = 'assistant'
          AND json_extract(data,'$.providerID') IN \(providerFilter)
          AND json_type(data,'$.cost') IN ('integer','real');
        """
    }

    static let anchorSQL = """
        SELECT MIN(time_created) FROM message
        WHERE json_valid(data)
          AND json_extract(data,'$.role') = 'assistant'
          AND json_extract(data,'$.providerID') = '\(goProviderID)'
          AND json_type(data,'$.cost') IN ('integer','real');
        """

    static let probeSQL = """
        SELECT 1 FROM message
        WHERE json_valid(data)
          AND json_extract(data,'$.role') = 'assistant'
          AND json_extract(data,'$.providerID') IN \(providerFilter)
          AND json_type(data,'$.cost') IN ('integer','real')
        LIMIT 1;
        """
}
