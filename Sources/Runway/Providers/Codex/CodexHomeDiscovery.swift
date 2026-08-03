import Foundation

/// Launch-time scan for Codex CLI homes beyond the one currently supplying the default card.
///
/// A file-backed candidate must contain a decodable `auth.json`, a usable OAuth access token, and a
/// provider-owned account identity (`tokens.account_id` or the ChatGPT account claim in `id_token`).
/// A keyring-backed home participates only after a prior exact-item read cached that same identity
/// under the item's current metadata fingerprint. Path-derived identities are forbidden.
///
/// Candidates are explicit `CODEX_HOME` entries, dot-directories at `~`, and directories directly
/// under `~/.config`. The scan is synchronous, bounded, and reads no Keychain secrets.
struct CodexHomeDiscovery {
    struct Finding: Equatable, Sendable {
        var identityKey: String
        var label: String?
        /// Expanded path used by both the scoped auth store and the local log scanner.
        var anchorPath: String
    }

    struct Result: Sendable {
        var findings: [Finding] = []
        /// Exact keyring homes whose identity cache is absent or stale. They stay hidden this launch;
        /// a retained post-launch task reads each item once to bind it for the next launch.
        var unverifiedKeyringHomes: Set<String> = []
        /// Token-free and email-free support trail for diagnosing rejected homes.
        var notes: [String] = []
    }

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var keychain: KeychainReading
    var identityCache: (any CodexHomeIdentityCaching)?
    var homeDirectory: @Sendable () -> URL
    var listSubdirectories: @Sendable (URL) -> [URL]
    var timeBudget: TimeInterval
    var now: @Sendable () -> Date

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainReading = SecurityKeychainAccessor(),
        identityCache: (any CodexHomeIdentityCaching)? = nil,
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        listSubdirectories: @escaping @Sendable (URL) -> [URL] = Self.filesystemSubdirectories,
        timeBudget: TimeInterval = 0.4,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.identityCache = identityCache
        self.homeDirectory = homeDirectory
        self.listSubdirectories = listSubdirectories
        self.timeBudget = timeBudget
        self.now = now
    }

    func run(excluding excludedPaths: Set<String> = []) -> Result {
        let started = now()
        let excluded = Set(excludedPaths.map(canonical))
        var result = Result()

        for candidate in candidateDirectories() {
            if now().timeIntervalSince(started) > timeBudget {
                result.notes.append(
                    "codex home scan hit its \(Int(timeBudget * 1000))ms budget; finishing with partial results"
                )
                break
            }
            guard !excluded.contains(canonical(candidate.path)) else { continue }
            if let finding = finding(at: candidate, result: &result) {
                result.findings.append(finding)
            }
        }
        return result
    }

    /// Ordered, canonical-path-deduplicated candidate set. Explicit `CODEX_HOME` entries join the
    /// set so a configured home outside the bounded directory walk still participates.
    private func candidateDirectories() -> [URL] {
        let home = homeDirectory()
        var candidates = configuredHomes().map { URL(fileURLWithPath: $0) }
        candidates += listSubdirectories(home).filter { $0.lastPathComponent.hasPrefix(".") }
        candidates += listSubdirectories(home.appendingPathComponent(".config"))

        var seen = Set<String>()
        return candidates
            .sorted { $0.path < $1.path }
            .filter { seen.insert(canonical($0.path)).inserted }
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

    private func finding(at url: URL, result: inout Result) -> Finding? {
        let authPath = url.path + "/auth.json"
        let authFileExists = files.exists(authPath)
        let explicitlyConfigured = configuredHomes().contains {
            canonical($0) == canonical(url.path)
        }
        let looksLikeCodexHome = authFileExists
            || files.exists(url.path + "/config.toml")
            || files.exists(url.path + "/sessions")
            || explicitlyConfigured
        guard looksLikeCodexHome else { return nil }

        let fileAuth = authFileExists
            ? (try? files.readText(authPath)).flatMap(CodexAuthStore.parseAuth)
            : nil
        let fileHasOAuth = fileAuth?.tokens?.accessToken?.nilIfEmpty != nil
        let fileIdentity = fileHasOAuth ? fileAuth.flatMap(DefaultAccountObserver.codexIdentity) : nil

        let canonicalHome = canonical(url.path)
        let account = CodexAuthStore.keychainAccountName(forHome: canonicalHome)
        switch keychain.genericPasswordExists(
            service: CodexAuthStore.keychainService,
            account: account
        ) {
        case false:
            guard let fileIdentity else {
                if authFileExists {
                    let reason = fileHasOAuth
                        ? "OAuth credential names no account"
                        : "auth.json present but has no usable OAuth token"
                    result.notes.append(
                        "codex candidate \(logPath(url.path)): \(reason) → skipped"
                    )
                }
                return nil
            }
            result.notes.append(
                "codex candidate \(logPath(url.path)): accepted (\(hash8(fileIdentity.key)), auth.json)"
            )
            return Finding(
                identityKey: fileIdentity.key,
                label: fileIdentity.label,
                anchorPath: url.path
            )
        case true:
            guard let fingerprint = keychain.genericPasswordAttributeFingerprint(
                service: CodexAuthStore.keychainService,
                account: account
            ),
                let keychainIdentity = identityCache?.identity(
                    forHome: canonicalHome,
                    keychainItemFingerprint: fingerprint
                )
            else {
                result.unverifiedKeyringHomes.insert(canonicalHome)
                result.notes.append(
                    "codex candidate \(logPath(url.path)): keyring identity unverified → hidden until its exact item is bound"
                )
                return nil
            }
            if let fileIdentity, fileIdentity.key != keychainIdentity.key {
                result.unverifiedKeyringHomes.insert(canonicalHome)
                result.notes.append(
                    "codex candidate \(logPath(url.path)): auth file and keyring identities disagree → hidden"
                )
                return nil
            }
            let identity = fileIdentity ?? keychainIdentity
            result.notes.append(
                "codex candidate \(logPath(url.path)): accepted (\(hash8(identity.key)), verified keyring)"
            )
            return Finding(
                identityKey: identity.key,
                label: identity.label,
                anchorPath: url.path
            )
        case nil:
            result.unverifiedKeyringHomes.insert(canonicalHome)
            result.notes.append(
                "codex candidate \(logPath(url.path)): keyring attributes unavailable → hidden"
            )
            return nil
        }
    }

    /// Every explicit home when `CODEX_HOME` is a comma-separated list. With no override, both
    /// historical homes join the scan; whichever one the observer selected is excluded by assembly.
    private func configuredHomes() -> [String] {
        if let raw = environment.value(for: "CODEX_HOME")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            let homes = raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map(expandTilde)
            if !homes.isEmpty { return homes }
        }
        let home = homeDirectory()
        return [
            home.appendingPathComponent(".config/codex").path,
            home.appendingPathComponent(".codex").path,
        ]
    }

    private func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return homeDirectory().path + String(path.dropFirst(1))
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: expandTilde(path))
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
    }

    private func logPath(_ path: String) -> String {
        let home = homeDirectory().path
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private func hash8(_ identityKey: String) -> String {
        ProviderAccountID.hash8(identityKey)
    }
}
