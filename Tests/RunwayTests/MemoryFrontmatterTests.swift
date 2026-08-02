import XCTest
@testable import Runway

/// The fact-file frontmatter split: observed keys come out, unknown keys are skipped, anything
/// that isn't a complete `---` fence leaves the whole text as the body, and the body is always
/// byte-identical to what follows the closing fence.
final class MemoryFrontmatterTests: XCTestCase {
    /// The exact shape Claude Code writes: quoted description, `metadata: ` with a trailing
    /// space, and extra metadata children beyond `type`.
    func testParsesTheOnDiskFactFileShape() throws {
        let text = """
        ---
        name: runway-perf-baseline
        description: "Measured Runway perf baseline — startup 13.5s CPU"
        metadata:\u{20}
          node_type: memory
          type: project
          originSessionId: 30e29010-1929-41c1-a999-451ae0dd5e6a
          modified: 2026-08-02T17:15:58.055Z
        ---

        Perf profile of Runway measured 2026-08-01.
        """

        let (frontmatter, body) = MemoryFrontmatter.parse(text)

        let parsed = try XCTUnwrap(frontmatter)
        XCTAssertEqual(parsed.name, "runway-perf-baseline")
        XCTAssertEqual(parsed.description, "Measured Runway perf baseline — startup 13.5s CPU")
        XCTAssertEqual(parsed.type, "project")
        XCTAssertEqual(String(body), "\nPerf profile of Runway measured 2026-08-01.")
    }

    func testMissingKeysStayNil() throws {
        let text = """
        ---
        name: just-a-name
        ---
        Body.
        """

        let (frontmatter, body) = MemoryFrontmatter.parse(text)

        let parsed = try XCTUnwrap(frontmatter)
        XCTAssertEqual(parsed.name, "just-a-name")
        XCTAssertNil(parsed.description)
        XCTAssertNil(parsed.type)
        XCTAssertEqual(String(body), "Body.")
    }

    func testMetadataChildrenOnlyCountInsideTheMetadataBlock() throws {
        // A `type:` child under some other block must not leak into `metadata.type`.
        let text = """
        ---
        other:
          type: user
        metadata:
          type: feedback
        ---
        Body.
        """

        let (frontmatter, _) = MemoryFrontmatter.parse(text)

        XCTAssertEqual(try XCTUnwrap(frontmatter).type, "feedback")
    }

    func testNoFrontmatterLeavesTheWholeTextAsBody() {
        let text = "# Just A Heading\n\nPlain markdown, no fence.\n"

        let (frontmatter, body) = MemoryFrontmatter.parse(text)

        XCTAssertNil(frontmatter)
        XCTAssertEqual(String(body), text)
    }

    func testUnterminatedFenceIsNotFrontmatter() {
        // A lone `---` (a thematic break, or a truncated file) must not swallow the text.
        let text = "---\nname: looks-like-frontmatter\n\nBut the fence never closes.\n"

        let (frontmatter, body) = MemoryFrontmatter.parse(text)

        XCTAssertNil(frontmatter)
        XCTAssertEqual(String(body), text)
    }

    func testBodyIsByteIdenticalToWhatFollowsTheClosingFence() {
        // Blank lines, trailing whitespace, a stray `---` inside the body — none of it may change.
        let bodyText = "\n\nline one  \n---\n\ttabbed\nno trailing newline"
        let text = "---\nname: fidelity\n---\n" + bodyText

        let (_, body) = MemoryFrontmatter.parse(text)

        XCTAssertEqual(String(body), bodyText)
    }

    func testTemplateEmitsTheObservedShapeWithAnEmptyBody() {
        let text = MemoryFrontmatter.template(
            name: "new-fact", description: "What this fact captures", type: "reference"
        )

        XCTAssertEqual(
            text,
            "---\nname: new-fact\ndescription: What this fact captures\nmetadata:\n  type: reference\n---\n\n"
        )

        // And the template must round-trip through the parser.
        let (frontmatter, body) = MemoryFrontmatter.parse(text)
        XCTAssertEqual(frontmatter?.name, "new-fact")
        XCTAssertEqual(frontmatter?.description, "What this fact captures")
        XCTAssertEqual(frontmatter?.type, "reference")
        XCTAssertEqual(String(body), "\n")
    }
}
