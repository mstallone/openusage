import Foundation

/// Best-effort decoder for Claude-style project directory slugs, where an absolute path is
/// flattened by replacing `/` (and a component's leading `.`) with `-`:
/// `/Users/dev/.superset/worktrees/abc/my-branch` → `-Users-dev--superset-worktrees-abc-my-branch`.
///
/// The encoding is lossy — real components may themselves contain dashes — so the decoder
/// greedily splits at each dash and verifies every partial path against the filesystem,
/// backtracking (with a bounded probe budget) whenever a prefix does not exist. For each
/// candidate component it also tries the `.`-prefixed variant, since a doubled dash usually
/// signals a dot-directory. Display-only: callers fall back to the raw slug when decoding fails.
struct ProjectSlugDecoder: Sendable {
    /// Injected for tests; the default asks the real filesystem.
    var directoryExists: @Sendable (String) -> Bool = { path in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Upper bound on filesystem probes per decode, so a pathological dash-heavy slug stays cheap.
    private static let probeBudget = 256

    /// Decode `slug` into a verified absolute path, or `nil` when no full path checks out.
    func bestEffortPath(fromSlug slug: String) -> String? {
        guard slug.hasPrefix("-"), slug.count > 1 else { return nil }
        var probesRemaining = Self.probeBudget
        return decode(remainder: slug.dropFirst(), prefix: "", probesRemaining: &probesRemaining)
    }

    /// Depth-first search: cut one component off the front of `remainder` (splitting at each dash,
    /// shortest first), verify `prefix + "/" + component` exists, and recurse into the rest.
    private func decode(
        remainder: Substring, prefix: String, probesRemaining: inout Int
    ) -> String? {
        var cut = remainder.startIndex
        while true {
            let raw = remainder[remainder.startIndex..<cut]
            for component in candidates(forRawComponent: raw) {
                guard probesRemaining > 0 else { return nil }
                probesRemaining -= 1

                let path = prefix + "/" + component
                guard directoryExists(path) else { continue }
                if cut == remainder.endIndex { return path }

                let rest = remainder[remainder.index(after: cut)...]
                if let full = decode(remainder: rest, prefix: path, probesRemaining: &probesRemaining) {
                    return full
                }
            }

            guard cut < remainder.endIndex else { return nil }
            // Extend the component across the dash we just tried splitting at.
            guard let nextDash = remainder[remainder.index(after: cut)...].firstIndex(of: "-") else {
                cut = remainder.endIndex
                continue
            }
            cut = nextDash
        }
    }

    /// The spellings a raw slug segment could stand for, most likely first. A segment that starts
    /// with a dash (from a doubled dash in the slug) most often encodes a dot-directory; a plain
    /// segment is usually literal, but the dot-prefixed variant is still probed as a fallback for
    /// encoders that keep the dot out of the slug.
    private func candidates(forRawComponent raw: Substring) -> [String] {
        guard !raw.isEmpty else { return [] }
        if raw.hasPrefix("-") {
            return ["." + raw.dropFirst(), String(raw)]
        }
        return [String(raw), "." + raw]
    }
}
