import Foundation
import XCTest
@testable import Detours

final class DetoursWordDocumentTests: XCTestCase {
    func testParagraphsAndRunsParse() throws {
        let document = try read(body: """
        <w:p><w:r><w:t xml:space="preserve">First </w:t></w:r><w:r><w:t>paragraph</w:t></w:r></w:p>
        <w:p><w:r><w:t>Second</w:t><w:tab/><w:t>after a tab</w:t><w:br/><w:t>after a break</w:t></w:r></w:p>
        """)

        XCTAssertEqual(document.blocks.count, 2)
        XCTAssertEqual(Self.text(of: document.blocks[0]), "First paragraph")
        XCTAssertEqual(Self.text(of: document.blocks[1]), "Second\tafter a tab\nafter a break")
    }

    func testHeadingStylesResolveToLevels() throws {
        // The style identifier is German; only the style's own name and outline level identify it.
        let document = try read(
            body: """
            <w:p><w:pPr><w:pStyle w:val="berschrift2"/></w:pPr><w:r><w:t>Chapter</w:t></w:r></w:p>
            """,
            styles: """
            <w:style w:type="paragraph" w:styleId="berschrift2">
            <w:name w:val="heading 2"/><w:pPr><w:outlineLvl w:val="1"/></w:pPr></w:style>
            """
        )

        guard case .heading(let level, _) = document.blocks.first else {
            return XCTFail("Expected a heading, got \(String(describing: document.blocks.first))")
        }
        XCTAssertEqual(level, 2)
    }

    func testNumberingResolvesToOrderedAndUnorderedLists() throws {
        let document = try read(
            body: """
            <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>
            <w:r><w:t>Bullet</w:t></w:r></w:p>
            <w:p><w:pPr><w:numPr><w:ilvl w:val="1"/><w:numId w:val="1"/></w:numPr></w:pPr>
            <w:r><w:t>Nested</w:t></w:r></w:p>
            <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr></w:pPr>
            <w:r><w:t>Numbered</w:t></w:r></w:p>
            """,
            numbering: """
            <w:abstractNum w:abstractNumId="10"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl>
            <w:lvl w:ilvl="1"><w:numFmt w:val="bullet"/></w:lvl></w:abstractNum>
            <w:abstractNum w:abstractNumId="20"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl>
            </w:abstractNum>
            <w:num w:numId="1"><w:abstractNumId w:val="10"/></w:num>
            <w:num w:numId="2"><w:abstractNumId w:val="20"/></w:num>
            """
        )

        XCTAssertEqual(document.blocks.count, 2, "Each numbering reference is its own list")
        guard case .list(let bullets) = document.blocks[0], case .list(let numbers) = document.blocks[1] else {
            return XCTFail("Expected two lists, got \(document.blocks)")
        }
        XCTAssertEqual(bullets.map(\.ordered), [false, false])
        XCTAssertEqual(bullets.map(\.level), [0, 1])
        XCTAssertEqual(numbers.map(\.ordered), [true])
    }

    func testRunEmphasisIsCarried() throws {
        let document = try read(body: """
        <w:p>
        <w:r><w:rPr><w:b/></w:rPr><w:t>bold</w:t></w:r>
        <w:r><w:rPr><w:i/></w:rPr><w:t>italic</w:t></w:r>
        <w:r><w:rPr><w:u w:val="single"/></w:rPr><w:t>underlined</w:t></w:r>
        <w:r><w:rPr><w:u w:val="none"/></w:rPr><w:t>plain</w:t></w:r>
        </w:p>
        """)

        guard case .paragraph(let inlines) = document.blocks.first else {
            return XCTFail("Expected a paragraph, got \(String(describing: document.blocks.first))")
        }
        let runs = inlines.compactMap { inline -> DetoursWordDocument.Run? in
            guard case .text(let run) = inline else { return nil }
            return run
        }
        XCTAssertEqual(runs.map(\.bold), [true, false, false, false])
        XCTAssertEqual(runs.map(\.italic), [false, true, false, false])
        XCTAssertEqual(runs.map(\.underline), [false, false, true, false])
    }

    func testTablesParseIntoRowsAndCells() throws {
        let document = try read(body: """
        <w:tbl>
        <w:tr><w:tc><w:p><w:r><w:t>Name</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>Role</w:t></w:r></w:p></w:tc></w:tr>
        <w:tr><w:tc><w:tcPr><w:gridSpan w:val="2"/></w:tcPr>
        <w:p><w:r><w:t>Across both</w:t></w:r></w:p></w:tc></w:tr>
        </w:tbl>
        """)

        guard case .table(let rows) = document.blocks.first else {
            return XCTFail("Expected a table, got \(String(describing: document.blocks.first))")
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].count, 2)
        XCTAssertEqual(rows[1][0].span, 2, "A spanned cell keeps its span")
    }

    func testDrawingsBecomePlaceholders() throws {
        let document = try read(body: """
        <w:p><w:r><w:drawing><wp:inline><a:blip r:embed="rId7"/></wp:inline></w:drawing></w:r>
        <w:r><w:t>Caption</w:t></w:r></w:p>
        """)

        guard case .paragraph(let inlines) = document.blocks.first else {
            return XCTFail("Expected a paragraph, got \(String(describing: document.blocks.first))")
        }
        XCTAssertEqual(inlines.first, .placeholder("Image"))
        // Nothing from inside the drawing survives into the model.
        XCTAssertFalse(Self.text(of: document.blocks[0]).contains("rId7"))
    }

    func testUnknownElementsAreIgnored() throws {
        let document = try read(body: """
        <w:p><w:customElement w:attr="x"><w:r><w:t>Kept</w:t></w:r></w:customElement></w:p>
        <w:bookmarkStart w:id="1" w:name="start"/>
        <w:p><w:r><w:t>Also kept</w:t></w:r></w:p>
        """)

        XCTAssertEqual(document.blocks.count, 2)
        XCTAssertEqual(Self.text(of: document.blocks[0]), "Kept")
        XCTAssertEqual(Self.text(of: document.blocks[1]), "Also kept")
    }

    // MARK: - Helpers

    private func read(body: String, styles: String? = nil, numbering: String? = nil) throws -> DetoursWordDocument {
        let data = OfficeFixtureBuilder.wordDocument(body: body, styles: styles, numbering: numbering)
        return try DetoursWordDocument.read(archive: try DetoursOfficeArchive(data: data))
    }

    private static func text(of block: DetoursWordDocument.Block) -> String {
        switch block {
        case .paragraph(let inlines), .heading(_, let inlines):
            return text(of: inlines)
        case .list(let items):
            return items.map { text(of: $0.inlines) }.joined(separator: "\n")
        case .table(let rows):
            return rows.map { row in row.map { text(of: $0.inlines) }.joined(separator: "\t") }
                .joined(separator: "\n")
        }
    }

    private static func text(of inlines: [DetoursWordDocument.Inline]) -> String {
        inlines.map { inline in
            switch inline {
            case .text(let run): return run.text
            case .placeholder: return ""
            }
        }.joined()
    }
}
