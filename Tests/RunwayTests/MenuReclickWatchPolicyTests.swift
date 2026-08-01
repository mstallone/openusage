import XCTest
@testable import Runway

final class MenuReclickWatchPolicyTests: XCTestCase {
    func testClickElsewhereThenHoveringBackNeverConfirms() {
        // Dismiss the menu (Esc or a click elsewhere), click some other control — the session-wide
        // counter advances — then drift the cursor back over the title inside the watch window. The
        // increment is bracketed by an off-control tick, so it must not read as a re-click.
        XCTAssertFalse(MenuReclickWatchPolicy.confirms(
            alreadyConfirmed: false,
            counterAdvanced: true,
            overControlNow: false,
            overControlAtPriorTick: false
        ))
        // The next tick: cursor now over the control, but the counter already settled.
        XCTAssertFalse(MenuReclickWatchPolicy.confirms(
            alreadyConfirmed: false,
            counterAdvanced: false,
            overControlNow: true,
            overControlAtPriorTick: false
        ))
    }

    func testIncrementBracketedOnTheControlConfirms() {
        XCTAssertTrue(MenuReclickWatchPolicy.confirms(
            alreadyConfirmed: false,
            counterAdvanced: true,
            overControlNow: true,
            overControlAtPriorTick: true
        ))
    }

    func testIncrementWithCursorArrivingLateDoesNotConfirm() {
        // Counter advanced during a tick interval whose start was off-control: the click belonged
        // to wherever the cursor came from.
        XCTAssertFalse(MenuReclickWatchPolicy.confirms(
            alreadyConfirmed: false,
            counterAdvanced: true,
            overControlNow: true,
            overControlAtPriorTick: false
        ))
    }

    func testConfirmationLatchesAcrossTicks() {
        // A re-click observed while the button is still down can't fire yet; the confirmation must
        // survive to a later tick even though the counter no longer advances.
        XCTAssertTrue(MenuReclickWatchPolicy.confirms(
            alreadyConfirmed: true,
            counterAdvanced: false,
            overControlNow: true,
            overControlAtPriorTick: true
        ))
    }

    func testReopenWaitsForButtonReleaseAndCursorOnControl() {
        XCTAssertFalse(MenuReclickWatchPolicy.mayReopen(confirmed: true, buttonsPressed: true, overControlNow: true))
        XCTAssertFalse(MenuReclickWatchPolicy.mayReopen(confirmed: true, buttonsPressed: false, overControlNow: false))
        XCTAssertFalse(MenuReclickWatchPolicy.mayReopen(confirmed: false, buttonsPressed: false, overControlNow: true))
        XCTAssertTrue(MenuReclickWatchPolicy.mayReopen(confirmed: true, buttonsPressed: false, overControlNow: true))
    }
}
