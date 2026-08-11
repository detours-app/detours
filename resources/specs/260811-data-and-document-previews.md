# Data and Document Previews

## Meta

- Status: Draft
- Branch: feature/data-and-document-previews

---

## Business

### Goal

Pressing Space on a data file or an Office document opens it inside the Detours preview window, in the Detours theme, instead of showing a wall of run-together text or handing the file to the separate macOS preview panel.

### Proposal

Detours reads comma, semicolon and tab separated data files, Word documents and Excel workbooks itself, and shows each as a readable table or document in its own preview window.

### Behaviors

- Pressing Space on a `.csv` or `.tsv` file shows the data as a table with columns lined up.
- Pressing Space on a `.docx` file shows the document text with its headings, paragraphs, bulleted and numbered lists, tables, and bold, italic and underlined words preserved.
- Pressing Space on an `.xlsx` file shows the workbook as a grid, and a workbook with several sheets shows one sheet at a time with a row of sheet names at the top to switch between them.
- In every table and grid, the column names stay in place while scrolling down and the row numbers stay in place while scrolling sideways.
- For data files, the separator is detected from the file itself, so comma, semicolon and tab files all line up correctly. European exports that use semicolons show as columns, not as one run-on line.
- Values appear exactly as written in the file. Long numbers, leading zeros and identifiers are never reformatted or rounded.
- Quoted values containing separators, line breaks or quotation marks appear as a single cell with their quotes removed.
- Rows where a value is missing show empty cells rather than shifting the remaining values into the wrong columns.
- In workbooks, dates appear as dates rather than as a serial number, a cell holding a calculation shows its last calculated result, and empty trailing rows and columns are left out.
- Columns holding only numbers are aligned to the right, everything else to the left.
- Pictures, charts, drawings and embedded objects in Office documents are replaced by a labelled placeholder. Nothing from inside the file is loaded or run, and links appear as plain text.
- The wrap setting that already applies to text previews also applies to tables: wrapped shows tall cells with the full value, unwrapped keeps one line per row and scrolls sideways.
- Long files fill in further rows as the reader scrolls, so a large export opens as quickly as a small one.
- A data file with only one column, a password-protected or damaged Office file, a PowerPoint file, and the older Word and Excel formats all keep their existing preview behavior.
- A file too large for a rich preview, or one whose content expands beyond the safe limit, shows the existing plain-language fallback message rather than a blank window or a stall.

### Acceptance Criteria

- [ ] **A1** Pressing Space on a comma separated file shows a table with aligned columns, a header row and row numbers.
- [ ] **A2** Scrolling down keeps the column names visible, and scrolling sideways keeps the row numbers visible, in both data tables and workbook grids.
- [ ] **A3** A semicolon separated export and a tab separated file both show as correctly split columns.
- [ ] **A4** A file containing a quoted value with a comma, a line break and a doubled quotation mark inside it shows that value in one cell, on the row it belongs to.
- [ ] **A5** A long identifier with leading zeros appears exactly as written, in both data files and workbooks.
- [ ] **A6** Switching the wrap setting changes tables between full-height cells and single-line rows.
- [ ] **A7** A file of a hundred thousand rows opens without a visible delay and shows further rows as the reader scrolls to them.
- [ ] **A8** Pressing Space on a Word document shows its text in the active theme, with headings, lists and tables recognisable.
- [ ] **A9** Bold, italic and underlined words in a Word document appear with that emphasis in the preview.
- [ ] **A10** Pressing Space on an Excel workbook shows a grid with column letters and row numbers, and a workbook with more than one sheet lets the reader move between sheets from inside the preview.
- [ ] **A11** A date cell shows a readable date, and a cell containing a calculation shows its last calculated result.
- [ ] **A12** A document containing a picture shows a labelled placeholder, and no picture, script or address from inside the file is loaded.
- [ ] **A13** A single-column data file, a password-protected Word file, a PowerPoint file, and an older-format Word file all keep their existing preview behavior.
- [ ] **A14** A file beyond the size limit, or one that expands beyond the safe limit while being read, shows the existing plain-language fallback message.

### Out of scope

- Sorting, filtering or searching within a table.
- Editing, saving or exporting anything.
- Charts, totals, recalculated formulas, or any calculation over the values.
- Choosing the separator by hand, or column resizing by dragging.
- PowerPoint presentations, the older binary Word and Excel formats, and OpenDocument files.
- Showing pictures, charts, shapes or drawings as anything other than a placeholder.
- Reproducing page layout, page breaks, fonts, colours, column widths or cell fills from the original document.
- Comments, tracked changes, footnotes, headers and footers.

---

## Technical

### Approach

One shared grid renderer serves all three formats, which is why they belong in a single change. `DetoursPreviewKind` gains `delimitedTable`, `wordDocument` and `spreadsheet` cases; everything else hangs off the existing pipeline, so theme variables, the wrap class, caching, size guards and the fallback banner apply unchanged, and every failure path returns the original URL so the file keeps its current macOS preview behavior.

Delimited files are parsed in `src/QuickLook/DetoursDelimitedTable.swift` following RFC 4180: doubled quotes inside quoted fields, separators and newlines inside quoted fields, LF and CRLF endings, and a leading byte-order mark strip. Delimiter detection counts unquoted candidates in the first lines and picks the one giving the most consistent field count, preferring the extension's separator on a tie. Ragged rows are padded to the widest row.

Office files are ZIP containers of XML parts. `src/QuickLook/DetoursOfficeArchive.swift` reads a named entry without unpacking the whole file: it locates the end-of-central-directory record and walks the central directory the way `src/Operations/ZipArchiveMetadata.swift` already does, then inflates stored and deflated entries with the `Compression` framework, refusing encrypted entries and capping inflated size per part and per document. `src/QuickLook/DetoursWordDocument.swift` parses `word/document.xml`, `word/styles.xml` and `word/numbering.xml` with Foundation's `XMLParser` into paragraphs, headings, lists, tables and emphasis, with drawings becoming placeholders. `src/QuickLook/DetoursExcelWorkbook.swift` parses `xl/workbook.xml`, `xl/sharedStrings.xml`, `xl/styles.xml` and each worksheet part, resolving shared strings, using the cached value of a formula cell, converting date-formatted serial numbers, and trimming trailing empty rows and columns. No AppKit text system is involved, so generation stays off the main actor like the existing generators.

Rendering lives in `src/QuickLook/DetoursPreviewGenerator+Table.swift` for the shared grid and `+Office.swift` for Word, both returning a `GeneratedDocument` through the existing `htmlDocument` chrome. The grid's `<tbody>` carries `id="source-preview"` with the existing `data-chunks` and `data-chunk-scheme` attributes, so `preview-lazy.js` appends further row chunks with no JavaScript change. Table styling uses `border-collapse: separate`, because WebKit does not stick header cells inside a collapsed-border table, and sheet switching reuses the pure-CSS radio control the Markdown preview already uses for its rendered and source views.

### Approach Validation

Sticky table headers in WebKit have two documented traps that shape the CSS: a table using the default `border-collapse: collapse` will not stick its header cells in Safari, and an ancestor with `overflow: hidden` silently breaks stickiness. [Adrian Roselli's fixed table headers reference](http://adrianroselli.com/2020/01/fixed-table-headers.html) and [CSS-Tricks on position sticky and table headers](https://css-tricks.com/position-sticky-and-table-headers/) both land on separated borders plus sticky cells, which is what this spec adopts, along with the same reference's sticky-first-column pattern for the row-number gutter.

Complaints about existing data viewers pointed at three things. Headers scrolling out of view is the most reported pain. Garbled output is most often a separator that is not a comma, since European exports use semicolons where the comma is the decimal point, which is why detection is part of the first version rather than an option. Spreadsheet tools quietly turning order numbers into scientific notation and stripping leading zeros is why values are emitted verbatim and only alignment varies. Bounded rendering with progressive fill matches what large-file viewers such as [csvkit's viewer](https://csvkit.org/csv-viewer) do, and the existing chunk mechanism already provides it. Field parsing follows [RFC 4180](https://www.rfc-editor.org/rfc/rfc4180) with the common relaxations of LF endings and ragged rows.

For Word, the tempting shortcut is AppKit's own reader, `NSAttributedString` with the `officeOpenXML` document type. It is rejected here because its importers are backed by AppKit and WebKit text machinery with main-thread expectations, conflicting with a generator that runs off the main actor; its Office support covers only a subset of attributes; and it produces styled HTML carrying its own fonts and colours, which fights the theme the preview exists to apply. Packages such as [DocX](https://github.com/shinjukunian/DocX) exist precisely because the system path is partial, and this project carries no third-party dependencies today. Reading the container directly extends proven code: `ZipArchiveMetadata` already parses the central directory including the ZIP64 case, and Apple's `Compression` framework covers the only two methods Office writes.

The failure modes worth designing against are size-related rather than format-related. A container can declare a small compressed size and expand enormously, so the reader caps both a single part and the document total instead of trusting the header. Fully reproducing Excel's number formats is open-ended, so this spec commits to the narrow, high-value case, resolving date formats and otherwise showing the stored value, and says so in the behaviors rather than implying Excel-identical formatting.

### Risks

| Risk | Mitigation |
| ---- | ---------- |
| A file with separators inside quoted values splits into the wrong columns. | Parse quoted fields per RFC 4180 with a state machine rather than splitting on the separator, and cover quoted separators, quoted newlines and doubled quotes in tests. |
| Delimiter detection picks the wrong separator and produces one useless column. | Score candidates by field-count consistency across the first lines, prefer the extension's separator on a tie, and fall back to the existing text preview when the winner yields a single column. |
| Sticky header or row-number gutter silently fails to stick in the preview window. | Use separated borders and sticky cells rather than a sticky `thead`, keep the table free of an `overflow: hidden` ancestor, and assert the generated markup and CSS hooks in tests. |
| A crafted document expands into an enormous amount of memory while being read. | Cap the inflated size of each part and of the document as a whole, stop reading at the cap, and route to the existing plain-text fallback banner. |
| Content from inside a document loads or runs something. | Emit no image, object or script from the container, replace drawings with placeholders, render hyperlinks as inert text, and keep the existing restrictive content security policy. |
| Malformed or unexpected XML crashes or hangs the preview. | Parse with a delegate that ignores unknown elements rather than asserting on structure, treat a parse failure as unsupported, and cover truncated and hostile fixtures in tests. |
| Values are altered on the way to the screen, as spreadsheet tools do. | Emit every cell through HTML escaping only, never through the syntax highlighter or a number formatter, and assert leading zeros and long digit strings survive verbatim. |
| Word documents lose structure and read as one undifferentiated block. | Map heading styles, list numbering and tables explicitly, and assert each structure against fixtures rather than testing only that text appears. |
| A password-protected or damaged file previews as an empty document. | Detect encrypted entries and parse failures before any HTML is generated and return the original URL. |
| The new kinds regress existing text previews sharing the same pipeline. | Add the new kinds alongside the existing ones without touching their branches, and keep the current preview test classes green. |

### Implementation Plan

**Phase 1: Delimited data**

- [ ] **C1** Add `case delimitedTable(delimiter: Character)` to `DetoursPreviewKind` in `src/QuickLook/DetoursPreviewKind.swift`, with a distinct cache component, classifying the `csv`, `tsv` and `tab` extensions.
- [ ] **C2** Create `src/QuickLook/DetoursDelimitedTable.swift` with a parser turning decoded text plus a delimiter into rows of fields, handling quoted fields, doubled quotes, embedded separators and newlines, LF and CRLF endings, and a leading byte-order mark.
- [ ] **C3** Add delimiter detection to `DetoursDelimitedTable` scoring comma, semicolon and tab over the first lines by field-count consistency, preferring the extension's separator on a tie.
- [ ] **C4** Add row normalisation to `DetoursDelimitedTable` padding short rows to the widest row and reporting the column count.

**Phase 2: Office containers**

- [ ] **C5** Create `src/QuickLook/DetoursOfficeArchive.swift` locating the end-of-central-directory record and walking the central directory including the ZIP64 case, following the pattern in `src/Operations/ZipArchiveMetadata.swift`, returning the bytes of a named entry.
- [ ] **C6** Add inflation to `DetoursOfficeArchive` for stored and deflated entries using the `Compression` framework, rejecting any other compression method.
- [ ] **C7** Add expansion guards to `DetoursOfficeArchive`: a per-part ceiling, a per-document total ceiling, and refusal of encrypted entries, each surfacing a distinct error rather than a partial result.
- [ ] **C8** Create `src/QuickLook/DetoursWordDocument.swift` parsing `word/document.xml` with `XMLParser` into an ordered model of paragraphs, runs, lists and tables.
- [ ] **C9** Extend `DetoursWordDocument` to read `word/styles.xml` and `word/numbering.xml` so paragraph styles resolve to heading levels and numbering references resolve to ordered or unordered lists.
- [ ] **C10** Extend `DetoursWordDocument` to carry bold, italic and underline from run properties and to emit labelled placeholders for drawings, pictures and embedded objects.
- [ ] **C11** Create `src/QuickLook/DetoursExcelWorkbook.swift` parsing `xl/workbook.xml` for sheet names and order and each worksheet part into rows of cells addressed by column letter and row number.
- [ ] **C12** Extend `DetoursExcelWorkbook` to resolve shared strings from `xl/sharedStrings.xml`, use the cached value of a formula cell, and trim trailing empty rows and columns.
- [ ] **C13** Extend `DetoursExcelWorkbook` to read `xl/styles.xml` number formats and convert date-formatted serial numbers to a readable date, leaving every other value as stored.
- [ ] **C14** Add `case wordDocument` and `case spreadsheet` to `DetoursPreviewKind` classified from the `docx` and `xlsx` extensions with their own cache components, excluded from the text-like sniffing path.

**Phase 3: Rendering**

- [ ] **C15** Create `src/QuickLook/DetoursPreviewGenerator+Table.swift` with a shared grid renderer returning a `GeneratedDocument`, reusing `htmlDocument`, `PreviewChrome`, the wrap body class and `lossyWarning`, emitting a header row, a row-number cell per row, and every cell escaped through `escapeHTML`.
- [ ] **C16** Emit the grid body as `<tbody id="source-preview">` carrying the existing `data-chunks` and `data-chunk-scheme` attributes, splitting rows beyond `eagerLineLimit` into `chunkLineCount`-sized chunks of row markup so `preview-lazy.js` appends them unchanged.
- [ ] **C17** Add right-alignment for columns whose non-empty cells all parse as numbers, decided per column at generation time and applied as a class, without reformatting any value.
- [ ] **C18** Create `src/QuickLook/DetoursPreviewGenerator+Office.swift` with a `wordHTML` function rendering the Word model through the existing chrome, escaping all text, rendering hyperlinks as inert text, and honouring the wrap body class.
- [ ] **C19** Add a `workbookHTML` function to `DetoursPreviewGenerator+Office.swift` rendering the active sheet through the shared grid renderer with column letters as headers, and sheet switching using the pure-CSS radio control pattern already used by the Markdown toggle.
- [ ] **C20** Add table, document and sheet-tab styling to `resources/PreviewAssets/detours/preview.css` using `border-collapse: separate`, sticky header cells, a sticky row-number gutter, headings, lists, placeholders, and wrapped versus single-line cell behaviour driven by the existing `wrap-lines` body class, using existing theme variables only.

**Phase 4: Wiring**

- [ ] **C21** Route the new kinds in `generatePreview` in `src/QuickLook/DetoursPreviewGenerator.swift`, keeping the existing input-size and output-size guards and the existing fallback banner when a guard trips.
- [ ] **C22** Return the original source URL from `generatePreview` when a delimited file yields one column or fewer, when an Office container is encrypted or missing a required part, when parsing fails, or when an expansion guard trips.
- [ ] **C23** Update `resources/docs/text-previews.md` with the supported data and document types, the separator and row-number conventions, the placeholder and inert-link behavior, the date and formula value conventions, and what keeps its existing preview behavior.

---

## Testing

### Unit Tests (`Tests/DetoursDelimitedTableTests.swift`)

- [ ] **T1** `testPlainRowsSplitOnTheDelimiter` - Unquoted rows split into fields.
- [ ] **T2** `testQuotedFieldKeepsItsDelimiter` - A separator inside a quoted field stays in one cell.
- [ ] **T3** `testQuotedFieldKeepsItsNewline` - A line break inside a quoted field stays on one row.
- [ ] **T4** `testDoubledQuotesBecomeOneQuote` - Escaped quotes decode to a single quotation mark.
- [ ] **T5** `testCarriageReturnLineEndingsParse` - CRLF files produce the same rows as LF files.
- [ ] **T6** `testByteOrderMarkIsStrippedFromTheFirstHeader` - The first column name has no leading mark.
- [ ] **T7** `testRaggedRowsArePaddedNotShifted` - A short row yields trailing empty cells with earlier values in place.
- [ ] **T8** `testSemicolonExportIsDetected` - A semicolon file scores semicolon over comma.
- [ ] **T9** `testTabFileIsDetected` - A tab separated file scores tab over comma.
- [ ] **T10** `testAmbiguousFilePrefersTheExtensionDelimiter` - A tie resolves to the separator implied by the extension.

### Unit Tests (`Tests/DetoursOfficeArchiveTests.swift`)

- [ ] **T11** `testStoredEntryIsReadVerbatim` - An uncompressed entry returns its exact bytes.
- [ ] **T12** `testDeflatedEntryInflates` - A compressed entry returns the original content.
- [ ] **T13** `testMissingEntryReportsNotFound` - Asking for an absent part fails with a distinct error.
- [ ] **T14** `testEncryptedEntryIsRefused` - An encrypted entry fails rather than returning bytes.
- [ ] **T15** `testPartBeyondTheCeilingStopsReading` - A part inflating past the per-part ceiling fails with the expansion error.
- [ ] **T16** `testDocumentBeyondTheTotalCeilingStopsReading` - Several parts crossing the document ceiling fail with the expansion error.
- [ ] **T17** `testTruncatedContainerFailsCleanly` - A cut-off file reports a read error without crashing.

### Unit Tests (`Tests/DetoursWordDocumentTests.swift`)

- [ ] **T18** `testParagraphsAndRunsParse` - Plain paragraphs and their text parse in order.
- [ ] **T19** `testHeadingStylesResolveToLevels` - Styled paragraphs resolve to heading levels.
- [ ] **T20** `testNumberingResolvesToOrderedAndUnorderedLists` - Numbered and bulleted paragraphs group into the right list type.
- [ ] **T21** `testRunEmphasisIsCarried` - Bold, italic and underline survive into the model.
- [ ] **T22** `testTablesParseIntoRowsAndCells` - A table parses with its rows and cells intact.
- [ ] **T23** `testDrawingsBecomePlaceholders` - A drawing yields a placeholder rather than being dropped.
- [ ] **T24** `testUnknownElementsAreIgnored` - Unexpected elements parse without failing the document.

### Unit Tests (`Tests/DetoursExcelWorkbookTests.swift`)

- [ ] **T25** `testSheetNamesAndOrderParse` - Sheets come back named and in workbook order.
- [ ] **T26** `testSharedStringsResolve` - A shared-string cell returns its text.
- [ ] **T27** `testFormulaCellUsesItsCachedValue` - A formula cell returns the stored result.
- [ ] **T28** `testDateFormattedNumberBecomesAReadableDate` - A date-formatted serial number converts to a date.
- [ ] **T29** `testNonDateNumbersStayVerbatim` - Long identifiers and leading zeros survive unchanged.
- [ ] **T30** `testTrailingEmptyRowsAndColumnsAreTrimmed` - A sparse sheet trims to its used range.
- [ ] **T31** `testMissingSharedStringsPartFailsCleanly` - A workbook without the expected part reports failure rather than empty text.

### Unit Tests (`Tests/DetoursPreviewKindTests.swift`)

- [ ] **T32** `testDelimitedExtensionsClassifyAsTable` - `.csv`, `.tsv` and `.tab` classify as the delimited table kind.
- [ ] **T33** `testOfficeExtensionsClassifyAsDocumentAndSpreadsheet` - `.docx` and `.xlsx` classify as their own kinds.
- [ ] **T34** `testBinaryDataWithACSVExtensionIsRejected` - A binary file named `.csv` stays unsupported.

### Integration Tests (`Tests/DetoursPreviewGeneratorTests.swift`)

- [ ] **T35** `testDelimitedPreviewRendersAHeaderAndRowNumbers` - Generated markup contains header cells and per-row file line numbers.
- [ ] **T36** `testDelimitedPreviewEscapesCellContent` - Markup-shaped cell values appear escaped, not live.
- [ ] **T37** `testGridPreviewKeepsValuesVerbatim` - Leading zeros and long digit strings survive into the markup unchanged.
- [ ] **T38** `testNumericColumnsAreAlignedRight` - A digits-only column carries the alignment class and a mixed column does not.
- [ ] **T39** `testLongDelimitedFileChunksItsRows` - A file beyond the eager row limit emits chunks and a body carrying the chunk attributes.
- [ ] **T40** `testWrapSettingChangesTheTableBodyClass` - Wrapped and unwrapped requests differ in the generated body class.
- [ ] **T41** `testGridPreviewCarriesTheStickyStyling` - The generated stylesheet contains the separated-border and sticky rules the grid depends on.
- [ ] **T42** `testWordPreviewRendersStructure` - Generated markup contains headings, list items and a table from a Word fixture.
- [ ] **T43** `testWordPreviewEscapesDocumentText` - Markup-shaped document text appears escaped, not live.
- [ ] **T44** `testWordPreviewRendersLinksAsInertText` - A hyperlink appears as text with no navigable address.
- [ ] **T45** `testOfficePreviewCarriesNoEmbeddedContent` - Generated markup contains no image, object or script element.
- [ ] **T46** `testWorkbookPreviewRendersGridWithHeaders` - Generated markup contains column letters, row numbers and cell values.
- [ ] **T47** `testWorkbookPreviewOffersEachSheet` - A two-sheet fixture emits a label per sheet name.
- [ ] **T48** `testSingleColumnFileFallsBackToTheTextPreview` - A one-column data file generates the source preview markup instead of a table.
- [ ] **T49** `testEncryptedDocumentFallsBackToTheSystemPreview` - An encrypted fixture returns the original source URL.
- [ ] **T50** `testUnsupportedOfficeFormatsFallBackToTheSystemPreview` - PowerPoint and older-format fixtures return the original source URL.
- [ ] **T51** `testOversizedFilesUseThePlainTextFallback` - A file beyond the input guard generates the existing fallback banner.

### Test Fixtures (`Tests/Fixtures/Office/`)

- [ ] **T52** `OfficeFixtureBuilder` - A helper writing Office Open XML parts and packing them into a container, so every Office fixture is built in the test rather than committed as an opaque binary.

---

## Build Log

Populated at implement time.
