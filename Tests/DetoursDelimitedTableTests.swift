import Foundation
import XCTest
@testable import Detours

final class DetoursDelimitedTableTests: XCTestCase {
    func testPlainRowsSplitOnTheDelimiter() {
        let rows = DetoursDelimitedTable.parseRows("a,b,c\n1,2,3\n", delimiter: ",")

        XCTAssertEqual(rows, [["a", "b", "c"], ["1", "2", "3"]])
    }

    func testQuotedFieldKeepsItsDelimiter() {
        let rows = DetoursDelimitedTable.parseRows("name,note\nAda,\"one, two\"\n", delimiter: ",")

        XCTAssertEqual(rows, [["name", "note"], ["Ada", "one, two"]])
    }

    func testQuotedFieldKeepsItsNewline() {
        let rows = DetoursDelimitedTable.parseRows("name,note\nAda,\"first\nsecond\"\n", delimiter: ",")

        XCTAssertEqual(rows.count, 2, "A line break inside quotes must not start a new row")
        XCTAssertEqual(rows[1], ["Ada", "first\nsecond"])
    }

    func testDoubledQuotesBecomeOneQuote() {
        let rows = DetoursDelimitedTable.parseRows("note\n\"she said \"\"yes\"\"\"\n", delimiter: ",")

        XCTAssertEqual(rows[1], ["she said \"yes\""])
    }

    func testCarriageReturnLineEndingsParse() {
        let windows = DetoursDelimitedTable.parseRows("a,b\r\n1,2\r\n", delimiter: ",")
        let unix = DetoursDelimitedTable.parseRows("a,b\n1,2\n", delimiter: ",")

        XCTAssertEqual(windows, unix)
    }

    func testByteOrderMarkIsStrippedFromTheFirstHeader() throws {
        let table = try XCTUnwrap(DetoursDelimitedTable.make(text: "\u{FEFF}id,name\n1,Ada\n", delimiter: ","))

        XCTAssertEqual(table.header, ["id", "name"])
    }

    func testRaggedRowsArePaddedNotShifted() throws {
        let table = try XCTUnwrap(DetoursDelimitedTable.make(text: "a,b,c\n1,2\n", delimiter: ","))

        XCTAssertEqual(table.columnCount, 3)
        // The short row keeps its values under the columns they belong to.
        XCTAssertEqual(table.rows[0], ["1", "2", ""])
    }

    func testSemicolonExportIsDetected() {
        let text = "Artikel;Preis;Menge\nSchraube;1,50;20\nMutter;0,75;40\n"

        XCTAssertEqual(DetoursDelimitedTable.detectDelimiter(in: text, preferring: ","), ";")
    }

    func testTabFileIsDetected() {
        let text = "id\tname\tcity\n1\tAda\tLondon\n2\tGrace\tNew York\n"

        XCTAssertEqual(DetoursDelimitedTable.detectDelimiter(in: text, preferring: ","), "\t")
    }

    func testAmbiguousFilePrefersTheExtensionDelimiter() {
        // Both separators split every row into two equally consistent fields, so nothing but the
        // extension can settle it.
        let text = "a\tb,c\n1\t2,3\n"

        XCTAssertEqual(DetoursDelimitedTable.detectDelimiter(in: text, preferring: "\t"), "\t")
        XCTAssertEqual(DetoursDelimitedTable.detectDelimiter(in: text, preferring: ","), ",")
    }

    func testWindowsEuropeanBytesDecodeWithoutLoss() throws {
        let text = "Artikel;Größe\nSchraube;groß\n"
        let data = try XCTUnwrap(text.data(using: .windowsCP1252))
        XCTAssertNil(String(data: data, encoding: .utf8), "The fixture must not already be valid UTF-8")

        let table = try XCTUnwrap(DetoursDelimitedTable.read(data: data, fileExtension: "csv"))

        XCTAssertEqual(table.header, ["Artikel", "Größe"])
        XCTAssertEqual(table.rows[0], ["Schraube", "groß"])
        XCTAssertFalse(table.header.joined().contains("\u{FFFD}"), "No replacement marks may survive")
    }

    func testColumnWidthsAreMeasuredAndCapped() throws {
        let long = String(repeating: "x", count: 200)
        let table = try XCTUnwrap(
            DetoursDelimitedTable.make(text: "id,description\n1,\(long)\n", delimiter: ",")
        )
        let grid = try XCTUnwrap(DetoursPreviewGenerator.grid(from: table))

        // Never narrower than the column's own name, and never wider than the cap.
        XCTAssertEqual(grid.columns[0].width, 2)
        XCTAssertEqual(grid.columns[1].width, DetoursPreviewGrid.maximumColumnWidth)
    }
}
