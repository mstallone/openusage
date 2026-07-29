import XCTest
@testable import Runway

@MainActor
final class PanelHeightBridgeTests: XCTestCase {
    /// Main-thread pushes (SwiftUI's interpolation thread) apply synchronously, in push order — that's
    /// what keeps the AppKit backdrop in the same transaction as the SwiftUI frame it matches.
    func testMainThreadPushesApplySynchronouslyInOrder() {
        resetBridge()
        defer { resetBridge() }

        var applied: [CGFloat] = []
        MenuBarPopover.applyHeight = { applied.append($0) }

        PanelHeightBridge.push(520)
        PanelHeightBridge.push(560)
        PanelHeightBridge.push(600)

        XCTAssertEqual(applied, [520, 560, 600])
    }

    /// `effectValue` re-pushes the current height on every re-render of the popover root, including
    /// renders where nothing moved; duplicates must not re-apply identical frames.
    func testDuplicatePushIsDropped() {
        resetBridge()
        defer { resetBridge() }

        var applied: [CGFloat] = []
        MenuBarPopover.applyHeight = { applied.append($0) }

        PanelHeightBridge.push(600)
        PanelHeightBridge.push(600)
        PanelHeightBridge.push(640)

        XCTAssertEqual(applied, [600, 640])
    }

    /// `invalidate` (panel open/close) clears the duplicate filter, so a reopen that re-establishes
    /// the same height still reaches the controller.
    func testInvalidateAllowsSameHeightToReapply() {
        resetBridge()
        defer { resetBridge() }

        var applied: [CGFloat] = []
        MenuBarPopover.applyHeight = { applied.append($0) }

        PanelHeightBridge.push(600)
        PanelHeightBridge.invalidate()
        PanelHeightBridge.push(600)

        XCTAssertEqual(applied, [600, 600])
    }

    func testEffectValuePushesEstablishedHeight() {
        resetBridge()
        defer { resetBridge() }

        var applied: [CGFloat] = []
        MenuBarPopover.applyHeight = { applied.append($0) }

        _ = PanelHeightModifier(height: 640).effectValue(size: CGSize(width: 320, height: 640))

        XCTAssertEqual(applied, [640])
    }

    /// The off-main safety net: pushes from another thread coalesce into one main-queue apply carrying
    /// the newest height.
    func testOffMainBurstCoalescesToNewestHeight() {
        resetBridge()
        defer { resetBridge() }

        var applied: [CGFloat] = []
        let apply = expectation(description: "applies coalesced height")
        MenuBarPopover.applyHeight = { height in
            applied.append(height)
            apply.fulfill()
        }

        let pushed = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            PanelHeightBridge.push(520)
            PanelHeightBridge.push(560)
            PanelHeightBridge.push(600)
            pushed.signal()
        }
        pushed.wait()

        wait(for: [apply], timeout: 1)
        XCTAssertEqual(applied, [600])
    }

    /// A queued off-main height must not survive an `invalidate` (the panel closed before the hop ran).
    func testInvalidateDropsQueuedOffMainHeight() {
        resetBridge()
        defer { resetBridge() }

        let droppedApply = expectation(description: "drops queued height")
        droppedApply.isInverted = true
        MenuBarPopover.applyHeight = { _ in droppedApply.fulfill() }

        let pushed = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            PanelHeightBridge.push(600)
            pushed.signal()
        }
        pushed.wait()
        PanelHeightBridge.invalidate()

        wait(for: [droppedApply], timeout: 0.05)
    }

    private func resetBridge() {
        PanelHeightBridge.invalidate()
        MenuBarPopover.applyHeight = nil
    }
}
