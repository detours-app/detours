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

    /// Room reserved for each cell's own padding and border, in the same unit as the widths. The
    /// stylesheet states that padding in `ch` for exactly this reason: stated in pixels it would
    /// stop matching as soon as the reader changed the preview's font size.
    static let cellPaddingWidth = 2

    /// Measures the columns in one pass across every row, so a value arriving in the last chunk
    /// cannot widen a column that was drawn thousands of rows earlier.
    ///
    /// Pass `numericColumns` when the source already knows which columns hold numbers, as a
    /// workbook does from its cell types. Leave it out and the same pass works it out from the text.
    static func make(headers: [String], rows: [Row], numericColumns: Set<Int>? = nil) -> DetoursPreviewGrid? {
        guard !headers.isEmpty, headers.count <= maximumColumnCount else { return nil }

        var widths = headers.map { max(1, min($0.displayWidth, maximumColumnWidth)) }
        let derivesNumeric = numericColumns == nil
        var nonNumeric = Set<Int>()
        var populated = Set<Int>()

        for row in rows {
            for (index, value) in row.values.enumerated() where index < widths.count {
                if widths[index] < maximumColumnWidth {
                    widths[index] = max(widths[index], min(value.displayWidth, maximumColumnWidth))
                }
                guard derivesNumeric, !nonNumeric.contains(index) else { continue }
                // The whole-value reading comes first because it is the one that allocates nothing,
                // and it is the one every cell of a column of numbers takes.
                if Double(value) != nil {
                    populated.insert(index)
                } else if !value.trimmingCharacters(in: .whitespaces).isEmpty {
                    populated.insert(index)
                    nonNumeric.insert(index)
                }
            }
        }

        let numeric = numericColumns ?? populated.subtracting(nonNumeric)
        let columns = headers.enumerated().map { index, header in
            Column(header: header, width: widths[index], isNumeric: numeric.contains(index))
        }
        let gutter = max(2, rows.last?.label.count ?? 1)
        return DetoursPreviewGrid(columns: columns, rows: rows, gutterWidth: gutter)
    }

    /// Enough room for every column, the gutter, and the padding each cell carries.
    var totalWidth: Int {
        columns.reduce(gutterWidth + Self.cellPaddingWidth) { $0 + $1.width + Self.cellPaddingWidth }
    }
}

private extension String {
    /// How wide a value reads, counted in characters rather than in bytes, and measured only as far
    /// as a column could ever be. Counting the whole of a very long value would be wasted work.
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
        DetoursPreviewGrid.make(
            headers: table.header,
            rows: table.rows.enumerated().map { index, values in
                DetoursPreviewGrid.Row(label: String(index + 1), values: values)
            }
        )
    }

    /// Draws a grid, chunking its rows the way a long source file is chunked.
    func gridHTML(
        request: DetoursPreviewRequest,
        grid: DetoursPreviewGrid,
        lossyDecode: Bool
    ) -> GeneratedDocument {
        let body = chunked(grid.rows.map { Self.rowHTML($0, columns: grid.columns) })

        // Widths live on the column group rather than on the cells. A cell resolves `ch` against its
        // own font, and the header cells are drawn in a different one, so per-cell widths would have
        // made the header and the rows disagree about how wide a column is.
        let columnGroup = "<colgroup><col class=\"grid-gutter-col\">"
            + grid.columns.indices.map { "<col class=\"grid-col-\($0)\">" }.joined()
            + "</colgroup>"

        let headerCells = grid.columns.map { column in
            let numeric = column.isNumeric ? " class=\"grid-number\"" : ""
            return "<th\(numeric)>\(Self.escapeHTML(column.header))</th>"
        }.joined()

        let html = htmlDocument(
            chrome: PreviewChrome(
                theme: request.theme,
                title: request.displayName,
                bodyClass: request.wrapLines ? "grid-preview wrap-lines" : "grid-preview",
                allowsChunkRequests: !body.chunks.isEmpty,
                extraStylesheet: Self.gridStylesheetName
            ),
            // "Wrapped" is what the setting is called for a text file, where it means long lines
            // fold instead of running off the edge. On a table it decides whether a value too wide
            // for its column is shown whole or trimmed, so the toolbar names that instead.
            toolbar: """
            <span class="preview-hint">\(request.wrapLines ? "Full values" : "One line per row") &middot; \u{2325}W</span>
            """,
            body: """
            \(lossyWarning(lossyDecode))
            <table class="data-grid">
            \(columnGroup)
            <thead><tr><th class="grid-gutter"></th>\(headerCells)</tr></thead>
            <tbody id="source-preview" data-chunks="\(body.chunks.count)" data-chunk-scheme="\(DetoursPreviewChunkHandler.scheme)">
            \(body.eager)
            </tbody>
            </table>
            \(body.tail)
            """
        )
        return GeneratedDocument(
            html: html,
            chunks: body.chunks,
            supportFiles: [Self.gridStylesheetName: Self.gridStylesheet(for: grid)]
        )
    }

    private static func rowHTML(_ row: DetoursPreviewGrid.Row, columns: [DetoursPreviewGrid.Column]) -> String {
        var markup = "<tr><th class=\"grid-gutter\">\(escapeHTML(row.label))</th>"
        for index in columns.indices {
            let value = index < row.values.count ? row.values[index] : ""
            markup += columns[index].isNumeric
                ? "<td class=\"grid-number\">\(escapeHTML(value))</td>"
                : "<td>\(escapeHTML(value))</td>"
        }
        markup += "</tr>"
        return markup
    }

    /// The measured widths, written as a stylesheet of this preview's own.
    ///
    /// The table's total width has to be stated for fixed layout to take effect at all: left to
    /// decide its own width, a table falls back to measuring its contents, which is the behaviour
    /// this exists to avoid.
    static func gridStylesheet(for grid: DetoursPreviewGrid) -> String {
        var rules = [
            ".data-grid{table-layout:fixed;width:\(grid.totalWidth)ch}",
            ".data-grid col.grid-gutter-col{width:\(grid.gutterWidth + DetoursPreviewGrid.cellPaddingWidth)ch}"
        ]
        for (index, column) in grid.columns.enumerated() {
            let width = column.width + DetoursPreviewGrid.cellPaddingWidth
            rules.append(".data-grid col.grid-col-\(index){width:\(width)ch}")
        }
        return rules.joined(separator: "\n") + "\n"
    }
}
