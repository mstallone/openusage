import XCTest
@testable import Runway

/// The caret co-animation's first-toggle height guess: the revealed-row selection must mirror the
/// card's render path (applicability filtering + On Demand promotion), and the per-row pricing
/// must follow each row's rendered anatomy. These lock the regressions the estimator fixed:
/// counting saved-but-never-rendered widgets (a Copilot seat's other-plan metrics) and pricing
/// every row at a flat constant both made the panel overshoot and spring back on expand.
final class ExpansionHeightEstimatorTests: XCTestCase {
    // MARK: - Revealed-row selection

    func testInapplicableExpandedRowsNeverCountTowardTheEstimate() {
        let revealed = ExpansionHeightEstimator.expandedSectionRows(
            alwaysShown: [textRow("always")],
            expanded: [textRow("today"), textRow("org-only", applicable: false), textRow("monthly")]
        )
        XCTAssertEqual(revealed.map(\.id), ["today", "monthly"])
    }

    func testEmptyApplicableAlwaysSidePromotesOnDemandAndEmptiesTheExpansion() {
        // Account-aware filtering can empty the Always Visible side (a Business Copilot seat whose
        // org metrics were saved On Demand); the card then promotes the applicable On Demand rows
        // above the caret, so the expansion reveals no metrics (links only).
        let revealed = ExpansionHeightEstimator.expandedSectionRows(
            alwaysShown: [textRow("free-chat", applicable: false)],
            expanded: [textRow("premium"), textRow("credits")]
        )
        XCTAssertTrue(revealed.isEmpty)
    }

    func testDeltaKeyTracksCompositionOrderAndLinks() {
        let today = textRow("today")
        let monthly = textRow("monthly")
        let key = ExpansionHeightEstimator.deltaKey(
            providerID: "codex", revealedRows: [today, monthly], hasLinks: false
        )
        XCTAssertNotEqual(key, ExpansionHeightEstimator.deltaKey(
            providerID: "codex", revealedRows: [monthly, today], hasLinks: false
        ), "Order matters: adjacent text rows condense")
        XCTAssertNotEqual(key, ExpansionHeightEstimator.deltaKey(
            providerID: "codex", revealedRows: [today, monthly], hasLinks: true
        ))
        XCTAssertNotEqual(key, ExpansionHeightEstimator.deltaKey(
            providerID: "grok", revealedRows: [today, monthly], hasLinks: false
        ))
    }

    // MARK: - Row anatomy pricing

    func testRowHeightsFollowRenderedAnatomy() {
        let condensedText = ExpansionHeightEstimator.estimatedRowHeight(textData(), condensedTop: true)
        let text = ExpansionHeightEstimator.estimatedRowHeight(textData(), condensedTop: false)
        let meter = ExpansionHeightEstimator.estimatedRowHeight(meterData(), condensedTop: false)
        XCTAssertLessThan(condensedText, text, "A condensed text row pulls up against its neighbor")
        XCTAssertLessThan(text, meter, "A meter row stacks label, bar, and reading")
    }

    func testChartRowPricesLabelBesideTheBarsNotStacked() {
        // UsageSparkline is an HStack: the row's height is max(label, chart), never their sum.
        let chart = ExpansionHeightEstimator.estimatedRowHeight(chartData(), condensedTop: false)
        let density = DensitySetting.compact
        let stackedLowerBound = density.textRowPadding * 2 + 15 + density.trendChartHeight
        XCTAssertLessThan(chart, stackedLowerBound)
    }

    func testCondensedClusterEstimatesBelowFlatPerRowConstant() {
        // The default On Demand tail (Today / Yesterday / Last 30 Days) is a condensing text
        // cluster — the regression this locks priced it at a flat 36pt per row.
        let cluster = [textRow("today"), textRow("yesterday"), textRow("month")]
        let estimate = ExpansionHeightEstimator.estimatedDelta(revealedRows: cluster, linkCount: 0)
        XCTAssertLessThan(estimate, 3 * DensitySetting.compact.estimatedMetricRowHeight)
    }

    func testLinksRowHeightWrapsAtThreeAcross() {
        XCTAssertEqual(ExpansionHeightEstimator.estimatedLinksRowHeight(linkCount: 0), 0)
        XCTAssertEqual(
            ExpansionHeightEstimator.estimatedLinksRowHeight(linkCount: 1),
            ExpansionHeightEstimator.estimatedLinksRowHeight(linkCount: 3),
            "Up to three buttons share one row"
        )
        XCTAssertGreaterThan(
            ExpansionHeightEstimator.estimatedLinksRowHeight(linkCount: 4),
            ExpansionHeightEstimator.estimatedLinksRowHeight(linkCount: 3),
            "A fourth button wraps to a second row"
        )
    }

    // MARK: - Fixtures

    private func textRow(_ id: String, applicable: Bool = true) -> ExpansionHeightEstimator.Row {
        ExpansionHeightEstimator.Row(id: id, data: textData(), isApplicable: applicable)
    }

    private func textData() -> WidgetData {
        WidgetData(title: "Today", icon: .providerMark("codex"), kind: .dollars, used: 1, limit: nil)
    }

    private func meterData() -> WidgetData {
        WidgetData(title: "Weekly", icon: .providerMark("codex"), kind: .percent, used: 40, limit: 100)
    }

    private func chartData() -> WidgetData {
        var data = WidgetData(title: "Usage Trend", icon: .providerMark("codex"), kind: .count, used: 0, limit: nil)
        data.isChart = true
        return data
    }
}
