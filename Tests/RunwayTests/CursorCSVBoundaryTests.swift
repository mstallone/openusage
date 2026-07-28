import XCTest
@testable import Runway

final class CursorCSVBoundaryTests: XCTestCase {
    private let header = "Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens"

    func testParserRejectsIllegalQuotePlacement() {
        let malformed = [
            "Date,Model\n2026-01-01T00:00:00Z,\"composer-1\"suffix",
            "Date,Model\n2026-01-01T00:00:00Z,com\"poser-1"
        ]

        for csv in malformed {
            let summary = CursorCSVParser.forEachRecord(in: csv) { _ in
                XCTFail("a structurally malformed record must not be emitted")
            }
            XCTAssertFalse(summary.isStructurallyComplete, csv)
        }
    }

    func testUsageCSVValidatesGroupedAndUngroupedIntegers() throws {
        let csv = """
        \(header)
        2026-01-01T00:00:00Z,composer-1,,,,
        2026-01-01T00:00:00Z,composer-1,0,"1,234",0,0
        2026-01-01T00:00:00Z,composer-1,0,",",0,0
        2026-01-01T00:00:00Z,composer-1,0,"1,2",0,0
        2026-01-01T00:00:00Z,composer-1,0,"1,,2",0,0
        2026-01-01T00:00:00Z,composer-1,0,"12,34",0,0
        2026-01-01T00:00:00Z,composer-1,0,-1,0,0
        2026-01-01T00:00:00Z,composer-1,0,1.5,0,0
        2026-01-01T00:00:00Z,composer-1,0,1e3,0,0
        2026-01-01T00:00:00Z,composer-1,0,9223372036854775808,0,0
        """

        let parsed = try CursorUsageCSV.parse(csv: csv, pricing: TestPricing.bundled)

        XCTAssertEqual(parsed.rows.map(\.tokens.totalTokens), [0, 1_234])
        XCTAssertEqual(parsed.rejectedRowCount, 8)
    }

    func testUsageCSVRejectsRowsWhoseTokenBucketsOverflow() throws {
        let csv = """
        \(header)
        2026-01-01T00:00:00Z,composer-1,\(Int.max),1,0,0
        2026-01-01T00:00:00Z,composer-1,0,100,0,0
        """

        let parsed = try CursorUsageCSV.parse(csv: csv, pricing: TestPricing.bundled)

        XCTAssertEqual(parsed.rows.map(\.tokens.totalTokens), [100])
        XCTAssertEqual(parsed.rejectedRowCount, 1)
    }

    func testUsageCSVRejectsAggregateOverflowWithoutDiscardingSafeRows() throws {
        let firstRowTokens = Int.max - 1
        let csv = """
        \(header)
        2026-01-01T00:00:00Z,composer-1,0,\(firstRowTokens),0,0
        2026-01-02T00:00:00Z,composer-1,0,2,0,0
        """

        let parsed = try CursorUsageCSV.parse(csv: csv, pricing: TestPricing.bundled)

        XCTAssertEqual(parsed.rows.map(\.tokens.totalTokens), [firstRowTokens])
        XCTAssertEqual(parsed.rejectedRowCount, 1)
    }

    func testUsageCSVAcceptsLargeNonOverflowingValues() throws {
        let large = Int.max / 2
        let csv = """
        \(header)
        2026-01-01T00:00:00Z,composer-1,0,\(large),0,1
        """

        let parsed = try CursorUsageCSV.parse(csv: csv, pricing: TestPricing.bundled)

        XCTAssertEqual(parsed.rows.first?.tokens.totalTokens, large + 1)
        XCTAssertEqual(parsed.rejectedRowCount, 0)
    }

    func testUsageCSVRejectsMismatchedRecordWidths() throws {
        let csv = """
        \(header)
        2026-01-01T00:00:00Z,composer-1,0,10,0,20
        2026-01-01T00:00:00Z,composer-1,0,10,0,20,
        2026-01-01T00:00:00Z,composer-1,0,10,0
        """

        let parsed = try CursorUsageCSV.parse(csv: csv, pricing: TestPricing.bundled)

        XCTAssertEqual(parsed.rows.map(\.tokens.totalTokens), [30])
        XCTAssertEqual(parsed.rejectedRowCount, 2)
    }

    func testUsageCSVAcceptsBOMQuotedHeadersAndOptionalColumns() throws {
        let csv = """
        "﻿Date","Model","Input (w/ Cache Write)","Input (w/o Cache Write)","Cache Read","Output Tokens",Cost
        2026-01-01T00:00:00Z,composer-1,,,,,Included
        """

        let parsed = try CursorUsageCSV.parse(csv: csv, pricing: TestPricing.bundled)

        XCTAssertEqual(parsed.rows.first?.tokens.totalTokens, 0)
        XCTAssertEqual(parsed.rejectedRowCount, 0)
    }

    func testUsageCSVRejectsMissingDuplicateAndStructurallyMalformedColumns() {
        let missingOutput = """
        Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read
        2026-01-01T00:00:00Z,composer-1,0,10,0
        """
        XCTAssertThrowsError(try CursorUsageCSV.parse(csv: missingOutput, pricing: TestPricing.bundled)) { error in
            XCTAssertEqual(error as? CursorUsageCSVError, .missingColumns(["Output Tokens"]))
        }

        let duplicateDate = """
        Date,Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens
        2026-01-01T00:00:00Z,2026-01-01T00:00:00Z,composer-1,0,10,0,20
        """
        XCTAssertThrowsError(try CursorUsageCSV.parse(csv: duplicateDate, pricing: TestPricing.bundled)) { error in
            XCTAssertEqual(error as? CursorUsageCSVError, .malformedCSV)
        }

        let unterminated = """
        \(header)
        2026-01-01T00:00:00Z,"composer-1,0,10,0,20
        """
        XCTAssertThrowsError(try CursorUsageCSV.parse(csv: unterminated, pricing: TestPricing.bundled)) { error in
            XCTAssertEqual(error as? CursorUsageCSVError, .malformedCSV)
        }
    }
}
