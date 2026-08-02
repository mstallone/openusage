import Foundation

/// One `stage1_outputs` row from a Codex `memories_1.sqlite` database.
struct CodexMemoryRow: Equatable, Sendable {
    var threadID: String
    var rawMemory: String
    var rolloutSummary: String?
    var rolloutSlug: String?
    var generatedAt: String?
    var usageCount: Int?
    var lastUsage: String?
}

/// Read-only view of a Codex home's `memories_1.sqlite`.
///
/// The inventory scanner only records that the database file exists; the row
/// listing and body fetches happen here, both through `SQLiteAccessing`'s
/// read-only JSON query so a missing database is never created. Listing selects
/// metadata columns only — a memory's bodies load on demand via `loadRow`.
struct CodexMemoryDatabase: Sendable {
    var sqlite: any SQLiteAccessing

    init(sqlite: any SQLiteAccessing = SQLiteCLIAccessor()) {
        self.sqlite = sqlite
    }

    /// The newest 500 memories as read-only documents, without bodies. A
    /// missing database and an empty table both come back as an empty list.
    func listDocuments(dbPath: String) throws -> [MemoryDocument] {
        let sql = """
        SELECT thread_id, rollout_slug, generated_at, usage_count, last_usage \
        FROM stage1_outputs ORDER BY generated_at DESC LIMIT 500
        """
        guard let json = try sqlite.queryJSONRows(path: dbPath, sql: sql) else { return [] }
        return try decodeRows(json).map { row in
            MemoryDocument(
                id: "sqlite:\(dbPath)#\(row.threadID)",
                title: title(for: row),
                subtitle: subtitle(for: row),
                kind: .databaseMemory,
                location: .sqliteRow(dbPath: dbPath, threadID: row.threadID),
                modificationDate: nil,
                isEditable: false
            )
        }
    }

    /// One memory's bodies plus metadata for the editor's read-only view.
    func loadRow(dbPath: String, threadID: String) throws -> CodexMemoryRow {
        // Single-quote doubling is the SQL string-literal escape; thread ids
        // are the only interpolated value.
        let escaped = threadID.replacingOccurrences(of: "'", with: "''")
        let sql = """
        SELECT thread_id, raw_memory, rollout_summary, rollout_slug, generated_at, usage_count, last_usage \
        FROM stage1_outputs WHERE thread_id = '\(escaped)' LIMIT 1
        """
        guard let json = try sqlite.queryJSONRows(path: dbPath, sql: sql),
              let row = try decodeRows(json).first else {
            throw CodexMemoryDatabaseError.rowNotFound(threadID: threadID)
        }
        return CodexMemoryRow(
            threadID: row.threadID,
            rawMemory: row.rawMemory ?? "",
            rolloutSummary: row.rolloutSummary,
            rolloutSlug: row.rolloutSlug,
            generatedAt: row.generatedAt,
            usageCount: row.usageCount,
            lastUsage: row.lastUsage
        )
    }

    // MARK: - Row decoding

    /// A `sqlite3 -json` row; every column but `thread_id` may be NULL or unselected, and the
    /// timestamp columns are INTEGER unix seconds in current databases but TEXT in older ones.
    private struct RawRow: Decodable {
        var threadID: String
        var rawMemory: String?
        var rolloutSummary: String?
        var rolloutSlug: String?
        var generatedAt: String?
        var usageCount: Int?
        var lastUsage: String?

        enum CodingKeys: String, CodingKey {
            case threadID = "thread_id"
            case rawMemory = "raw_memory"
            case rolloutSummary = "rollout_summary"
            case rolloutSlug = "rollout_slug"
            case generatedAt = "generated_at"
            case usageCount = "usage_count"
            case lastUsage = "last_usage"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            threadID = try container.decode(String.self, forKey: .threadID)
            rawMemory = try container.decodeIfPresent(String.self, forKey: .rawMemory)
            rolloutSummary = try container.decodeIfPresent(String.self, forKey: .rolloutSummary)
            rolloutSlug = try container.decodeIfPresent(String.self, forKey: .rolloutSlug)
            generatedAt = try Self.timestamp(container, .generatedAt)
            usageCount = try Self.count(container, .usageCount)
            lastUsage = try Self.timestamp(container, .lastUsage)
        }

        /// TEXT passes through; numeric unix seconds (or milliseconds) become an ISO-8601 string
        /// so the display code has one shape to handle.
        private static func timestamp(
            _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
        ) throws -> String? {
            if let text = try? container.decodeIfPresent(String.self, forKey: key) { return text }
            guard var seconds = try container.decodeIfPresent(Double.self, forKey: key) else { return nil }
            if seconds > 1e12 { seconds /= 1000 }
            return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
        }

        private static func count(
            _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
        ) throws -> Int? {
            if let number = try? container.decodeIfPresent(Int.self, forKey: key) { return number }
            guard let text = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
            return Int(text)
        }
    }

    private func decodeRows(_ json: String) throws -> [RawRow] {
        do {
            return try JSONDecoder().decode([RawRow].self, from: Data(json.utf8))
        } catch {
            throw CodexMemoryDatabaseError.malformedRows(String(describing: error))
        }
    }

    // MARK: - Display mapping

    /// The rollout slug when present, otherwise a shortened thread id.
    private func title(for row: RawRow) -> String {
        if let slug = row.rolloutSlug, !slug.isEmpty { return slug }
        guard row.threadID.count > 8 else { return row.threadID }
        return String(row.threadID.prefix(8)) + "…"
    }

    private func subtitle(for row: RawRow) -> String? {
        var parts: [String] = []
        if let generatedAt = row.generatedAt, !generatedAt.isEmpty {
            parts.append(datePortion(of: generatedAt))
        }
        switch row.usageCount {
        case nil: break
        case 0: parts.append("never used")
        case 1: parts.append("used once")
        case let count?: parts.append("used \(count) times")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// `2026-07-30T12:34:56Z` → `2026-07-30`; a value without a time part passes through.
    private func datePortion(of timestamp: String) -> String {
        guard let separator = timestamp.firstIndex(where: { $0 == "T" || $0 == " " }) else {
            return timestamp
        }
        return String(timestamp[..<separator])
    }
}

enum CodexMemoryDatabaseError: Error, LocalizedError, Equatable {
    case malformedRows(String)
    case rowNotFound(threadID: String)

    var errorDescription: String? {
        switch self {
        case .malformedRows(let detail):
            return "The Codex memory database returned unreadable rows: \(detail)"
        case .rowNotFound(let threadID):
            return "Memory \(threadID) was not found in the Codex database."
        }
    }
}
