import Foundation
@testable import Runway

final class ConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0

    var maximumActive: Int {
        lock.withLock { maximum }
    }

    func begin() {
        lock.withLock {
            active += 1
            maximum = max(maximum, active)
        }
    }

    func end() {
        lock.withLock {
            active -= 1
        }
    }
}

final class WarningRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCounts: [Int] = []

    var counts: [Int] {
        lock.withLock { recordedCounts }
    }

    func record(_ count: Int) {
        lock.withLock {
            recordedCounts.append(count)
        }
    }
}

/// Records every chunk handed to a stateless tail parser that reads one `Int` per line.
final class ChunkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var chunks: [String] {
        lock.withLock { recorded }
    }

    var parser: JSONLTailParser<Int> {
        JSONLTailParser { [self] chunk, _ in
            lock.withLock { recorded.append(String(decoding: chunk, as: UTF8.self)) }
            let items = chunk.split(separator: UInt8(ascii: "\n")).compactMap {
                Int(String(decoding: $0, as: UTF8.self))
            }
            return (items, nil)
        }
    }
}

final class ParseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let delay: TimeInterval
    private var recordedCount = 0

    init(delay: TimeInterval = 0) {
        self.delay = delay
    }

    var count: Int {
        lock.withLock { recordedCount }
    }

    func parse(_ data: Data) -> [Int]? {
        lock.withLock { recordedCount += 1 }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return String(data: data, encoding: .utf8).flatMap(Int.init).map { [$0] }
    }
}

final class BlockingParser: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private let release = DispatchSemaphore(value: 0)

    var hasStarted: Bool {
        lock.withLock { started }
    }

    func parse(_ data: Data) -> [Int]? {
        lock.withLock { started = true }
        release.wait()
        return String(data: data, encoding: .utf8).flatMap(Int.init).map { [$0] }
    }

    func unblock() {
        release.signal()
    }
}
