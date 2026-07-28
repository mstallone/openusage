import Foundation

/// Turns the Go plan windows into the three cap meters. The published OpenCode Go caps are dollar-based,
/// so each is a `.dollars` progress meter of observed-local spend against its cap. Local spend can only
/// undercount true account usage (this machine only), which is why the card leads with these caps but
/// also shows honest spend tiles.
enum OpenCodeUsageMapper {
    static let sessionCap: Double = 12   // per rolling 5 hours
    static let weeklyCap: Double = 30    // per UTC week
    static let monthlyCap: Double = 60   // per anchored month

    static func meterLines(_ windows: OpenCodeGoWindows) -> [MetricLine] {
        [
            .progress(
                label: "Session", used: windows.sessionSpend, limit: sessionCap, format: .dollars,
                resetsAt: windows.sessionResetsAt, periodDurationMs: MetricPeriod.sessionMs
            ),
            .progress(
                label: "Weekly", used: windows.weeklySpend, limit: weeklyCap, format: .dollars,
                resetsAt: windows.weeklyResetsAt, periodDurationMs: MetricPeriod.weekMs
            ),
            .progress(
                label: "Monthly", used: windows.monthlySpend, limit: monthlyCap, format: .dollars,
                resetsAt: windows.monthlyResetsAt, periodDurationMs: windows.monthlyPeriodMs
            )
        ]
    }
}
