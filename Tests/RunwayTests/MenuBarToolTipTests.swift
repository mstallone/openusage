import AppKit
import XCTest
@testable import Runway

@MainActor
final class MenuBarToolTipTests: XCTestCase {
    func testTextPresentationLabelsEachSegmentWithResolvedDisplayName() throws {
        let content = makeContent()
        let presentation = try XCTUnwrap(MenuBarStripRenderer.presentation(for: content, style: .text))
        let regions = presentation.toolTipRegions

        XCTAssertEqual(regions.map(\.displayName), ["Claude — Personal", "Claude — Work"])
        XCTAssertEqual(regions.count, 2)
        XCTAssertEqual(regions[0].rect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(regions[0].rect.maxX, regions[1].rect.minX, accuracy: 0.001)
        XCTAssertEqual(regions[1].rect.maxX, presentation.image.size.width, accuracy: 0.001)
        XCTAssertTrue(regions.allSatisfy { $0.rect.width > 0 })
    }

    func testBarsPresentationHasNoAccountRegions() throws {
        let presentation = try XCTUnwrap(
            MenuBarStripRenderer.presentation(for: makeContent(), style: .bars)
        )
        XCTAssertTrue(presentation.toolTipRegions.isEmpty)
    }

    func testButtonGeometryMapsImageRangesWithoutSplittingClickTarget() {
        let regions = [
            MenuBarToolTipRegion(
                displayName: "Personal",
                rect: CGRect(x: 0, y: 0, width: 40, height: 20)
            ),
            MenuBarToolTipRegion(
                displayName: "Work",
                rect: CGRect(x: 40, y: 0, width: 60, height: 20)
            ),
        ]

        let rects = StatusItemToolTipGeometry.buttonRects(
            for: regions,
            imageSize: NSSize(width: 100, height: 20),
            imageRect: NSRect(x: 8, y: 1, width: 100, height: 20),
            buttonBounds: NSRect(x: 0, y: 0, width: 116, height: 22)
        )

        XCTAssertEqual(rects, [
            NSRect(x: 8, y: 0, width: 40, height: 22),
            NSRect(x: 48, y: 0, width: 60, height: 22),
        ])
    }

    private func makeContent() -> MenuBarContent {
        let personal = metric(id: "claude.session", value: "41%", fraction: 0.41)
        let work = metric(id: "claude@work.session", value: "72%", fraction: 0.72)
        return MenuBarContent(
            groups: [
                .init(
                    providerID: "claude",
                    displayName: "Claude — Personal",
                    icon: .providerMark("claude"),
                    metrics: [personal]
                ),
                .init(
                    providerID: "claude@work",
                    displayName: "Claude — Work",
                    icon: .providerMark("claude"),
                    metrics: [work]
                ),
            ],
            bars: [personal, work]
        )
    }

    private func metric(id: String, value: String, fraction: Double) -> MenuBarContent.Metric {
        .init(
            id: id,
            label: "Session",
            value: value,
            fraction: fraction,
            isBounded: true,
            hasData: true
        )
    }
}
