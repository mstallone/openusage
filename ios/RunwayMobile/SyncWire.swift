import Foundation

/// Decode-only mirrors of the payloads Runway for Mac publishes to CloudKit (one `DeviceUsage`
/// record per device, `history` + `snapshot` byte fields). The wire contract is the schema string
/// inside each payload — `runway.history.v2` and `runway.snapshot.v1` — written and round-trip
/// tested by the Mac app. Decoding ignores keys it doesn't render, so additive Mac-side changes
/// never break this app; a schema bump surfaces as a friendly "update" message instead.
enum SyncWire {
    static let historySchemas: Set<String> = ["runway.history.v1", "runway.history.v2"]
    static let snapshotSchemas: Set<String> = ["runway.snapshot.v1"]

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - History payload (merged for cross-device totals)

struct HistoryDocument: Decodable {
    var schema: String
    var deviceID: String
    var deviceName: String
    var updatedAt: Date
    var providers: [String: ProviderHistory]
    var identities: [String: String]?
}

struct ProviderHistory: Decodable {
    var series: DailySeries
    /// Day → names of models the Mac couldn't price; their usage is EXCLUDED from `series`, so
    /// combined totals must warn when any fall inside the displayed window.
    var unknownModelsByDay: [String: [String]]?
}

struct DailySeries: Decodable {
    var daily: [DailyEntry]
}

struct DailyEntry: Decodable {
    var date: String
    var totalTokens: Int
    var costUSD: Double?
}

// MARK: - Snapshot payload (each device's live rendered state)

struct SnapshotDocument: Decodable {
    var schema: String
    var deviceID: String
    var deviceName: String
    var updatedAt: Date
    var snapshots: [String: ProviderSnapshotWire]
    var providerErrors: [String: String]
    /// Display names for error-only providers (no snapshot to take a title from).
    var providerNames: [String: String]?
}

struct ProviderSnapshotWire: Decodable {
    var providerID: String
    var displayName: String
    var plan: String?
    var refreshedAt: Date
    var warning: String?
    var lines: [MetricLineWire]
}

struct MetricValueWire: Decodable {
    var number: Double
    var kind: MetricKindWire
    var label: String?
    var estimated: Bool
}

enum MetricKindWire: String, Decodable {
    case percent, dollars, count
}

struct ProgressFormatWire: Decodable {
    var kind: MetricKindWire
    var suffix: String?
}

/// The rendered rows a Mac's dashboard shows, in wire form. Unknown line types decode as
/// `.unsupported` rather than failing the whole snapshot, so a newer Mac can add row kinds freely.
enum MetricLineWire: Decodable {
    case text(label: String, value: String, subtitle: String?)
    case values(label: String, values: [MetricValueWire], unknownModels: [String])
    case progress(label: String, used: Double, limit: Double, format: ProgressFormatWire, resetsAt: Date?)
    case badge(label: String, text: String, subtitle: String?)
    case chart(label: String, points: [ChartPointWire], note: String?)
    case unsupported

    var label: String? {
        switch self {
        case .text(let label, _, _), .values(let label, _, _), .progress(let label, _, _, _, _),
             .badge(let label, _, _), .chart(let label, _, _):
            return label
        case .unsupported:
            return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, label, value, values, used, limit, format, resetsAt, unknownModels, text, points, note, subtitle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let label = try container.decode(String.self, forKey: .label)
        switch try container.decode(String.self, forKey: .type) {
        case "text":
            self = .text(
                label: label,
                value: try container.decode(String.self, forKey: .value),
                subtitle: try container.decodeIfPresent(String.self, forKey: .subtitle)
            )
        case "values":
            self = .values(
                label: label,
                values: try container.decode([MetricValueWire].self, forKey: .values),
                unknownModels: try container.decodeIfPresent([String].self, forKey: .unknownModels) ?? []
            )
        case "progress":
            self = .progress(
                label: label,
                used: try container.decode(Double.self, forKey: .used),
                limit: try container.decode(Double.self, forKey: .limit),
                format: try container.decode(ProgressFormatWire.self, forKey: .format),
                resetsAt: try container.decodeIfPresent(Date.self, forKey: .resetsAt)
            )
        case "badge":
            self = .badge(
                label: label,
                text: try container.decode(String.self, forKey: .text),
                subtitle: try container.decodeIfPresent(String.self, forKey: .subtitle)
            )
        case "chart":
            self = .chart(
                label: label,
                points: try container.decode([ChartPointWire].self, forKey: .points),
                note: try container.decodeIfPresent(String.self, forKey: .note)
            )
        default:
            self = .unsupported
        }
    }
}

struct ChartPointWire: Decodable {
    var value: Double
    var label: String
    var valueLabel: String?
}

// MARK: - Display formatting

enum UsageFormat {
    static func dollars(_ value: Double) -> String {
        "$" + value.formatted(.number.precision(.fractionLength(value >= 100 ? 0 : 2)))
    }

    /// Counts below a million print in full with thousands separators ("58,342"); larger ones
    /// stay compact ("1.2M", "3.4B") so rows don't overflow.
    static func tokens(_ value: Double) -> String {
        let magnitude = abs(value)
        switch magnitude {
        case 1_000_000_000...: return String(format: "%.1fB", value / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", value / 1_000_000)
        default: return value.formatted(.number.precision(.fractionLength(0)))
        }
    }

    static func value(_ value: MetricValueWire) -> String {
        switch value.kind {
        // "~" marks spend imputed locally by the Mac rather than measured or billed.
        case .dollars: return (value.estimated ? "~" : "") + dollars(value.number)
        case .percent: return String(format: "%.0f%%", value.number)
        case .count: return tokens(value.number) + (value.label.map { " \($0)" } ?? "")
        }
    }

    static func progress(used: Double, limit: Double, format: ProgressFormatWire) -> String {
        switch format.kind {
        case .percent: return String(format: "%.0f%%", used)
        case .dollars: return "\(dollars(used)) of \(dollars(limit))"
        case .count:
            let suffix = format.suffix.map { " \($0)" } ?? ""
            return "\(tokens(used)) of \(tokens(limit))\(suffix)"
        }
    }
}
