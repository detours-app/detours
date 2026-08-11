import Foundation

extension DetoursPreviewGenerator {
    /// Draws a Word document as text in the reader's theme.
    ///
    /// No address, image or object from inside the file reaches the page. A hyperlink's text is kept
    /// and its destination dropped, so a link reads as the words the author wrote and goes nowhere.
    func wordHTML(request: DetoursPreviewRequest, document: DetoursWordDocument) -> GeneratedDocument {
        let body = document.blocks.map(Self.blockHTML).joined(separator: "\n")

        let html = htmlDocument(
            chrome: PreviewChrome(
                theme: request.theme,
                title: request.displayName,
                bodyClass: request.wrapLines ? "document-preview wrap-lines" : "document-preview"
            ),
            toolbar: """
            <span class="preview-hint">Images, links, and embedded content disabled</span>
            """,
            body: """
            <article class="document-body">
            \(body)
            </article>
            """
        )
        return GeneratedDocument(html: html)
    }

    /// Draws the first sheet of a workbook through the shared grid.
    func workbookHTML(request: DetoursPreviewRequest, workbook: DetoursExcelWorkbook) -> GeneratedDocument? {
        let headers = (0..<workbook.columnCount).map(DetoursExcelWorkbook.columnLetters)
        let rows = workbook.rows.map { row in
            DetoursPreviewGrid.Row(label: String(row.number), values: row.values)
        }
        guard let grid = DetoursPreviewGrid.make(
            headers: headers,
            rows: rows,
            numericColumns: workbook.numericColumns
        ) else {
            return nil
        }
        return gridHTML(request: request, grid: grid, lossyDecode: false)
    }

    // MARK: - Blocks

    private static func blockHTML(_ block: DetoursWordDocument.Block) -> String {
        switch block {
        case .paragraph(let inlines):
            return "<p>\(inlineHTML(inlines))</p>"
        case .heading(let level, let inlines):
            return "<h\(level)>\(inlineHTML(inlines))</h\(level)>"
        case .list(let items):
            return listHTML(items)
        case .table(let rows):
            let body = rows.map { row in
                let cells = row.map { cell in
                    let span = cell.span > 1 ? " colspan=\"\(cell.span)\"" : ""
                    return "<td\(span)>\(inlineHTML(cell.inlines))</td>"
                }.joined()
                return "<tr>\(cells)</tr>"
            }.joined(separator: "\n")
            return "<table class=\"document-table\">\n\(body)\n</table>"
        }
    }

    /// Nests each run of items one level deeper than the last, so an indented sub-list reads as one.
    private static func listHTML(_ items: [DetoursWordDocument.ListItem]) -> String {
        var html = ""
        var open: [(level: Int, tag: String)] = []

        for item in items {
            let tag = item.ordered ? "ol" : "ul"
            while let deepest = open.last, deepest.level > item.level {
                html += "</\(deepest.tag)>"
                open.removeLast()
            }
            if open.last?.level != item.level {
                html += "<\(tag)>"
                open.append((item.level, tag))
            }
            html += "<li>\(inlineHTML(item.inlines))</li>"
        }
        while let deepest = open.popLast() {
            html += "</\(deepest.tag)>"
        }
        return html
    }

    private static func inlineHTML(_ inlines: [DetoursWordDocument.Inline]) -> String {
        inlines.map { inline in
            switch inline {
            case .placeholder(let label):
                return "<span class=\"blocked-image\">\(escapeHTML(label))</span>"
            case .text(let run):
                // A line break inside a run is a break the author typed, and it is the only markup
                // a run's text is ever allowed to become.
                var text = escapeHTML(run.text).replacingOccurrences(of: "\n", with: "<br>")
                if run.bold { text = "<strong>\(text)</strong>" }
                if run.italic { text = "<em>\(text)</em>" }
                if run.underline { text = "<u>\(text)</u>" }
                return text
            }
        }.joined()
    }
}
