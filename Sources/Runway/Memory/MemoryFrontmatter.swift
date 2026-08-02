import Foundation

/// The YAML-ish frontmatter block Claude Code writes at the top of memory fact files. Line-based
/// and tolerant, parsing only the observed keys (`name`, `description`, `metadata.type`) — it never
/// round-trips an existing file, so unknown keys are simply skipped, not preserved.
struct MemoryFrontmatter: Equatable, Sendable {
    var name: String?
    var description: String?
    /// `metadata.type`: user | feedback | project | reference.
    var type: String?

    /// Splits `text` into a parsed frontmatter block and the body that follows it. When the text
    /// has no leading `---` fence, or the fence never closes, the frontmatter is nil and the body
    /// is the whole text unchanged. The body is always byte-identical to what follows the closing
    /// fence line (including any leading blank line).
    static func parse(_ text: String) -> (frontmatter: MemoryFrontmatter?, body: Substring) {
        let full = text[...]
        var cursor = full.startIndex

        guard let opening = nextLine(in: full, from: &cursor), trimmed(opening) == "---" else {
            return (nil, full)
        }

        var frontmatter = MemoryFrontmatter()
        var inMetadataBlock = false
        while let line = nextLine(in: full, from: &cursor) {
            if trimmed(line) == "---" {
                return (frontmatter, full[cursor...])
            }
            if line.hasPrefix("  ") {
                // Two-space-indented child of the last `metadata:` line; other blocks are skipped.
                guard inMetadataBlock, let (key, value) = keyValue(from: line.dropFirst(2)) else { continue }
                if key == "type" { frontmatter.type = value }
                continue
            }
            inMetadataBlock = false
            guard let (key, value) = keyValue(from: line) else { continue }
            switch key {
            case "name": frontmatter.name = value
            case "description": frontmatter.description = value
            case "metadata": inMetadataBlock = true
            default: break
            }
        }
        // Ran off the end without a closing fence: not frontmatter after all.
        return (nil, full)
    }

    /// The full text of a brand-new fact file, matching the on-disk shape Claude Code writes:
    /// frontmatter with `name`, `description`, and `metadata.type`, then an empty body.
    static func template(name: String, description: String, type: String) -> String {
        """
        ---
        name: \(name)
        description: \(description)
        metadata:
          type: \(type)
        ---


        """
    }

    /// Returns the line starting at `cursor` (without its newline) and moves `cursor` past it,
    /// or nil when the end of `text` was reached.
    private static func nextLine(in text: Substring, from cursor: inout Substring.Index) -> Substring? {
        guard cursor < text.endIndex else { return nil }
        let lineStart = cursor
        if let newline = text[cursor...].firstIndex(of: "\n") {
            cursor = text.index(after: newline)
            return text[lineStart..<newline]
        }
        cursor = text.endIndex
        return text[lineStart...]
    }

    /// Splits a `key: value` line; nil when there is no colon or the key is empty. Values lose
    /// surrounding whitespace and one pair of double quotes (descriptions are quoted on disk);
    /// a bare `key:` yields nil for the value.
    private static func keyValue(from line: Substring) -> (key: String, value: String?)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = trimmed(line[..<colon])
        guard !key.isEmpty else { return nil }
        var value = trimmed(line[line.index(after: colon)...])
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return (key, value.isEmpty ? nil : value)
    }

    private static func trimmed(_ line: Substring) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }
}
