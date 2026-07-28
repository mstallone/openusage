import Foundation

/// Normalizes the managed Kimi Code `/usages` response used by the official CLI's `/usage` command.
/// The API is not a public contract, so the boundary parser intentionally accepts the field aliases
/// and numeric strings the CLI accepts while emitting a small, stable set of Runway labels.
enum KimiUsageMapper {
    static let sessionPeriodMs = 5 * 60 * 60 * 1000
    static let weeklyPeriodMs = 7 * 24 * 60 * 60 * 1000
    static let monthlyPeriodMs = 30 * 24 * 60 * 60 * 1000

    static func map(_ body: Data, now: Date = Date()) throws -> [MetricLine] {
        guard let root = ProviderParse.jsonObject(body) else {
            throw KimiUsageError.invalidResponse
        }

        let summary = quotaRow(root["usage"], now: now)
        let rawLimits = root["limits"] as? [Any] ?? []
        let limits = rawLimits.compactMap { raw -> ClassifiedRow? in
            guard let item = raw as? [String: Any] else { return nil }
            let detail = item["detail"] as? [String: Any] ?? item
            guard var row = quotaRow(detail, now: now) else { return nil }
            let window = item["window"] as? [String: Any] ?? [:]
            if let seconds = durationSeconds(item: item, detail: detail, window: window),
               seconds <= Double(Int.max) / 1_000 {
                row.periodDurationMs = Int(seconds * 1_000)
            }
            return ClassifiedRow(row: row, kind: classify(item: item, detail: detail))
        }

        // The top-level `usage` object is Kimi's weekly summary. Prefer explicit window/name
        // classification for the limits, then use documented product semantics as a conservative
        // fallback: the first non-summary limit is the rolling five-hour window.
        var session = limits.first(where: { $0.kind == .session })?.row
        var weekly = summary ?? limits.first(where: { $0.kind == .weekly })?.row
        let unclassified = limits.filter { $0.kind == nil }.map(\.row)
        var consumedFirstUnclassified = false
        if session == nil {
            session = unclassified.first
            consumedFirstUnclassified = session != nil
        }
        if weekly == nil {
            weekly = unclassified.dropFirst(consumedFirstUnclassified ? 1 : 0).first
        }

        var lines: [MetricLine] = []
        if let session {
            lines.append(progressLine(
                label: "Five-Hour Usage",
                row: session,
                defaultPeriodMs: sessionPeriodMs
            ))
        }
        if let weekly {
            lines.append(progressLine(
                label: "Weekly Usage",
                row: weekly,
                defaultPeriodMs: weeklyPeriodMs
            ))
        }
        lines += extraUsageLines(root["boosterWallet"])
        MetricLine.appendNoDataIfNeeded(&lines)
        return lines
    }

    private enum WindowKind {
        case session
        case weekly
    }

    private struct QuotaRow {
        var used: Double
        var limit: Double
        var resetsAt: Date?
        var periodDurationMs: Int?
    }

    private struct ClassifiedRow {
        var row: QuotaRow
        var kind: WindowKind?
    }

    private static func quotaRow(_ raw: Any?, now: Date) -> QuotaRow? {
        guard let object = raw as? [String: Any],
              let limit = ProviderParse.number(object["limit"]),
              limit >= 0
        else {
            return nil
        }
        let used: Double
        if let direct = ProviderParse.number(object["used"]), direct >= 0 {
            used = direct
        } else if let remaining = ProviderParse.number(object["remaining"]), remaining >= 0 {
            used = max(0, limit - remaining)
        } else {
            return nil
        }
        return QuotaRow(
            used: used,
            limit: limit,
            resetsAt: resetDate(object, now: now),
            periodDurationMs: nil
        )
    }

    private static func classify(item: [String: Any], detail: [String: Any]) -> WindowKind? {
        let window = item["window"] as? [String: Any] ?? [:]
        let label = [
            item["name"], item["title"], item["scope"],
            detail["name"], detail["title"], detail["scope"]
        ]
        .compactMap { $0 as? String }
        .joined(separator: " ")
        .lowercased()

        if label.contains("week") || label.contains("7d") || label.contains("7 d") {
            return .weekly
        }
        if label.contains("5h") || label.contains("5 h") || label.contains("5-hour")
            || label.contains("5 hour") || label.contains("session") {
            return .session
        }

        guard let seconds = durationSeconds(item: item, detail: detail, window: window) else {
            return nil
        }
        return seconds < 24 * 60 * 60 ? .session : .weekly
    }

    private static func progressLine(label: String, row: QuotaRow, defaultPeriodMs: Int) -> MetricLine {
        let percent = row.limit > 0
            ? ProviderParse.clampPercent(row.used / row.limit * 100)
            : 0
        return .progress(
            label: label,
            used: percent,
            limit: 100,
            format: .percent,
            resetsAt: row.resetsAt,
            periodDurationMs: row.periodDurationMs ?? defaultPeriodMs
        )
    }

    private static func extraUsageLines(_ raw: Any?) -> [MetricLine] {
        guard let wallet = raw as? [String: Any],
              let balance = wallet["balance"] as? [String: Any],
              (balance["type"] as? String) == "BOOSTER",
              let totalRaw = integer(balance["amount"]),
              totalRaw > 0
        else {
            return []
        }

        let balanceRaw = integer(balance["amountLeft"]) ?? 0
        let balanceCents = fixedPointToCents(balanceRaw)
        let monthlyLimit = money(wallet["monthlyChargeLimit"])
        let monthlyUsed = money(wallet["monthlyUsed"])
        let currency = (monthlyLimit?.currency.nilIfEmpty ?? monthlyUsed?.currency.nilIfEmpty ?? "USD")
            .uppercased()
        let usedAmount = Double(monthlyUsed?.cents ?? 0) / 100
        let balanceAmount = Double(balanceCents) / 100

        var lines: [MetricLine] = [
            .values(
                label: "Extra Usage Balance",
                values: [currencyValue(balanceAmount, currency: currency)]
            )
        ]

        let capEnabled = ProviderParse.bool(wallet["monthlyChargeLimitEnabled"]) == true
        if capEnabled, let limitCents = monthlyLimit?.cents, limitCents > 0 {
            lines.append(.progress(
                label: "Monthly Extra Usage",
                used: usedAmount,
                limit: Double(limitCents) / 100,
                format: currency == "USD" ? .dollars : .count(suffix: currency),
                periodDurationMs: monthlyPeriodMs
            ))
        } else {
            lines.append(.values(
                label: "Monthly Extra Usage",
                values: [currencyValue(usedAmount, currency: currency)]
            ))
        }
        return lines
    }

    private static func resetDate(_ object: [String: Any], now: Date) -> Date? {
        for key in ["reset_at", "resetAt", "reset_time", "resetTime"] {
            if let value = object[key] as? String,
               let date = RunwayISO8601.date(from: value) {
                return date
            }
        }
        for key in ["reset_in", "resetIn", "ttl", "window"] {
            if let seconds = ProviderParse.number(object[key]), seconds > 0 {
                return now.addingTimeInterval(seconds)
            }
        }
        return nil
    }

    private static func durationSeconds(
        item: [String: Any],
        detail: [String: Any],
        window: [String: Any]
    ) -> Double? {
        guard let duration = ProviderParse.number(
            window["duration"] ?? item["duration"] ?? detail["duration"]
        ), duration > 0 else {
            return nil
        }
        let rawUnit = window["timeUnit"] ?? item["timeUnit"] ?? detail["timeUnit"]
        let unit = (rawUnit as? String)?.uppercased() ?? ""
        if unit.contains("MINUTE") { return duration * 60 }
        if unit.contains("HOUR") { return duration * 60 * 60 }
        if unit.contains("DAY") { return duration * 24 * 60 * 60 }
        if unit.contains("WEEK") { return duration * 7 * 24 * 60 * 60 }
        return duration
    }

    private struct Money {
        var cents: Int
        var currency: String
    }

    private static func money(_ raw: Any?) -> Money? {
        guard let object = raw as? [String: Any],
              let cents = integer(object["priceInCents"])
        else {
            return nil
        }
        return Money(cents: cents, currency: object["currency"] as? String ?? "")
    }

    private static func integer(_ raw: Any?) -> Int? {
        guard let number = ProviderParse.number(raw),
              number >= Double(Int.min),
              number <= Double(Int.max)
        else {
            return nil
        }
        return Int(number.rounded(.towardZero))
    }

    /// Kimi's booster balance is fixed point: 1,000,000 raw units equal one cent. Mirror the CLI's
    /// minimum-one-cent treatment so a small positive remainder never displays as a false zero.
    private static func fixedPointToCents(_ raw: Int) -> Int {
        let cents = Double(raw) / 1_000_000
        if cents > 0, cents < 1 { return 1 }
        return Int(cents.rounded())
    }

    private static func currencyValue(_ amount: Double, currency: String) -> MetricValue {
        if currency == "USD" {
            return MetricValue(number: amount, kind: .dollars)
        }
        return MetricValue(number: amount, kind: .count, label: currency)
    }
}
