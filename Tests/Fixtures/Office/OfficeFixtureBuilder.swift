import Compression
import Foundation

/// Builds Office containers in the test rather than committing them as opaque binaries.
///
/// A checked-in `.docx` is a black box: nobody can see what it contains, a reviewer cannot tell why
/// a case passes, and a case that needs one more cell needs a new binary. Writing the parts here
/// keeps every fixture readable and lets a case say exactly what it is testing.
struct OfficeFixtureBuilder {
    private struct Part {
        let name: String
        let data: Data
        let compressed: Data
        let method: UInt16
    }

    private var parts: [Part] = []

    /// Marks every entry as encrypted, which is how a password-protected document reads from
    /// outside without any password being involved.
    var isEncrypted = false

    mutating func add(_ name: String, _ xml: String, deflated: Bool = true) {
        add(name, Data(xml.utf8), deflated: deflated)
    }

    mutating func add(_ name: String, _ data: Data, deflated: Bool = true) {
        guard deflated, let compressed = Self.deflate(data), compressed.count < data.count else {
            parts.append(Part(name: name, data: data, compressed: data, method: 0))
            return
        }
        parts.append(Part(name: name, data: data, compressed: compressed, method: 8))
    }

    func archiveData() -> Data {
        var payload = Data()
        var directory = Data()
        var offsets: [Int] = []

        for part in parts {
            offsets.append(payload.count)
            let name = Data(part.name.utf8)
            payload.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            payload.appendLittle(UInt16(20))
            payload.appendLittle(UInt16(isEncrypted ? 1 : 0))
            payload.appendLittle(part.method)
            payload.appendLittle(UInt16(0))
            payload.appendLittle(UInt16(0))
            payload.appendLittle(UInt32(0))
            payload.appendLittle(UInt32(part.compressed.count))
            payload.appendLittle(UInt32(part.data.count))
            payload.appendLittle(UInt16(name.count))
            payload.appendLittle(UInt16(0))
            payload.append(name)
            payload.append(part.compressed)
        }

        for (index, part) in parts.enumerated() {
            let name = Data(part.name.utf8)
            directory.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            directory.appendLittle(UInt16(20))
            directory.appendLittle(UInt16(20))
            directory.appendLittle(UInt16(isEncrypted ? 1 : 0))
            directory.appendLittle(part.method)
            directory.appendLittle(UInt16(0))
            directory.appendLittle(UInt16(0))
            directory.appendLittle(UInt32(0))
            directory.appendLittle(UInt32(part.compressed.count))
            directory.appendLittle(UInt32(part.data.count))
            directory.appendLittle(UInt16(name.count))
            directory.appendLittle(UInt16(0))
            directory.appendLittle(UInt16(0))
            directory.appendLittle(UInt16(0))
            directory.appendLittle(UInt16(0))
            directory.appendLittle(UInt32(0))
            directory.appendLittle(UInt32(offsets[index]))
            directory.append(name)
        }

        var archive = payload
        let directoryOffset = archive.count
        archive.append(directory)
        archive.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        archive.appendLittle(UInt16(0))
        archive.appendLittle(UInt16(0))
        archive.appendLittle(UInt16(parts.count))
        archive.appendLittle(UInt16(parts.count))
        archive.appendLittle(UInt32(directory.count))
        archive.appendLittle(UInt32(directoryOffset))
        archive.appendLittle(UInt16(0))
        return archive
    }

    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var destination = Data(count: data.count + 64)
        let written: Int = destination.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                guard let outputBase = output.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let inputBase = input.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return 0
                }
                return compression_encode_buffer(
                    outputBase,
                    output.count,
                    inputBase,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        return destination.prefix(written)
    }
}

// MARK: - Common documents

extension OfficeFixtureBuilder {
    static func wordDocument(body: String, styles: String? = nil, numbering: String? = nil) -> Data {
        var builder = OfficeFixtureBuilder()
        builder.add("word/document.xml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <w:body>\(body)</w:body></w:document>
        """)
        if let styles {
            builder.add("word/styles.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\(styles)</w:styles>
            """)
        }
        if let numbering {
            builder.add("word/numbering.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\(numbering)</w:numbering>
            """)
        }
        return builder.archiveData()
    }

    /// A workbook whose parts can each be swapped out by a case that cares about one of them.
    static func workbook(
        sheets: [(name: String, rows: String, hidden: Bool)] = [("Sheet1", "", false)],
        sharedStrings: String? = nil,
        styles: String? = nil,
        uses1904: Bool = false,
        strictFormat: Bool = false,
        omitSharedStrings: Bool = false
    ) -> Data {
        var builder = OfficeFixtureBuilder()
        let namespace = strictFormat
            ? "http://purl.oclc.org/ooxml/spreadsheetml/main"
            : "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

        let sheetEntries = sheets.enumerated().map { index, sheet in
            let state = sheet.hidden ? " state=\"hidden\"" : ""
            return "<sheet name=\"\(sheet.name)\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"\(state)/>"
        }.joined()

        builder.add("xl/workbook.xml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="\(namespace)" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <workbookPr date1904="\(uses1904 ? "1" : "0")"/>
        <sheets>\(sheetEntries)</sheets></workbook>
        """)

        let relationships = sheets.indices.map { index in
            """
            <Relationship Id="rId\(index + 1)" \
            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" \
            Target="worksheets/sheet\(index + 1).xml"/>
            """
        }.joined()
        builder.add("xl/_rels/workbook.xml.rels", """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        \(relationships)</Relationships>
        """)

        for (index, sheet) in sheets.enumerated() {
            builder.add("xl/worksheets/sheet\(index + 1).xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <worksheet xmlns="\(namespace)"><sheetData>\(sheet.rows)</sheetData></worksheet>
            """)
        }

        if let sharedStrings, !omitSharedStrings {
            builder.add("xl/sharedStrings.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <sst xmlns="\(namespace)">\(sharedStrings)</sst>
            """)
        }
        if let styles {
            builder.add("xl/styles.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <styleSheet xmlns="\(namespace)">\(styles)</styleSheet>
            """)
        }
        return builder.archiveData()
    }
}

private extension Data {
    mutating func appendLittle(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8 & 0xFF))
    }

    mutating func appendLittle(_ value: UInt32) {
        appendLittle(UInt16(value & 0xFFFF))
        appendLittle(UInt16(value >> 16 & 0xFFFF))
    }
}
