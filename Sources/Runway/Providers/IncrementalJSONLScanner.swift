import Foundation

/// The `Item`-independent half of the incremental scan machinery: file discovery and the scan-window
/// lower bound. A non-generic namespace so providers that only need the window math (Grok) share it
/// without dragging in the generic actor, and so call sites read `JSONLScanning.sinceDate(...)` instead
/// of `IncrementalJSONLScanner<Entry>.sinceDate(...)`.
enum JSONLScanning {
    /// A discovered log file plus the stat fields the parse cache is keyed on.
    struct DiscoveredFile: Sendable {
        var path: String
        var size: Int
        var mtime: Date
    }

    /// Start of the day `daysBack` days before `now` — the lower bound of the scan window.
    static func sinceDate(daysBack: Int, now: Date) -> Date {
        let shifted = Calendar.current.date(byAdding: .day, value: -daysBack, to: now) ?? now
        return Calendar.current.startOfDay(for: shifted)
    }

    /// Every `*.jsonl` regular file under `dir` (recursively), path-sorted so a keep-first dedup is
    /// deterministic. Empty when `dir` can't be enumerated.
    static func jsonlFiles(under dir: URL) -> [DiscoveredFile] {
        // `FileManager.enumerator` silently yields nothing when `dir` itself is a symlink.
        // Resolve first so the enumeration sees the real directory.
        let dir = dir.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let keySet = Set(keys)
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: keys, options: []
        ) else { return [] }
        var files: [DiscoveredFile] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: keySet),
                  values.isRegularFile == true
            else { continue }
            files.append(DiscoveredFile(
                path: url.path,
                size: values.fileSize ?? 0,
                mtime: values.contentModificationDate ?? .distantPast
            ))
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Order-sensitive FNV-1a digest of a discovered-file list (path + size + mtime). Callers pair
    /// it with the scan revision to memoize aggregates: same digest + same revision means the scan
    /// would return the same items.
    static func digest(of files: [DiscoveredFile]) -> Int64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        func combine(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        for file in files {
            for byte in file.path.utf8 { combine(byte) }
            combine(0)
            withUnsafeBytes(of: Int64(file.size)) { for byte in $0 { combine(byte) } }
            withUnsafeBytes(of: file.mtime.timeIntervalSinceReferenceDate.bitPattern) {
                for byte in $0 { combine(byte) }
            }
        }
        return Int64(bitPattern: hash)
    }
}

/// The incremental, off-main-actor scan machinery shared by the Claude, Codex, and pi log scanners: discover
/// `*.jsonl` files, re-parse only those changed since the last scan (a per-file cache keyed by path +
/// size + mtime), and return the parsed items concatenated in file order. Each provider supplies its own
/// file discovery, per-file parser, and post-parse dedup/aggregation; this owns the cache, the parallel
/// parse, the mtime-window skip, and (via `JSONLScanning`) the jsonl enumeration so that scaffolding
/// isn't copied per provider.
///
/// An actor so the parse cache persists across the ~5-minute provider refreshes while staying off the
/// main actor. Provider scanner instances share one actor per parser; `Item` is that parser's row.
actor IncrementalJSONLScanner<Item: Codable & Sendable> {
    private typealias CachedFile = JSONLScanCachedFile<Item>

    private struct IdentityWaiter {
        var id: UUID
        var continuation: CheckedContinuation<Bool, Never>
    }

    /// One in-memory partition per provider/home identity. Provider scanner instances share this actor,
    /// so same-home multi-account cards reuse both memory and disk without letting disjoint homes prune
    /// one another's files.
    private var caches: [String: [String: CachedFile]] = [:]
    /// Per-identity change counter — bumped whenever a scan parses or drops any cached file, so
    /// callers can tell "the concatenated items are the same as last scan" without hashing them.
    private var revisions: [String: Int] = [:]
    private var persistedMetadata: [String: [String: JSONLScanCacheFileMetadata]] = [:]
    private var dirtyUpsertPaths: [String: Set<String>] = [:]
    private var dirtyRemovals: [String: [String: JSONLScanCacheFileMetadata]] = [:]
    private var invalidPersistenceIdentities: Set<String> = []
    private var loadedIdentities: Set<String> = []
    private var activeIdentities: Set<String> = []
    private var identityWaiters: [String: [IdentityWaiter]] = [:]
    private var writeTasks: [String: Task<Void, Never>] = [:]
    private var writeGenerations: [String: Int] = [:]
    private let maxConcurrentParses: Int
    private let parsePermitPool: JSONLParsePermitPool
    private let readFailureReporter: UsageLogReadFailureReporter
    private let persistence: JSONLScanCachePersistence?

    init(
        maxConcurrentParses: Int = 8,
        logTag: String = LogTag.refresh.rawValue,
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil,
        persistence: JSONLScanCachePersistence? = nil
    ) {
        precondition(maxConcurrentParses > 0)
        self.maxConcurrentParses = maxConcurrentParses
        self.parsePermitPool = JSONLParsePermitPool(limit: maxConcurrentParses)
        self.readFailureReporter = UsageLogReadFailureReporter(logTag: logTag, warning: readFailureWarning)
        self.persistence = persistence
        if let persistence {
            let cutoff = Date().addingTimeInterval(-JSONLScanCachePaths.staleIdentityRetention)
            Task.detached(priority: .utility) {
                await JSONLScanCacheWriter.shared.pruneStaleIdentities(
                    persistence: persistence,
                    before: cutoff
                )
            }
        }
    }

    /// Re-parse the in-window files (reusing the cache on an unchanged path + size + mtime), then return
    /// every file's items concatenated in the input order — callers pass a path-sorted list so a
    /// keep-first dedup stays deterministic. Files whose mtime predates `since` are skipped, so a
    /// years-deep tree stays cheap to rescan; an unreadable file is skipped and not cached, so a
    /// transient read failure doesn't stick. `nil` means the scan was canceled; a completed scan with
    /// no parsed rows returns `[]`, so callers never mistake cancellation for authoritative empty data.
    func items(
        from files: [JSONLScanning.DiscoveredFile],
        since: Date,
        cacheIdentity: String = "default",
        parse: @Sendable @escaping (Data) -> [Item]?
    ) async -> [Item]? {
        await items(from: files, since: since, cacheIdentity: cacheIdentity, strategy: .wholeFile(parse))?.items
    }

    /// Like `items(from:since:cacheIdentity:parse:)`, but a file that only grew since its cached
    /// parse re-reads just the appended bytes and resumes from the recorded parser state — the
    /// active session logs this app scans are multi-hundred-MB append-only rollouts, and re-reading
    /// one in full every refresh was the app's single largest recurring CPU cost.
    func items(
        from files: [JSONLScanning.DiscoveredFile],
        since: Date,
        cacheIdentity: String = "default",
        tailParser: JSONLTailParser<Item>
    ) async -> [Item]? {
        await items(from: files, since: since, cacheIdentity: cacheIdentity, strategy: .tail(tailParser))?.items
    }

    /// Like the tail-parsing `items`, but also returns the identity's change revision so callers
    /// can memoize the dedup/aggregate work they run over the returned items. The revision bumps
    /// whenever a scan parses or drops any cached file; combined with a digest of the discovered
    /// file list it identifies "same inputs as last time" without hashing the items themselves.
    func output(
        from files: [JSONLScanning.DiscoveredFile],
        since: Date,
        cacheIdentity: String = "default",
        tailParser: JSONLTailParser<Item>
    ) async -> JSONLScanOutput<Item>? {
        await items(from: files, since: since, cacheIdentity: cacheIdentity, strategy: .tail(tailParser))
    }

    private func items(
        from files: [JSONLScanning.DiscoveredFile],
        since: Date,
        cacheIdentity: String,
        strategy: JSONLParseStrategy<Item>
    ) async -> JSONLScanOutput<Item>? {
        precondition(!cacheIdentity.isEmpty)
        guard await acquire(cacheIdentity) else { return nil }
        defer { release(cacheIdentity) }
        guard !Task.isCancelled else { return nil }

        await loadCacheIfNeeded(identity: cacheIdentity)
        guard !Task.isCancelled else { return nil }
        let currentCache = caches[cacheIdentity] ?? [:]
        // Keep other same-parser scans' files in the shared partition until they age out of the window.
        // This lets multi-account cards with disjoint roots share one actor safely; only the current
        // call's input paths are returned below.
        var nextCache = currentCache.filter { $0.value.mtime >= since }
        var toParse: [JSONLParseRequest] = []
        // Items already parsed up to each resume point, re-attached ahead of appended results.
        var resumeItems: [String: [Item]] = [:]
        for file in files {
            guard file.mtime >= since else { continue }
            if let cached = currentCache[file.path], cached.size == file.size, cached.mtime == file.mtime {
                nextCache[file.path] = cached
            } else {
                nextCache[file.path] = nil
                var resume: JSONLResumeHint?
                if case .tail = strategy,
                   let cached = currentCache[file.path],
                   let offset = cached.parsedOffset,
                   let fingerprint = cached.tailFingerprint,
                   file.size > cached.size,
                   offset <= cached.size
                {
                    resume = JSONLResumeHint(
                        offset: offset, state: cached.resumeState, fingerprint: fingerprint
                    )
                    resumeItems[file.path] = cached.items
                }
                toParse.append(JSONLParseRequest(file: file, resume: resume))
            }
        }
        let parseResults = await Self.parseFiles(
            toParse,
            maxConcurrentParses: maxConcurrentParses,
            permitPool: parsePermitPool,
            strategy: strategy
        )
        guard !Task.isCancelled else { return nil }
        let checkedPaths = Set(parseResults.lazy.map(\.file.path))
        let unreadablePaths = Set(
            parseResults.lazy.filter {
                if case .unreadable = $0.outcome { return true }
                return false
            }.map(\.file.path)
        )
        await readFailureReporter.update(checkedPaths: checkedPaths, failingPaths: unreadablePaths)
        guard !Task.isCancelled else { return nil }
        var parsedPaths: Set<String> = []
        for result in parseResults {
            let file = result.file
            switch result.outcome {
            case .replaced(let items, let offset, let state, let fingerprint):
                nextCache[file.path] = CachedFile(
                    size: file.size, mtime: file.mtime, items: items,
                    parsedOffset: offset, resumeState: state, tailFingerprint: fingerprint
                )
                parsedPaths.insert(file.path)
            case .appended(let newItems, let offset, let state, let fingerprint):
                // `offset` is the parsed coverage, which a successful tail parse extends to the end
                // of the bytes read — the file's true size at read time. Cache that (not the
                // discovered stat size): if the file changed between stat and read, the next scan
                // re-detects the difference instead of treating stale bytes as covered.
                nextCache[file.path] = CachedFile(
                    size: offset, mtime: file.mtime,
                    items: (resumeItems[file.path] ?? []) + newItems,
                    parsedOffset: offset, resumeState: state, tailFingerprint: fingerprint
                )
                parsedPaths.insert(file.path)
            case .skipped, .unreadable:
                break
            }
        }
        var droppedPaths = 0
        for (path, cached) in currentCache where nextCache[path] == nil {
            droppedPaths += 1
            dirtyRemovals[cacheIdentity, default: [:]][path] = JSONLScanCacheFileMetadata(
                size: cached.size,
                mtime: cached.mtime,
                recordFileName: JSONLScanCachePaths.recordFileName(path: path)
            )
        }
        caches[cacheIdentity] = nextCache
        if !parsedPaths.isEmpty || droppedPaths > 0 {
            revisions[cacheIdentity, default: 0] += 1
        }
        dirtyUpsertPaths[cacheIdentity, default: []].formUnion(parsedPaths)
        if !dirtyUpsertPaths[cacheIdentity, default: []].isEmpty
            || !dirtyRemovals[cacheIdentity, default: [:]].isEmpty
            || invalidPersistenceIdentities.contains(cacheIdentity)
        {
            scheduleWrite(identity: cacheIdentity)
        }

        var items: [Item] = []
        for file in files {
            guard let cached = nextCache[file.path] else { continue }
            items.append(contentsOf: cached.items)
        }
        return Task.isCancelled
            ? nil
            : JSONLScanOutput(items: items, revision: revisions[cacheIdentity, default: 0])
    }

    /// Wait for the real debounced tasks rather than bypassing them. Tests configure a tiny debounce,
    /// then use this to prove ordinary scans actually schedule and finish persistence.
    func waitForPendingWritesForTesting() async {
        for task in Array(writeTasks.values) {
            await task.value
        }
    }

    /// Commits the latest snapshots immediately. One-shot processes call this before exiting; the
    /// long-lived app keeps the ordinary debounced path so refresh latency is unaffected.
    func flushPendingWrites() async {
        var identities = Set(writeTasks.keys)
        identities.formUnion(dirtyUpsertPaths.compactMap { $0.value.isEmpty ? nil : $0.key })
        identities.formUnion(dirtyRemovals.compactMap { $0.value.isEmpty ? nil : $0.key })
        identities.formUnion(invalidPersistenceIdentities)
        for identity in identities {
            writeTasks[identity]?.cancel()
            writeTasks[identity] = nil
            // Supersede an encoding or writer operation already in flight. Its generation guards then
            // leave the dirty state for this explicit drain to commit instead of racing to clear it.
            let generation = writeGenerations[identity, default: 0] + 1
            writeGenerations[identity] = generation
            await persistCache(identity: identity, generation: generation)
        }
    }

    func cacheRecordURLForTesting(identity: String, filePath: String) -> URL? {
        guard let persistence else { return nil }
        return JSONLScanCachePaths.recordURL(
            persistence: persistence,
            identity: identity,
            fileName: JSONLScanCachePaths.recordFileName(path: filePath)
        )
    }

    func queuedScanCountForTesting(identity: String) -> Int {
        identityWaiters[identity]?.count ?? 0
    }

    // MARK: - Same-identity scan serialization

    /// Actors are reentrant at `await parseFiles`; without this gate two cards launched together can
    /// cold-parse the same home concurrently and then race to replace its cache. Different identities
    /// remain independent, while matching ones queue behind the first parse and immediately hit cache.
    private func acquire(_ identity: String) async -> Bool {
        guard activeIdentities.contains(identity) else {
            activeIdentities.insert(identity)
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    identityWaiters[identity, default: []].append(
                        IdentityWaiter(id: waiterID, continuation: continuation)
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(identity: identity, waiterID: waiterID) }
        }
    }

    private func cancelWaiter(identity: String, waiterID: UUID) {
        guard var waiters = identityWaiters[identity],
              let index = waiters.firstIndex(where: { $0.id == waiterID })
        else { return }
        let waiter = waiters.remove(at: index)
        identityWaiters[identity] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume(returning: false)
    }

    private func release(_ identity: String) {
        guard var waiters = identityWaiters[identity], !waiters.isEmpty else {
            activeIdentities.remove(identity)
            identityWaiters[identity] = nil
            return
        }
        let next = waiters.removeFirst()
        identityWaiters[identity] = waiters.isEmpty ? nil : waiters
        next.continuation.resume(returning: true)
    }

    // MARK: - Persistence

    private func loadCacheIfNeeded(identity: String) async {
        guard loadedIdentities.insert(identity).inserted, let persistence else { return }
        do {
            guard let snapshot = try JSONLScanCacheWriter.shared.load(
                persistence: persistence,
                identity: identity,
                itemType: Item.self
            ) else { return }
            let manifest = snapshot.manifest
            guard manifest.formatVersion == JSONLScanCachePaths.formatVersion,
                  manifest.schemaVersion == persistence.schemaVersion,
                  manifest.identity == identity
            else {
                AppLog.info(.cache, "\(persistence.namespace) log parse cache schema changed; rebuilding")
                invalidPersistenceIdentities.insert(identity)
                return
            }
            persistedMetadata[identity] = manifest.files
            caches[identity] = snapshot.files
            dirtyRemovals[identity, default: [:]].merge(snapshot.invalidRecords) { _, new in new }
            if !snapshot.invalidRecords.isEmpty {
                AppLog.warn(
                    .cache,
                    "\(persistence.namespace) log parse cache has \(snapshot.invalidRecords.count) unreadable file records; reparsing"
                )
            }
            AppLog.debug(
                .cache,
                "loaded \(snapshot.files.count) \(persistence.namespace) log files from parse cache"
            )
        } catch {
            invalidPersistenceIdentities.insert(identity)
            AppLog.warn(
                .cache,
                "\(persistence.namespace) log parse cache unreadable; rebuilding: \(error.localizedDescription)"
            )
        }
    }

    private func scheduleWrite(identity: String) {
        guard let persistence else { return }
        let generation = writeGenerations[identity, default: 0] + 1
        writeGenerations[identity] = generation
        writeTasks[identity]?.cancel()
        writeTasks[identity] = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: persistence.writeDebounce)
            } catch {
                await self.finishWriteTask(identity: identity, generation: generation)
                return
            }
            guard !Task.isCancelled else { return }
            await self.persistCache(identity: identity, generation: generation)
            await self.finishWriteTask(identity: identity, generation: generation)
        }
    }

    private func finishWriteTask(identity: String, generation: Int) {
        guard writeGenerations[identity] == generation else { return }
        writeTasks[identity] = nil
    }

    private func persistCache(identity: String, generation: Int) async {
        guard let persistence,
              writeGenerations[identity] == generation,
              let files = caches[identity]
        else { return }

        let manifestFiles = metadata(for: files)
        let pathsToWrite = dirtyUpsertPaths[identity, default: []]
        let records = pathsToWrite.compactMap {
            path -> (path: String, metadata: JSONLScanCacheFileMetadata, record: JSONLScanCacheRecord<Item>)? in
            guard let cached = files[path], let metadata = manifestFiles[path] else { return nil }
            return (
                path,
                metadata,
                JSONLScanCacheRecord(
                    path: path, size: cached.size, mtime: cached.mtime, items: cached.items,
                    parsedOffset: cached.parsedOffset,
                    resumeState: cached.resumeState,
                    tailFingerprint: cached.tailFingerprint
                )
            )
        }
        let removalSnapshot = dirtyRemovals[identity, default: [:]]
        do {
            // Only changed per-source records are encoded, avoiding an O(all 30-day history) rewrite
            // whenever the active rollout grows. The writer builds the small merged manifest under lock.
            let upserts = try await Task.detached(priority: .utility) {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                return try Dictionary(uniqueKeysWithValues: records.map { input in
                    (
                        input.path,
                        JSONLScanCacheUpsert(
                            metadata: input.metadata,
                            recordData: try encoder.encode(input.record)
                        )
                    )
                })
            }.value
            guard !Task.isCancelled, writeGenerations[identity] == generation else { return }
            let result = try await JSONLScanCacheWriter.shared.commit(
                JSONLScanCacheWriteBatch(
                    persistence: persistence,
                    identity: identity,
                    upserts: upserts,
                    removals: removalSnapshot
                )
            )
            guard writeGenerations[identity] == generation else { return }
            persistedMetadata[identity] = result.manifest.files
            dirtyUpsertPaths[identity, default: []].subtract(result.acceptedUpsertPaths)
            for path in removalSnapshot.keys {
                dirtyRemovals[identity]?[path] = nil
            }
            invalidPersistenceIdentities.remove(identity)
            AppLog.debug(
                .cache,
                "persisted \(result.acceptedUpsertPaths.count) changed / \(result.manifest.files.count) retained \(persistence.namespace) log files"
            )
        } catch is CancellationError {
            return
        } catch {
            AppLog.warn(
                .cache,
                "could not persist \(persistence.namespace) log parse cache: \(error.localizedDescription)"
            )
        }
    }

    private func metadata(for files: [String: CachedFile]) -> [String: JSONLScanCacheFileMetadata] {
        var result: [String: JSONLScanCacheFileMetadata] = [:]
        result.reserveCapacity(files.count)
        for (path, cached) in files {
            result[path] = JSONLScanCacheFileMetadata(
                size: cached.size,
                mtime: cached.mtime,
                recordFileName: JSONLScanCachePaths.recordFileName(path: path)
            )
        }
        return result
    }

    /// Read + parse a bounded number of changed files in parallel. Results are keyed back to the
    /// input order; requests not reached before cancellation keep their `.skipped` placeholder.
    private static func parseFiles(
        _ requests: [JSONLParseRequest],
        maxConcurrentParses: Int,
        permitPool: JSONLParsePermitPool,
        strategy: JSONLParseStrategy<Item>
    ) async -> [(file: JSONLScanning.DiscoveredFile, outcome: JSONLParseOutcome<Item>)] {
        await withTaskGroup(
            of: (Int, JSONLParseOutcome<Item>).self,
            returning: [(file: JSONLScanning.DiscoveredFile, outcome: JSONLParseOutcome<Item>)].self
        ) { group in
            func addTask(at index: Int) {
                let request = requests[index]
                group.addTask {
                    guard await permitPool.acquire() else { return (index, .skipped) }
                    let result: (Int, JSONLParseOutcome<Item>)
                    if Task.isCancelled || !FileManager.default.fileExists(atPath: request.file.path) {
                        result = (index, .skipped)
                    } else {
                        result = autoreleasepool {
                            (index, JSONLTailIO.parse(request: request, strategy: strategy))
                        }
                    }
                    await permitPool.release()
                    return result
                }
            }

            var nextIndex = 0
            let initialCount = min(maxConcurrentParses, requests.count)
            for index in 0..<initialCount where !Task.isCancelled {
                addTask(at: index)
                nextIndex += 1
            }

            var results = requests.map { (file: $0.file, outcome: JSONLParseOutcome<Item>.skipped) }
            for await (index, outcome) in group {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                results[index] = (requests[index].file, outcome)
                if nextIndex < requests.count {
                    addTask(at: nextIndex)
                    nextIndex += 1
                }
            }
            return results
        }
    }
}
