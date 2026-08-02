import Foundation

/// Fixed per-million-token prices Sakana publishes for the Fugu variants whose underlying model
/// routing does not change the rate. Plain `fugu` deliberately has no entry: its price depends on the
/// routed model pool, which the Codex rollout does not identify.
enum SakanaFuguPricing {
    struct Rates: Equatable, Sendable {
        var input: Double
        var output: Double
        var cachedInput: Double
    }

    static let longContextThreshold = 272_000

    static func rates(for model: String, inputTokens: Int) -> Rates? {
        let longContext = inputTokens > longContextThreshold
        switch normalized(model) {
        case "fugu-ultra", "fugu-ultra-v1.0", "fugu-ultra-v1.1", "fugu-ultra-20260615":
            return longContext
                ? Rates(input: 10, output: 45, cachedInput: 1)
                : Rates(input: 5, output: 30, cachedInput: 0.5)
        case "fugu-cyber", "fugu-cyber-v1.0":
            return longContext
                ? Rates(input: 12, output: 54, cachedInput: 1.2)
                : Rates(input: 6, output: 36, cachedInput: 0.6)
        default:
            return nil
        }
    }

    static func estimatedCost(for event: CodexLogUsageScanner.Event) -> Double? {
        guard let rates = rates(for: event.model, inputTokens: event.input) else { return nil }
        let cached = min(max(event.cached, 0), max(event.input, 0))
        let uncached = max(0, event.input - cached)
        return (
            Double(uncached) * rates.input
                + Double(cached) * rates.cachedInput
                + Double(max(event.output, 0)) * rates.output
        ) / 1_000_000
    }

    static func isFuguModel(_ model: String) -> Bool {
        let value = normalized(model)
        return value == "fugu" || value.hasPrefix("fugu-")
    }

    private static func normalized(_ model: String) -> String {
        model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\[1m\]$"#, with: "", options: .regularExpression)
    }
}

/// Reads Fugu token events from every locally configured Sakana Codex home. The console's subscription
/// meters are account-wide, but Sakana exposes no documented account-history endpoint; these logs are
/// therefore an explicitly machine-local source for spend tiles and the 31-day usage graph.
///
/// Parsing is delegated to `CodexLogUsageScanner` so cumulative counters, child-session replays, copied
/// rollouts, and model transitions have exactly one interpretation across the app. This scanner filters
/// those normalized events to Fugu and applies only Sakana's published fixed prices.
struct SakanaLogUsageScanner: Sendable {
    var environment: any EnvironmentReading
    var files: any TextFileAccessing
    var homeDirectory: @Sendable () -> URL
    var listSubdirectories: @Sendable (URL) -> [URL]
    var rootsOverride: [URL]?

    init(
        environment: any EnvironmentReading = ProcessEnvironmentReader(),
        files: any TextFileAccessing = LocalTextFileAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = {
            FileManager.default.homeDirectoryForCurrentUser
        },
        listSubdirectories: @escaping @Sendable (URL) -> [URL] = Self.filesystemSubdirectories,
        rootsOverride: [URL]? = nil
    ) {
        self.environment = environment
        self.files = files
        self.homeDirectory = homeDirectory
        self.listSubdirectories = listSubdirectories
        self.rootsOverride = rootsOverride
    }

    /// Cheap local footprint probe used by provider auto-enablement. It reads only directory names and
    /// provider configuration; rollout contents are parsed only during refresh.
    func hasSakanaFootprint() -> Bool {
        !sakanaHomes().isEmpty
    }

    func scan(daysBack: Int = 30, now: Date = Date()) async -> LogUsageScan? {
        let homes = sakanaHomes()
        guard !homes.isEmpty else { return nil }
        let paths = homes.map(canonicalPath).sorted()
        let parser = CodexLogUsageScanner(
            cacheIdentityOverride: "sakana-fugu\n" + paths.joined(separator: "\n"),
            rootsOverride: homes
        )
        guard let events = await parser.scanEvents(daysBack: daysBack, now: now),
              !Task.isCancelled
        else {
            return nil
        }
        return Self.aggregate(
            events: events,
            since: JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        )
    }

    static func aggregate(
        events: [CodexLogUsageScanner.Event],
        since: Date
    ) -> LogUsageScan {
        struct EventKey: Hashable {
            var timestamp: Date
            var model: String
            var input: Int
            var cached: Int
            var output: Int
            var reasoning: Int
            var total: Int
        }

        var seen: Set<EventKey> = []
        var accumulator = DailyUsageAccumulator()
        var dayKeys = DailyUsageAccumulator.DayKeyCache()
        for event in events where event.timestamp >= since {
            let key = EventKey(
                timestamp: event.timestamp,
                model: event.model,
                input: event.input,
                cached: event.cached,
                output: event.output,
                reasoning: event.reasoning,
                total: event.total
            )
            guard seen.insert(key).inserted,
                  SakanaFuguPricing.isFuguModel(event.model)
            else {
                continue
            }

            let day = dayKeys.key(for: event.timestamp)
            guard let cost = SakanaFuguPricing.estimatedCost(for: event) else {
                if event.total > 0 {
                    accumulator.addUnknownModel(day: day, model: event.model)
                }
                continue
            }
            // Codex's total is the measured standard usage value saved for the turn. Sakana's
            // orchestration detail fields are not preserved in the rollout, so neither the token bar
            // nor its estimated cost claims to include unobserved orchestration.
            let total = event.total > 0
                ? event.total
                : max(0, event.input) + max(0, event.output)
            accumulator.add(day: day, tokens: total, cost: cost, model: event.model)
        }
        return accumulator.build()
    }

    // MARK: - Codex home discovery

    private func sakanaHomes() -> [URL] {
        if let rootsOverride {
            return deduplicated(rootsOverride)
        }
        return deduplicated(candidateHomes()).filter(isSakanaHome)
    }

    private func candidateHomes() -> [URL] {
        let home = homeDirectory()
        var result = configuredHomes()
        result.append(home.appendingPathComponent(".codex", isDirectory: true))
        result += listSubdirectories(home).filter {
            $0.lastPathComponent.lowercased().hasPrefix(".codex")
        }
        result += listSubdirectories(home.appendingPathComponent(".config", isDirectory: true))
        return result
    }

    private func configuredHomes() -> [URL] {
        guard let raw = environment.value(for: "CODEX_HOME")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else {
            return []
        }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: expandTilde($0)) }
    }

    private func isSakanaHome(_ home: URL) -> Bool {
        let configPath = home.appendingPathComponent("config.toml").path
        do {
            if let config = try files.readTextIfPresent(configPath)?.lowercased(),
               config.contains("api.sakana.ai")
                || config.contains(#"model_provider = "sakana""#)
                || config.contains(#"model_provider="sakana""#)
            {
                return true
            }
        } catch {
            AppLog.warn(
                LogTag.plugin("sakana"),
                "couldn't inspect \(home.lastPathComponent)/config.toml: \(error.localizedDescription)"
            )
        }
        if files.exists(home.appendingPathComponent("fugu.json").path) {
            return true
        }
        let name = home.lastPathComponent.lowercased()
        return name.contains("fugu")
            && (
                files.exists(home.appendingPathComponent("sessions").path)
                    || files.exists(home.appendingPathComponent("archived_sessions").path)
            )
    }

    private func deduplicated(_ homes: [URL]) -> [URL] {
        var seen: Set<String> = []
        return homes
            .map { URL(fileURLWithPath: canonicalPath($0), isDirectory: true) }
            .sorted { $0.path < $1.path }
            .filter { seen.insert($0.path).inserted }
    }

    private func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return homeDirectory().path + String(path.dropFirst())
    }

    private static func filesystemSubdirectories(of url: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
        return contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }
}
