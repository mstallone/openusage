import Foundation

struct SakanaMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

/// Decodes the authenticated Next.js React Flight payload embedded in Sakana Console's billing page.
/// This is intentionally isolated at the system boundary because the console page is not a public API.
enum SakanaUsageMapper {
    static let sessionPeriodMs = 5 * 60 * 60 * 1000
    static let weeklyPeriodMs = 7 * 24 * 60 * 60 * 1000

    static func validateSession(_ response: HTTPResponse, now: Date = Date()) throws {
        if response.statusCode == 401 || response.statusCode == 403 {
            throw SakanaAuthError.sessionExpired
        }
        guard (200..<300).contains(response.statusCode) else {
            throw SakanaUsageError.requestFailed(response.statusCode)
        }
        guard let root = ProviderParse.jsonObject(response.body),
              root["user"] is [String: Any],
              let expires = (root["expires"] as? String).flatMap(RunwayISO8601.date(from:)),
              expires > now
        else {
            throw SakanaAuthError.sessionExpired
        }
    }

    static func mapBilling(_ response: HTTPResponse) throws -> SakanaMappedUsage {
        if response.statusCode == 401 || response.statusCode == 403 {
            throw SakanaAuthError.sessionExpired
        }
        guard (200..<300).contains(response.statusCode) else {
            throw SakanaUsageError.requestFailed(response.statusCode)
        }
        guard let html = String(data: response.body, encoding: .utf8) else {
            throw SakanaUsageError.invalidResponse
        }
        let flight = try decodedFlightStrings(in: html).joined()
        guard let status = try jsonObjectValue(named: "usageLimitStatus", in: flight) else {
            throw SakanaUsageError.invalidResponse
        }

        // Sakana represents a valid, unused subscription window as JSON null. Keep missing keys
        // distinct from explicit nulls: null is a real zero-usage state, while a missing key means
        // the private console contract changed and must not be silently displayed as zero.
        guard status.keys.contains("window_usage"),
              status.keys.contains("weekly_usage")
        else {
            throw SakanaUsageError.invalidResponse
        }
        let window = try quotaRow(status["window_usage"])
        let weekly = try quotaRow(status["weekly_usage"])

        let lines: [MetricLine] = [
            .progress(
                label: "Five-Hour Usage",
                used: ProviderParse.clampPercent(window.usedPercent),
                limit: 100,
                format: .percent,
                resetsAt: window.resetsAt,
                periodDurationMs: sessionPeriodMs
            ),
            .progress(
                label: "Weekly Usage",
                used: ProviderParse.clampPercent(weekly.usedPercent),
                limit: 100,
                format: .percent,
                resetsAt: weekly.resetsAt,
                periodDurationMs: weeklyPeriodMs
            )
        ]
        let rawPlan = window.plan ?? weekly.plan
        return SakanaMappedUsage(plan: rawPlan.map(planTitle), lines: lines)
    }

    private struct QuotaRow {
        var plan: String?
        var usedPercent: Double
        var resetsAt: Date?
    }

    private static func quotaRow(_ raw: Any?) throws -> QuotaRow {
        if raw is NSNull {
            return QuotaRow(plan: nil, usedPercent: 0, resetsAt: nil)
        }
        guard let object = raw as? [String: Any],
              let percent = ProviderParse.number(object["usage_percent"]),
              percent.isFinite
        else {
            throw SakanaUsageError.invalidResponse
        }
        let resetsAt: Date?
        if let reset = object["reset_at"] as? String {
            guard let parsed = RunwayISO8601.date(from: reset) else {
                throw SakanaUsageError.invalidResponse
            }
            resetsAt = parsed
        } else {
            resetsAt = nil
        }
        let plan = (object["plan"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return QuotaRow(plan: plan, usedPercent: percent, resetsAt: resetsAt)
    }

    private static func planTitle(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    /// Each `self.__next_f.push(...)` argument is JSON even though it sits inside JavaScript. Decode
    /// those arrays normally rather than trying to hand-unescape their strings.
    private static func decodedFlightStrings(in html: String) throws -> [String] {
        let marker = "self.__next_f.push("
        var strings: [String] = []
        var cursor = html.startIndex
        while let range = html[cursor...].range(of: marker) {
            let start = range.upperBound
            guard let end = endOfJavaScriptArgument(in: html, from: start) else {
                throw SakanaUsageError.invalidResponse
            }
            let argument = String(html[start..<end])
            guard let data = argument.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
            else {
                throw SakanaUsageError.invalidResponse
            }
            strings += array.compactMap { $0 as? String }
            cursor = html.index(after: end)
        }
        guard !strings.isEmpty else { throw SakanaUsageError.invalidResponse }
        return strings
    }

    private static func endOfJavaScriptArgument(in text: String, from start: String.Index) -> String.Index? {
        var index = start
        var depth = 0
        var inString = false
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"":
                    inString = true
                case "[", "{":
                    depth += 1
                case "]", "}":
                    depth -= 1
                case ")" where depth == 0:
                    return index
                default:
                    break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func jsonObjectValue(named name: String, in text: String) throws -> [String: Any]? {
        let marker = "\"\(name)\""
        guard let nameRange = text.range(of: marker) else { return nil }
        var index = nameRange.upperBound
        while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
        guard index < text.endIndex, text[index] == ":" else {
            throw SakanaUsageError.invalidResponse
        }
        index = text.index(after: index)
        while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
        guard index < text.endIndex, text[index] == "{",
              let end = endOfJSONObject(in: text, from: index)
        else {
            throw SakanaUsageError.invalidResponse
        }
        let json = String(text[index...end])
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw SakanaUsageError.invalidResponse
        }
        return object
    }

    private static func endOfJSONObject(in text: String, from start: String.Index) -> String.Index? {
        var index = start
        var depth = 0
        var inString = false
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
