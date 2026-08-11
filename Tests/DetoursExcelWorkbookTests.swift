import Foundation
import XCTest
@testable import Detours

final class DetoursExcelWorkbookTests: XCTestCase {
    func testSheetOrderAndFirstSheetPartResolve() throws {
        let workbook = try read(sheets: [
            ("Summary", Self.row(1, [("A", "", "First sheet")]), false),
            ("Detail", Self.row(1, [("A", "", "Second sheet")]), false)
        ])

        XCTAssertEqual(workbook.sheetName, "Summary")
        XCTAssertEqual(workbook.rows.first?.values.first, "First sheet")
    }

    func testHiddenFirstSheetIsSkipped() throws {
        let workbook = try read(sheets: [
            ("Hidden", Self.row(1, [("A", "", "Hidden value")]), true),
            ("Visible", Self.row(1, [("A", "", "Visible value")]), false)
        ])

        XCTAssertEqual(workbook.sheetName, "Visible")
        XCTAssertEqual(workbook.rows.first?.values.first, "Visible value")
    }

    func testSharedStringsResolve() throws {
        let workbook = try read(
            sheets: [("Sheet1", Self.row(1, [("A", "s", "0")]), false)],
            sharedStrings: "<si><t>Shared text</t></si>"
        )

        XCTAssertEqual(workbook.rows.first?.values.first, "Shared text")
    }

    func testRichTextSharedStringJoinsItsParts() throws {
        let workbook = try read(
            sheets: [("Sheet1", Self.row(1, [("A", "s", "0"), ("B", "s", "1")]), false)],
            sharedStrings: """
            <si><r><t>Rich </t></r><r><t>text</t></r><rPh><t>ignored</t></rPh></si>
            <si><t>Second</t></si>
            """
        )

        // The runs are joined and the phonetic part dropped. Reading only the first `t` of an entry
        // would also shift the index of every string after it, which the second cell proves it did
        // not.
        XCTAssertEqual(workbook.rows.first?.values, ["Rich text", "Second"])
    }

    func testInlineStringCellResolves() throws {
        let rows = "<row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>Inline value</t></is></c></row>"
        let workbook = try read(sheets: [("Sheet1", rows, false)])

        XCTAssertEqual(workbook.rows.first?.values.first, "Inline value")
    }

    func testFormulaCellUsesItsCachedValue() throws {
        let rows = "<row r=\"1\"><c r=\"A1\"><f>SUM(B1:B9)</f><v>42</v></c></row>"
        let workbook = try read(sheets: [("Sheet1", rows, false)])

        XCTAssertEqual(workbook.rows.first?.values.first, "42")
    }

    func testBooleanAndErrorCellsRender() throws {
        let rows = Self.row(1, [("A", "b", "1"), ("B", "b", "0"), ("C", "e", "#DIV/0!")])
        let workbook = try read(sheets: [("Sheet1", rows, false)])

        XCTAssertEqual(workbook.rows.first?.values, ["TRUE", "FALSE", "#DIV/0!"])
    }

    func testDateFormattedNumberBecomesAReadableDate() throws {
        let rows = "<row r=\"1\"><c r=\"A1\" s=\"1\"><v>45000</v></c><c r=\"B1\" s=\"2\"><v>45000</v></c></row>"
        let workbook = try read(
            sheets: [("Sheet1", rows, false)],
            styles: """
            <numFmts><numFmt numFmtId="200" formatCode="dd/mm/yyyy"/></numFmts>
            <cellXfs><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="200"/></cellXfs>
            """
        )

        // One resolves from a built-in identifier, the other from a custom format code.
        XCTAssertEqual(workbook.rows.first?.values, ["2023-03-15", "2023-03-15"])
    }

    func testMacDateSystemShiftsSerials() throws {
        let rows = "<row r=\"1\"><c r=\"A1\" s=\"1\"><v>45000</v></c></row>"
        let styles = "<cellXfs><xf numFmtId=\"0\"/><xf numFmtId=\"14\"/></cellXfs>"
        let mac = try read(sheets: [("Sheet1", rows, false)], styles: styles, uses1904: true)

        XCTAssertEqual(mac.rows.first?.values.first, "2027-03-16")

        // Serial 59 sits below Excel's phantom 29 February 1900 and must land on the day Excel prints.
        let early = try read(
            sheets: [("Sheet1", "<row r=\"1\"><c r=\"A1\" s=\"1\"><v>59</v></c></row>", false)],
            styles: styles
        )
        XCTAssertEqual(early.rows.first?.values.first, "1900-02-28")
    }

    func testNonDateNumbersStayVerbatim() throws {
        let rows = Self.row(1, [("A", "s", "0"), ("B", "", "123456789012345")])
        let workbook = try read(
            sheets: [("Sheet1", rows, false)],
            sharedStrings: "<si><t>007412</t></si>"
        )

        XCTAssertEqual(workbook.rows.first?.values, ["007412", "123456789012345"])
    }

    func testSparseRowPlacesCellsByAddress() throws {
        let rows = "<row r=\"1\"><c r=\"A1\"><v>1</v></c><c r=\"D1\"><v>4</v></c></row>"
        let workbook = try read(sheets: [("Sheet1", rows, false)])

        XCTAssertEqual(workbook.columnCount, 4)
        XCTAssertEqual(workbook.rows.first?.values, ["1", "", "", "4"])
    }

    func testTrailingEmptyRowsAndColumnsAreTrimmed() throws {
        let rows = """
        <row r="1"><c r="A1"><v>1</v></c><c r="C1"></c></row>
        <row r="2"></row>
        <row r="3"><c r="A3"></c></row>
        """
        let workbook = try read(sheets: [("Sheet1", rows, false)])

        XCTAssertEqual(workbook.columnCount, 1)
        XCTAssertEqual(workbook.rows.count, 1)
    }

    func testNeededPartMissingFailsCleanlyAndUnusedPartMissingDoesNot() throws {
        XCTAssertThrowsError(
            try read(
                sheets: [("Sheet1", Self.row(1, [("A", "s", "0")]), false)],
                sharedStrings: "<si><t>Text</t></si>",
                omitSharedStrings: true
            )
        )

        let numbersOnly = try read(
            sheets: [("Sheet1", Self.row(1, [("A", "", "5")]), false)],
            sharedStrings: "<si><t>Text</t></si>",
            omitSharedStrings: true
        )
        XCTAssertEqual(numbersOnly.rows.first?.values.first, "5")
    }

    func testStrictFormatWorkbookIsUnsupported() throws {
        XCTAssertThrowsError(
            try read(sheets: [("Sheet1", Self.row(1, [("A", "", "1")]), false)], strictFormat: true)
        ) { error in
            XCTAssertEqual(error as? DetoursExcelWorkbookError, .strictFormat)
        }
    }

    // MARK: - Helpers

    private func read(
        sheets: [(name: String, rows: String, hidden: Bool)],
        sharedStrings: String? = nil,
        styles: String? = nil,
        uses1904: Bool = false,
        strictFormat: Bool = false,
        omitSharedStrings: Bool = false
    ) throws -> DetoursExcelWorkbook {
        let data = OfficeFixtureBuilder.workbook(
            sheets: sheets,
            sharedStrings: sharedStrings,
            styles: styles,
            uses1904: uses1904,
            strictFormat: strictFormat,
            omitSharedStrings: omitSharedStrings
        )
        return try DetoursExcelWorkbook.read(archive: try DetoursOfficeArchive(data: data))
    }

    /// `<row>` markup for one row of cells, each given as its column letter, type and value.
    private static func row(_ number: Int, _ cells: [(String, String, String)]) -> String {
        let markup = cells.map { column, type, value in
            let typeAttribute = type.isEmpty ? "" : " t=\"\(type)\""
            return "<c r=\"\(column)\(number)\"\(typeAttribute)><v>\(value)</v></c>"
        }.joined()
        return "<row r=\"\(number)\">\(markup)</row>"
    }
}
