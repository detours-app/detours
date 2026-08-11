import Foundation

/// The grid a data file and a workbook sheet both reduce to before either is drawn.
///
/// Column widths are settled here, once, before a single row of markup exists. The alternative is
/// letting the browser measure, and a browser re-measures every row it already drew each time more
/// arrive, which is what makes a long file get slower the further it is read.
struct DetoursPreviewGrid {
    struct Column {
        var header: String
        var width: Int
        var isNumeric: Bool
    }

    struct Row {
        /// What goes in the gutter: a data file counts its rows, a sheet carries its own numbers.
        var label: String
        var values: [String]
    }

    var columns: [Column]
    var rows: [Row]
    var gutterWidth: Int

    /// How wide a column may get before its values are trimmed, and how many columns are worth
    /// drawing at all. A file wider than the second number is not a table anybody reads.
    static let maximumColumnWidth = 60
    static let maximumColumnCount = 512

    /// Measures the columns across every row, so a value arriving in the last chunk cannot widen a
    /// column that was drawn thousands of rows earlier.
    static func make(headers: [String], rows: [Row], numericColumns: Set<Int>) -> DetoursPreviewGrid? {
        guard !headers.isEmpty, headers.count <= maximumColumnCount else { return nil }

        var widths = headers.map { max(1, min($0.displayWidth, maximumColumnWidth)) }
        for row in rows {
            for (index, value) in row.values.enumerated() where index < widths.count {
                widths[index] = max(widths[index], min(value.displayWidth, maximumColumnWidth))
            }
        }

        let columns = headers.enumerated().map { index, header in
            Column(header: header, width: widths[index], isNumeric: numericColumns.contains(index))
        }
        let gutter = max(2, rows.last?.label.count ?? 1)
        return DetoursPreviewGrid(columns: columns, rows: rows, gutterWidth: gutter)
    }
}

private extension String {
    /// How wide a value reads, counted in characters rather than in bytes, and measured only as far
    /// as a column could ever be.
    var displayWidth: Int {
        var width = 0
        for _ in self {
            width += 1
            if width >= DetoursPreviewGrid.maximumColumnWidth { break }
        }
        return width
    }
}

extension DetoursPreviewGenerator {
    static let gridStylesheetName = "grid.css"

    /// Turns a parsed data file into a grid, numbering its rows from the first one under the header.
    ///
    /// A row number counts rows, not lines: a value carrying a line break inside its quotes occupies
    /// several lines of the file and one row of the table.
    static func grid(from table: DetoursDelimitedTable) -> DetoursPreviewGrid? {
        let rows = table.rows.enumerated().map { index, values in
            DetoursPreviewGrid.Row(label: String(index + 1), values: values)
        }

        var numeric = Set(0..<table.columnCount)
        var populated = Set<Int>()
        for row in table.rows {
            for (index, value) in row.enumerated() where index < table.columnCount {
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                populated.insert(index)
                if Double(trimmed) == nil {
                    numeric.remove(index)
                }
            }
        }
        // A column holding nothing is not a column of numbers.
        numeric.formIntersection(populated)

        return DetoursPreviewGrid.make(headers: table.header, rows: rows, numericColumns: numeric)
    }

    /// Draws a grid, chunking its rows the way a long source file is chunked.
    func gridHTML(
        request: DetoursPreviewRequest,
        grid: DetoursPreviewGrid,
        lossyDecode: Bool
    ) -> GeneratedDocument {
        let rowMarkup = grid.rows.map { row in Self.rowHTML(row, columns: grid.columns) }
        let isLong = rowMarkup.count > Self.eagerLineLimit
        let eager = (isLong ? Array(rowMarkup.prefix(Self.eagerLineLimit)) : rowMarkup)
            .joined(separator: "\n")
        let chunks: [String] = isLong
            ? stride(from: Self.eagerLineLimit, to: rowMarkup.count, by: Self.chunkLineCount).map { start in
                rowMarkup[start..<min(start + Self.chunkLineCount, rowMarkup.count)].joined(separator: "\n")
            }
            : []
        let tail = isLong ? """
        <script src="support/preview-lazy.js" defer></script>
        """ : ""

        let headerCells = grid.columns.enumerated().map { index, column in
            """
            <th class="grid-cell grid-col-\(index)\(column.isNumeric ? " grid-number" : "")">\
            \(Self.escapeHTML(column.header))</th>
            """
        }.joined()

        let html = htmlDocument(
            chrome: PreviewChrome(
                theme: request.theme,
                title: request.displayName,
                bodyClass: request.wrapLines ? "grid-preview wrap-lines" : "grid-preview",
                allowsChunkRequests: !chunks.isEmpty,
                extraStylesheet: Self.gridStylesheetName
            ),
            toolbar: """
            <span class="preview-hint">\(request.wrapLines ? "Wrapped" : "Not wrapped") &middot; \u{2325}W</span>
            """,
            body: """
            \(lossyWarning(lossyDecode))
            <table class="data-grid">
            <thead><tr><th class="grid-gutter"></th>\(headerCells)</tr></thead>
            <tbody id="source-preview" data-chunks="\(chunks.count)" data-chunk-scheme="\(DetoursPreviewChunkHandler.scheme)">
            \(eager)
            </tbody>
            </table>
            \(tail)
            """
        )
        return GeneratedDocument(
            html: html,
            chunks: chunks,
            supportFiles: [Self.gridStylesheetName: Self.gridStylesheet(for: grid)]
        )
    }

    private static func rowHTML(_ row: DetoursPreviewGrid.Row, columns: [DetoursPreviewGrid.Column]) -> String {
        var cells = "<th class=\"grid-gutter\">\(escapeHTML(row.label))</th>"
        for index in columns.indices {
            let value = index < row.values.count ? row.values[index] : ""
            let numeric = columns[index].isNumeric ? " grid-number" : ""
            cells += "<td class=\"grid-cell grid-col-\(index)\(numeric)\">\(escapeHTML(value))</td>"
        }
        return "<tr>\(cells)</tr>"
    }

    /// The measured widths, written as a stylesheet of this preview's own.
    ///
    /// The table's total width has to be stated for fixed layout to take effect at all: left to
    /// decide its own width, a table falls back to measuring its contents, which is the behaviour
    /// this exists to avoid.
    static func gridStylesheet(for grid: DetoursPreviewGrid) -> String {
        var rules = [
            ".data-grid{table-layout:fixed;width:\(grid.totalWidth)ch}",
            ".data-grid .grid-gutter{width:\(grid.gutterWidth)ch}"
        ]
        for (index, column) in grid.columns.enumerated() {
            rules.append(".data-grid .grid-col-\(index){width:\(column.width)ch}")
        }
        return rules.joined(separator: "\n") + "\n"
    }
}

extension DetoursPreviewGrid {
    /// Enough room for every column, the gutter, and the padding each cell carries.
    var totalWidth: Int {
        columns.reduce(gutterWidth) { $0 + $1.width + 2 } + 2
    }
}
