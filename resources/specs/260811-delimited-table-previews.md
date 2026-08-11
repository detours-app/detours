# Delimited Table Previews

## Meta

- Status: Draft
- Branch: feature/delimited-table-previews

---

## Business

### Goal

Pressing Space on a data file such as a spreadsheet export shows the data as a readable table with columns lined up and column names always visible, instead of the run-together wall of text macOS shows today.

### Proposal

Detours renders comma, semicolon and tab separated data files in its own preview window as a table with a frozen header row and a frozen row-number column, matching the current theme.

### Behaviors

- Pressing Space on a `.csv` or `.tsv` file opens the Detours preview window showing the data as a table.
- The first line of the file is shown as the column header and stays in place while scrolling down.
- Each row carries its line number in the file, and that number column stays in place while scrolling sideways.
- The separator is detected from the file itself, so comma, semicolon and tab files all line up correctly. European exports that use semicolons show as columns, not as one run-on line.
- Values appear exactly as written in the file. Long numbers, leading zeros and dates are never reformatted or rounded.
- Quoted values containing separators, line breaks or quotation marks appear as a single cell with their quotes removed.
- Columns holding only numbers are aligned to the right, everything else to the left.
- The wrap setting that already applies to text previews also applies here: wrapped shows tall cells with the full value, unwrapped keeps one line per row and scrolls sideways.
- Rows where a value is missing show empty cells rather than shifting the remaining values into the wrong columns.
- Long files fill in further rows as the reader scrolls, so a large export opens as quickly as a small one.
- A data file that turns out to have only one column, or that cannot be read as a table, shows the existing text preview instead of an empty table.
- A file too large for a rich preview shows the existing plain-text fallback message rather than a blank window.

### Acceptance Criteria

- [ ] **A1** Pressing Space on a comma separated file shows a table with aligned columns, a header row and row numbers.
- [ ] **A2** Scrolling down keeps the column names visible, and scrolling sideways keeps the row numbers visible.
- [ ] **A3** A semicolon separated export and a tab separated file both show as correctly split columns.
- [ ] **A4** A file containing a quoted value with a comma, a line break and a doubled quotation mark inside it shows that value in one cell, on the row it belongs to.
- [ ] **A5** A long identifier with leading zeros appears in the table exactly as written in the file.
- [ ] **A6** Switching the wrap setting changes the table between full-height cells and single-line rows.
- [ ] **A7** A file of a hundred thousand rows opens without a visible delay and shows further rows as the reader scrolls to them.
- [ ] **A8** A single-column data file shows the existing text preview, and a file beyond the size limit shows the existing plain-text fallback message.

### Out of scope

- Sorting, filtering or searching within the table.
- Editing, saving or exporting the data.
- Charts, totals, or any calculation over the values.
- Choosing the separator by hand, or column resizing by dragging.
- Spreadsheet formats such as Excel workbooks and OpenDocument sheets.

---

## Technical

### Approach

Add a delimited-table branch to the existing preview pipeline rather than a parallel one. `DetoursPreviewKind` gains a `delimitedTable` case carrying the detected delimiter, classified from the `csv`, `tsv` and `tab` extensions. A new parser in `src/QuickLook/DetoursDelimitedTable.swift` turns the decoded text into rows of fields following RFC 4180: doubled quotes inside quoted fields, delimiters and newlines inside quoted fields, and both LF and CRLF line endings, plus a leading byte-order mark strip. Delimiter detection counts unquoted candidate separators in the first lines and picks the one giving the most consistent field count, defaulting to comma.

Rendering lives in a new `src/QuickLook/DetoursPreviewGenerator+Table.swift` so `+HTML.swift` stays within the file-length limit, and reuses the existing `htmlDocument` chrome, theme variables, wrap body class and lazy-chunk mechanism unchanged. The generated markup is a `<table>` whose `<tbody>` carries `id="source-preview"` with the existing `data-chunks` and `data-chunk-scheme` attributes, so `preview-lazy.js` appends further `<tr>` chunks with no JavaScript change. Cells are escaped through the existing `escapeHTML`, never through the syntax highlighter, so no value is re-styled or altered. Table styling goes in `resources/PreviewAssets/detours/preview.css` using `border-collapse: separate`, because WebKit does not stick header cells inside a collapsed-border table.

Row numbers are the line number in the file, which stays meaningful because the preview never reorders rows. Ragged rows are padded to the widest row so values never shift columns. When the parse yields a single column, or fails, generation falls back to the existing source preview path for the same file.

### Approach Validation

Sticky table headers in WebKit have two well-documented traps that shape the CSS: a table using the default `border-collapse: collapse` will not stick its header cells in Safari, and an ancestor with `overflow: hidden` silently breaks stickiness. [Adrian Roselli's fixed table headers reference](http://adrianroselli.com/2020/01/fixed-table-headers.html) and [CSS-Tricks on position sticky and table headers](https://css-tricks.com/position-sticky-and-table-headers/) both land on separated borders plus sticky cells as the approach that works across engines, which is what this spec adopts. Freezing the row-number gutter as well as the header comes from the same reference's sticky-first-column pattern.

Complaints about existing CSV viewers pointed at three things this spec answers directly. Headers scrolling out of view is the single most reported pain in dataset previews. Garbled output is most often a separator that is not a comma, since European exports use semicolons where the comma is the decimal point, which is why detection is part of the first version rather than an option. Spreadsheet tools quietly turning order numbers into scientific notation and stripping leading zeros is the reason values are emitted verbatim and only alignment varies. Bounded rendering with progressive fill matches what large-file viewers such as [csvkit's viewer](https://csvkit.org/csv-viewer) do to stay responsive, and the existing chunk mechanism already provides it.

Field parsing follows [RFC 4180](https://www.rfc-editor.org/rfc/rfc4180) for quoting, embedded separators and embedded line breaks, with the common real-world relaxations of accepting LF endings and ragged row lengths.

### Risks

| Risk | Mitigation |
| ---- | ---------- |
| A file with commas inside quoted values splits into the wrong columns. | Parse quoted fields per RFC 4180 with a state machine rather than splitting on the separator, and cover quoted separators, quoted newlines and doubled quotes in unit tests. |
| Delimiter detection picks the wrong separator and produces one useless column. | Score candidates by field-count consistency across the first lines, prefer the extension's separator on a tie, and fall back to the existing text preview when the winning candidate yields a single column. |
| Sticky header or row-number gutter silently fails to stick in the preview window. | Use separated borders and sticky cells rather than a sticky `thead`, keep the table free of an `overflow: hidden` ancestor, and assert the generated markup and CSS hooks in tests. |
| A very wide file produces enormous rows and a slow first paint. | Keep the existing eager-row limit and chunked appending, and cap rendered columns at a fixed width per cell so first paint does not wait on the widest value. |
| Values are altered on the way to the screen, as spreadsheet tools do. | Emit every cell through HTML escaping only, never through the syntax highlighter or a number formatter, and assert leading zeros and long digit strings survive verbatim. |
| Table preview regresses existing text previews sharing the same pipeline. | Add the new kind alongside the existing ones without touching their branches, and keep the current preview test classes green. |

### Implementation Plan

**Phase 1: Parse**

- [ ] **C1** Add `case delimitedTable(delimiter: Character)` to `DetoursPreviewKind` in `src/QuickLook/DetoursPreviewKind.swift`, with its `highlightLanguage` returning `plaintext` and a distinct `cacheComponent`, and classify the `csv`, `tsv` and `tab` extensions to it.
- [ ] **C2** Create `src/QuickLook/DetoursDelimitedTable.swift` with a parser that turns decoded text plus a delimiter into `[[String]]`, handling quoted fields, doubled quotes inside quotes, delimiters and newlines inside quotes, LF and CRLF endings, and a leading byte-order mark.
- [ ] **C3** Add delimiter detection to `DetoursDelimitedTable` that scores comma, semicolon and tab over the first lines by field-count consistency and prefers the extension's separator on a tie.
- [ ] **C4** Add row normalisation to `DetoursDelimitedTable` that pads short rows to the widest row and reports the column count, so values never shift columns.

**Phase 2: Render**

- [ ] **C5** Create `src/QuickLook/DetoursPreviewGenerator+Table.swift` with a `tableHTML` function returning a `GeneratedDocument`, reusing `htmlDocument`, `PreviewChrome`, the wrap body class and `lossyWarning`, emitting a header row from the first parsed row, a row-number cell per row carrying the file line number, and every cell escaped through `escapeHTML`.
- [ ] **C6** Emit the table body as `<tbody id="source-preview">` carrying the existing `data-chunks` and `data-chunk-scheme` attributes, splitting rows beyond `eagerLineLimit` into `chunkLineCount`-sized chunks of `<tr>` markup so `preview-lazy.js` appends them unchanged.
- [ ] **C7** Add right-alignment for columns whose non-empty cells all parse as numbers, decided per column at generation time and applied as a class, without reformatting any value.
- [ ] **C8** Add table styling to `resources/PreviewAssets/detours/preview.css` using `border-collapse: separate`, sticky header cells, a sticky row-number gutter column, theme variables for borders and gutter colour, and wrapped versus single-line cell behaviour driven by the existing `wrap-lines` body class.

**Phase 3: Wire**

- [ ] **C9** Handle the new kind in `generatePreview` in `src/QuickLook/DetoursPreviewGenerator.swift` so it routes to `tableHTML`, keeps the existing input-size and output-size guards, and uses the existing plain-text fallback when a guard trips.
- [ ] **C10** Fall back to the existing source preview path in `DetoursPreviewGenerator` when the parsed table has one column or fewer, or when parsing produces no rows.
- [ ] **C11** Update `resources/docs/text-previews.md` with the supported delimited file types, the separator detection and row-number conventions, and the single-column fallback.

---

## Testing

### Unit Tests (`Tests/DetoursDelimitedTableTests.swift`)

- [ ] **T1** `testPlainRowsSplitOnTheDelimiter` - Unquoted comma rows split into fields.
- [ ] **T2** `testQuotedFieldKeepsItsDelimiter` - A comma inside a quoted field stays in one cell.
- [ ] **T3** `testQuotedFieldKeepsItsNewline` - A line break inside a quoted field stays on one row.
- [ ] **T4** `testDoubledQuotesBecomeOneQuote` - Escaped quotes inside a quoted field decode to a single quotation mark.
- [ ] **T5** `testCarriageReturnLineEndingsParse` - CRLF files produce the same rows as LF files.
- [ ] **T6** `testByteOrderMarkIsStrippedFromTheFirstHeader` - The first column name has no leading mark.
- [ ] **T7** `testRaggedRowsArePaddedNotShifted` - A short row yields trailing empty cells with earlier values in place.
- [ ] **T8** `testSemicolonExportIsDetected` - A semicolon file scores semicolon over comma.
- [ ] **T9** `testTabFileIsDetected` - A tab separated file scores tab over comma.
- [ ] **T10** `testAmbiguousFilePrefersTheExtensionDelimiter` - A tie resolves to the separator implied by the extension.

### Unit Tests (`Tests/DetoursPreviewKindTests.swift`)

- [ ] **T11** `testDelimitedExtensionsClassifyAsTable` - `.csv`, `.tsv` and `.tab` classify as the delimited table kind.
- [ ] **T12** `testBinaryDataWithACSVExtensionIsRejected` - A binary file named `.csv` stays unsupported.

### Integration Tests (`Tests/DetoursPreviewGeneratorTests.swift`)

- [ ] **T13** `testDelimitedPreviewRendersAHeaderAndRowNumbers` - Generated markup contains the header cells and per-row file line numbers.
- [ ] **T14** `testDelimitedPreviewEscapesCellContent` - Markup-shaped cell values appear escaped, not as live markup.
- [ ] **T15** `testDelimitedPreviewKeepsValuesVerbatim` - Leading zeros and long digit strings survive into the markup unchanged.
- [ ] **T16** `testNumericColumnsAreAlignedRight` - A digits-only column carries the alignment class and a mixed column does not.
- [ ] **T17** `testLongDelimitedFileChunksItsRows` - A file beyond the eager row limit emits chunks and a table body carrying the chunk attributes.
- [ ] **T18** `testWrapSettingChangesTheTableBodyClass` - Wrapped and unwrapped requests differ in the generated body class.
- [ ] **T19** `testSingleColumnFileFallsBackToTheTextPreview` - A one-column file generates the source preview markup instead of a table.
- [ ] **T20** `testOversizedDelimitedFileUsesThePlainTextFallback` - A file beyond the input guard generates the existing fallback banner.
- [ ] **T21** `testDelimitedPreviewCarriesTheStickyTableStyling` - The generated support stylesheet contains the separated-border and sticky rules the table depends on.

---

## Build Log

Populated at implement time.
