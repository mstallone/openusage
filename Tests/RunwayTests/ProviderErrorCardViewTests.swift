import XCTest
@testable import Runway

@MainActor
final class ProviderErrorCardViewTests: XCTestCase {
    func testTwoSentenceMessagesSplitIntoTitleCasedTitleAndGuidance() {
        // Provider error strings follow "Short statement. Guidance." — the statement becomes the
        // card title (title-cased, no trailing period) and the guidance the description.
        XCTAssertEqual(
            ProviderErrorCardView.copy(
                for: ClaudeAuthError.codeConnectRequired.localizedDescription
            ),
            ProviderErrorCardView.Copy(
                title: "Claude Code Login Found",
                description: "Connect to load it; if macOS asks, choose Always Allow to avoid future dialogs."
            )
        )
        XCTAssertEqual(
            ProviderErrorCardView.copy(for: ClaudeAuthError.notLoggedIn.localizedDescription),
            ProviderErrorCardView.Copy(
                title: "Not Logged In",
                description: "Run `claude` to authenticate."
            )
        )
    }

    func testTitleCasingKeepsSmallWordsCodeQuotesAndProductCapsIntact() {
        // Mid-title articles/prepositions stay lowercase, edge words always capitalize, and words
        // that already carry capitals (macOS) or code ticks (`claude`) pass through untouched.
        XCTAssertEqual(
            ProviderErrorCardView.titleCased("Claude Desktop login is stale"),
            "Claude Desktop Login Is Stale"
        )
        XCTAssertEqual(
            ProviderErrorCardView.titleCased("the token for macOS expired"),
            "The Token for macOS Expired"
        )
        XCTAssertEqual(
            ProviderErrorCardView.titleCased("run `claude` again"),
            "Run `claude` Again"
        )
    }

    func testSingleSentenceMessageKeepsGenericTitle() {
        // A one-sentence failure (an HTTP error line) must not render as bold headline text.
        XCTAssertEqual(
            ProviderErrorCardView.copy(for: "Request failed with status 503."),
            ProviderErrorCardView.Copy(
                title: "Can't Load Usage",
                description: "Request failed with status 503."
            )
        )
    }
}
