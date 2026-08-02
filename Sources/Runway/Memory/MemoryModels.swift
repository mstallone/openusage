import Foundation

/// Where a memory document's content lives.
enum MemoryDocumentLocation: Hashable, Sendable {
    case file(path: String)
    case sqliteRow(dbPath: String, threadID: String)
}

enum MemoryDocumentKind: Hashable, Sendable {
    case instructions
    case memoryIndex
    case fact
    case legacyMemory
    case databaseMemory
}

struct MemoryDocument: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var subtitle: String?
    var kind: MemoryDocumentKind
    var location: MemoryDocumentLocation
    var modificationDate: Date?
    var isEditable: Bool
}

/// One Claude-style per-project memory directory: MEMORY.md index plus fact files.
struct MemoryProjectGroup: Identifiable, Hashable, Sendable {
    var id: String
    var slug: String
    var displayName: String
    var displayPath: String?
    var indexDocument: MemoryDocument?
    var facts: [MemoryDocument]

    /// Absolute path of the memory directory (same as `id`).
    var directoryPath: String { id }
}

enum MemorySourceStatus: Hashable, Sendable {
    case ready
    case empty
    case missingFile
    case memoryDisabled(note: String)

    /// The sidebar's section ranking: something to read now, then nothing-yet homes (one click
    /// from useful), then features turned off elsewhere. Shared by the scanner's initial sort and
    /// the store's re-sort after database listing can demote a source.
    var sortRank: Int {
        switch self {
        case .ready: return 0
        case .empty, .missingFile: return 1
        case .memoryDisabled: return 2
        }
    }
}

/// One harness config home and everything memory-related found inside it.
struct MemorySource: Identifiable, Hashable, Sendable {
    var id: String
    var harness: String
    var homePath: String
    var status: MemorySourceStatus
    var instructions: MemoryDocument?
    var projects: [MemoryProjectGroup]
    var legacyDocuments: [MemoryDocument]
    var databaseDocuments: [MemoryDocument]
    var footnote: String?

    var allDocuments: [MemoryDocument] {
        var docs: [MemoryDocument] = []
        if let instructions { docs.append(instructions) }
        for project in projects {
            if let index = project.indexDocument { docs.append(index) }
            docs.append(contentsOf: project.facts)
        }
        docs.append(contentsOf: legacyDocuments)
        docs.append(contentsOf: databaseDocuments)
        return docs
    }
}
