import Foundation

/// A resumable line parser for append-only JSONL files. The scanner feeds it chunks that end on a
/// line boundary; `state` is the opaque blob the parser returned after the previous chunk of the
/// same file (`nil` at the start of a file), letting a stateful parser carry model context, delta
/// baselines, and similar session-scoped facts across appends without re-reading earlier bytes.
///
/// Return `nil` when the chunk (or the state blob) is unusable — the scanner then skips the file
/// this pass and re-parses it in full on the next one. A stateless parser returns `nil` state.
struct JSONLTailParser<Item: Codable & Sendable>: Sendable {
    var parseChunk: @Sendable (_ chunk: Data, _ state: Data?) -> (items: [Item], state: Data?)?

    init(parseChunk: @escaping @Sendable (_ chunk: Data, _ state: Data?) -> (items: [Item], state: Data?)?) {
        self.parseChunk = parseChunk
    }
}

/// A scan's concatenated items plus the identity's change revision (see
/// `IncrementalJSONLScanner.output(from:since:cacheIdentity:tailParser:)`).
struct JSONLScanOutput<Item: Codable & Sendable>: Sendable {
    var items: [Item]
    var revision: Int
}

/// How the scanner turns one changed file into items: parse the whole file with a stateless
/// closure (the historical behavior), or resume from the previous parse's byte offset when the
/// file only grew.
enum JSONLParseStrategy<Item: Codable & Sendable>: Sendable {
    case wholeFile(@Sendable (Data) -> [Item]?)
    case tail(JSONLTailParser<Item>)
}

/// A changed file scheduled for parsing, plus the resume point when tail parsing is possible.
struct JSONLParseRequest: Sendable {
    var file: JSONLScanning.DiscoveredFile
    var resume: JSONLResumeHint?
}

struct JSONLResumeHint: Sendable {
    var offset: Int
    var state: Data?
    var fingerprint: Int64
}

enum JSONLParseOutcome<Item: Codable & Sendable>: Sendable {
    /// A full parse; `items` replace the file's cached items. A `nil` offset means the file cannot
    /// resume (whole-file parser, or its final line was unterminated at parse time).
    case replaced(items: [Item], offset: Int?, state: Data?, fingerprint: Int64?)
    /// Only the appended tail was parsed; `newItems` extend the previously cached items.
    case appended(newItems: [Item], offset: Int, state: Data?, fingerprint: Int64)
    /// Canceled, missing, or rejected by the parser — leave the file uncached so it retries.
    case skipped
    /// The file exists but could not be read; reported through the read-failure warning.
    case unreadable
}

/// The blocking read/verify/parse half of a scan, run inside the scanner's bounded parse tasks.
enum JSONLTailIO {
    /// How many trailing parsed bytes the resume fingerprint covers. Appends leave this window
    /// intact; an in-place rewrite almost always disturbs it and falls back to a full parse.
    static let fingerprintWindow = 4096

    /// FNV-1a as a stable across-launch fingerprint (same construction as
    /// `JSONLScanCachePaths.stableFingerprint`), bit-cast so it round-trips through a plist.
    static func fingerprint(of bytes: Data) -> Int64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int64(bitPattern: hash)
    }

    /// Count of bytes up to and including the last newline (0 when the data has none). Index-safe
    /// for slices with a nonzero `startIndex`.
    static func lineBoundary(in data: Data) -> Int {
        guard let index = data.lastIndex(of: UInt8(ascii: "\n")) else { return 0 }
        return index - data.startIndex + 1
    }

    static func parse<Item>(
        request: JSONLParseRequest,
        strategy: JSONLParseStrategy<Item>
    ) -> JSONLParseOutcome<Item> {
        switch strategy {
        case .wholeFile(let parse):
            guard let data = FileManager.default.contents(atPath: request.file.path) else {
                return .unreadable
            }
            guard let items = parse(data) else { return .skipped }
            return .replaced(items: items, offset: nil, state: nil, fingerprint: nil)
        case .tail(let parser):
            if let resume = request.resume,
               let outcome = tailParse(file: request.file, resume: resume, parser: parser) {
                return outcome
            }
            guard let data = FileManager.default.contents(atPath: request.file.path) else {
                return .unreadable
            }
            // The whole file is parsed — including a trailing unterminated line, matching the
            // whole-file path byte for byte — but resuming is only armed when the file ends
            // cleanly at a newline. Otherwise the fragment's items are already in `items`, and a
            // later append would re-present those bytes and double-count them.
            guard let parsed = parser.parseChunk(data, nil) else { return .skipped }
            let boundary = lineBoundary(in: data)
            guard boundary == data.count else {
                return .replaced(items: parsed.items, offset: nil, state: nil, fingerprint: nil)
            }
            return .replaced(
                items: parsed.items,
                offset: boundary,
                state: parsed.state,
                fingerprint: fingerprint(of: data.suffix(min(fingerprintWindow, boundary)))
            )
        }
    }

    /// One bounded read covering the fingerprint window plus the appended bytes. `nil` falls back
    /// to a full parse (rewritten prefix, shrunken file, or an I/O hiccup).
    private static func tailParse<Item>(
        file: JSONLScanning.DiscoveredFile,
        resume: JSONLResumeHint,
        parser: JSONLTailParser<Item>
    ) -> JSONLParseOutcome<Item>? {
        guard file.size > resume.offset, resume.offset >= 0,
              let handle = FileHandle(forReadingAtPath: file.path)
        else { return nil }
        defer { try? handle.close() }

        let windowStart = max(0, resume.offset - fingerprintWindow)
        let prefixLength = resume.offset - windowStart
        guard (try? handle.seek(toOffset: UInt64(windowStart))) != nil,
              let buffer = read(from: handle, upTo: file.size - windowStart),
              buffer.count >= prefixLength,
              fingerprint(of: buffer.prefix(prefixLength)) == resume.fingerprint
        else { return nil }

        let appended = buffer.dropFirst(prefixLength)
        let boundary = lineBoundary(in: appended)
        guard boundary > 0 else {
            // The appended bytes contain no complete line. Fall back to a full parse — it handles
            // an unterminated final record (parses it, disables resume), so a writer that stopped
            // mid-line without a newline still gets its last record counted, exactly like the
            // whole-file path. Caching a "nothing new" result here instead would mark those bytes
            // as covered and permanently skip that record if the file never grows again.
            return nil
        }
        // Copy so the parser sees a zero-based chunk containing only whole lines.
        guard let parsed = parser.parseChunk(Data(appended.prefix(boundary)), resume.state) else {
            return nil
        }
        let newOffset = resume.offset + boundary
        let windowLength = min(fingerprintWindow, newOffset)
        let parsedEnd = prefixLength + boundary
        return .appended(
            newItems: parsed.items,
            offset: newOffset,
            state: parsed.state,
            fingerprint: fingerprint(of: Data(buffer[(parsedEnd - windowLength)..<parsedEnd]))
        )
    }

    /// Read until `count` bytes or end of file — `FileHandle.read(upToCount:)` may legally return
    /// short of both, and treating a short read as complete would cache unread bytes as parsed.
    /// `nil` on a read error.
    private static func read(from handle: FileHandle, upTo count: Int) -> Data? {
        var buffer = Data(capacity: count)
        while buffer.count < count {
            guard let chunk = try? handle.read(upToCount: count - buffer.count) else { return nil }
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)
        }
        return buffer
    }
}
