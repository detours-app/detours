import Foundation

/// A delimited data file read into a header row and the rows beneath it.
///
/// Field parsing follows RFC 4180 with the two relaxations real exports need: a lone line feed ends
/// a row as readily as a carriage return pair, and a row carrying fewer fields than the widest one
/// is padded rather than shifted, so one missing value never slides the values after it into the
/// wrong columns.
struct DetoursDelimitedTable: Equatable {
    /// The first row of the file, taken as the column names.
    let header: [String]

    /// Every row after the header, each padded to the same width as the header.
    let rows: [[String]]

    let delimiter: Character

    var columnCount: Int { header.count }

    /// The separators worth telling apart. Comma and tab are the two conventions; semicolon is what
    /// every European export uses, because there the comma is the decimal point.
    static let candidateDelimiters: [Character] = [",", ";", "\t"]

    /// How much of the file is read to decide the separator, and how many of its rows are scored.
    /// The first rows settle it, and reading further only slows a large export down.
    private static let detectionCharacterLimit = 64 * 1_024
    private static let detectionRowLimit = 20

    /// The separator a file's own extension implies, used to settle a tie between equally
    /// consistent candidates.
    static func delimiterHint(forExtension ext: String) -> Character? {
        switch ext.lowercased() {
        case "csv": return ","
        case "tsv", "tab": return "\t"
        default: return nil
        }
    }

    /// Reads a data file, deciding its encoding and its separator from the bytes themselves.
    static func read(data: Data, fileExtension: String) -> DetoursDelimitedTable? {
        // The mark is left on for detection, which a single leading character cannot mislead, and
        // taken off once inside `make`. Stripping it here would copy the whole file to drop one
        // character from the front of it.
        let text = decode(data)
        let hint = delimiterHint(forExtension: fileExtension)
        let delimiter = detectDelimiter(in: text, preferring: hint) ?? hint ?? ","
        return make(text: text, delimiter: delimiter)
    }

    /// Decodes the file's bytes.
    ///
    /// UTF-8 first, then the Windows European encoding: that is what Excel on Windows writes for the
    /// semicolon exports the separator detection exists to serve, and reading those as UTF-8 turns
    /// every accented character into a replacement mark.
    static func decode(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .windowsCP1252) {
            return text
        }
        // Intentional lossy decode once both readings have been rejected.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: data, as: UTF8.self)
    }

    static func stripByteOrderMark(_ text: String) -> String {
        guard text.hasPrefix("\u{FEFF}") else { return text }
        return String(text.dropFirst())
    }

    /// Scores each candidate separator over the first rows and returns the most consistent one.
    ///
    /// A separator that never appears leaves every row a single field, which is why a modal field
    /// count of one disqualifies a candidate outright: it is the signature of the wrong guess.
    static func detectDelimiter(in text: String, preferring hint: Character?) -> Character? {
        let sample = String(text.prefix(detectionCharacterLimit))
        let sampleWasCut = sample.count == detectionCharacterLimit
        // The hint is scored first so that a tie resolves in its favour without a second comparison.
        let ordered: [Character] = hint.map { preferred in
            [preferred] + candidateDelimiters.filter { $0 != preferred }
        } ?? candidateDelimiters

        var best: (delimiter: Character, consistency: Double, columns: Int)?
        for candidate in ordered {
            // Only what gets scored is parsed. Reading the whole sample three times over and then
            // scoring twenty rows of it is most of the work thrown away.
            var sampleRows = parseRows(sample, delimiter: candidate, rowLimit: detectionRowLimit)
            // A sample cut mid-row leaves a half-read last row, which scores as ragged.
            if sampleWasCut, sampleRows.count > 1, sampleRows.count < detectionRowLimit {
                sampleRows.removeLast()
            }
            guard !sampleRows.isEmpty else { continue }

            let counts = sampleRows.map(\.count)
            guard let modal = modalValue(of: counts), modal > 1 else { continue }
            let consistency = Double(counts.filter { $0 == modal }.count) / Double(counts.count)

            guard let current = best else {
                best = (candidate, consistency, modal)
                continue
            }
            if consistency > current.consistency
                || (consistency == current.consistency && modal > current.columns) {
                best = (candidate, consistency, modal)
            }
        }
        return best?.delimiter
    }

    /// Parses the text and pads every row out to the widest one.
    static func make(text: String, delimiter: Character) -> DetoursDelimitedTable? {
        var parsed = parseRows(stripByteOrderMark(text), delimiter: delimiter)
        guard !parsed.isEmpty else { return nil }
        let width = parsed.lazy.map(\.count).max() ?? 0

        // Only the rows that are actually short are touched. Rebuilding every row of a large export
        // to pad the few that need it is the whole file copied for nothing.
        for index in parsed.indices where parsed[index].count < width {
            parsed[index].append(contentsOf: repeatElement("", count: width - parsed[index].count))
        }
        let header = parsed.removeFirst()
        return DetoursDelimitedTable(header: header, rows: parsed, delimiter: delimiter)
    }

    /// Splits text into rows of fields.
    ///
    /// A quotation mark only opens a quoted field at the start of one, so a mark in the middle of an
    /// unquoted value stays the character it is. Inside a quoted field a doubled mark is one literal
    /// mark, and separators and line breaks are ordinary content.
    /// Pass `rowLimit` to stop once that many rows exist, which is what separator detection wants:
    /// it scores the first rows and has no use for the rest.
    static func parseRows(_ text: String, delimiter: Character, rowLimit: Int? = nil) -> [[String]] {
        var rows: [[String]] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var fieldWasQuoted = false

        var index = text.startIndex
        let end = text.endIndex
        while index < end {
            let character = text[index]

            if inQuotes {
                if character == "\"" {
                    let next = text.index(after: index)
                    if next < end, text[next] == "\"" {
                        field.append("\"")
                        index = text.index(after: next)
                        continue
                    }
                    inQuotes = false
                    index = next
                    continue
                }
                field.append(character)
                index = text.index(after: index)
                continue
            }

            switch character {
            case "\"" where field.isEmpty && !fieldWasQuoted:
                inQuotes = true
                fieldWasQuoted = true
            case delimiter:
                fields.append(field)
                field = ""
                fieldWasQuoted = false
            // A carriage return and the line feed after it are one Character in Swift, so the pair
            // has to be matched as itself rather than looked for one character at a time.
            case "\n", "\r", "\r\n":
                fields.append(field)
                field = ""
                fieldWasQuoted = false
                rows.append(fields)
                fields = []
                if let rowLimit, rows.count >= rowLimit {
                    return rows
                }
            default:
                field.append(character)
            }
            index = text.index(after: index)
        }

        // A file ending in a line break has already closed its last row; anything left is a row that
        // simply ran out of file.
        if !field.isEmpty || !fields.isEmpty || fieldWasQuoted {
            fields.append(field)
            rows.append(fields)
        }
        return rows
    }

    private static func modalValue(of counts: [Int]) -> Int? {
        var tally: [Int: Int] = [:]
        for count in counts {
            tally[count, default: 0] += 1
        }
        // A tie between two equally common counts resolves to the larger, which is the one carrying
        // more columns and therefore more evidence that the separator is right.
        return tally.max { left, right in
            left.value == right.value ? left.key < right.key : left.value < right.value
        }?.key
    }
}
