import Foundation
import Observation

/// One document's loaded content plus the modification date it had at read time — the editor keeps
/// the date to detect external changes before a save. Database rows have no file behind them, so
/// their date is nil.
struct MemoryDocumentText: Sendable {
    var text: String
    var modificationDate: Date?
}

/// The Memory Explorer window's single source of truth: the scanned `MemorySource` inventory plus
/// every read/save/delete/create operation the editor performs. All blocking I/O runs off the main
/// actor via `loadOffMainActor`; every failure is logged loudly under `[memory]` AND rethrown so
/// the UI can show a friendly error.
///
/// Built lazily by the Memory window controller and torn down on close — it holds no timers or
/// observers, so teardown is just releasing it.
@MainActor
@Observable
final class MemoryStore {
    private(set) var sources: [MemorySource] = []
    private(set) var isLoading = false
    /// False until the first `reload()` finishes. The window renders before its `.task` starts that
    /// scan, so "no sources yet" means *scanning*, not *nothing found*, until this flips — the UI
    /// must not flash the empty state on the way in.
    private(set) var hasCompletedInitialScan = false
    private(set) var loadError: String?
    /// Non-fatal scan problems worth showing beside a non-empty inventory — a budget-truncated
    /// scan must not present partial homes as the complete picture.
    private(set) var scanWarning: String?
    var selectedDocumentID: String?

    @ObservationIgnored private let files: any TextFileAccessing
    @ObservationIgnored private let scanner: MemoryInventoryScanner
    @ObservationIgnored private let database: CodexMemoryDatabase
    /// Fresh-stat seam for conflict checks; injectable so tests can pin dates without a filesystem.
    @ObservationIgnored private let modificationDate: @Sendable (String) -> Date?
    /// Listing a Codex database spawns a whole sqlite3 process; an unchanged file (same
    /// modification date) keeps its previous rows so re-scans only pay for databases that moved.
    /// Static — the store is torn down with the window, and rows' metadata is small, so surviving
    /// close/reopen makes every warm open's listing effectively free. The modification-date check
    /// keeps a stale entry from ever being served.
    private static var databaseListingCache: [String: CachedDatabaseListing] = [:]

    /// WAL-mode commits land in the `-wal` sidecar without touching the main file's modification
    /// date, so the fingerprint covers both — otherwise a listing would stay stale until the next
    /// checkpoint rewrites the main database.
    private struct CachedDatabaseListing: Sendable {
        var modified: Date
        var walModified: Date?
        var documents: [MemoryDocument]
    }

    init(
        files: any TextFileAccessing = LocalTextFileAccessor(),
        scanner: MemoryInventoryScanner = MemoryInventoryScanner(),
        database: CodexMemoryDatabase = CodexMemoryDatabase(),
        modificationDate: @escaping @Sendable (String) -> Date? = MemoryStore.filesystemModificationDate
    ) {
        self.files = files
        self.scanner = scanner
        self.database = database
        self.modificationDate = modificationDate
    }

    // MARK: - Loading

    /// Re-scan every harness home, then list each Codex source's database rows. A database that
    /// cannot be read becomes that source's footnote (plus a loud log line), never a crash — the
    /// file-backed documents around it must stay usable.
    func reload() async {
        isLoading = true
        loadError = nil
        defer {
            isLoading = false
            hasCompletedInitialScan = true
        }

        let scanner = scanner
        let (scannedWithoutRows, notes, scanMs) = await loadOffMainActor {
            let scanStart = CFAbsoluteTimeGetCurrent()
            let (sources, notes) = scanner.scan()
            for note in notes {
                AppLog.info(.memory, note)
            }
            return (sources, notes, (CFAbsoluteTimeGetCurrent() - scanStart) * 1000)
        }
        let dbListStart = CFAbsoluteTimeGetCurrent()
        var (scanned, refreshedCache) = await Self.listingDatabaseDocuments(
            in: scannedWithoutRows,
            files: files,
            database: database,
            modificationDate: modificationDate,
            cache: Self.databaseListingCache
        )
        Self.databaseListingCache = refreshedCache
        // The scanner marks a home Ready off a database file's mere existence; only the listing
        // knows the tables are empty. A "ready" source with nothing whatsoever to read is really
        // a No File home — demote it (a listing *failure* keeps Ready: the footnote explains, and
        // the files may well exist) and re-rank so it sits with the other nothing-yet homes.
        for index in scanned.indices
        where scanned[index].status == .ready
            && scanned[index].footnote == nil
            && scanned[index].allDocuments.isEmpty {
            scanned[index].status = .missingFile
        }
        scanned = scanned.enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (lhs.element.status.sortRank, rhs.element.status.sortRank)
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
        UIProfiler.report("memory.scan", milliseconds: scanMs)
        UIProfiler.report("memory.dbList", milliseconds: (CFAbsoluteTimeGetCurrent() - dbListStart) * 1000)
        sources = scanned
        // An empty result with notes means the scan itself went wrong (read failures, an exhausted
        // time budget) — surface that instead of the generic "nothing on this Mac" empty state.
        // With sources present the notes are informational and the log already has them.
        if scanned.isEmpty, !notes.isEmpty {
            loadError = "The memory scan ran into problems and may have missed files. Check the log for details."
        }
        // A truncated or partially failed scan beside a non-empty inventory gets its own visible
        // warning — the sidebar must not present a partial list as the complete picture. Listing
        // and read failures count too: one may hit a candidate root that never became a source,
        // so no footnote carries it.
        let budgetHit = notes.contains { $0.contains("hit its") && $0.contains("budget") }
        let readOrListFailed = notes.contains { $0.contains("could not list") || $0.contains("could not read") }
        scanWarning = if budgetHit {
            "The scan ran out of time and this list may be incomplete. Refresh to rescan."
        } else if readOrListFailed {
            "Some files or folders could not be read, so this list may be incomplete. Check the log for details."
        } else {
            nil
        }
    }

    /// For each Codex source whose home has a `memories_1.sqlite`, fill `databaseDocuments` from the
    /// database. The existence probe mirrors the scanner's record-only check.
    ///
    /// Two speed rules keep this off the open path's critical feel: an unchanged database (same
    /// modification date as the cache) reuses its previous rows without touching sqlite, and the
    /// databases that did change are listed concurrently — each is its own sqlite3 process, so the
    /// wall clock is the slowest one, not the sum of all of them.
    private nonisolated static func listingDatabaseDocuments(
        in sources: [MemorySource],
        files: any TextFileAccessing,
        database: CodexMemoryDatabase,
        modificationDate: @escaping @Sendable (String) -> Date?,
        cache: [String: CachedDatabaseListing]
    ) async -> ([MemorySource], [String: CachedDatabaseListing]) {
        struct Job: Sendable {
            var index: Int
            var dbPath: String
            var modified: Date?
            var walModified: Date?
        }
        var result = sources
        var refreshedCache: [String: CachedDatabaseListing] = [:]
        var jobs: [Job] = []
        for (index, source) in sources.enumerated() {
            guard source.id.hasPrefix("codex:") else { continue }
            let dbPath = source.homePath + "/memories_1.sqlite"
            guard files.exists(dbPath) else { continue }
            let modified = modificationDate(dbPath)
            let walModified = modificationDate(dbPath + "-wal")
            if let modified, let cached = cache[dbPath],
               cached.modified == modified, cached.walModified == walModified {
                result[index].databaseDocuments = cached.documents
                refreshedCache[dbPath] = cached
                continue
            }
            jobs.append(Job(index: index, dbPath: dbPath, modified: modified, walModified: walModified))
        }
        guard !jobs.isEmpty else { return (result, refreshedCache) }

        let outcomes = await withTaskGroup(
            of: (Job, Result<[MemoryDocument], any Error>).self
        ) { group in
            for job in jobs {
                group.addTask {
                    (job, Result { try database.listDocuments(dbPath: job.dbPath) })
                }
            }
            var collected: [(Job, Result<[MemoryDocument], any Error>)] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }
        for (job, outcome) in outcomes {
            switch outcome {
            case .success(let documents):
                result[job.index].databaseDocuments = documents
                if let modified = job.modified {
                    refreshedCache[job.dbPath] = CachedDatabaseListing(
                        modified: modified,
                        walModified: job.walModified,
                        documents: documents
                    )
                }
            case .failure(let error):
                AppLog.error(.memory, "listing \(job.dbPath) failed: \(error.localizedDescription)")
                result[job.index].footnote = "The memory database could not be read: \(error.localizedDescription)"
            }
        }
        return (result, refreshedCache)
    }

    // MARK: - Lookup

    func document(withID id: String) -> MemoryDocument? {
        for source in sources {
            if let match = source.allDocuments.first(where: { $0.id == id }) {
                return match
            }
        }
        return nil
    }

    func projectGroup(containing doc: MemoryDocument) -> MemoryProjectGroup? {
        for source in sources {
            for project in source.projects {
                if project.indexDocument?.id == doc.id || project.facts.contains(where: { $0.id == doc.id }) {
                    return project
                }
            }
        }
        return nil
    }

    func source(containing doc: MemoryDocument) -> MemorySource? {
        sources.first { source in
            source.allDocuments.contains { $0.id == doc.id }
        }
    }

    // MARK: - Content

    /// A document's full text. File-backed documents also report the modification date the file had
    /// at read time; a Codex database row composes its `raw_memory` above its rollout summary, the
    /// order the read-only editor renders.
    func loadContent(_ doc: MemoryDocument) async throws -> MemoryDocumentText {
        switch doc.location {
        case .file(let path):
            let files = files
            let modificationDate = modificationDate
            do {
                return try await loadOffMainActor {
                    MemoryDocumentText(text: try files.readText(path), modificationDate: modificationDate(path))
                }
            } catch {
                AppLog.error(.memory, "reading \(path) failed: \(error.localizedDescription)")
                throw error
            }
        case .sqliteRow(let dbPath, let threadID):
            let database = database
            do {
                let row = try await loadOffMainActor {
                    try database.loadRow(dbPath: dbPath, threadID: threadID)
                }
                return MemoryDocumentText(text: Self.composedText(for: row), modificationDate: nil)
            } catch {
                AppLog.error(.memory, "loading row \(threadID) from \(dbPath) failed: \(error.localizedDescription)")
                throw error
            }
        }
    }

    /// The memory body first, then the rollout summary under a divider — matching the read-only
    /// editor's "raw memory above rollout summary" layout.
    private nonisolated static func composedText(for row: CodexMemoryRow) -> String {
        guard let summary = row.rolloutSummary?.nilIfEmpty else { return row.rawMemory }
        return row.rawMemory + "\n\n---\n\n## Rollout Summary\n\n" + summary
    }

    /// A fresh stat for the editor's external-change checks. Database rows have no file, so nil.
    func currentModificationDate(of doc: MemoryDocument) async -> Date? {
        guard case .file(let path) = doc.location else { return nil }
        let modificationDate = modificationDate
        return await loadOffMainActor { modificationDate(path) }
    }

    // MARK: - Editing

    /// Write `text` over the document's file, keeping the file's existing POSIX mode (memory files
    /// are shared with the harness that created them), then refresh the stored modification date so
    /// the just-saved state is not mistaken for an external change.
    func save(_ doc: MemoryDocument, text: String) async throws {
        guard doc.isEditable, case .file(let path) = doc.location else {
            AppLog.error(.memory, "save rejected: \(doc.id) is not an editable file")
            throw MemoryStoreError.documentIsReadOnly
        }
        let files = files
        let modificationDate = modificationDate
        do {
            let savedDate = try await loadOffMainActor {
                try files.writeTextPreservingMode(path, text)
                return modificationDate(path)
            }
            updateModificationDate(savedDate, forDocumentID: doc.id)
        } catch {
            AppLog.error(.memory, "saving \(path) failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Remove a fact file AND its `MEMORY.md` index line, so the index cannot drift into pointing
    /// at a file that no longer exists. A missing index is fine — orphaned facts have none.
    ///
    /// The index line goes first: the two steps are not atomic, and if the second fails the safe
    /// leftover is an unindexed fact file (still listed — the scanner enumerates the directory, not
    /// the index), never an index line pointing at a deleted file.
    func deleteFact(_ doc: MemoryDocument) async throws {
        guard doc.kind == .fact, case .file(let path) = doc.location else {
            AppLog.error(.memory, "delete rejected: \(doc.id) is not a fact file")
            throw MemoryStoreError.notAFact
        }
        let files = files
        let fileURL = URL(fileURLWithPath: path)
        let fileName = fileURL.lastPathComponent
        let indexPath = fileURL.deletingLastPathComponent().path + "/MEMORY.md"
        do {
            try await loadOffMainActor {
                if let index = try files.readTextIfPresent(indexPath) {
                    let rewritten = ClaudeMemoryIndex.removingEntry(forFile: fileName, from: index)
                    if rewritten != index {
                        try files.writeTextPreservingMode(indexPath, rewritten)
                    }
                }
                try files.remove(path)
            }
        } catch {
            AppLog.error(.memory, "deleting \(path) failed: \(error.localizedDescription)")
            throw error
        }
        if selectedDocumentID == doc.id {
            selectedDocumentID = nil
        }
        await reload()
    }

    /// Create a new fact in a Claude project group: a kebab-slug file named after `name` (suffixed
    /// `-2`, `-3`, … on collision) holding the frontmatter template, plus its index line — creating
    /// `MEMORY.md` when the project has none yet. Returns the new document's id (its path).
    func createFact(
        in project: MemoryProjectGroup,
        name: String,
        description: String,
        type: String
    ) async throws -> String {
        let files = files
        let modificationDate = modificationDate
        let directory = project.directoryPath
        do {
            let path = try await loadOffMainActor {
                let slug = Self.slugified(name)
                var fileName = slug + ".md"
                var suffix = 2
                while files.exists(directory + "/" + fileName) {
                    fileName = "\(slug)-\(suffix).md"
                    suffix += 1
                }
                let path = directory + "/" + fileName
                try files.writeTextPreservingMode(
                    path,
                    MemoryFrontmatter.template(name: name, description: description, type: type)
                )
                do {
                    let indexPath = directory + "/MEMORY.md"
                    let entry = ClaudeMemoryIndex.Entry(
                        title: name,
                        fileName: fileName,
                        hook: description.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    )
                    // Best-effort compare-and-retry against a live agent rewriting the index: stat
                    // before the read, re-stat right before the write, and re-read when the file
                    // moved in between. The residual stat→write window is microseconds — without
                    // cross-process locking (which Claude Code itself does not use) that is as
                    // narrow as this read-modify-write gets.
                    var attempt = 0
                    while true {
                        attempt += 1
                        let baseline = modificationDate(indexPath)
                        let index = try files.readTextIfPresent(indexPath) ?? ""
                        if modificationDate(indexPath) != baseline {
                            // The index moved mid-read. Retry; after the limit, FAIL — knowingly
                            // publishing a stale snapshot would erase the agent's latest update,
                            // and the rollback below removes the new fact cleanly.
                            guard attempt < 3 else { throw MemoryStoreError.indexContention }
                            continue
                        }
                        try files.writeTextPreservingMode(indexPath, ClaudeMemoryIndex.appendingEntry(entry, to: index))
                        break
                    }
                } catch {
                    // Roll the fact back: leaving it unindexed would make a retry mint a
                    // suffixed duplicate beside the orphan.
                    try? files.remove(path)
                    throw error
                }
                return path
            }
            await reload()
            return path
        } catch {
            AppLog.error(.memory, "creating fact '\(name)' in \(directory) failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Create the harness's top-level instruction file (empty) for a `.missingFile` source, so the
    /// editor can go straight from "no file yet" to editing it.
    func createInstructionFile(for source: MemorySource) async throws {
        guard let path = Self.instructionsPath(for: source) else {
            AppLog.error(.memory, "create instructions rejected: unknown harness for source \(source.id)")
            throw MemoryStoreError.unknownInstructionsPath
        }
        let files = files
        do {
            try await loadOffMainActor {
                // Exclusive publish: an agent may create the file at any point up to the rename —
                // its content wins (creating means "make the file exist", and it does). The
                // reload below picks up whichever content landed.
                _ = try files.createTextFileExclusively(path, "")
            }
        } catch {
            AppLog.error(.memory, "creating \(path) failed: \(error.localizedDescription)")
            throw error
        }
        await reload()
    }

    /// Where each harness expects its top-level instruction or memory file, keyed off the stable
    /// source-id prefix the scanner assigns.
    private nonisolated static func instructionsPath(for source: MemorySource) -> String? {
        let home = source.homePath
        if source.id.hasPrefix("claude:") { return home + "/CLAUDE.md" }
        if source.id.hasPrefix("codex:") { return home + "/AGENTS.md" }
        if source.id.hasPrefix("gemini:") { return home + "/GEMINI.md" }
        if source.id.hasPrefix("grok:") { return home + "/memory/MEMORY.md" }
        return nil
    }

    // MARK: - Helpers

    /// Lowercase kebab slug: alphanumerics kept, every other run becomes one dash, dashes trimmed.
    /// An all-symbol name still yields a usable file name.
    private nonisolated static func slugified(_ name: String) -> String {
        var slug = ""
        var pendingDash = false
        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash, !slug.isEmpty {
                    slug.append("-")
                }
                pendingDash = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return slug.isEmpty ? "memory" : slug
    }

    /// Refresh one document's stored modification date wherever it sits in the inventory.
    private func updateModificationDate(_ date: Date?, forDocumentID id: String) {
        for sourceIndex in sources.indices {
            if sources[sourceIndex].instructions?.id == id {
                sources[sourceIndex].instructions?.modificationDate = date
                return
            }
            for projectIndex in sources[sourceIndex].projects.indices {
                if sources[sourceIndex].projects[projectIndex].indexDocument?.id == id {
                    sources[sourceIndex].projects[projectIndex].indexDocument?.modificationDate = date
                    return
                }
                if let factIndex = sources[sourceIndex].projects[projectIndex].facts.firstIndex(where: { $0.id == id }) {
                    sources[sourceIndex].projects[projectIndex].facts[factIndex].modificationDate = date
                    return
                }
            }
            if let legacyIndex = sources[sourceIndex].legacyDocuments.firstIndex(where: { $0.id == id }) {
                sources[sourceIndex].legacyDocuments[legacyIndex].modificationDate = date
                return
            }
        }
    }

    /// Stats the symlink TARGET, not the link: reads and writes follow links, so the conflict and
    /// contention checks must watch the same inode they read — a symlinked MEMORY.md whose target
    /// an agent rewrites would otherwise never register as moved.
    nonisolated static func filesystemModificationDate(of path: String) -> Date? {
        let resolved = URL(fileURLWithPath: expandHome(path)).resolvingSymlinksInPath().path
        let attributes = try? FileManager.default.attributesOfItem(atPath: resolved)
        return attributes?[.modificationDate] as? Date
    }
}

enum MemoryStoreError: Error, LocalizedError, Equatable {
    case documentIsReadOnly
    case notAFact
    case unknownInstructionsPath
    case indexContention

    var errorDescription: String? {
        switch self {
        case .documentIsReadOnly:
            return "This memory is read-only and cannot be saved."
        case .notAFact:
            return "Only memory fact files can be deleted."
        case .unknownInstructionsPath:
            return "Runway does not know where this harness keeps its instruction file."
        case .indexContention:
            return "MEMORY.md is being rewritten by a live session right now. Try again in a moment."
        }
    }
}
