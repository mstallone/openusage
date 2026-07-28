import XCTest
@testable import OpenUsage

@MainActor
final class ProviderMarksTests: XCTestCase {
    func testGrokResolvesToVectorMarkNotBoltFallback() {
        let mark = ProviderMarks.mark(for: "grok")
        XCTAssertNotNil(mark, "Grok must load a real vector mark instead of the bolt.fill fallback")
        XCTAssertFalse(mark?.pathData.isEmpty ?? true, "Grok mark must carry SVG path data")
        XCTAssertFalse(mark?.path.isEmpty ?? true, "Grok mark must cache its parsed vector path")
    }

    func testDevinResolvesToVectorMark() {
        let mark = ProviderMarks.mark(for: "devin")
        XCTAssertNotNil(mark)
        XCTAssertFalse(mark?.pathData.isEmpty ?? true, "Devin mark must carry SVG path data")
        XCTAssertFalse(mark?.path.isEmpty ?? true, "Devin mark must cache its parsed vector path")
    }

    func testStandardProviderMarksLoad() {
        for id in ["claude", "codex", "cursor", "kimi", "sakana"] {
            let mark = ProviderMarks.mark(for: id)
            XCTAssertNotNil(mark, "\(id) should load")
            XCTAssertFalse(mark?.pathData.isEmpty ?? true, "\(id) mark must carry SVG path data")
            XCTAssertFalse(mark?.path.isEmpty ?? true, "\(id) mark must cache its parsed vector path")
        }
    }

    func testKimiArcMarkParsesAcrossItsFullArtworkBounds() throws {
        let mark = try XCTUnwrap(ProviderMarks.mark(for: "kimi"))
        let bounds = mark.bounds

        XCTAssertGreaterThan(bounds.width, 700)
        XCTAssertGreaterThan(bounds.height, 700)
    }

    func testShapeUsesCachedPathAndNormalizesItIntoTheRequestedFrame() throws {
        let mark = try XCTUnwrap(ProviderMarks.mark(for: "kimi"))
        let rect = CGRect(x: 0, y: 0, width: 40, height: 40)
        let renderedBounds = ProviderIconShape(mark: mark, inset: 0.1)
            .path(in: rect)
            .cgPath
            .boundingBoxOfPath

        XCTAssertLessThanOrEqual(renderedBounds.width, 32.01)
        XCTAssertLessThanOrEqual(renderedBounds.height, 32.01)
        XCTAssertEqual(renderedBounds.midX, rect.midX, accuracy: 0.01)
        XCTAssertEqual(renderedBounds.midY, rect.midY, accuracy: 0.01)
    }
}
