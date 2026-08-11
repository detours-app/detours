import Foundation
import XCTest
@testable import Detours

final class DetoursOfficeArchiveTests: XCTestCase {
    func testStoredEntryIsReadVerbatim() throws {
        var builder = OfficeFixtureBuilder()
        builder.add("word/document.xml", "<w:document/>", deflated: false)
        let archive = try DetoursOfficeArchive(data: builder.archiveData())

        let bytes = try archive.data(forEntry: "word/document.xml")

        XCTAssertEqual(String(bytes: bytes, encoding: .utf8),"<w:document/>")
    }

    func testDeflatedEntryInflates() throws {
        let body = String(repeating: "<w:p><w:r><w:t>text</w:t></w:r></w:p>", count: 200)
        var builder = OfficeFixtureBuilder()
        builder.add("word/document.xml", body)
        let archive = try DetoursOfficeArchive(data: builder.archiveData())

        let bytes = try archive.data(forEntry: "word/document.xml")

        XCTAssertEqual(String(bytes: bytes, encoding: .utf8),body)
    }

    func testMissingEntryReportsNotFound() throws {
        var builder = OfficeFixtureBuilder()
        builder.add("word/document.xml", "<w:document/>")
        let archive = try DetoursOfficeArchive(data: builder.archiveData())

        XCTAssertThrowsError(try archive.data(forEntry: "word/styles.xml")) { error in
            XCTAssertEqual(
                error as? DetoursOfficeArchiveError,
                .entryNotFound("word/styles.xml")
            )
        }
    }

    func testEncryptedEntryIsRefused() throws {
        var builder = OfficeFixtureBuilder()
        builder.isEncrypted = true
        builder.add("word/document.xml", "<w:document/>")
        let archive = try DetoursOfficeArchive(data: builder.archiveData())

        XCTAssertThrowsError(try archive.data(forEntry: "word/document.xml")) { error in
            XCTAssertEqual(error as? DetoursOfficeArchiveError, .encrypted)
        }
    }

    func testPartBeyondTheCeilingStopsReading() throws {
        var builder = OfficeFixtureBuilder()
        builder.add("word/document.xml", String(repeating: "a", count: 200))
        let archive = try DetoursOfficeArchive(data: builder.archiveData(), partByteLimit: 100)

        // The declared size is refused before a byte is read, so a container claiming to be small
        // cannot unpack into something enormous.
        XCTAssertThrowsError(try archive.data(forEntry: "word/document.xml")) { error in
            XCTAssertEqual(error as? DetoursOfficeArchiveError, .expansionLimitExceeded)
        }
    }

    func testDocumentBeyondTheTotalCeilingStopsReading() throws {
        var builder = OfficeFixtureBuilder()
        for index in 0..<3 {
            builder.add("part\(index).xml", String(repeating: "a", count: 100))
        }
        let archive = try DetoursOfficeArchive(
            data: builder.archiveData(),
            partByteLimit: 100,
            documentByteLimit: 150
        )

        // Each part fits on its own; together they do not.
        XCTAssertNoThrow(try archive.data(forEntry: "part0.xml"))
        XCTAssertThrowsError(try archive.data(forEntry: "part1.xml")) { error in
            XCTAssertEqual(error as? DetoursOfficeArchiveError, .expansionLimitExceeded)
        }
    }

    func testTruncatedContainerFailsCleanly() throws {
        var builder = OfficeFixtureBuilder()
        builder.add("word/document.xml", "<w:document/>")
        let whole = builder.archiveData()
        let cut = whole.prefix(whole.count / 2)

        XCTAssertThrowsError(try DetoursOfficeArchive(data: Data(cut)))
    }
}
