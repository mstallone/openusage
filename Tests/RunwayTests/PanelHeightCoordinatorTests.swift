import XCTest
@testable import Runway

/// The popover auto-fit height computation, now unit-testable after being split out of DashboardView:
/// each screen's ideal = (top bar unless dashboard) + (footer unless customize) + scroll content, and
/// `target` clamps it.
@MainActor
final class PanelHeightCoordinatorTests: XCTestCase {
    private let topBar: CGFloat = 44
    private let footer: CGFloat = 40

    private func makeCoordinator() -> PanelHeightCoordinator {
        PanelHeightCoordinator(topBarHeight: topBar, footerHeight: footer)
    }

    func testDashboardIdealOmitsTopBar() {
        let c = makeCoordinator()
        c.setScrollContent(300, for: .dashboard)
        // Dashboard has no top bar: ideal = content + footer.
        XCTAssertEqual(c.measuredIdeal[.dashboard], 300 + 40)
    }

    func testCustomizeOmitsFooter() {
        let c = makeCoordinator()
        c.setScrollContent(300, for: .customize)
        // Customize pins the fixed top bar but shows no footer: ideal = topBar + content.
        XCTAssertEqual(c.measuredIdeal[.customize], 44 + 300)
    }

    func testIdealUnsetUntilScrollContentMeasured() {
        let c = makeCoordinator()
        XCTAssertNil(c.measuredIdeal[.dashboard])
        // A zero-height content measurement is ignored — the view keeps the controller's opening size
        // until real content lands.
        c.setScrollContent(0, for: .dashboard)
        XCTAssertNil(c.measuredIdeal[.dashboard])
    }

    func testTargetIsNilUntilMeasuredThenClamps() {
        // The clamp hook is a process global (see PanelHeightBridgeTests for the same reset pattern):
        // pin it explicitly on both branches so this test can't depend on suite order.
        let previousClamp = MenuBarPopover.clampHeight
        defer { MenuBarPopover.clampHeight = previousClamp }

        let c = makeCoordinator()
        XCTAssertNil(c.target(for: .dashboard))

        MenuBarPopover.clampHeight = nil
        c.setScrollContent(300, for: .dashboard)
        // No clamp hook installed → target is the raw ideal (content + footer).
        XCTAssertEqual(c.target(for: .dashboard), 340)

        // With the panel's hook installed, the target is floored and capped at both edges.
        MenuBarPopover.clampHeight = { min(max($0, 400), 600) }
        XCTAssertEqual(c.target(for: .dashboard), 400)  // 340 floored to the panel minimum
        c.setScrollContent(900, for: .dashboard)
        XCTAssertEqual(c.target(for: .dashboard), 600)  // 940 capped at the screen max
        c.setScrollContent(500, for: .dashboard)
        XCTAssertEqual(c.target(for: .dashboard), 540)  // in-range ideals pass through
    }

    func testLaterMeasurementRecomposesIdeal() {
        let c = makeCoordinator()
        c.setScrollContent(300, for: .dashboard)
        XCTAssertEqual(c.measuredIdeal[.dashboard], 340)
        c.setScrollContent(500, for: .dashboard)   // content grew (rows loaded)
        XCTAssertEqual(c.measuredIdeal[.dashboard], 540)
    }
}
