import XCTest
@testable import Runway

final class ClaudeMemoryIndexTests: XCTestCase {
    /// Mirrors the on-disk shape of a real MEMORY.md: heading, blank lines,
    /// entries with and without hooks.
    private let sampleIndex = """
    # Memory Index

    - [Codex cloud review signal](codex-cloud-review-signal.md) — reactions on the PR body: 👀 in progress
    - [Use codex-personal for reviews](use-codex-personal-for-reviews.md)

    - [Runway perf baseline](runway-perf-baseline.md) — Aug 2026 measurements
    """ + "\n"

    // MARK: - Parsing

    func testParsesEntriesWithAndWithoutHook() {
        let entries = ClaudeMemoryIndex.entries(in: sampleIndex)

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(
            entries[0],
            ClaudeMemoryIndex.Entry(
                title: "Codex cloud review signal",
                fileName: "codex-cloud-review-signal.md",
                hook: "reactions on the PR body: 👀 in progress"
            )
        )
        XCTAssertEqual(
            entries[1],
            ClaudeMemoryIndex.Entry(
                title: "Use codex-personal for reviews",
                fileName: "use-codex-personal-for-reviews.md",
                hook: nil
            )
        )
        XCTAssertEqual(entries[2].fileName, "runway-perf-baseline.md")
        XCTAssertEqual(entries[2].hook, "Aug 2026 measurements")
    }

    func testIgnoresNonListLines() {
        let text = """
        # Memory Index

        Some prose that mentions [a link](not-an-entry.md) inline.
        - plain list item without a link
        * [Wrong marker](wrong-marker.md)
        - [Real entry](real-entry.md) — kept
        """

        XCTAssertEqual(
            ClaudeMemoryIndex.entries(in: text),
            [ClaudeMemoryIndex.Entry(title: "Real entry", fileName: "real-entry.md", hook: "kept")]
        )
    }

    // MARK: - Removal

    func testRemovalDropsOnlyTheMatchingLineAndPreservesEverythingElse() {
        let result = ClaudeMemoryIndex.removingEntry(
            forFile: "use-codex-personal-for-reviews.md",
            from: sampleIndex
        )

        XCTAssertEqual(
            result,
            """
            # Memory Index

            - [Codex cloud review signal](codex-cloud-review-signal.md) — reactions on the PR body: 👀 in progress

            - [Runway perf baseline](runway-perf-baseline.md) — Aug 2026 measurements
            """ + "\n"
        )
    }

    func testRemovalMatchesByLinkTargetNotTitle() {
        let text = """
        - [Same Title](first.md) — one
        - [Same Title](second.md) — two
        """

        let result = ClaudeMemoryIndex.removingEntry(forFile: "second.md", from: text)

        XCTAssertEqual(result, "- [Same Title](first.md) — one")
    }

    func testRemovalOfOnlyEntryLeavesEmptyText() {
        XCTAssertEqual(
            ClaudeMemoryIndex.removingEntry(forFile: "only.md", from: "- [Only](only.md) — hook\n"),
            ""
        )
    }

    func testRemovalWithoutMatchReturnsTextUnchanged() {
        XCTAssertEqual(
            ClaudeMemoryIndex.removingEntry(forFile: "absent.md", from: sampleIndex),
            sampleIndex
        )
    }

    func testRemovalPreservesTextWithoutTrailingNewline() {
        let text = "# Heading\n- [Gone](gone.md)\n- [Kept](kept.md)"

        XCTAssertEqual(
            ClaudeMemoryIndex.removingEntry(forFile: "gone.md", from: text),
            "# Heading\n- [Kept](kept.md)"
        )
    }

    // MARK: - Append

    func testAppendToEmptyIndex() {
        let entry = ClaudeMemoryIndex.Entry(title: "First", fileName: "first.md", hook: "the hook")

        XCTAssertEqual(
            ClaudeMemoryIndex.appendingEntry(entry, to: ""),
            "- [First](first.md) — the hook\n"
        )
    }

    func testAppendToIndexWithTrailingNewline() {
        let entry = ClaudeMemoryIndex.Entry(title: "New", fileName: "new.md", hook: "fresh")

        XCTAssertEqual(
            ClaudeMemoryIndex.appendingEntry(entry, to: sampleIndex),
            sampleIndex + "- [New](new.md) — fresh\n"
        )
    }

    func testAppendToIndexWithoutTrailingNewline() {
        let entry = ClaudeMemoryIndex.Entry(title: "New", fileName: "new.md", hook: nil)

        XCTAssertEqual(
            ClaudeMemoryIndex.appendingEntry(entry, to: "- [Old](old.md)"),
            "- [Old](old.md)\n- [New](new.md)\n"
        )
    }

    func testAppendedEntryRoundTripsThroughParsing() {
        let entry = ClaudeMemoryIndex.Entry(title: "Round Trip", fileName: "round-trip.md", hook: "back again")
        let text = ClaudeMemoryIndex.appendingEntry(entry, to: sampleIndex)

        XCTAssertEqual(ClaudeMemoryIndex.entries(in: text).last, entry)
    }

    func testAppendDefusesLinkBreakingTitleSoTheEntryStaysRemovable() {
        // A raw "](" in the title would end the link text early, mis-parse the file name, and leave
        // an index line `removingEntry` can never match — a permanent orphan after a delete.
        let entry = ClaudeMemoryIndex.Entry(title: "foo](bar", fileName: "foo-bar.md", hook: nil)

        let text = ClaudeMemoryIndex.appendingEntry(entry, to: "")

        let parsed = ClaudeMemoryIndex.entries(in: text)
        XCTAssertEqual(parsed.map(\.fileName), ["foo-bar.md"])
        XCTAssertEqual(parsed.first?.title, "foo] (bar")
        XCTAssertEqual(ClaudeMemoryIndex.removingEntry(forFile: "foo-bar.md", from: text), "")
    }
}
