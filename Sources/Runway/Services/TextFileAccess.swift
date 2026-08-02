import Foundation

protocol TextFileAccessing: Sendable {
    func exists(_ path: String) -> Bool
    /// Read a UTF-8 file when it exists. `nil` means the path is absent; permission, encoding, and
    /// other failures still throw so credential callers do not confuse broken storage with logout.
    func readTextIfPresent(_ path: String) throws -> String?
    func readText(_ path: String) throws -> String
    func writeText(_ path: String, _ text: String) throws
    /// Write like `writeText`, but keep the destination's existing POSIX permissions instead of
    /// forcing the private credential mode. Memory and instruction files are shared with other
    /// tools, so a save must not tighten what the harness created. New files get 0644.
    func writeTextPreservingMode(_ path: String, _ text: String) throws
    /// Remove the file at `path`. A missing file is not an error — the caller wants the key gone, and
    /// it already is. Used by the in-app API-key editor's Remove / Clear-override actions.
    func remove(_ path: String) throws
    /// Create the directory that will contain `path` (with intermediates). Writes land in a temp
    /// file beside the destination, so a first-ever file in a not-yet-existing folder (Grok's
    /// `memory/MEMORY.md`) needs this before the write. No-op default for in-memory test doubles.
    func ensureParentDirectory(for path: String) throws
    /// Atomically create `path` with `text` only when nothing exists there yet; returns false when
    /// the destination already exists (that content stands — creating means "make the file
    /// exist"). The local accessor publishes with an exclusive rename, so a file another process
    /// creates between any pre-check and the publish is never clobbered.
    func createTextFileExclusively(_ path: String, _ text: String) throws -> Bool
}

extension TextFileAccessing {
    /// Compatibility path for test doubles. The production accessor classifies the read error directly
    /// so it does not have an exists-then-read race.
    func readTextIfPresent(_ path: String) throws -> String? {
        guard exists(path) else { return nil }
        return try readText(path)
    }

    /// Compatibility path for test doubles that store text in memory and have no mode to preserve.
    func writeTextPreservingMode(_ path: String, _ text: String) throws {
        try writeText(path, text)
    }

    /// No-op for in-memory test doubles; the local accessor creates real directories.
    func ensureParentDirectory(for path: String) throws {}

    /// Check-then-write for in-memory test doubles, which have no concurrent writers.
    func createTextFileExclusively(_ path: String, _ text: String) throws -> Bool {
        guard !exists(path) else { return false }
        try ensureParentDirectory(for: path)
        try writeTextPreservingMode(path, text)
        return true
    }
}

struct LocalTextFileAccessor: TextFileAccessing {
    /// Credential and token files must never be readable by another local account. Write through a
    /// private temporary file in the destination directory, flush it, then rename it over the target:
    /// the final replacement is atomic and has mode 0600 from the moment it becomes addressable.
    private static let privateFileMode = mode_t(S_IRUSR | S_IWUSR)
    /// Default for freshly created non-credential files (0644) — the mode a plain shell `touch`
    /// would produce, used when `writeTextPreservingMode` has no existing file to copy from.
    private static let sharedFileMode = mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: expandHome(path))
    }

    func readText(_ path: String) throws -> String {
        try String(contentsOfFile: expandHome(path), encoding: .utf8)
    }

    func readTextIfPresent(_ path: String) throws -> String? {
        do {
            return try readText(path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func writeText(_ path: String, _ text: String) throws {
        try write(path, text, mode: Self.privateFileMode)
    }

    func writeTextPreservingMode(_ path: String, _ text: String) throws {
        // Copy the destination's current permission bits so overwriting a shared file (a harness's
        // CLAUDE.md, a memory fact) cannot tighten it to the credential-only 0600.
        let expanded = expandHome(path)
        var status = stat()
        // Unqualified call: `Darwin.stat` names the struct, shadowing the C function.
        let statResult = expanded.withCString { stat($0, &status) }
        if statResult == 0 {
            try write(path, text, mode: status.st_mode & 0o7777)
        } else if errno == ENOENT {
            // A brand-new file honors the process umask: the kernel applies it at open(2), so
            // skipping the exact-mode reassertion lets a restrictive umask (077 on a shared Mac)
            // strip group/other bits naturally — with no process-wide umask fiddling that could
            // race other threads' file creation. Preserved modes reassert exactly: the umask must
            // never tighten what the harness already had.
            try write(path, text, mode: Self.sharedFileMode, reassertingExactMode: false)
        } else {
            throw Self.currentPOSIXError()
        }
    }

    private func write(_ path: String, _ text: String, mode: mode_t, reassertingExactMode: Bool = true) throws {
        // Resolve symlinks before publishing: `rename` replaces a destination symlink with a plain
        // file instead of following it. Memory and instruction files (CLAUDE.md, AGENTS.md, …) are
        // commonly symlinked into a dotfiles repo — the save must land in the link's target, exactly
        // where `readText` read from, or the target silently diverges from what the editor shows.
        let expanded = URL(fileURLWithPath: expandHome(path)).resolvingSymlinksInPath().path
        let parent = URL(fileURLWithPath: expanded).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let destination = URL(fileURLWithPath: expanded)
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = temporary.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode)
        }
        guard descriptor >= 0 else { throw Self.currentPOSIXError() }

        var descriptorIsOpen = true
        var temporaryExists = true
        defer {
            if descriptorIsOpen { _ = Darwin.close(descriptor) }
            if temporaryExists {
                temporary.path.withCString { _ = Darwin.unlink($0) }
            }
        }

        // A process umask may only remove permissions at creation. Callers preserving an existing
        // file's exact mode reassert it on the still-unpublished inode; brand-new files skip this
        // so the kernel-applied umask stands.
        if reassertingExactMode {
            guard Darwin.fchmod(descriptor, mode) == 0 else {
                throw Self.currentPOSIXError()
            }
        }
        try Self.writeAll(Data(text.utf8), to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else { throw Self.currentPOSIXError() }
        let closeResult = Darwin.close(descriptor)
        descriptorIsOpen = false
        guard closeResult == 0 else { throw Self.currentPOSIXError() }

        let renameResult = temporary.path.withCString { source in
            expanded.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        guard renameResult == 0 else { throw Self.currentPOSIXError() }
        temporaryExists = false
    }

    func remove(_ path: String) throws {
        let expanded = expandHome(path)
        guard FileManager.default.fileExists(atPath: expanded) else { return }
        try FileManager.default.removeItem(atPath: expanded)
    }

    func ensureParentDirectory(for path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (expandHome(path) as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
    }

    func createTextFileExclusively(_ path: String, _ text: String) throws -> Bool {
        var expanded = URL(fileURLWithPath: expandHome(path)).resolvingSymlinksInPath().path
        // A DANGLING symlink resolves to itself (there is no target inode to land on), and the
        // exclusive rename would see the link entry and report EEXIST forever — a silent no-op
        // Create. Follow the link text manually so creation lands where the link points, exactly
        // like a write-through of an intact link.
        var hops = 0
        while hops < 8,
              let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: expanded) {
            expanded = destination.hasPrefix("/")
                ? destination
                : URL(fileURLWithPath: expanded).deletingLastPathComponent()
                    .appendingPathComponent(destination).standardized.path
            hops += 1
        }
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: expanded)) != nil {
            // A cycle (or an absurd chain): the exclusive rename would EEXIST against the link
            // entry and read as "another writer won" — Create silently doing nothing forever.
            // Fail loudly instead; the editor surfaces the error.
            throw POSIXError(.ELOOP)
        }
        try ensureParentDirectory(for: expanded)
        let destination = URL(fileURLWithPath: expanded)
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        // The kernel applies the umask at open(2), like every brand-new file this accessor makes.
        let descriptor = temporary.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, Self.sharedFileMode)
        }
        guard descriptor >= 0 else { throw Self.currentPOSIXError() }

        var descriptorIsOpen = true
        var temporaryExists = true
        defer {
            if descriptorIsOpen { _ = Darwin.close(descriptor) }
            if temporaryExists {
                temporary.path.withCString { _ = Darwin.unlink($0) }
            }
        }
        try Self.writeAll(Data(text.utf8), to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else { throw Self.currentPOSIXError() }
        descriptorIsOpen = false
        guard Darwin.close(descriptor) == 0 else { throw Self.currentPOSIXError() }

        // RENAME_EXCL makes the publish itself the existence check: whoever renames first wins,
        // and a destination that appeared since any earlier probe surfaces as EEXIST, not a
        // clobber.
        let renameResult = temporary.path.withCString { source in
            expanded.withCString { target in
                renamex_np(source, target, UInt32(RENAME_EXCL))
            }
        }
        if renameResult == 0 {
            temporaryExists = false
            return true
        }
        if errno == EEXIST {
            return false
        }
        throw Self.currentPOSIXError()
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw currentPOSIXError()
                }
                guard result > 0 else { throw POSIXError(.EIO) }
                offset += result
            }
        }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
