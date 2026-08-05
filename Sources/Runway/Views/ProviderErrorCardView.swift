import SwiftUI

/// The card body a provider shows instead of its metric rows when its refresh failed and there is
/// no last-good data to keep on screen — a login awaiting Keychain approval, a fresh install that
/// isn't signed in. A column of empty "No data" bars tells the user nothing; this states the
/// problem and carries the one action that can move it forward: a manual Refresh, the explicit
/// user gesture that is allowed to show a Keychain approval prompt.
///
/// Once a provider has any last-good data, the dashboard keeps the metric rows and surfaces the
/// error on the header triangle instead (see `WidgetDataStore.emptyStateError(for:)`).
struct ProviderErrorCardView: View {
    struct Copy: Equatable {
        var title: String
        var description: String
    }

    /// How the prompt reads: `.warning` (amber triangle, "Refresh") for a real failure the user
    /// must fix, `.connect` (neutral key glyph, "Connect") for a credential that exists but simply
    /// hasn't been loaded into this process yet — nothing is broken and nothing was denied.
    enum Style {
        case warning
        case connect
    }

    let message: String
    let isRefreshing: Bool
    /// The share-card export sets this false: a Refresh button in a static PNG is dead chrome, and
    /// the exported card already strips interactive elements (grips, spinners, toggles).
    var showsRefreshAction: Bool = true
    var style: Style = .warning
    let onRefresh: () -> Void

    var body: some View {
        let copy = Self.copy(for: message)
        // Same anatomy as `DismissableHintCard` (glyph, title, caption, small button) so the two
        // read as one family, minus its dismiss control — an error state can't be waved away. The
        // button sits centered under the whole body: it acts on the card, not on the text column.
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: style == .connect ? "key.fill" : "exclamationmark.triangle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(style == .connect ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 4) {
                    Text(copy.title)
                        .font(.subheadline.weight(.semibold))
                    Text(copy.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if showsRefreshAction {
                Button(style == .connect ? "Connect" : "Refresh", action: onRefresh)
                    .controlSize(.small)
                    .disabled(isRefreshing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Provider error strings follow a "Short statement. Guidance." shape ("Claude Code login
    /// found. Connect to load it; if macOS asks, choose Always Allow…"), so the first sentence
    /// becomes the title — title-cased, since it renders as one — and the rest the description. A
    /// message without that shape (an HTTP failure line) keeps a generic title so a long sentence
    /// never renders as bold headline text.
    static func copy(for message: String) -> Copy {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: ". ") {
            let title = String(trimmed[..<range.lowerBound])
            let description = String(trimmed[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty, !description.isEmpty {
                return Copy(title: titleCased(title), description: description)
            }
        }
        return Copy(title: "Can't Load Usage", description: trimmed)
    }

    /// Words kept lowercase mid-title (articles, short prepositions, conjunctions). The first and
    /// last words always capitalize, per standard title-case conventions.
    private static let lowercaseTitleWords: Set<String> = [
        "a", "an", "and", "as", "at", "but", "by", "for", "in", "of", "on", "or", "the", "to", "with",
    ]

    /// Title-cases a sentence-case error statement ("Claude Code login found" → "Claude Code Login
    /// Found") so derived headings follow the same title rule as hardcoded ones. Words already
    /// carrying capitals past their first letter (macOS, product names) and code-quoted words
    /// (`claude`) pass through untouched.
    static func titleCased(_ statement: String) -> String {
        let words = statement.split(separator: " ")
        return words.enumerated().map { index, word in
            let text = String(word)
            if text.contains("`") || text.dropFirst().contains(where: \.isUppercase) {
                return text
            }
            let isEdgeWord = index == 0 || index == words.count - 1
            if !isEdgeWord, Self.lowercaseTitleWords.contains(text.lowercased()) {
                return text.lowercased()
            }
            return text.prefix(1).uppercased() + text.dropFirst()
        }
        .joined(separator: " ")
    }
}
