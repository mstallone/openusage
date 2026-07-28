import XCTest
@testable import Runway

@MainActor
final class SingleInstanceLockTests: XCTestCase {
    func testSecondAcquisitionIsRejectedUntilTheFirstTokenIsReleased() throws {
        let lockURL = makeLockURL()
        var token: SingleInstanceLock.Token?

        switch SingleInstanceLock.acquire(at: lockURL) {
        case .acquired(let acquired):
            token = acquired
        default:
            XCTFail("first acquisition should own the lock")
        }

        XCTAssertNotNil(token)
        assertAlreadyRunning(SingleInstanceLock.acquire(at: lockURL))
        token = nil

        switch SingleInstanceLock.acquire(at: lockURL) {
        case .acquired:
            break
        default:
            XCTFail("lock should be acquirable after the first token is released")
        }
    }

    func testLockRejectsDuplicateWhenRunningApplicationSnapshotMissesThePeer() throws {
        let lockURL = makeLockURL()
        var token: SingleInstanceLock.Token?

        switch SingleInstanceLock.acquire(at: lockURL) {
        case .acquired(let acquired):
            token = acquired
        default:
            XCTFail("first acquisition should own the lock")
        }

        XCTAssertNotNil(token)
        XCTAssertNil(SingleInstanceGuard.instanceToYieldTo(myPID: 101, runningPIDs: [101]))
        assertAlreadyRunning(SingleInstanceLock.acquire(at: lockURL))
        token = nil
    }

    private func makeLockURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("runway-lock-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Runway.lock")
    }

    private func assertAlreadyRunning(
        _ acquisition: SingleInstanceLock.Acquisition,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .alreadyRunning = acquisition else {
            XCTFail("second acquisition should be rejected", file: file, line: line)
            return
        }
    }
}
