import Foundation

enum DetoursExcelWorkbookError: Error, Equatable {
    /// The strict flavour of Office Open XML, which uses different namespaces and stores dates as
    /// text. Rare enough to hand back to the system rather than to read badly.
    case strictFormat
    case noSheets
    case corrupt
}

/// The first visible sheet of a workbook, read into rows of text ready to be drawn as a grid.
///
/// Values are carried through exactly as the file stores them. The one conversion is a date: a date
/// in a workbook is an ordinary number whose style says to show it as a date, so leaving it alone
/// would show a five-digit serial where the reader expects a day.
struct DetoursExcelWorkbook: Equatable {
    let sheetName: String

    /// Every row of the used range, keyed by the sheet's own row number so a gap stays a gap.
    let rows: [(number: Int, values: [String])]

    let columnCount: Int

    /// Column indices, zero based, whose non-empty cells are all numbers. Alignment reads from this
    /// rather than from guessing at the text.
    let numericColumns: Set<Int>

    static func == (lhs: DetoursExcelWorkbook, rhs: DetoursExcelWorkbook) -> Bool {
        lhs.sheetName == rhs.sheetName
            && lhs.columnCount == rhs.columnCount
            && lhs.numericColumns == rhs.numericColumns
            && lhs.rows.count == rhs.rows.count
            && zip(lhs.rows, rhs.rows).allSatisfy { $0.number == $1.number && $0.values == $1.values }
    }

    static func read(archive: DetoursOfficeArchive) throws -> DetoursExcelWorkbook {
        let workbookData = try archive.data(forEntry: "xl/workbook.xml")
        let workbook = try WorkbookIndex.parse(workbookData)

        let relationships = (try? archive.data(forEntry: "xl/_rels/workbook.xml.rels"))
            .map(WorkbookRelationships.parse) ?? WorkbookRelationships()

        // The first sheet the reader would see in Excel, which is the first one not hidden.
        guard let sheet = workbook.sheets.first(where: { !$0.isHidden }) ?? workbook.sheets.first else {
            throw DetoursExcelWorkbookError.noSheets
        }
        guard let target = sheet.relationshipID.flatMap({ relationships.targets[$0] }) else {
            throw DetoursExcelWorkbookError.corrupt
        }

        let sheetData = try archive.data(forEntry: Self.partPath(for: target))
        let styles = (try? archive.data(forEntry: "xl/styles.xml")).map(WorkbookStyles.parse) ?? WorkbookStyles()
        let sheetReader = WorksheetReader(styles: styles, uses1904: workbook.uses1904)
        guard sheetReader.parse(sheetData) else {
            throw DetoursExcelWorkbookError.corrupt
        }

        // The shared string table is only required when a cell actually points into it. A workbook
        // that never does is complete without it.
        var sharedStrings: [String] = []
        if sheetReader.needsSharedStrings {
            let stringsData = try archive.data(forEntry: "xl/sharedStrings.xml")
            sharedStrings = SharedStrings.parse(stringsData)
        }

        return Self.assemble(
            sheetName: sheet.name,
            cells: sheetReader.cells,
            sharedStrings: sharedStrings
        )
    }

    /// Relationship targets are written relative to the part that declares them, which for the
    /// workbook means relative to `xl/`.
    static func partPath(for target: String) -> String {
        if target.hasPrefix("/") {
            return String(target.dropFirst())
        }
        if target.hasPrefix("xl/") {
            return target
        }
        return "xl/" + target
    }

    private static func assemble(
        sheetName: String,
        cells: [WorksheetReader.ParsedRow],
        sharedStrings: [String]
    ) -> DetoursExcelWorkbook {
        var resolved: [(number: Int, values: [Int: String])] = []
        var widest = 0
        var populated = Set<Int>()
        var textColumns = Set<Int>()

        // Whether a column holds numbers is settled from the cell types the file itself carries,
        // which is better evidence than reading the text back and guessing at it.
        for row in cells {
            var values: [Int: String] = [:]
            for (column, cell) in row.cells {
                let text = cell.resolvedText(sharedStrings: sharedStrings)
                guard !text.isEmpty else { continue }
                values[column] = text
                widest = max(widest, column + 1)
                populated.insert(column)
                if !cell.isNumeric {
                    textColumns.insert(column)
                }
            }
            if !values.isEmpty {
                resolved.append((row.number, values))
            }
        }

        // A column nothing was ever written into is not a column of numbers.
        let numericColumns = populated.subtracting(textColumns)

        let dense = resolved.map { row in
            (
                number: row.number,
                values: (0..<widest).map { row.values[$0] ?? "" }
            )
        }
        return DetoursExcelWorkbook(
            sheetName: sheetName,
            rows: dense,
            columnCount: widest,
            numericColumns: numericColumns
        )
    }

    /// `AB` to 27, so a cell can be placed by the address it carries rather than by counting the
    /// cells before it, which sparse rows make meaningless.
    static func columnIndex(fromReference reference: String) -> Int? {
        var index = 0
        var sawLetter = false
        for character in reference {
            guard let ascii = character.asciiValue else { return nil }
            if ascii >= 65, ascii <= 90 {
                index = index * 26 + Int(ascii - 64)
                sawLetter = true
            } else if ascii >= 97, ascii <= 122 {
                index = index * 26 + Int(ascii - 96)
                sawLetter = true
            } else {
                break
            }
        }
        return sawLetter ? index - 1 : nil
    }

    /// `27` to `AB`, for the header row of the grid.
    static func columnLetters(_ index: Int) -> String {
        var remaining = index + 1
        var letters = ""
        while remaining > 0 {
            let residue = (remaining - 1) % 26
            letters = String(UnicodeScalar(UInt8(65 + residue))) + letters
            remaining = (remaining - 1) / 26
        }
        return letters
    }
}

// MARK: - Workbook part

private struct WorkbookIndex {
    struct Sheet {
        let name: String
        let relationshipID: String?
        let isHidden: Bool
    }

    let sheets: [Sheet]
    let uses1904: Bool

    static func parse(_ data: Data) throws -> WorkbookIndex {
        let reader = WorkbookReader()
        guard reader.parse(data) else { throw DetoursExcelWorkbookError.corrupt }
        if reader.isStrictFormat { throw DetoursExcelWorkbookError.strictFormat }
        guard !reader.sheets.isEmpty else { throw DetoursExcelWorkbookError.noSheets }
        return WorkbookIndex(sheets: reader.sheets, uses1904: reader.uses1904)
    }
}

private final class WorkbookReader: NSObject, XMLParserDelegate {
    var sheets: [WorkbookIndex.Sheet] = []
    var uses1904 = false
    var isStrictFormat = false

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        switch officeLocalName(elementName) {
        case "workbook":
            if let namespace = attributes["xmlns"], namespace.contains("purl.oclc.org") {
                isStrictFormat = true
            }
        case "workbookPr":
            // The flag is an XML boolean, so it arrives as any of these four spellings.
            if let value = attributes["date1904"] ?? attributes["dateCompatibility"] {
                uses1904 = value == "1" || value.lowercased() == "true"
            }
        case "sheet":
            let state = attributes["state"]?.lowercased()
            sheets.append(
                WorkbookIndex.Sheet(
                    name: attributes["name"] ?? "Sheet",
                    relationshipID: attributes.first { officeLocalName($0.key) == "id" }?.value,
                    isHidden: state == "hidden" || state == "veryhidden"
                )
            )
        default:
            break
        }
    }
}

private struct WorkbookRelationships {
    var targets: [String: String] = [:]

    static func parse(_ data: Data) -> WorkbookRelationships {
        let reader = RelationshipsReader()
        _ = reader.parse(data)
        return WorkbookRelationships(targets: reader.targets)
    }
}

private final class RelationshipsReader: NSObject, XMLParserDelegate {
    var targets: [String: String] = [:]

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        guard officeLocalName(elementName) == "Relationship",
              let id = attributes["Id"], let target = attributes["Target"] else { return }
        targets[id] = target
    }
}

// MARK: - Shared strings

private enum SharedStrings {
    static func parse(_ data: Data) -> [String] {
        let reader = SharedStringsReader()
        _ = reader.parse(data)
        return reader.strings
    }
}

private final class SharedStringsReader: NSObject, XMLParserDelegate {
    var strings: [String] = []

    private var current: String?
    private var collecting = false
    private var phoneticDepth = 0

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        switch officeLocalName(elementName) {
        case "si":
            // An empty entry still occupies its index, and dropping it shifts every later string.
            current = ""
        case "rPh":
            phoneticDepth += 1
        case "t":
            collecting = phoneticDepth == 0
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard collecting, current != nil else { return }
        current?.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        switch officeLocalName(elementName) {
        case "si":
            strings.append(current ?? "")
            current = nil
        case "rPh":
            phoneticDepth = max(0, phoneticDepth - 1)
        case "t":
            collecting = false
        default:
            break
        }
    }
}

// MARK: - Styles

/// Which cell formats mean "this number is a date".
struct WorkbookStyles {
    /// Cell format index to whether that format shows a date or a time.
    var dateFormats: [Int: Bool] = [:]

    func isDate(styleIndex: Int?) -> Bool {
        guard let styleIndex else { return false }
        return dateFormats[styleIndex] ?? false
    }

    static func parse(_ data: Data) -> WorkbookStyles {
        let reader = StylesReader()
        _ = reader.parse(data)
        var resolved: [Int: Bool] = [:]
        for (index, numberFormatID) in reader.cellFormats.enumerated() {
            resolved[index] = isDateFormat(id: numberFormatID, code: reader.customCodes[numberFormatID])
        }
        return WorkbookStyles(dateFormats: resolved)
    }

    /// Built-in identifiers 14 to 22 and 45 to 47 are the dates and times Excel ships, and they are
    /// usually not written into the file at all, so they have to be known rather than read. Anything
    /// custom is decided by looking at the format code itself.
    static func isDateFormat(id: Int, code: String?) -> Bool {
        if (14...22).contains(id) || (45...47).contains(id) {
            return true
        }
        guard let code else { return false }
        return codeShowsDate(code)
    }

    /// Looks for a date or time token in a format code, ignoring the parts that only decorate it:
    /// quoted literals, escaped characters, and the bracketed colour and condition sections.
    static func codeShowsDate(_ code: String) -> Bool {
        var inQuotes = false
        var inBrackets = false
        var escaped = false
        for character in code {
            if escaped {
                escaped = false
                continue
            }
            switch character {
            case "\\":
                escaped = true
            case "\"":
                inQuotes.toggle()
            case "[":
                inBrackets = true
            case "]":
                inBrackets = false
            case "y", "Y", "d", "D", "h", "H", "s", "S":
                // A lone `m` is left out on purpose: it means minutes as often as months, and a
                // format carrying a real date always carries a year or a day beside it.
                if !inQuotes && !inBrackets { return true }
            default:
                break
            }
        }
        return false
    }
}

private final class StylesReader: NSObject, XMLParserDelegate {
    var customCodes: [Int: String] = [:]
    var cellFormats: [Int] = []

    private var inCellFormats = false

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        switch officeLocalName(elementName) {
        case "numFmt":
            if let id = attributes["numFmtId"].flatMap(Int.init), let code = attributes["formatCode"] {
                customCodes[id] = code
            }
        case "cellXfs":
            inCellFormats = true
        case "xf":
            // Only the cell formats are indexed by a cell's style attribute; the named ones above
            // them share the element name and must not shift the indices.
            if inCellFormats {
                cellFormats.append(attributes["numFmtId"].flatMap(Int.init) ?? 0)
            }
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        if officeLocalName(elementName) == "cellXfs" {
            inCellFormats = false
        }
    }
}

// MARK: - Worksheet

private final class WorksheetReader: NSObject, XMLParserDelegate {
    struct Cell {
        /// Set when the cell points into the shared string table rather than carrying its own text.
        var sharedIndex: Int?
        var text: String = ""
        var isNumeric: Bool

        func resolvedText(sharedStrings: [String]) -> String {
            guard let sharedIndex else { return text }
            guard sharedIndex >= 0, sharedIndex < sharedStrings.count else { return "" }
            return sharedStrings[sharedIndex]
        }
    }

    struct ParsedRow {
        var number: Int
        var cells: [Int: Cell]
    }

    private(set) var cells: [ParsedRow] = []
    private(set) var needsSharedStrings = false

    private let styles: WorkbookStyles
    private let uses1904: Bool

    private var currentRow: ParsedRow?
    private var fallbackRowNumber = 0
    private var currentColumn = 0
    private var fallbackColumn = 0
    private var currentType: String?
    private var currentStyleIndex: Int?
    private var value = ""
    private var collectingValue = false
    private var collectingInline = false
    private var inlineText = ""

    init(styles: WorkbookStyles, uses1904: Bool) {
        self.styles = styles
        self.uses1904 = uses1904
    }

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        switch officeLocalName(elementName) {
        case "row":
            fallbackRowNumber += 1
            let number = attributes["r"].flatMap(Int.init) ?? fallbackRowNumber
            fallbackRowNumber = number
            currentRow = ParsedRow(number: number, cells: [:])
            fallbackColumn = 0
        case "c":
            currentColumn = attributes["r"]
                .flatMap(DetoursExcelWorkbook.columnIndex(fromReference:)) ?? fallbackColumn
            fallbackColumn = currentColumn + 1
            currentType = attributes["t"]
            currentStyleIndex = attributes["s"].flatMap(Int.init)
            value = ""
            inlineText = ""
        case "v":
            collectingValue = true
        case "is":
            collectingInline = true
        case "t":
            if collectingInline { collectingValue = true }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard collectingValue else { return }
        if collectingInline {
            inlineText.append(string)
        } else {
            value.append(string)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        switch officeLocalName(elementName) {
        case "v", "t":
            collectingValue = false
        case "is":
            collectingInline = false
        case "c":
            finishCell()
        case "row":
            if let row = currentRow, !row.cells.isEmpty {
                cells.append(row)
            }
            currentRow = nil
        default:
            break
        }
    }

    private func finishCell() {
        guard currentRow != nil else { return }
        let cell: Cell?

        switch currentType {
        case "s":
            needsSharedStrings = true
            cell = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
                .map { Cell(sharedIndex: $0, isNumeric: false) }
        case "inlineStr":
            cell = inlineText.isEmpty ? nil : Cell(text: inlineText, isNumeric: false)
        case "str", "e":
            cell = value.isEmpty ? nil : Cell(text: value, isNumeric: false)
        case "b":
            cell = value.isEmpty ? nil : Cell(text: value == "1" ? "TRUE" : "FALSE", isNumeric: false)
        default:
            if value.isEmpty {
                cell = nil
            } else if styles.isDate(styleIndex: currentStyleIndex), let serial = Double(value) {
                cell = Cell(text: Self.dateText(serial: serial, uses1904: uses1904), isNumeric: false)
            } else {
                // Stored exactly as written. Reformatting is how a spreadsheet turns an order number
                // into scientific notation.
                cell = Cell(text: value, isNumeric: Double(value) != nil)
            }
        }

        if let cell {
            currentRow?.cells[currentColumn] = cell
        }
        currentType = nil
        currentStyleIndex = nil
        value = ""
        inlineText = ""
    }

    /// Turns a serial into a date the way Excel shows it.
    ///
    /// Day zero is 30 December 1899, not 31 December, because Excel believes 1900 was a leap year
    /// and counts a 29 February that never happened. That phantom day only affects serials below it,
    /// which are shifted back by one to land on the date Excel prints.
    static func dateText(serial: Double, uses1904: Bool) -> String {
        var days = serial
        if !uses1904, days < 60 {
            days += 1
        }
        let epoch = uses1904
            ? DateComponents(year: 1904, month: 1, day: 1)
            : DateComponents(year: 1899, month: 12, day: 30)

        var calendar = Calendar(identifier: .gregorian)
        guard let timeZone = TimeZone(identifier: "UTC") else { return String(serial) }
        calendar.timeZone = timeZone
        guard let base = calendar.date(from: epoch) else { return String(serial) }

        let whole = days.rounded(.down)
        let fraction = days - whole
        // Times are fractions of a day and carry float noise, so they are settled to the second.
        let seconds = (fraction * 86_400).rounded()
        guard let moment = calendar.date(byAdding: .day, value: Int(whole), to: base) else {
            return String(serial)
        }
        let stamp = moment.addingTimeInterval(seconds)

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = seconds > 0 ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd"
        return formatter.string(from: stamp)
    }
}
