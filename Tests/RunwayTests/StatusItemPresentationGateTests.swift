import XCTest
@testable import Runway

/// Covers the presentation gate in front of the status item: an unchanged presentation must not
/// reach AppKit twice (no repeated tooltip re-registration or button layout), while any visible
/// change — or a rebuilt button — applies again.
@MainActor
final class StatusItemPresentationGateTests: XCTestCase {
    func testIdenticalPresentationAppliesOnce() {
        var applied = 0
        let gate = StatusItemPresentationGate { _ in
            applied += 1
            return true
        }
        let presentation = makePresentation()
        gate.submit(presentation)
        gate.submit(presentation)
        XCTAssertEqual(applied, 1)
    }

    func testMemoizedRenderIsGatedToOneApply() throws {
        // End to end through the renderer: equal content hits the renderer's memo, and the memo's
        // identical instance is exactly what the gate keys on — so a coalesced re-render of
        // unchanged data never reaches AppKit.
        var applied = 0
        let gate = StatusItemPresentationGate { _ in
            applied += 1
            return true
        }
        gate.submit(try XCTUnwrap(MenuBarStripRenderer.presentation(for: makeContent(value: "42%"), style: .text)))
        gate.submit(try XCTUnwrap(MenuBarStripRenderer.presentation(for: makeContent(value: "42%"), style: .text)))
        XCTAssertEqual(applied, 1)
    }

    func testChangedImageAppliesAgain() {
        var applied = 0
        let gate = StatusItemPresentationGate { _ in
            applied += 1
            return true
        }
        gate.submit(makePresentation())
        gate.submit(makePresentation())
        XCTAssertEqual(applied, 2)
    }

    func testChangedToolTipRegionsApplyAgain() {
        var applied = 0
        let gate = StatusItemPresentationGate { _ in
            applied += 1
            return true
        }
        let image = NSImage(size: NSSize(width: 10, height: 10))
        gate.submit(MenuBarStripPresentation(image: image, toolTipRegions: []))
        gate.submit(MenuBarStripPresentation(
            image: image,
            toolTipRegions: [MenuBarToolTipRegion(displayName: "Claude", rect: CGRect(x: 0, y: 0, width: 10, height: 10))]
        ))
        XCTAssertEqual(applied, 2)
    }

    func testFailedApplyRetriesOnNextSubmit() {
        // A missing status button (apply returns false) must not count as applied, or the strip
        // would stay blank until the next real data change.
        var buttonExists = false
        var applied = 0
        let gate = StatusItemPresentationGate { _ in
            guard buttonExists else { return false }
            applied += 1
            return true
        }
        let presentation = makePresentation()
        gate.submit(presentation)
        XCTAssertEqual(applied, 0)
        buttonExists = true
        gate.submit(presentation)
        XCTAssertEqual(applied, 1)
    }

    func testInvalidateReappliesUnchangedPresentation() {
        // The notch rescue rebuilds the button; after invalidate() even an identical presentation
        // must reach AppKit again.
        var applied = 0
        let gate = StatusItemPresentationGate { _ in
            applied += 1
            return true
        }
        let presentation = makePresentation()
        gate.submit(presentation)
        gate.invalidate()
        gate.submit(presentation)
        XCTAssertEqual(applied, 2)
    }

    private func makePresentation() -> MenuBarStripPresentation {
        MenuBarStripPresentation(image: NSImage(size: NSSize(width: 10, height: 10)), toolTipRegions: [])
    }

    private func makeContent(value: String) -> MenuBarContent {
        let metric = MenuBarContent.Metric(
            id: "claude.session", label: "Session", value: value,
            fraction: 0.42, isBounded: true, hasData: true
        )
        return MenuBarContent(
            groups: [MenuBarContent.Group(
                providerID: "claude",
                displayName: "Claude",
                icon: .providerMark("claude"),
                metrics: [metric]
            )],
            bars: [metric]
        )
    }
}
