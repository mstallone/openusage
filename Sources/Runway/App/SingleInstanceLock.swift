import Darwin
import Foundation

/// Kernel-backed single-instance lock, closing the startup race `SingleInstanceGuard` (#635/#637)
/// can't: the guard decides from an `NSRunningApplication` snapshot, and when two copies launch
/// near-simultaneously LaunchServices can hand each a snapshot containing only itself — both
/// conclude "no older peer" and keep running. An exclusive `flock` on a per-bundle file is atomic
/// in the kernel: exactly one process holds it no matter how the launches interleave. The kernel
/// also releases it when the holder exits or crashes, so a stale lock can never block a relaunch.
enum SingleInstanceLock {
    enum Acquisition {
        case acquired(Token)
        case alreadyRunning
        case failed(String)
    }

    /// Owns the lock for the process lifetime — keeps the descriptor open so the kernel keeps the
    /// `flock` held. Dropping the token unlocks and closes the descriptor.
    final class Token {
        private let fd: CInt

        fileprivate init(fd: CInt) {
            self.fd = fd
        }

        deinit {
            flock(fd, LOCK_UN)
            Darwin.close(fd)
        }
    }

    /// Locks `Application Support/Runway/<bundle id>.lock` — a directory the app already uses
    /// for its own state, and stable no matter where the app bundle itself lives.
    static func acquire(bundleIdentifier: String) -> Acquisition {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return .failed("Application Support directory unavailable")
        }
        let lockURL = appSupport
            .appendingPathComponent("Runway", isDirectory: true)
            .appendingPathComponent("\(bundleIdentifier).lock")
        return acquire(at: lockURL)
    }

    /// Split out from the well-known-path entry point so tests can aim the lock at a temp file.
    static func acquire(at lockURL: URL) -> Acquisition {
        do {
            try FileManager.default.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return .failed(error.localizedDescription)
        }

        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else {
            return .failed(String(cString: strerror(errno)))
        }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            Darwin.close(fd)
            return lockError == EWOULDBLOCK ? .alreadyRunning : .failed(String(cString: strerror(lockError)))
        }

        return .acquired(Token(fd: fd))
    }
}
