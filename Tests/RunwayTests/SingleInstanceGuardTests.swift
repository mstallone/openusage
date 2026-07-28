import XCTest
@testable import Runway

/// Covers the single-instance guard's decision logic (issue #635): given our PID and the PIDs of
/// running apps sharing our bundle id, decide which instance we should yield to (lowest-PID-wins), or
/// `nil` to keep running. The live `NSRunningApplication` query and the activate/terminate handoff are
/// thin glue over this pure function and aren't unit-testable (they need a second running process).
@MainActor
final class SingleInstanceGuardTests: XCTestCase {
    func testSoloLaunchYieldsToNobody() {
        // Only our own process is running — nothing to defer to.
        XCTAssertNil(SingleInstanceGuard.instanceToYieldTo(myPID: 42, runningPIDs: [42]))
    }

    func testNoRunningAppsYieldsToNobody() {
        // Defensive: an empty workspace result must never make us yield.
        XCTAssertNil(SingleInstanceGuard.instanceToYieldTo(myPID: 42, runningPIDs: []))
    }

    func testYieldsToALowerPIDInstance() {
        // A copy with a lower PID (7) already owns the slot — we yield to it.
        XCTAssertEqual(SingleInstanceGuard.instanceToYieldTo(myPID: 42, runningPIDs: [7, 42]), 7)
    }

    func testYieldsToTheLowestWhenSeveralAreLower() {
        // The survivor is the single lowest PID, not just any lower one.
        XCTAssertEqual(SingleInstanceGuard.instanceToYieldTo(myPID: 42, runningPIDs: [20, 9, 42]), 9)
    }

    func testSurvivesWhenWeAreTheLowestPID() {
        // A higher-PID peer (99) yields to us, not the other way around — we keep running.
        XCTAssertNil(SingleInstanceGuard.instanceToYieldTo(myPID: 42, runningPIDs: [42, 99]))
    }

    /// The headline regression test for the reboot race (cubic P1 / Bugbot): two launches that both
    /// observe both PIDs must resolve to *exactly one* survivor — never zero (both terminate) and
    /// never two. With lowest-PID-wins, the higher-PID launch yields and the lower-PID launch keeps
    /// running.
    func testSimultaneousLaunchLeavesExactlyOneSurvivor() {
        let both: [pid_t] = [100, 101]
        let lowerYieldsTo = SingleInstanceGuard.instanceToYieldTo(myPID: 100, runningPIDs: both)
        let higherYieldsTo = SingleInstanceGuard.instanceToYieldTo(myPID: 101, runningPIDs: both)

        XCTAssertNil(lowerYieldsTo)            // pid 100 keeps running
        XCTAssertEqual(higherYieldsTo, 100)    // pid 101 yields to it
    }
}
