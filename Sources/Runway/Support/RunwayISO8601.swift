import Foundation

/// Shared ISO-8601 date parsing/formatting used by multiple providers and the local API. Normalizes
/// the various timestamp shapes providers return (space-separated, " UTC" suffix, variable fractional
/// digits) before parsing.
enum RunwayISO8601 {
    static func string(from date: Date) -> String {
        formatter(fractionalSeconds: true).string(from: date)
    }

    static func date(from value: String) -> Date? {
        let normalized = normalizeTimestamp(value)
        return formatter(fractionalSeconds: true).date(from: normalized) ??
        formatter(fractionalSeconds: false).date(from: normalized)
    }

    private static func normalizeTimestamp(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }

        if s.hasSuffix(" UTC") {
            s = String(s.dropLast(4)) + "Z"
        }

        guard let match = timestampPattern.firstMatch(
            in: s,
            range: NSRange(s.startIndex..., in: s)
        ),
              let dateRange = Range(match.range(at: 1), in: s),
              let timeRange = Range(match.range(at: 2), in: s)
        else {
            return s
        }

        let head = "\(s[dateRange])T\(s[timeRange])"
        var frac = ""
        if match.range(at: 3).location != NSNotFound,
           let fracRange = Range(match.range(at: 3), in: s) {
            var digits = String(s[fracRange]).dropFirst()
            if digits.count > 3 {
                digits = digits.prefix(3)
            }
            while digits.count < 3 {
                digits.append("0")
            }
            frac = ".\(digits)"
        }

        var tz = "Z"
        if match.range(at: 4).location != NSNotFound,
           let tzRange = Range(match.range(at: 4), in: s) {
            tz = String(s[tzRange])
        }

        return head + frac + tz
    }

    // One immutable matcher handles all provider variants. Constructing NSRegularExpression inside
    // this hot path dominated timestamp parsing when refreshing large local log histories.
    private static let timestampPattern = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})?$"#
    )

    // ISO8601DateFormatter is expensive to construct and is hit on every snapshot decode and local-API
    // encode, so the two fixed configurations are built once. `ISO8601DateFormatter` is thread-safe for
    // parsing/formatting, and parsing here runs on the main-actor refresh path; `nonisolated(unsafe)`
    // shares the immutable instances without per-call allocation.
    private nonisolated(unsafe) static let fractionalFormatter = makeFormatter(fractionalSeconds: true)
    private nonisolated(unsafe) static let plainFormatter = makeFormatter(fractionalSeconds: false)

    private static func formatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        fractionalSeconds ? fractionalFormatter : plainFormatter
    }

    private static func makeFormatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }
}
