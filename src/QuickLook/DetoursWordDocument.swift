import Foundation

/// A Word document read into the structures a preview can draw: paragraphs, headings, lists,
/// tables and the emphasis carried by each run of text.
///
/// Nothing here reproduces page layout. A preview shows what the document says and how it is
/// organised, in the reader's own theme, which is the opposite of reproducing the author's fonts
/// and colours.
struct DetoursWordDocument: Equatable {
    struct Run: Equatable {
        var text: String
        var bold = false
        var italic = false
        var underline = false
    }

    /// A run of text, or a stand-in for something the preview refuses to load.
    enum Inline: Equatable {
        case text(Run)
        case placeholder(String)
    }

    struct ListItem: Equatable {
        var level: Int
        var inlines: [Inline]
        var ordered: Bool
    }

    struct TableCell: Equatable {
        var inlines: [Inline]
        var span: Int = 1
    }

    enum Block: Equatable {
        case paragraph([Inline])
        case heading(level: Int, inlines: [Inline])
        case list([ListItem])
        case table([[TableCell]])
    }

    let blocks: [Block]

    static func read(archive: DetoursOfficeArchive) throws -> DetoursWordDocument {
        let documentData = try archive.data(forEntry: "word/document.xml")
        let styles = (try? archive.data(forEntry: "word/styles.xml")).map(WordStyles.parse) ?? WordStyles()
        let numbering = (try? archive.data(forEntry: "word/numbering.xml")).map(WordNumbering.parse) ?? WordNumbering()

        let reader = WordBodyReader(styles: styles, numbering: numbering)
        guard reader.parse(documentData) else {
            throw DetoursOfficeArchiveError.corrupt
        }
        return DetoursWordDocument(blocks: reader.blocks)
    }
}

// MARK: - Styles

/// What `word/styles.xml` says about each paragraph style.
///
/// Heading level is resolved from the style's own name, which Office writes as `heading 1` in every
/// language, or from its outline level. The style identifier is not used: it is `Heading1` in an
/// English document and something else entirely in a German or French one.
struct WordStyles: Equatable {
    var headingLevels: [String: Int] = [:]

    static func parse(_ data: Data) -> WordStyles {
        let reader = WordStylesReader()
        _ = reader.parse(data)
        return WordStyles(headingLevels: reader.headingLevels)
    }
}

private final class WordStylesReader: NSObject, XMLParserDelegate {
    var headingLevels: [String: Int] = [:]

    private var currentStyleID: String?
    private var currentName: String?
    private var currentOutlineLevel: Int?

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
        switch localName(elementName) {
        case "style":
            currentStyleID = attributes.wordValue(of: "styleId")
            currentName = nil
            currentOutlineLevel = nil
        case "name":
            currentName = attributes.wordAttribute("val")
        case "outlineLvl":
            currentOutlineLevel = attributes.wordAttribute("val").flatMap(Int.init)
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
        guard localName(elementName) == "style", let styleID = currentStyleID else { return }
        if let level = Self.headingLevel(name: currentName, outlineLevel: currentOutlineLevel) {
            headingLevels[styleID] = level
        }
        currentStyleID = nil
    }

    static func headingLevel(name: String?, outlineLevel: Int?) -> Int? {
        if let name {
            let lowered = name.lowercased()
            if lowered.hasPrefix("heading"),
               let digits = lowered.split(separator: " ").last,
               let level = Int(digits) {
                return min(max(level, 1), 6)
            }
        }
        if let outlineLevel, outlineLevel >= 0, outlineLevel <= 5 {
            return outlineLevel + 1
        }
        return nil
    }
}

// MARK: - Numbering

/// What `word/numbering.xml` says about each numbering reference: whether a level draws bullets or
/// numbers. A paragraph points at a `numId`, which points at an abstract definition, which is where
/// the format for each level lives.
struct WordNumbering: Equatable {
    /// `numId` to level to whether that level is ordered.
    var orderedLevels: [String: [Int: Bool]] = [:]

    func isOrdered(numberingID: String, level: Int) -> Bool {
        orderedLevels[numberingID]?[level] ?? true
    }

    static func parse(_ data: Data) -> WordNumbering {
        let reader = WordNumberingReader()
        _ = reader.parse(data)
        var resolved: [String: [Int: Bool]] = [:]
        for (numberingID, abstractID) in reader.numberingToAbstract {
            resolved[numberingID] = reader.abstractLevels[abstractID] ?? [:]
        }
        return WordNumbering(orderedLevels: resolved)
    }
}

private final class WordNumberingReader: NSObject, XMLParserDelegate {
    var abstractLevels: [String: [Int: Bool]] = [:]
    var numberingToAbstract: [String: String] = [:]

    private var currentAbstractID: String?
    private var currentLevel: Int?
    private var currentNumberingID: String?

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
        switch localName(elementName) {
        case "abstractNum":
            currentAbstractID = attributes.wordValue(of: "abstractNumId")
        case "lvl":
            currentLevel = attributes.wordAttribute("ilvl").flatMap(Int.init)
        case "numFmt":
            guard let abstractID = currentAbstractID, let level = currentLevel else { break }
            let format = attributes.wordAttribute("val") ?? "decimal"
            abstractLevels[abstractID, default: [:]][level] = format != "bullet" && format != "none"
        case "num":
            currentNumberingID = attributes.wordValue(of: "numId")
        case "abstractNumId":
            if let numberingID = currentNumberingID, let value = attributes.wordAttribute("val") {
                numberingToAbstract[numberingID] = value
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
        switch localName(elementName) {
        case "abstractNum": currentAbstractID = nil
        case "lvl": currentLevel = nil
        case "num": currentNumberingID = nil
        default: break
        }
    }
}

// MARK: - Body

private final class WordBodyReader: NSObject, XMLParserDelegate {
    private(set) var blocks: [DetoursWordDocument.Block] = []

    private let styles: WordStyles
    private let numbering: WordNumbering

    private var inlines: [DetoursWordDocument.Inline] = []
    private var run = DetoursWordDocument.Run(text: "")
    private var inRunProperties = false
    private var inParagraphProperties = false
    private var collectingText = false
    private var skipDepth = 0

    private var paragraphStyleID: String?
    private var paragraphOutlineLevel: Int?
    private var numberingID: String?
    private var numberingLevel = 0

    private var pendingList: [DetoursWordDocument.ListItem] = []
    private var pendingListNumberingID: String?

    private var tableStack: [[[DetoursWordDocument.TableCell]]] = []
    private var rowStack: [[DetoursWordDocument.TableCell]] = []
    private var cellSpan = 1
    private var inCell = false

    init(styles: WordStyles, numbering: WordNumbering) {
        self.styles = styles
        self.numbering = numbering
    }

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        let parsed = parser.parse()
        flushList()
        return parsed
    }

    // MARK: Elements

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        let name = localName(elementName)
        if skipDepth > 0 {
            skipDepth += 1
            return
        }

        switch name {
        case "drawing", "pict", "object":
            // Nothing from inside the file is loaded, so the shape of it is all that survives.
            inlines.append(.placeholder(name == "object" ? "Embedded object" : "Image"))
            skipDepth = 1
        case "tbl":
            flushList()
            tableStack.append([])
        case "tr":
            rowStack.append([])
        case "tc":
            inCell = true
            cellSpan = 1
            inlines = []
        case "gridSpan":
            cellSpan = attributes.wordAttribute("val").flatMap(Int.init) ?? 1
        case "p":
            if !inCell { inlines = [] }
            paragraphStyleID = nil
            paragraphOutlineLevel = nil
            numberingID = nil
            numberingLevel = 0
        case "pPr":
            inParagraphProperties = true
        case "pStyle":
            paragraphStyleID = attributes.wordAttribute("val")
        case "outlineLvl":
            if inParagraphProperties {
                paragraphOutlineLevel = attributes.wordAttribute("val").flatMap(Int.init)
            }
        case "numId":
            numberingID = attributes.wordAttribute("val")
        case "ilvl":
            numberingLevel = attributes.wordAttribute("val").flatMap(Int.init) ?? 0
        case "r":
            run = DetoursWordDocument.Run(text: "")
        case "rPr":
            inRunProperties = true
        case "b" where inRunProperties:
            run.bold = attributes.isWordFlagOn
        case "i" where inRunProperties:
            run.italic = attributes.isWordFlagOn
        case "u" where inRunProperties:
            // An underline is described by its style, and `none` is a style meaning no underline.
            run.underline = attributes.isWordFlagOn && attributes.wordAttribute("val") != "none"
        case "t":
            collectingText = true
        case "tab":
            run.text.append("\t")
        case "br":
            run.text.append("\n")
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipDepth == 0, collectingText else { return }
        run.text.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        if skipDepth > 0 {
            skipDepth -= 1
            return
        }
        let name = localName(elementName)

        switch name {
        case "t":
            collectingText = false
        case "rPr":
            inRunProperties = false
        case "pPr":
            inParagraphProperties = false
        case "r":
            if !run.text.isEmpty {
                inlines.append(.text(run))
            }
            run = DetoursWordDocument.Run(text: "")
        case "p":
            finishParagraph()
        case "tc":
            rowStack[rowStack.count - 1].append(
                DetoursWordDocument.TableCell(inlines: inlines, span: max(cellSpan, 1))
            )
            inlines = []
            inCell = false
        case "tr":
            let row = rowStack.removeLast()
            if !tableStack.isEmpty {
                tableStack[tableStack.count - 1].append(row)
            }
        case "tbl":
            let table = tableStack.removeLast()
            appendBlock(.table(table))
        default:
            break
        }
    }

    // MARK: Assembly

    private func finishParagraph() {
        // A paragraph inside a table cell belongs to the cell, which keeps collecting until the
        // cell closes. Clearing here would throw the cell's own text away.
        guard !inCell else { return }
        defer { inlines = [] }

        if let numberingID {
            let ordered = numbering.isOrdered(numberingID: numberingID, level: numberingLevel)
            if pendingListNumberingID != numberingID {
                flushList()
                pendingListNumberingID = numberingID
            }
            pendingList.append(
                DetoursWordDocument.ListItem(level: numberingLevel, inlines: inlines, ordered: ordered)
            )
            return
        }
        flushList()

        guard !inlines.isEmpty else { return }
        if let level = headingLevel() {
            appendBlock(.heading(level: level, inlines: inlines))
        } else {
            appendBlock(.paragraph(inlines))
        }
    }

    private func headingLevel() -> Int? {
        if let paragraphStyleID, let level = styles.headingLevels[paragraphStyleID] {
            return level
        }
        if let paragraphOutlineLevel, paragraphOutlineLevel >= 0, paragraphOutlineLevel <= 5 {
            return paragraphOutlineLevel + 1
        }
        return nil
    }

    private func flushList() {
        guard !pendingList.isEmpty else {
            pendingListNumberingID = nil
            return
        }
        appendBlock(.list(pendingList))
        pendingList = []
        pendingListNumberingID = nil
    }

    private func appendBlock(_ block: DetoursWordDocument.Block) {
        // A table inside a table cell is flattened into the outer document rather than nested, which
        // keeps the model one level deep without losing any text.
        blocks.append(block)
    }
}

// MARK: - XML helpers

/// Office XML is written with prefixes (`w:p`, `w:tbl`), and namespace processing is left off so
/// the parser reports those qualified names. Matching on the part after the colon keeps the reader
/// working whichever prefix a writer happens to choose.
private func localName(_ elementName: String) -> String {
    guard let colon = elementName.lastIndex(of: ":") else { return elementName }
    return String(elementName[elementName.index(after: colon)...])
}

private extension [String: String] {
    /// Reads an attribute by its local name, whatever prefix carries it.
    func wordAttribute(_ name: String) -> String? {
        if let direct = self["w:\(name)"] { return direct }
        if let plain = self[name] { return plain }
        for (key, value) in self where localName(key) == name {
            return value
        }
        return nil
    }

    func wordValue(of name: String) -> String? {
        wordAttribute(name)
    }

    /// An Office flag element is on by its presence, and off only when it says so.
    var isWordFlagOn: Bool {
        guard let value = wordAttribute("val") else { return true }
        return value != "0" && value != "false" && value != "off"
    }
}
