import Darwin
import Foundation

/// A held cross-process OAuth refresh lock. Release is idempotent so every error path can safely
/// call it from `defer`-style cleanup without removing a lock acquired by a later process.
struct KimiRefreshLockLease: Sendable {
    private let releaseImpl: @Sendable () async -> Void

    init(release: @escaping @Sendable () async -> Void = {}) {
        releaseImpl = release
    }

    func release() async {
        await releaseImpl()
    }
}

protocol KimiRefreshLocking: Sendable {
    func acquire(homeDirectory: String, credentialName: String) async throws -> KimiRefreshLockLease
}

/// Coordinates with Kimi Code's own `proper-lockfile` lock at
/// `$KIMI_CODE_HOME/oauth/kimi-code.lock`.
///
/// Refresh tokens rotate on every grant. Without this shared lock, Runway and a concurrently
/// running Kimi Code process could both spend the same refresh token, leaving one process with a
/// revoked session. The retry/stale timings and heartbeat match the official CLI.
struct KimiOAuthRefreshLock: KimiRefreshLocking {
    private static let retryCount = 120
    private static let retryIntervalMicroseconds: useconds_t = 500_000
    private static let staleAfter: TimeInterval = 5
    private static let heartbeatInterval: Duration = .seconds(2)
    private static let privateMode = mode_t(S_IRUSR | S_IWUSR)

    var environment: EnvironmentReading

    init(environment: EnvironmentReading = ProcessEnvironmentReader()) {
        self.environment = environment
    }

    func acquire(homeDirectory: String, credentialName: String) async throws -> KimiRefreshLockLease {
        if environment.value(for: "KIMI_DISABLE_OAUTH_LOCK") == "1" {
            return KimiRefreshLockLease()
        }
        return try await Task.detached(priority: .utility) {
            try Self.acquireBlocking(
                homeDirectory: homeDirectory,
                credentialName: credentialName
            )
        }.value
    }

    private static func acquireBlocking(
        homeDirectory: String,
        credentialName: String
    ) throws -> KimiRefreshLockLease {
        guard !credentialName.isEmpty,
              credentialName == URL(fileURLWithPath: credentialName).lastPathComponent,
              !credentialName.hasPrefix(".")
        else {
            throw KimiAuthError.refreshLockFailed
        }
        let home = expandHome(homeDirectory).trimmingTrailingSlashes
        let lockParent = home + "/oauth"
        let target = lockParent + "/" + credentialName
        let lockPath = target + ".lock"

        do {
            try FileManager.default.createDirectory(
                atPath: lockParent,
                withIntermediateDirectories: true
            )
        } catch {
            throw KimiAuthError.refreshLockFailed
        }

        // `proper-lockfile` locks a sentinel target and creates `<target>.lock`. Create the same
        // private sentinel so either process can be the first one to refresh.
        let targetDescriptor = target.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, privateMode)
        }
        guard targetDescriptor >= 0 else {
            throw KimiAuthError.refreshLockFailed
        }
        guard Darwin.close(targetDescriptor) == 0 else {
            throw KimiAuthError.refreshLockFailed
        }

        for attempt in 0...retryCount {
            if Task.isCancelled {
                throw CancellationError()
            }
            if lockPath.withCString({ Darwin.mkdir($0, S_IRWXU) }) == 0 {
                guard let identity = identity(of: lockPath) else {
                    _ = lockPath.withCString { Darwin.rmdir($0) }
                    throw KimiAuthError.refreshLockFailed
                }
                touch(lockPath, onlyIf: identity)
                return makeLease(path: lockPath, identity: identity)
            }

            guard errno == EEXIST else {
                throw KimiAuthError.refreshLockFailed
            }
            if isStale(lockPath) {
                _ = lockPath.withCString { Darwin.rmdir($0) }
                continue
            }
            guard attempt < retryCount else {
                throw KimiAuthError.refreshLockFailed
            }
            Darwin.usleep(retryIntervalMicroseconds)
        }
        throw KimiAuthError.refreshLockFailed
    }

    private static func makeLease(path: String, identity: FileIdentity) -> KimiRefreshLockLease {
        let releaseState = KimiLockReleaseState()
        let heartbeat = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: heartbeatInterval)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                touch(path, onlyIf: identity)
            }
        }

        return KimiRefreshLockLease {
            guard releaseState.beginRelease() else { return }
            heartbeat.cancel()
            await heartbeat.value
            guard Self.identity(of: path) == identity else { return }
            _ = path.withCString { Darwin.rmdir($0) }
        }
    }

    private static func isStale(_ path: String) -> Bool {
        var info = stat()
        guard path.withCString({ Darwin.lstat($0, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR
        else {
            return false
        }
        let modified = TimeInterval(info.st_mtimespec.tv_sec)
            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return Date().timeIntervalSince1970 - modified > staleAfter
    }

    private static func identity(of path: String) -> FileIdentity? {
        var info = stat()
        guard path.withCString({ Darwin.lstat($0, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR
        else {
            return nil
        }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    private static func touch(_ path: String, onlyIf identity: FileIdentity) {
        guard self.identity(of: path) == identity else { return }
        _ = path.withCString { Darwin.utimes($0, nil) }
    }
}

private struct FileIdentity: Equatable, Sendable {
    var device: dev_t
    var inode: ino_t
}

private final class KimiLockReleaseState: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false

    func beginRelease() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return false }
        released = true
        return true
    }
}
