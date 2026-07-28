import Foundation

/// Whether the cross-provider Total Spend card shows at the top of the dashboard. On by default;
/// the toggle sits at the top of Settings → General. Hiding it only affects the card — the
/// per-provider spend rows it aggregates stay wherever the user put them.
enum TotalSpendSetting {
    static let key = "showTotalSpend"
}
