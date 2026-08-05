import XCTest
@testable import Runway

@MainActor
final class ProviderSectionHeaderTests: XCTestCase {
    func testActionableWarningTooltipAppendsTheClickAffordance() {
        // Clicking the triangle refreshes the provider, and nothing else on screen says so — the
        // tooltip has to carry the affordance. Provider messages already end in a period, so the
        // hint joins as one more sentence.
        XCTAssertEqual(
            ProviderSectionHeader.warningTooltip(
                for: ClaudeAuthError.codePermissionDenied.localizedDescription,
                refreshable: true
            ),
            "Keychain access to the Claude Code login was declined. Refresh and choose Always Allow when macOS asks. Click to refresh."
        )
        // A message that arrives without end punctuation (an HTTP failure line) gets a period first,
        // so the hint never runs into it.
        XCTAssertEqual(
            ProviderSectionHeader.warningTooltip(for: "Refresh failed", refreshable: true),
            "Refresh failed. Click to refresh."
        )
        XCTAssertEqual(
            ProviderSectionHeader.warningTooltip(for: "Where did the data go?", refreshable: true),
            "Where did the data go? Click to refresh."
        )
    }

    func testNonActionableWarningTooltipStaysTheBareMessage() {
        // The reorder preview's triangle carries no action, so promising a click there would lie.
        XCTAssertEqual(
            ProviderSectionHeader.warningTooltip(for: "Token expired.", refreshable: false),
            "Token expired."
        )
        // An all-whitespace message resolves to empty (hoverTooltip's "no tooltip" case) rather than
        // a bare "Click to refresh." with nothing to explain it.
        XCTAssertEqual(ProviderSectionHeader.warningTooltip(for: "  ", refreshable: true), "")
    }
}
