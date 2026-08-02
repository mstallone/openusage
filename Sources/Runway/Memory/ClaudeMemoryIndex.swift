import Foundation

/// Parses and edits a Claude Code `MEMORY.md` index, whose entries are list
/// lines shaped like `- [Title](file.md) — hook` (em dash; the hook is optional).
///
/// Entries are matched by link target (the file name), never by title. Edits
/// are line-exact: every other line — headings, blank lines, non-entry list
/// items — is preserved byte-for-byte.
struct ClaudeMemoryIndex {
    struct Entry: Equatable, Sendable {
        var title: String
        var fileName: String
        var hook: String?
    }

    /// All index entries found in `text`, in document order.
    static func entries(in text: String) -> [Entry] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { parseEntry(String($0)) }
    }

    /// Drops every entry line whose link target is `fileName`, leaving all
    /// other text untouched. Returns `text` unchanged when nothing matches.
    static func removingEntry(forFile fileName: String, from text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { parseEntry($0)?.fileName != fileName }
            .joined(separator: "\n")
    }

    /// Appends `entry` as a new `- [Title](file.md) — hook` line, handling
    /// text with and without a trailing newline. The result always ends with
    /// a newline. A `](` inside the title would end the link text early and
    /// break the round-trip through `parseEntry` (leaving an undeletable
    /// entry), so it is defused with a space; file names are slugified and
    /// can't contain the closing `)`.
    static func appendingEntry(_ entry: Entry, to text: String) -> String {
        let title = entry.title.replacingOccurrences(of: "](", with: "] (")
        var line = "- [\(title)](\(entry.fileName))"
        if let hook = entry.hook, !hook.isEmpty {
            line += " — \(hook)"
        }
        if text.isEmpty { return line + "\n" }
        return text.hasSuffix("\n") ? text + line + "\n" : text + "\n" + line + "\n"
    }

    /// `- [Title](file.md) — hook` → Entry; anything else → nil.
    private static func parseEntry(_ line: String) -> Entry? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- [") else { return nil }
        let afterMarker = trimmed.dropFirst("- [".count)
        guard let titleEnd = afterMarker.range(of: "](") else { return nil }
        let title = String(afterMarker[..<titleEnd.lowerBound])
        let afterTitle = afterMarker[titleEnd.upperBound...]
        guard let linkEnd = afterTitle.firstIndex(of: ")") else { return nil }
        let fileName = String(afterTitle[..<linkEnd])
        guard !fileName.isEmpty else { return nil }
        let remainder = afterTitle[afterTitle.index(after: linkEnd)...]
        return Entry(title: title, fileName: fileName, hook: parseHook(remainder))
    }

    /// The text after the link, expected as ` — hook`; nil when absent.
    private static func parseHook(_ remainder: Substring) -> String? {
        var hook = remainder.drop { $0 == " " }
        guard hook.first == "—" else { return nil }
        hook = hook.dropFirst().drop { $0 == " " }
        return hook.isEmpty ? nil : String(hook)
    }
}
