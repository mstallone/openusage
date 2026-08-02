import Foundation

/// Discovery pass for the Memory Explorer: finds every harness config home that keeps memory or
/// instruction files on this machine and describes what is inside, without loading file bodies
/// into the result. Mirrors `ClaudeConfigDirDiscovery`'s shape — injected environment/file/directory
/// access, a wall-clock budget, and a notes trail — so it runs the same way on fakes in tests.
///
/// Discovery only: file contents are read just enough to decorate titles and classify a source as
/// ready/empty, and Codex's `memories_1.sqlite` is merely RECORDED as present (never opened) —
/// row listing happens later in `MemoryStore` via `CodexMemoryDatabase`. Homes are NOT
/// credential-gated: a logged-out harness's memory is still worth showing and editing.
struct MemoryInventoryScanner: Sendable {
    var environment: EnvironmentReading
    var files: TextFileAccessing
    var homeDirectory: @Sendable () -> URL
    var listSubdirectories: @Sendable (URL) -> [URL]
    /// Regular files directly inside a directory — fact and legacy memory enumeration needs files,
    /// which `listSubdirectories` (directories only) cannot provide.
    var listFiles: @Sendable (URL) -> [URL]
    var slugDecoder: ProjectSlugDecoder
    /// Wall-clock budget; on overrun the scan returns what it has, with a note saying so.
    var timeBudget: TimeInterval
    var now: @Sendable () -> Date
    /// Failures from the default filesystem listings, drained into notes and source footnotes at
    /// the end of `scan()` — an EACCES on `~/.claude/projects` must not silently read as "no
    /// projects". Injected fake listings in tests simply never record here.
    private let listingDiagnostics: ListingDiagnostics

    final class ListingDiagnostics: @unchecked Sendable {
        private let lock = NSLock()
        private var failures: [(path: String, message: String)] = []

        func record(path: String, message: String) {
            lock.withLock { failures.append((path, message)) }
        }

        func drain() -> [(path: String, message: String)] {
            lock.withLock {
                let drained = failures
                failures = []
                return drained
            }
        }
    }

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        listSubdirectories: (@Sendable (URL) -> [URL])? = nil,
        listFiles: (@Sendable (URL) -> [URL])? = nil,
        slugDecoder: ProjectSlugDecoder = ProjectSlugDecoder(),
        timeBudget: TimeInterval = 1.0,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.environment = environment
        self.files = files
        self.homeDirectory = homeDirectory
        let diagnostics = ListingDiagnostics()
        self.listingDiagnostics = diagnostics
        self.listSubdirectories = listSubdirectories
            ?? { Self.filesystemSubdirectories(of: $0, diagnostics: diagnostics) }
        self.listFiles = listFiles
            ?? { Self.filesystemFiles(of: $0, diagnostics: diagnostics) }
        self.slugDecoder = slugDecoder
        self.timeBudget = timeBudget
        self.now = now
    }

    func scan() -> (sources: [MemorySource], notes: [String]) {
        let started = now()
        var sources: [MemorySource] = []
        var notes: [String] = []
        var budgetExhausted = false

        // Fixed harness order: Claude and Codex first (the established providers), then the rest
        // alphabetically by display name — the same convention as the dashboard's provider order.
        let harnesses: [(harness: Harness, homes: [String])] = [
            (.claude, claudeHomeCandidates()),
            (.codex, codexHomeCandidates()),
            (.gemini, [homeDirectory().appendingPathComponent(".gemini").path]),
            // GROK_HOME first, like the Claude/Codex overrides — the usage scanners already honor
            // it, and the memory inventory must look where the CLI actually lives. The per-harness
            // `seen` dedupe collapses it with the default when they point at the same place.
            (.grok, commaListEnvironmentPaths("GROK_HOME") + [homeDirectory().appendingPathComponent(".grok").path]),
        ]
        for (harness, homes) in harnesses {
            var seen = Set<String>()
            for home in homes {
                if now().timeIntervalSince(started) > timeBudget {
                    notes.append("memory scan hit its \(Int(timeBudget * 1000))ms budget; finishing with partial results")
                    budgetExhausted = true
                    break
                }
                guard seen.insert(canonical(home)).inserted else { continue }
                guard directoryPresent(home) else { continue }
                // The builders also honor the deadline inside their own traversals — one Claude
                // home with thousands of projects must not blow through the advertised budget.
                let expired = { now().timeIntervalSince(started) > timeBudget }
                sources.append(source(for: harness, home: home, notes: &notes, expired: expired))
            }
            if budgetExhausted { break }
        }
        // Listing failures become user-visible: a note for the log, and a footnote on the source
        // whose home the unlistable folder lives under — an EACCES must not read as "no projects".
        Self.attachListingFailures(listingDiagnostics.drain(), to: &sources, notes: &notes, logPath: logPath)
        // Status ranks the sections: sources with something to read now, then homes with nothing
        // in them yet (one click from useful via Create Instruction File), then harnesses whose
        // memory feature is off (fixing that lives in the other tool, not here). Offsets break
        // ties because `sorted` guarantees no stability — the harness order above (Claude, Codex,
        // then alphabetical) must stay the within-bucket order.
        let ranked = sources.enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (lhs.element.status.sortRank, rhs.element.status.sortRank)
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
        return (ranked, notes)
    }

    // MARK: - Harnesses

    private enum Harness {
        case claude, codex, gemini, grok

        var displayName: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            case .gemini: return "Gemini"
            case .grok: return "Grok"
            }
        }

        /// Stable source-id prefix, so two harnesses pointed at the same directory cannot collide.
        var key: String {
            switch self {
            case .claude: return "claude"
            case .codex: return "codex"
            case .gemini: return "gemini"
            case .grok: return "grok"
            }
        }
    }

    private func source(
        for harness: Harness,
        home: String,
        notes: inout [String],
        expired: () -> Bool
    ) -> MemorySource {
        switch harness {
        case .claude: return claudeSource(home: home, notes: &notes, expired: expired)
        case .codex: return codexSource(home: home, notes: &notes, expired: expired)
        case .gemini: return geminiSource(home: home, notes: &notes)
        case .grok: return grokSource(home: home, notes: &notes, expired: expired)
        }
    }

    // MARK: - Candidate homes

    /// `CLAUDE_CONFIG_DIR` entries (comma list), the default homes, then `~/.claude*` dot-dirs
    /// (extra logins like `~/.claude-personal`). Canonical dedupe keeps the first spelling.
    private func claudeHomeCandidates() -> [String] {
        var homes = commaListEnvironmentPaths("CLAUDE_CONFIG_DIR")
        let home = homeDirectory()
        homes.append(home.appendingPathComponent(".claude").path)
        let xdg = environment.value(for: "XDG_CONFIG_HOME")?.nilIfEmpty.map(expandTilde)
            ?? home.appendingPathComponent(".config").path
        homes.append(xdg + "/claude")
        homes += dotDirectories(prefixed: ".claude")
        return homes
    }

    private func codexHomeCandidates() -> [String] {
        var homes = commaListEnvironmentPaths("CODEX_HOME")
        let home = homeDirectory()
        homes.append(home.appendingPathComponent(".codex").path)
        // The historical default `CodexHomeDiscovery` also recognizes; canonical dedupe collapses
        // it with `~/.codex` when they alias.
        let xdg = environment.value(for: "XDG_CONFIG_HOME")?.nilIfEmpty.map(expandTilde)
            ?? home.appendingPathComponent(".config").path
        homes.append(xdg + "/codex")
        homes += dotDirectories(prefixed: ".codex")
        return homes
    }

    private func commaListEnvironmentPaths(_ name: String) -> [String] {
        guard let raw = environment.value(for: name)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return [] }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map(expandTilde)
    }

    private func dotDirectories(prefixed prefix: String) -> [String] {
        listSubdirectories(homeDirectory())
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .map(\.path)
            .sorted()
    }

    // MARK: - Claude

    private func claudeSource(home: String, notes: inout [String], expired: () -> Bool) -> MemorySource {
        let instructionsPath = home + "/CLAUDE.md"
        let (instructionsText, unreadable) = readInstruction(instructionsPath, notes: &notes)
        let projectsDir = URL(fileURLWithPath: home).appendingPathComponent("projects")
        var projects: [MemoryProjectGroup] = []
        var readFailed = false
        for projectDir in listSubdirectories(projectsDir).sorted(by: { $0.path < $1.path }) {
            if expired() {
                notes.append("memory scan hit its budget inside \(logPath(home)); the project list is partial")
                break
            }
            if let group = claudeProjectGroup(
                projectDir: projectDir, notes: &notes, expired: expired, readFailed: &readFailed
            ) {
                projects.append(group)
            }
        }
        return MemorySource(
            id: sourceID(.claude, home: home),
            harness: Harness.claude.displayName,
            homePath: home,
            status: fileBackedStatus(instructionsText: instructionsText, hasOtherArtifacts: !projects.isEmpty),
            instructions: instructionsText.map { _ in fileDocument(path: instructionsPath, kind: .instructions) },
            projects: projects,
            legacyDocuments: [],
            databaseDocuments: [],
            footnote: readFailed ? Self.readFailureFootnote : nil,
            instructionsUnreadable: unreadable
        )
    }

    /// A memory file that exists but could not be read must not vanish silently — the log has the
    /// path, the sidebar gets this pointer.
    static let readFailureFootnote = "Some memory files could not be read. Check the log for details."

    /// One `projects/<slug>/memory/` directory. Facts come from the directory listing (every `*.md`
    /// except MEMORY.md) so a fact whose index line was lost still shows; titles and hooks are
    /// decorated from the MEMORY.md index (matched by filename) first, frontmatter second,
    /// filename last.
    private func claudeProjectGroup(
        projectDir: URL,
        notes: inout [String],
        expired: () -> Bool,
        readFailed: inout Bool
    ) -> MemoryProjectGroup? {
        let memoryDir = projectDir.appendingPathComponent("memory")
        let indexPath = memoryDir.path + "/MEMORY.md"
        let indexText = readIfPresent(indexPath, notes: &notes, failed: &readFailed)
        let indexEntries = indexText.map(ClaudeMemoryIndex.entries(in:)) ?? []

        var facts: [MemoryDocument] = []
        let factURLs = listFiles(memoryDir)
            .filter { $0.pathExtension == "md" && $0.lastPathComponent != "MEMORY.md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in factURLs {
            // Every fact costs a full read (frontmatter decoration); one project with hundreds of
            // large facts must not blow through the whole scan's budget.
            if expired() {
                notes.append("memory scan hit its budget inside \(logPath(memoryDir.path)); the fact list is partial")
                break
            }
            let frontmatter = readIfPresent(url.path, notes: &notes, failed: &readFailed)
                .flatMap { MemoryFrontmatter.parse($0).frontmatter }
            let entry = indexEntries.first { $0.fileName == url.lastPathComponent }
            facts.append(MemoryDocument(
                id: url.path,
                title: entry?.title ?? frontmatter?.name ?? url.deletingPathExtension().lastPathComponent,
                subtitle: entry?.hook ?? frontmatter?.description,
                kind: .fact,
                location: .file(path: url.path),
                modificationDate: nil,
                isEditable: true
            ))
        }
        guard indexText != nil || !facts.isEmpty else { return nil }

        let slug = projectDir.lastPathComponent
        let decodedPath = slugDecoder.bestEffortPath(fromSlug: slug)
        return MemoryProjectGroup(
            id: memoryDir.path,
            slug: slug,
            displayName: decodedPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? slug,
            displayPath: decodedPath,
            indexDocument: indexText.map { _ in fileDocument(path: indexPath, kind: .memoryIndex) },
            facts: facts
        )
    }

    // MARK: - Codex

    private func codexSource(home: String, notes: inout [String], expired: () -> Bool) -> MemorySource {
        let instructionsPath = home + "/AGENTS.md"
        let (instructionsText, unreadable) = readInstruction(instructionsPath, notes: &notes)

        var legacy: [MemoryDocument] = []
        var readFailed = false
        let legacyURLs = listFiles(URL(fileURLWithPath: home).appendingPathComponent("memories"))
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in legacyURLs {
            // Legacy memories can be large (MEMORY.md alone is ~100KB on real machines); this
            // full-read loop honors the scan budget like the Claude fact loop does.
            if expired() {
                notes.append("memory scan hit its budget inside \(logPath(home)); the legacy memory list is partial")
                break
            }
            let frontmatter = readIfPresent(url.path, notes: &notes, failed: &readFailed)
                .flatMap { MemoryFrontmatter.parse($0).frontmatter }
            legacy.append(MemoryDocument(
                id: url.path,
                title: frontmatter?.name ?? url.deletingPathExtension().lastPathComponent,
                subtitle: frontmatter?.description,
                kind: .legacyMemory,
                location: .file(path: url.path),
                modificationDate: nil,
                isEditable: true
            ))
        }

        // Record only that the database exists; opening it (and listing rows) is MemoryStore's job.
        let databasePresent = files.exists(home + "/memories_1.sqlite")
        if databasePresent {
            notes.append("codex home \(logPath(home)): memories_1.sqlite present; database rows list on demand")
        }

        var status = fileBackedStatus(
            instructionsText: instructionsText,
            hasOtherArtifacts: !legacy.isEmpty || databasePresent
        )
        let configText = readIfPresent(home + "/config.toml", notes: &notes)
        if let configText, codexMemoriesDisabled(configText: configText) {
            notes.append("codex home \(logPath(home)): use_memories = false in config.toml → memory disabled")
            // One sentence shape for every disabled source — "Memory is turned off in <the other
            // tool>, <where its switch lives>" — so Codex and Grok read as the same state.
            status = .memoryDisabled(note: "Memory is turned off in Codex (use_memories = false in config.toml).")
        }

        return MemorySource(
            id: sourceID(.codex, home: home),
            harness: Harness.codex.displayName,
            homePath: home,
            status: status,
            instructions: instructionsText.map { _ in fileDocument(path: instructionsPath, kind: .instructions) },
            projects: [],
            legacyDocuments: legacy,
            databaseDocuments: [],
            footnote: readFailed ? Self.readFailureFootnote : nil,
            instructionsUnreadable: unreadable
        )
    }

    /// Line-based match for `use_memories = false`, tolerant of spacing and trailing comments.
    private func codexMemoriesDisabled(configText: String) -> Bool {
        for rawLine in configText.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("use_memories") else { continue }
            let rest = line.dropFirst("use_memories".count).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("=") else { continue }
            let value = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            if value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "#" }).first == "false" {
                return true
            }
        }
        return false
    }

    // MARK: - Gemini

    private func geminiSource(home: String, notes: inout [String]) -> MemorySource {
        let instructionsPath = home + "/GEMINI.md"
        let (instructionsText, unreadable) = readInstruction(instructionsPath, notes: &notes)
        return MemorySource(
            id: sourceID(.gemini, home: home),
            harness: Harness.gemini.displayName,
            homePath: home,
            status: fileBackedStatus(instructionsText: instructionsText, hasOtherArtifacts: false),
            instructions: instructionsText.map { _ in fileDocument(path: instructionsPath, kind: .instructions) },
            projects: [],
            legacyDocuments: [],
            databaseDocuments: [],
            footnote: nil,
            instructionsUnreadable: unreadable
        )
    }

    // MARK: - Grok

    /// `~/.grok/memory/MEMORY.md` global plus `memory/<slug>-<hash8>/MEMORY.md` per project. The
    /// feature gate is a `[memory]` section in Grok's config.toml, evaluated FIRST: without one
    /// the source is Memory Disabled even when stale memory files remain on disk (they still
    /// list — readable is readable — but Grok is not using them). With the gate on and no
    /// `memory/` directory yet, the files just don't exist — the ordinary No File state, where
    /// creating MEMORY.md is real (Grok will read it).
    private func grokSource(home: String, notes: inout [String], expired: () -> Bool) -> MemorySource {
        let memoryConfigured = readIfPresent(home + "/config.toml", notes: &notes)
            .map { text in
                text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "[memory]" }
            } ?? false
        let disabledStatus = MemorySourceStatus.memoryDisabled(
            note: "Memory is turned off in Grok (no [memory] section in its config.toml)."
        )
        let memoryDir = home + "/memory"
        guard directoryPresent(memoryDir) else {
            notes.append("grok home \(logPath(home)): no memory directory → \(memoryConfigured ? "no files yet" : "memory disabled")")
            return MemorySource(
                id: sourceID(.grok, home: home),
                harness: Harness.grok.displayName,
                homePath: home,
                status: memoryConfigured ? .missingFile : disabledStatus,
                instructions: nil,
                projects: [],
                legacyDocuments: [],
                databaseDocuments: [],
                footnote: nil
            )
        }

        let globalPath = memoryDir + "/MEMORY.md"
        let (globalText, unreadable) = readInstruction(globalPath, notes: &notes)
        var projects: [MemoryProjectGroup] = []
        var readFailed = false
        for projectDir in listSubdirectories(URL(fileURLWithPath: memoryDir)).sorted(by: { $0.path < $1.path }) {
            if expired() {
                notes.append("memory scan hit its budget inside \(logPath(home)); the project list is partial")
                break
            }
            let indexPath = projectDir.path + "/MEMORY.md"
            guard readIfPresent(indexPath, notes: &notes, failed: &readFailed) != nil else { continue }
            let slug = projectDir.lastPathComponent
            projects.append(MemoryProjectGroup(
                id: projectDir.path,
                slug: slug,
                displayName: grokProjectDisplayName(slug),
                displayPath: nil,
                indexDocument: fileDocument(path: indexPath, kind: .memoryIndex),
                facts: []
            ))
        }
        if !memoryConfigured {
            notes.append("grok home \(logPath(home)): memory files present but no [memory] section → memory disabled")
        }
        return MemorySource(
            id: sourceID(.grok, home: home),
            harness: Harness.grok.displayName,
            homePath: home,
            status: memoryConfigured
                ? fileBackedStatus(instructionsText: globalText, hasOtherArtifacts: !projects.isEmpty)
                : disabledStatus,
            instructions: globalText.map { _ in fileDocument(path: globalPath, kind: .instructions) },
            projects: projects,
            legacyDocuments: [],
            databaseDocuments: [],
            footnote: readFailed ? Self.readFailureFootnote : nil,
            instructionsUnreadable: unreadable
        )
    }

    /// Grok project directories end in an 8-hex-digit hash (`myrepo-a1b2c3d4`); strip it for display.
    private func grokProjectDisplayName(_ directoryName: String) -> String {
        guard let dash = directoryName.lastIndex(of: "-") else { return directoryName }
        let suffix = directoryName[directoryName.index(after: dash)...]
        guard suffix.count == 8, suffix.allSatisfy(\.isHexDigit) else { return directoryName }
        return String(directoryName[..<dash])
    }

    /// Matches on a path-component boundary — `~/.codex-work`'s failure must not attach to
    /// `~/.codex` just because one string prefixes the other — and prefers the longest matching
    /// home when homes nest. Internal for direct testing (the diagnostics only populate from the
    /// default filesystem closures, which fakes replace).
    static func attachListingFailures(
        _ failures: [(path: String, message: String)],
        to sources: inout [MemorySource],
        notes: inout [String],
        logPath: (String) -> String
    ) {
        for failure in failures {
            notes.append("memory scan could not list \(logPath(failure.path)): \(failure.message)")
            let match = sources.indices
                .filter { index in
                    let home = sources[index].homePath
                    return failure.path == home || failure.path.hasPrefix(home + "/")
                }
                .max { sources[$0].homePath.count < sources[$1].homePath.count }
            if let match {
                sources[match].footnote = sources[match].footnote
                    ?? "Some folders under this home could not be listed. Check the log for details."
            }
        }
    }

    // MARK: - Shared building blocks

    /// Status from the harness's top-level file: content → ready; blank → empty (unless other
    /// memory artifacts make the source worth showing anyway); absent → missingFile, unless other
    /// artifacts keep the source ready. The sidebar offers Create Instruction File whenever the
    /// file itself is absent, whichever of those two states the source lands in.
    private func fileBackedStatus(instructionsText: String?, hasOtherArtifacts: Bool) -> MemorySourceStatus {
        guard let text = instructionsText else {
            return hasOtherArtifacts ? .ready : .missingFile
        }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .ready }
        return hasOtherArtifacts ? .ready : .empty
    }

    private func fileDocument(path: String, kind: MemoryDocumentKind) -> MemoryDocument {
        MemoryDocument(
            id: path,
            title: URL(fileURLWithPath: path).lastPathComponent,
            subtitle: nil,
            kind: kind,
            location: .file(path: path),
            modificationDate: nil,
            isEditable: true
        )
    }

    private func sourceID(_ harness: Harness, home: String) -> String {
        "\(harness.key):\(canonical(home))"
    }

    /// `readIfPresent` for instruction files, which must distinguish absence from unreadability:
    /// offering Create Instruction File over an unreadable-but-existing file would destroy it, so
    /// the source records the failure and the sidebar explains instead.
    private func readInstruction(_ path: String, notes: inout [String]) -> (text: String?, unreadable: Bool) {
        do {
            return (try files.readTextIfPresent(path), false)
        } catch {
            notes.append("memory scan could not read \(logPath(path)): \(error.localizedDescription)")
            return (nil, true)
        }
    }

    /// A read failure that is not plain absence goes into the notes trail — the scan keeps going,
    /// but the problem stays diagnosable from a default log.
    private func readIfPresent(_ path: String, notes: inout [String]) -> String? {
        var ignored = false
        return readIfPresent(path, notes: &notes, failed: &ignored)
    }

    /// Like `readIfPresent`, but also flips `failed` so per-source traversals can surface a
    /// footnote — a project whose only MEMORY.md is unreadable must not silently vanish.
    private func readIfPresent(_ path: String, notes: inout [String], failed: inout Bool) -> String? {
        do {
            return try files.readTextIfPresent(path)
        } catch {
            notes.append("memory scan could not read \(logPath(path)): \(error.localizedDescription)")
            failed = true
            return nil
        }
    }

    /// Whether `path` exists as a directory, checked through the injected listing so fakes see the
    /// same probe production does (its parent's subdirectory listing must contain it).
    private func directoryPresent(_ path: String) -> Bool {
        let target = canonical(path)
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        return listSubdirectories(parent).contains { canonical($0.path) == target }
    }

    // MARK: - Filesystem defaults

    private static func filesystemSubdirectories(of url: URL, diagnostics: ListingDiagnostics) -> [URL] {
        directoryContents(of: url, keys: [.isDirectoryKey], diagnostics: diagnostics).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    private static func filesystemFiles(of url: URL, diagnostics: ListingDiagnostics) -> [URL] {
        directoryContents(of: url, keys: [.isRegularFileKey], diagnostics: diagnostics).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
    }

    /// Absence is the common benign case and stays silent, but any other listing failure (EACCES on
    /// a restricted `~/.claude/projects`, an I/O error) would silently erase whole project trees
    /// from the sidebar — record it so `scan()` surfaces a note and a source footnote.
    private static func directoryContents(
        of url: URL,
        keys: [URLResourceKey],
        diagnostics: ListingDiagnostics
    ) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: []
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            diagnostics.record(path: url.path, message: error.localizedDescription)
            return []
        }
    }

    // MARK: - Path helpers

    private func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return homeDirectory().path + String(path.dropFirst(1))
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: expandTilde(path)).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Log-safe path: the home prefix is folded to `~` so support logs don't carry the username.
    private func logPath(_ path: String) -> String {
        let home = homeDirectory().path
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
