import Charts
import SwiftUI
import WidgetKit

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: UsageEntry

    var body: some View {
        if let usage = entry.usage {
            switch family {
            case .accessoryInline: InlineUsageView(usage: usage, mode: entry.mode, stale: entry.stale)
            case .accessoryCircular: CircularUsageView(usage: usage, mode: entry.mode, stale: entry.stale)
            case .accessoryRectangular: RectangularUsageView(usage: usage, mode: entry.mode, stale: entry.stale)
            case .systemMedium: MediumUsageView(usage: usage, mode: entry.mode, stale: entry.stale)
            default: SmallUsageView(usage: usage, mode: entry.mode, stale: entry.stale)
            }
        } else {
            NoUsageView(notice: entry.notice ?? .noRecentUsage, family: family)
        }
    }
}

/// The dashboard's incomplete-totals marker, widget-sized: some payload was unreadable or some
/// models unpriced, so the numbers undercount. (Inline and circular have no room; the larger
/// families all carry it.)
private struct PartialWarningIcon: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .imageScale(.small)
    }
}

/// Fetch age, shown when the entry is serving cached numbers after a failed refresh.
private struct FetchAgeText: View {
    var date: Date

    var body: some View {
        Text(date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
    }
}

/// Cost mode keeps the dashboards' honesty rule: "$4.20" when the day priced, "58,342 tok" when
/// only tokens were measured, "—" when absent — never "$0.00" for a day whose costs weren't
/// priced. Tokens mode shows the measured count outright (bare; context labels carry the unit).
private func dayValue(_ day: WidgetUsage.Day?, mode: UsageDisplayMode) -> String {
    guard let day else { return "—" }
    switch mode {
    case .cost:
        if let cost = day.cost { return UsageFormat.dollars(cost) }
        return UsageFormat.tokens(Double(day.tokens)) + " tok"
    case .tokens:
        return UsageFormat.tokens(Double(day.tokens))
    }
}

private func last30Value(_ usage: WidgetUsage, mode: UsageDisplayMode) -> String {
    switch mode {
    case .cost:
        if let cost = usage.last30Cost { return UsageFormat.dollars(cost) }
        if usage.last30Tokens > 0 { return UsageFormat.tokens(Double(usage.last30Tokens)) + " tok" }
        return "—"
    case .tokens:
        return UsageFormat.tokens(Double(usage.last30Tokens))
    }
}

private struct InlineUsageView: View {
    var usage: WidgetUsage
    var mode: UsageDisplayMode
    var stale: Bool

    var body: some View {
        // The one line of context-free text: tokens need their unit spelled out here, and a
        // cached value carries its fetch age.
        let value = Text("Runway · Today \(dayValue(usage.today, mode: mode))\(mode == .tokens ? " tok" : "")")
        if stale {
            value + Text(" · ") + Text(usage.fetchedAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
        } else {
            value
        }
    }
}

private struct CircularUsageView: View {
    var usage: WidgetUsage
    var mode: UsageDisplayMode
    var stale: Bool

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                // A cached value trades the "TODAY" label for its fetch age — the only room this
                // family has to say the number isn't current.
                if stale {
                    FetchAgeText(date: usage.fetchedAt)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                } else {
                    Text("TODAY")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(dayValue(usage.today, mode: mode))
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .padding(.horizontal, 4)
        }
    }
}

private struct RectangularUsageView: View {
    var usage: WidgetUsage
    var mode: UsageDisplayMode
    var stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text("Runway")
                    .font(.caption.weight(.semibold))
                    .widgetAccentable()
                if mode == .tokens {
                    Text("tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if usage.partial {
                    PartialWarningIcon()
                }
                if stale {
                    Spacer(minLength: 0)
                    FetchAgeText(date: usage.fetchedAt)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            row("Today", dayValue(usage.today, mode: mode))
            row("30 Days", last30Value(usage, mode: mode))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .font(.caption)
    }
}

private struct SmallUsageView: View {
    var usage: WidgetUsage
    var mode: UsageDisplayMode
    var stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("Runway")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if usage.partial {
                    PartialWarningIcon()
                }
                if stale {
                    Spacer(minLength: 0)
                    FetchAgeText(date: usage.fetchedAt)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text("Today")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(dayValue(usage.today, mode: mode))
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let caption = todayCaption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Text("30 Days")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(last30Value(usage, mode: mode))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The other measure, under the big value: token count in cost mode, unit (or spend, when
    /// priced) in tokens mode.
    private var todayCaption: String? {
        switch mode {
        case .cost:
            guard usage.today?.cost != nil, let tokens = usage.today?.tokens, tokens > 0 else { return nil }
            return "\(UsageFormat.tokens(Double(tokens))) tokens"
        case .tokens:
            guard let cost = usage.today?.cost else { return "tokens" }
            return "tokens · \(UsageFormat.dollars(cost))"
        }
    }
}

private struct MediumUsageView: View {
    var usage: WidgetUsage
    var mode: UsageDisplayMode
    var stale: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("Runway")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    if mode == .tokens {
                        Text("· tokens")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if usage.partial {
                        PartialWarningIcon()
                    }
                    // The chart column's age caption disappears with the chart — the header
                    // carries the staleness signal unconditionally.
                    if stale {
                        FetchAgeText(date: usage.fetchedAt)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                tile("Today", dayValue(usage.today, mode: mode))
                tile("Yesterday", dayValue(usage.yesterday, mode: mode))
                tile("30 Days", last30Value(usage, mode: mode))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if usage.trend.count > 1 {
                VStack(alignment: .trailing, spacing: 4) {
                    Chart(Array(usage.trend.enumerated()), id: \.offset) { index, day in
                        BarMark(
                            x: .value("Day", index),
                            y: .value("Tokens", day.tokens)
                        )
                        .foregroundStyle(.tint)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    Text(usage.fetchedAt, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

private struct NoUsageView: View {
    var notice: WidgetNotice
    var family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("Runway · \(notice.text)")
        case .accessoryCircular:
            // No room for the sentence, but the reason still shows: a per-state symbol and a
            // compact label, so "Update" is distinguishable from "Sign In" at a glance.
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 1) {
                    Image(systemName: notice.symbol)
                        .imageScale(.small)
                    Text(notice.shortLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .padding(.horizontal, 4)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("Runway")
                    .font(.caption.weight(.semibold))
                    .widgetAccentable()
                Text(notice.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(spacing: 4) {
                Image(systemName: notice.symbol)
                    .foregroundStyle(.secondary)
                Text(notice.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

#Preview("Small", as: .systemSmall) {
    CombinedUsageWidget()
} timeline: {
    UsageEntry.sample()
    UsageEntry.sample(mode: .tokens)
}

#Preview("Rectangular", as: .accessoryRectangular) {
    CombinedUsageWidget()
} timeline: {
    UsageEntry.sample()
    UsageEntry.sample(mode: .tokens)
}
