import Foundation
import Darwin

struct ProcessResult: Sendable, Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String

    var succeeded: Bool { exitCode == 0 }
}

protocol ProcessRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult
}

struct SystemProcessRunner: ProcessRunning {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        let process = Process()
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        // Debug-only, basename + arg count only: arg *values* can carry paths/identifiers, so they
        // are never logged here.
        AppLog.debug(.subprocess, "launch \((executable as NSString).lastPathComponent) (\(arguments.count) args)")

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain both pipes on background queues, started BEFORE the child runs. A child that writes
        // more than the OS pipe buffer (~64KB) would otherwise block on write, never exit, and trip the
        // timeout below — reading only after exit deadlocks. (`ps -ax -o command=` alone is ~240KB.)
        let output = SubprocessOutput()
        let drained = DispatchGroup()
        let drains = [
            PipeDrain(stdoutPipe.fileHandleForReading, into: output, isStdout: true, group: drained),
            PipeDrain(stderrPipe.fileHandleForReading, into: output, isStdout: false, group: drained),
        ]

        // One kernel-level wait instead of a 50ms poll loop: the termination handler trips the
        // group (registered before `run()` so an instantly-exiting child can't race it), and
        // `wait` blocks this thread exactly once until exit or the deadline.
        let exited = DispatchGroup()
        exited.enter()
        process.terminationHandler = { _ in exited.leave() }

        do {
            try process.run()
        } catch {
            cancelDrains(drains, group: drained)
            throw error
        }
        let rootIdentity = processIdentity(for: process.processIdentifier)
        let deadline = DispatchTime.now() + timeout

        if exited.wait(timeout: deadline) == .timedOut {
            // The root is still alive, so capture the process tree while its ownership links are
            // reliable. Identity checks keep delayed cleanup from signaling recycled PIDs.
            let descendants = rootIdentity.map { descendantProcesses(of: $0) } ?? []
            signalProcesses(descendants, signal: SIGTERM)
            process.terminate()
            _ = exited.wait(timeout: .now() + 0.1)
            signalProcesses(descendants, signal: SIGKILL)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            cancelDrains(drains, group: drained)
            throw ProcessRunnerError.timedOut(executable: executable, timeout: timeout)
        }

        process.waitUntilExit()
        guard drained.wait(timeout: deadline) == .success else {
            // The direct child can exit while a background descendant still holds its inherited pipe
            // descriptors open. Once the parent exits, ancestry is no longer a safe ownership signal;
            // cancel the bounded readers without targeting a potentially reused process or group ID.
            cancelDrains(drains, group: drained)
            throw ProcessRunnerError.timedOut(executable: executable, timeout: timeout)
        }
        AppLog.debug(.subprocess, "exit \(process.terminationStatus)")
        return ProcessResult(exitCode: process.terminationStatus, stdout: output.stdoutString, stderr: output.stderrString)
    }

    private func descendantProcesses(of parent: ProcessIdentity) -> [ProcessIdentity] {
        guard processIdentity(for: parent.processID) == parent else { return [] }
        let children = childPIDs(of: parent.processID).compactMap { childID -> ProcessSnapshot? in
            guard let child = processSnapshot(for: childID),
                  child.parentProcessID == UInt32(bitPattern: parent.processID)
            else {
                return nil
            }
            return child
        }
        // The parent can exit and its PID can be reused while its child list is being inspected.
        // Discard the entire snapshot unless the same parent still owns the validated child links.
        guard processIdentity(for: parent.processID) == parent else { return [] }
        return children.flatMap { child in
            [child.identity] + descendantProcesses(of: child.identity)
        }
    }

    private func childPIDs(of parentPID: pid_t) -> [pid_t] {
        var capacity = 8
        while true {
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = proc_listchildpids(
                parentPID,
                &pids,
                Int32(MemoryLayout<pid_t>.stride * pids.count)
            )
            guard count > 0 else { return [] }
            guard count < capacity else {
                capacity *= 2
                continue
            }
            return Array(pids.prefix(Int(count)))
        }
    }

    private func processIdentity(for processID: pid_t) -> ProcessIdentity? {
        processSnapshot(for: processID)?.identity
    }

    private func processSnapshot(for processID: pid_t) -> ProcessSnapshot? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(processID)
        else {
            return nil
        }
        return ProcessSnapshot(
            identity: ProcessIdentity(
                processID: processID,
                startedAtSeconds: info.pbi_start_tvsec,
                startedAtMicroseconds: info.pbi_start_tvusec
            ),
            parentProcessID: info.pbi_ppid
        )
    }

    private func signalProcesses(_ processes: [ProcessIdentity], signal: Int32) {
        // A descendant can exit during the TERM grace period and macOS can reuse its PID. Match the
        // immutable start timestamp before signaling so the delayed KILL cannot target a new process.
        for process in processes.reversed() where processIdentity(for: process.processID) == process {
            kill(process.processID, signal)
        }
    }

    private func cancelDrains(_ drains: [PipeDrain], group: DispatchGroup) {
        for drain in drains {
            drain.cancel()
        }
        group.wait()
    }
}

private struct ProcessIdentity: Equatable {
    let processID: pid_t
    let startedAtSeconds: UInt64
    let startedAtMicroseconds: UInt64
}

private struct ProcessSnapshot {
    let identity: ProcessIdentity
    let parentProcessID: UInt32
}

enum ProcessRunnerError: Error, LocalizedError, Equatable {
    case timedOut(executable: String, timeout: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .timedOut(let executable, let timeout):
            return "\(executable) timed out after \(Int(timeout))s."
        }
    }
}

/// Continuously drains one subprocess pipe without dedicating a blocked worker thread. Cancellation
/// stops future reads and closes the descriptor after any active event handler has returned.
final class PipeDrain: @unchecked Sendable {
    private let handle: FileHandle
    private let descriptor: Int32
    private let output: SubprocessOutput
    private let isStdout: Bool
    private let group: DispatchGroup
    private let source: DispatchSourceRead

    init(_ handle: FileHandle, into output: SubprocessOutput, isStdout: Bool, group: DispatchGroup) {
        self.handle = handle
        self.descriptor = handle.fileDescriptor
        self.output = output
        self.isStdout = isStdout
        self.group = group
        self.source = DispatchSource.makeReadSource(
            fileDescriptor: handle.fileDescriptor,
            queue: DispatchQueue.global(qos: .utility)
        )

        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        }

        group.enter()
        source.setEventHandler { [weak self] in
            self?.readAvailableData()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            try? self.handle.close()
            self.group.leave()
        }
        source.resume()
    }

    func cancel() {
        source.cancel()
    }

    private func readAvailableData() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        // Read at most one successful chunk per event. Returning to the dispatch source between
        // chunks lets a pending cancellation handler run even when a writer keeps the pipe readable.
        while !source.isCancelled {
            let byteCount = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if byteCount > 0 {
                output.append(Data(buffer.prefix(byteCount)), isStdout: isStdout)
                return
            } else if byteCount == 0 {
                source.cancel()
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                source.cancel()
                return
            }
        }
    }
}

/// Lock-guarded accumulator for the two concurrently-drained pipes.
final class SubprocessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func append(_ data: Data, isStdout: Bool) {
        lock.lock()
        if isStdout {
            stdout.append(data)
        } else {
            stderr.append(data)
        }
        lock.unlock()
    }

    var stdoutString: String { lock.lock(); defer { lock.unlock() }; return String(data: stdout, encoding: .utf8) ?? "" }
    var stderrString: String { lock.lock(); defer { lock.unlock() }; return String(data: stderr, encoding: .utf8) ?? "" }
}
