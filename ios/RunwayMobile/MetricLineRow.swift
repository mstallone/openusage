import Charts
import SwiftUI

/// Renders one wire line the way the Mac dashboard would: meters as progress, spend rows as
/// value strings, charts as mini bar charts. Unsupported (newer) line kinds render nothing.
struct MetricLineRow: View {
    var line: MetricLineWire

    var body: some View {
        switch line {
        case .progress(let label, let used, let limit, let format, let resetsAt):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(label)
                    Spacer()
                    Text(UsageFormat.progress(used: used, limit: limit, format: format))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.subheadline)
                ProgressView(value: min(max(used / max(limit, 1), 0), 1))
                if let resetsAt, resetsAt > .now {
                    Text("Resets \(resetsAt, format: .relative(presentation: .named))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)

        case .values(let label, let values, let unknownModels):
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(label)
                    if !unknownModels.isEmpty {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .imageScale(.small)
                    }
                    Spacer()
                    Text(values.map(UsageFormat.value).joined(separator: " · "))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.subheadline)
                // No hover on iOS: the triangle must explain itself inline.
                if !unknownModels.isEmpty {
                    Text("Unpriced models not included: \(unknownModels.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

        case .text(let label, let value, let subtitle):
            labeledText(label: label, value: value, subtitle: subtitle)

        case .badge(let label, let text, let subtitle):
            labeledText(label: label, value: text, subtitle: subtitle)

        case .chart(let label, let points, let note):
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.subheadline)
                // Plot by index: the wire points arrive oldest → newest, and a categorical
                // month-name label axis would re-sort them alphabetically (July before June).
                Chart(Array(points.enumerated()), id: \.offset) { index, point in
                    BarMark(
                        x: .value("Day", index),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(.tint)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 48)
                if let note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)

        case .unsupported:
            EmptyView()
        }
    }

    private func labeledText(label: String, value: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
