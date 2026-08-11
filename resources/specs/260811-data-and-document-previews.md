# Data and Document Previews

## Meta

- Status: Implemented
- Branch: feature/data-and-document-previews

---

## Business

### Goal

Pressing Space on a data file or an Office document opens it inside the Detours preview window, in the Detours theme, instead of showing a wall of run-together text or handing the file to the separate macOS preview panel.

### Proposal

Detours reads comma, semicolon and tab separated data files, Word documents and Excel workbooks itself, and shows each as a readable table or document in its own preview window.

### Behaviors

- Pressing Space on a `.csv`, `.tsv` or `.tab` file shows the data as a table with columns lined up. The first row is taken as the column names.
- Pressing Space on a `.docx` file shows the document text with its headings, paragraphs, bulleted and numbered lists, tables, and bold, italic and underlined words preserved.
- Pressing Space on an `.xlsx` file shows the first sheet of the workbook as a grid, with the sheet's own column letters across the top and its own row numbers down the side.
- In a data table and in a workbook grid, the column names stay in place while scrolling down and the row numbers stay in place while scrolling sideways. Tables inside a Word document are laid out with the document text and do not stick.
- For data files, the separator is detected from the file itself, so comma, semicolon and tab files all line up correctly. European exports that use semicolons show as columns, not as one run-on line.
- A data file written in the Windows European encoding rather than in UTF-8 shows its accented characters correctly.
- Values appear exactly as written in the file. Long numbers, leading zeros and identifiers are never reformatted or rounded.
- Quoted values containing separators, line breaks or quotation marks appear as a single cell with their quotes removed.
- Rows where a value is missing show empty cells rather than shifting the remaining values into the wrong columns.
- In workbooks, dates appear as dates rather than as a serial number, matching the date Excel itself shows for that file whichever of the two date systems it was created with. A cell holding a calculation shows its last calculated result, a yes-or-no cell shows TRUE or FALSE, a cell holding an error shows that error text, and empty trailing rows and columns are left out.
- Column widths are decided while the file is read and then stay put, so columns never shift as more of a long file appears. A value wider than its column is shown in full when wrapping is on, and trimmed with a trailing ellipsis when wrapping is off.
- Columns holding only numbers are aligned to the right, everything else to the left.
- Pictures, charts, drawings and embedded objects in Office documents are replaced by a labelled placeholder. Nothing from inside the file is loaded or run, and links appear as plain text.
- The wrap setting that already applies to text previews also applies to tables: wrapped shows tall cells with the full value, unwrapped keeps one line per row and scrolls sideways.
- Long files and long sheets fill in further rows as the reader scrolls, so a large export opens as quickly as a small one.
- A data file with only one column, an empty data file, a data file with more than five hundred columns, a password-protected or damaged Office file, a PowerPoint file, a workbook saved in the strict Office format, and the older Word and Excel formats all keep their existing preview behavior.
- A data file too large for a rich preview, or one whose content expands beyond the safe limit, shows the existing plain-language fallback message rather than a blank window or a stall. A Word or Excel file that is too large, too slow to read, or that expands beyond the safe limit is handed to the macOS preview instead, so the reader still sees the document rather than a window of unreadable characters.

### Acceptance Criteria

- [x] **A1** Pressing Space on a comma separated file shows a table with aligned columns, a header row taken from the first line, and row numbers.
- [x] **A2** Scrolling down keeps the column names visible below the toolbar, and scrolling sideways keeps the row numbers visible, in both data tables and workbook grids.
- [x] **A3** A semicolon separated export and a tab separated file both show as correctly split columns.
- [x] **A4** A file containing a quoted value with a comma, a line break and a doubled quotation mark inside it shows that value in one cell, on the row it belongs to.
- [x] **A5** A long identifier with leading zeros appears exactly as written, in both data files and workbooks.
- [x] **A6** Switching the wrap setting changes tables between full-height cells showing the whole value and single-line rows that trim an over-long value with an ellipsis.
- [x] **A7** A file of a hundred thousand rows opens without a visible delay, shows further rows as the reader scrolls to them, and its columns stay in the same place from the first row to the last.
- [x] **A8** Pressing Space on a Word document shows its text in the active theme, with headings, lists and tables recognisable.
- [x] **A9** Bold, italic and underlined words in a Word document appear with that emphasis in the preview.
- [x] **A10** Pressing Space on an Excel workbook shows the first sheet as a grid carrying that sheet's column letters and row numbers.
- [x] **A11** A date cell shows a readable date, a cell containing a calculation shows its last calculated result, and a workbook created on the older Mac date system shows the same dates Excel shows for it.
- [x] **A12** A document containing a picture shows a labelled placeholder, and no picture, script or address from inside the file is loaded.
- [x] **A13** A single-column data file, an empty data file, a data file past the column limit, a password-protected Word file, a PowerPoint file, a strict-format workbook, and an older-format Word file all keep their existing preview behavior.
- [x] **A14** A data file beyond the size limit shows the existing plain-language fallback message, and a Word or Excel file beyond the size limit or beyond the safe expansion limit opens in the macOS preview instead.
- [x] **A15** A semicolon separated export written in the Windows European encoding shows its accented characters correctly and without a decoding notice.

### Out of scope

- Sorting, filtering or searching within a table.
- Editing, saving or exporting anything.
- Charts, totals, recalculated formulas, or any calculation over the values.
- Choosing the separator by hand, or column resizing by dragging.
- Reaching sheets other than the first one from inside the preview.
- PowerPoint presentations, the older binary Word and Excel formats, the strict Office format, and OpenDocument files.
- Showing pictures, charts, shapes or drawings as anything other than a placeholder.
- Reproducing page layout, page breaks, fonts, colours, column widths or cell fills from the original document.
- Cells merged vertically in a Word table shown as merged rather than as separate cells.
- Comments, tracked changes, footnotes, headers and footers.

---

## Technical

### Approach

One shared grid renderer serves the data tables and the workbook grid, and the same container reader serves both Office formats, which is why they belong in a single change. `DetoursPreviewKind` gains `delimitedTable`, `wordDocument` and `spreadsheet` cases; everything else hangs off the existing pipeline, so theme variables, the wrap class, caching, size guards and the chunked row loading apply unchanged, and every failure path returns the original URL so the file keeps its current macOS preview behavior.

Delimited files are parsed in `src/QuickLook/DetoursDelimitedTable.swift` following RFC 4180: doubled quotes inside quoted fields, separators and newlines inside quoted fields, LF and CRLF endings, and a leading byte-order mark strip. Delimiter detection counts unquoted candidates in the first lines and picks the one giving the most consistent field count, preferring the extension's separator on a tie. Ragged rows are padded to the widest row. Bytes that are not valid UTF-8 are re-read as Windows-1252 before the lossy decode is reached, because that is what Excel on Windows writes for the semicolon exports the detection exists to serve.

Office files are ZIP containers of XML parts. `src/QuickLook/DetoursOfficeArchive.swift` reads a named entry without unpacking the whole file: it locates the end-of-central-directory record and walks the central directory the way `src/Operations/ZipArchiveMetadata.swift` already does, then inflates stored and deflated entries with the `Compression` framework, refusing encrypted entries and capping inflated size at 64 MB per part and 256 MB per document. `src/QuickLook/DetoursWordDocument.swift` parses `word/document.xml`, `word/styles.xml` and `word/numbering.xml` with Foundation's `XMLParser` into paragraphs, headings, lists, tables and emphasis, with drawings becoming placeholders. `src/QuickLook/DetoursExcelWorkbook.swift` parses `xl/workbook.xml` for the sheet order, resolves the first sheet's part through `xl/_rels/workbook.xml.rels`, and parses that one worksheet along with `xl/sharedStrings.xml` and `xl/styles.xml`. No AppKit text system is involved, so generation stays off the main actor like the existing generators.

Rendering lives in `src/QuickLook/DetoursPreviewGenerator+Table.swift` for the shared grid and `+Office.swift` for Word. Both return a `GeneratedDocument` through the existing `htmlDocument` chrome, which means `htmlDocument` and `lossyWarning` stop being `private` to `+HTML.swift`. The grid's `<tbody>` carries `id="source-preview"` with the existing `data-chunks` and `data-chunk-scheme` attributes and sets `allowsChunkRequests`, so `preview-lazy.js` appends further row chunks with no JavaScript change; showing one sheet per workbook keeps exactly one grid per document, which is what that single anchor allows. Column widths are measured across every parsed row, capped at 60 characters, and written into a generated `grid.css` beside the existing generated `theme.css`, because the preview's content security policy admits stylesheets from the preview folder but no inline styling. The table then uses `table-layout: fixed`, so appending a chunk never re-measures the rows already shown. Table styling uses `border-collapse: separate`, because WebKit does not stick header cells inside a collapsed-border table.

### Approach Validation

Sticky table headers in WebKit have two documented traps that shape the CSS: a table using the default `border-collapse: collapse` will not stick its header cells in Safari, and an ancestor with `overflow: hidden` silently breaks stickiness. [Adrian Roselli's fixed table headers reference](http://adrianroselli.com/2020/01/fixed-table-headers.html) and [CSS-Tricks on position sticky and table headers](https://css-tricks.com/position-sticky-and-table-headers/) both land on separated borders plus sticky cells, which is what this spec adopts, along with the same reference's sticky-first-column pattern for the row-number gutter. The page's own toolbar is already sticky at the top with a 43 pixel height, so the header row sticks below it rather than at zero and stays under its stacking order.

Automatic column sizing is rejected on evidence already recorded in this repository: the comment above `.source-line` in `resources/PreviewAssets/detours/preview.css` documents that laying lines out as a table forced every line to be measured before the first could be drawn. [MDN's table-layout reference](https://developer.mozilla.org/en/docs/Web/CSS/table-layout) and [a practical write-up on large HTML tables](https://patdavid.net/2019/02/displaying-a-big-html-table/) both describe the same failure and the same fix: fix the table width and the column widths so appended rows cannot change what came before. That is why widths are measured at generation time and emitted as a generated stylesheet.

Complaints about existing data viewers pointed at three things. Headers scrolling out of view is the most reported pain. Garbled output is most often a separator that is not a comma, since European exports use semicolons where the comma is the decimal point, which is why detection is part of the first version rather than an option. Those same exports are written in the Windows European encoding rather than UTF-8, so a plain UTF-8 read turns every accented character into a replacement mark, which is why the decode falls back to Windows-1252 for data files. Spreadsheet tools quietly turning order numbers into scientific notation and stripping leading zeros is why values are emitted verbatim and only alignment varies. Bounded rendering with progressive fill matches what large-file viewers such as [csvkit's viewer](https://csvkit.org/csv-viewer) do, and the existing chunk mechanism already provides it. Field parsing follows [RFC 4180](https://www.rfc-editor.org/rfc/rfc4180) with the common relaxations of LF endings and ragged rows.

For Word, the tempting shortcut is AppKit's own reader, `NSAttributedString` with the `officeOpenXML` document type. It is rejected here because its importers are backed by AppKit and WebKit text machinery with main-thread expectations, conflicting with a generator that runs off the main actor; its Office support covers only a subset of attributes; and it produces styled HTML carrying its own fonts and colours, which fights the theme the preview exists to apply. Packages such as [DocX](https://github.com/shinjukunian/DocX) exist precisely because the system path is partial, and this project carries no third-party dependencies today. Reading the container directly extends proven code: `ZipArchiveMetadata` already parses the central directory including the ZIP64 case, and Apple's `Compression` framework covers the only two methods Office writes.

Workbook reading has a set of well-documented traps that the tasks below name individually rather than leaving to discovery. Text arrives by three different routes, not one: a shared-string index, an inline string, or a formula's cached string, and a shared-string entry may itself be split into rich-text runs whose parts must be joined or every later index shifts. Dates are ordinary numbers whose style says to show them as dates, so date-ness is decided from the built-in format identifiers and from sniffing custom format codes. Workbooks written on the old Mac epoch count from a different day, and the 1900 system carries Excel's phantom 29 February. Cells are sparse and carry their own address, so position comes from the address rather than from counting siblings. The [minimum viable XLSX reader](https://www.brendanlong.com/the-minimum-viable-xlsx-reader.html) and [Xlsxir's number style notes](https://hexdocs.pm/xlsxir/number_styles.html) cover the same ground, and the practical rule from both is that the real specification is whatever Excel accepts, so a missing style or an out-of-range index degrades to the stored value rather than failing the document.

The failure modes worth designing against are size-related rather than format-related. A container can declare a small compressed size and expand enormously, so the reader caps both a single part and the document total instead of trusting the header. Fully reproducing Excel's number formats is open-ended, so this spec commits to the narrow, high-value case, resolving date formats and otherwise showing the stored value, and says so in the behaviors rather than implying Excel-identical formatting.

### Risks

| Risk | Mitigation |
| ---- | ---------- |
| A file with separators inside quoted values splits into the wrong columns. | Parse quoted fields per RFC 4180 with a state machine rather than splitting on the separator, and cover quoted separators, quoted newlines and doubled quotes in tests. |
| Delimiter detection picks the wrong separator and produces one useless column. | Score candidates by field-count consistency across the first lines, prefer the extension's separator on a tie, and fall back to the existing preview behavior when the winner yields a single column. |
| Sticky header or row-number gutter silently fails to stick in the preview window. | Use separated borders and sticky cells rather than a sticky `thead`, offset the header below the existing sticky toolbar, keep the table free of an `overflow: hidden` ancestor, and assert the generated markup and CSS hooks in tests. |
| A long file slows down as further rows arrive, because each chunk re-measures the table. | Measure column widths once at generation time, emit them in a generated stylesheet, and use `table-layout: fixed` so appended rows cannot change the columns above them. |
| A crafted document expands into an enormous amount of memory while being read. | Cap the inflated size of each part at 64 MB and of the document at 256 MB, stop reading at the cap, and return the original URL. |
| Content from inside a document loads or runs something. | Emit no image, object or script from the container, replace drawings with placeholders, render hyperlinks as inert text, and keep the existing restrictive content security policy. |
| Malformed or unexpected XML crashes or hangs the preview. | Parse with a delegate that ignores unknown elements rather than asserting on structure, treat a parse failure as unsupported, and cover truncated and hostile fixtures in tests. |
| Values are altered on the way to the screen, as spreadsheet tools do. | Emit every cell through HTML escaping only, never through the syntax highlighter or a number formatter, and assert leading zeros and long digit strings survive verbatim. |
| A workbook's dates land four years out, or a rich-text entry shifts every later string. | Read the workbook date system as an XML boolean, correct the 1900 phantom leap day, join every text part inside a shared-string entry, and cover both with fixtures. |
| Word documents lose structure and read as one undifferentiated block. | Resolve heading levels through the style's own name and outline level rather than an English style identifier, map list numbering explicitly, and assert each structure against fixtures rather than testing only that text appears. |
| A password-protected or damaged file previews as an empty document. | Detect encrypted entries and parse failures before any HTML is generated and return the original URL. |
| An oversized Office file shows a screenful of compressed bytes through the existing text fallback. | Route the size, expansion and timeout paths for the Office kinds to the original URL instead of the plain-text fallback, and keep the fallback banner for data files, which are text. |
| The new kinds regress existing text previews sharing the same pipeline. | Add the new kinds alongside the existing ones without touching their branches, and keep the current preview test classes green. |

### Implementation Plan

**Phase 1: Delimited data**

- [x] **C1** Add `case delimitedTable(delimiter: Character)` to `DetoursPreviewKind` in `src/QuickLook/DetoursPreviewKind.swift`, classifying the `csv`, `tsv` and `tab` extensions, with a distinct cache component and `plaintext` as its highlight language.
- [x] **C2** Create `src/QuickLook/DetoursDelimitedTable.swift` with a parser turning decoded text plus a delimiter into rows of fields, handling quoted fields, doubled quotes, embedded separators and newlines, LF and CRLF endings, and a leading byte-order mark.
- [x] **C3** Add delimiter detection to `DetoursDelimitedTable` scoring comma, semicolon and tab over the first lines by field-count consistency, preferring the extension's separator on a tie.
- [x] **C4** Add row normalisation to `DetoursDelimitedTable` padding short rows to the widest row, reporting the column count, and exposing the first row as the header row with the remaining rows numbered from one.
- [x] **C24** Add a Windows-1252 decode to `DetoursDelimitedTable` used when the file's bytes are not valid UTF-8, so the delimited path never reaches the generator's lossy decode.

**Phase 2: Office containers**

- [x] **C5** Create `src/QuickLook/DetoursOfficeArchive.swift` locating the end-of-central-directory record and walking the central directory including the ZIP64 case, following the pattern in `src/Operations/ZipArchiveMetadata.swift`, returning the bytes of a named entry.
- [x] **C6** Add inflation to `DetoursOfficeArchive` for stored and deflated entries using the `Compression` framework, rejecting any other compression method.
- [x] **C7** Add expansion guards to `DetoursOfficeArchive`: a 64 MB per-part ceiling, a 256 MB per-document total ceiling, and refusal of encrypted entries, each surfacing a distinct error rather than a partial result.
- [x] **C8** Create `src/QuickLook/DetoursWordDocument.swift` parsing `word/document.xml` with `XMLParser` into an ordered model of paragraphs, runs, lists and tables, honouring `xml:space="preserve"`, turning `w:tab` and `w:br` into a tab and a line break, and honouring `w:gridSpan` as a horizontal cell span.
- [x] **C9** Extend `DetoursWordDocument` to read `word/styles.xml` and `word/numbering.xml` so a paragraph style resolves to a heading level through the style's own `w:name` or `w:outlineLvl` rather than an English style identifier, and a numbering reference resolves through `w:num` and `w:abstractNum` to an ordered or unordered list nested by its level.
- [x] **C10** Extend `DetoursWordDocument` to carry bold, italic and underline from run properties, treating an underline value of `none` as absent, and to emit labelled placeholders for drawings, pictures and embedded objects.
- [x] **C11** Create `src/QuickLook/DetoursExcelWorkbook.swift` parsing `xl/workbook.xml` for the sheet order, taking the first sheet that is not hidden and the first sheet outright when every sheet is hidden, resolving its part path through `xl/_rels/workbook.xml.rels`, rejecting the strict Office namespace as unsupported, and parsing that one worksheet into rows of cells placed by the address in each cell's `r` attribute so sparse rows keep their columns.
- [x] **C12** Extend `DetoursExcelWorkbook` to resolve every cell text route: a shared-string index into `xl/sharedStrings.xml` read positionally with every text part of an entry joined and phonetic parts skipped, an inline string, a formula's cached string or number, a boolean shown as TRUE or FALSE, and an error shown as its text; a part is required only when a cell actually references it, and trailing empty rows and columns are trimmed.
- [x] **C13** Extend `DetoursExcelWorkbook` to decide date cells from `xl/styles.xml`, treating built-in format identifiers 14 to 22 and 45 to 47 as dates and sniffing custom format codes for date and time tokens outside quoted, escaped and bracketed sections, then converting the serial against the workbook's date system read from `workbookPr` as an XML boolean, correcting the 1900 phantom leap day, and rendering as `yyyy-MM-dd` or `yyyy-MM-dd HH:mm:ss` when a time part is present; every other value stays as stored, and a missing or out-of-range style falls back to the stored value.
- [x] **C14** Add `case wordDocument` and `case spreadsheet` to `DetoursPreviewKind` classified from the `docx` and `xlsx` extensions with their own cache components and `plaintext` highlight language, exempt from the binary-sniffing rejection in `classify` so their container bytes do not disqualify them.

**Phase 3: Rendering**

- [x] **C26** Widen `htmlDocument` and `lossyWarning` in `src/QuickLook/DetoursPreviewGenerator+HTML.swift` from `private` to internal, and add a `PreviewChrome` option that links an extra generated stylesheet from the preview's support folder.
- [x] **C25** Add column measurement to the shared grid model: the width of each column is the widest value it holds, capped at 60 characters and never narrower than its own header, measured across every parsed row before any markup is written, and refuse a grid of more than 512 columns rather than emitting a rule per column.
- [x] **C15** Create `src/QuickLook/DetoursPreviewGenerator+Table.swift` with a shared grid renderer returning a `GeneratedDocument`, taking a list of header cells and a gutter label per row so it serves both the delimited table and the workbook grid, reusing `htmlDocument`, `PreviewChrome`, the wrap body class and `lossyWarning`, and escaping every cell through `escapeHTML`.
- [x] **C27** Write the measured widths as a generated `grid.css` into the preview's support folder beside `theme.css`, carrying one width rule per column and the table's own total width, and link it through the chrome option added in C26.
- [x] **C16** Emit the grid body as `<tbody id="source-preview">` carrying the existing `data-chunks` and `data-chunk-scheme` attributes, setting `allowsChunkRequests` and including the `preview-lazy.js` tail, splitting rows beyond `eagerLineLimit` into `chunkLineCount`-sized chunks of row markup so `preview-lazy.js` appends them unchanged.
- [x] **C17** Add right-alignment for columns whose non-empty values are all numeric, decided per column at generation time and applied as a class, from the parsed text for delimited files and from the cell type for workbooks, without reformatting any value.
- [x] **C18** Create `src/QuickLook/DetoursPreviewGenerator+Office.swift` with a `wordHTML` function rendering the Word model through the existing chrome, escaping all text, rendering hyperlinks with the existing `inert-link` class and placeholders with the existing `blocked-image` class, and honouring the wrap body class.
- [x] **C19** Add a `workbookHTML` function to `DetoursPreviewGenerator+Office.swift` rendering the first sheet through the shared grid renderer, with the sheet's column letters as the header cells and its real row numbers as the gutter labels.
- [x] **C20** Add table, grid and document styling to `resources/PreviewAssets/detours/preview.css` using `border-collapse: separate` and `table-layout: fixed`, header cells sticking below the existing 43 pixel toolbar and under its stacking order, a sticky row-number gutter, both carrying the theme surface background so scrolled content cannot show through, plus headings, lists, placeholders, and wrapped versus trimmed single-line cell behaviour driven by the existing `wrap-lines` body class, using existing theme variables only.

**Phase 4: Wiring**

- [x] **C21** Route the new kinds in `generatePreview` in `src/QuickLook/DetoursPreviewGenerator.swift`, reading the file's bytes for the Office kinds without putting them through the text decode so no lossy notice can appear over a document, and keeping the existing input-size and output-size guards.
- [x] **C22** Return the original source URL from `generatePreview` when a delimited file yields one column or fewer or more than 512 columns, when an Office container is encrypted, is in the strict format, or is missing a part a cell needs, when parsing fails, and when an expansion guard trips; extend the same handling to the input-size and output-size guards for the Office kinds, and to the timeout race in `previewURL`, so an Office file never reaches the plain-text fallback while an oversized delimited file still shows its banner.
- [x] **C28** Raise `currentDocumentFormatVersion` in `src/QuickLook/DetoursPreviewGenerator.swift` and `assetManifestVersion` in `resources/PreviewAssets/manifest.json`, so previews already cached are rebuilt against the changed document shape and stylesheet.
- [x] **C23** Update `resources/docs/text-previews.md` with the supported data and document types, the separator, encoding and row-number conventions, the fixed column width and trimming behaviour, the placeholder and inert-link behavior, the date and formula value conventions, the first-sheet rule, and what keeps its existing preview behavior.

---

## Testing

### Unit Tests (`Tests/DetoursDelimitedTableTests.swift`)

- [x] **T1** `testPlainRowsSplitOnTheDelimiter` - Unquoted rows split into fields.
- [x] **T2** `testQuotedFieldKeepsItsDelimiter` - A separator inside a quoted field stays in one cell.
- [x] **T3** `testQuotedFieldKeepsItsNewline` - A line break inside a quoted field stays on one row.
- [x] **T4** `testDoubledQuotesBecomeOneQuote` - Escaped quotes decode to a single quotation mark.
- [x] **T5** `testCarriageReturnLineEndingsParse` - CRLF files produce the same rows as LF files.
- [x] **T6** `testByteOrderMarkIsStrippedFromTheFirstHeader` - The first column name has no leading mark.
- [x] **T7** `testRaggedRowsArePaddedNotShifted` - A short row yields trailing empty cells with earlier values in place.
- [x] **T8** `testSemicolonExportIsDetected` - A semicolon file scores semicolon over comma.
- [x] **T9** `testTabFileIsDetected` - A tab separated file scores tab over comma.
- [x] **T10** `testAmbiguousFilePrefersTheExtensionDelimiter` - A tie resolves to the separator implied by the extension.
- [x] **T53** `testWindowsEuropeanBytesDecodeWithoutLoss` - Latin-1 accented bytes decode to their characters with no replacement marks.
- [x] **T54** `testColumnWidthsAreMeasuredAndCapped` - Widths match the widest value per column, never below the header width and never above sixty.

### Unit Tests (`Tests/DetoursOfficeArchiveTests.swift`)

- [x] **T11** `testStoredEntryIsReadVerbatim` - An uncompressed entry returns its exact bytes.
- [x] **T12** `testDeflatedEntryInflates` - A compressed entry returns the original content.
- [x] **T13** `testMissingEntryReportsNotFound` - Asking for an absent part fails with a distinct error.
- [x] **T14** `testEncryptedEntryIsRefused` - An encrypted entry fails rather than returning bytes.
- [x] **T15** `testPartBeyondTheCeilingStopsReading` - A part inflating past the per-part ceiling fails with the expansion error.
- [x] **T16** `testDocumentBeyondTheTotalCeilingStopsReading` - Several parts crossing the document ceiling fail with the expansion error.
- [x] **T17** `testTruncatedContainerFailsCleanly` - A cut-off file reports a read error without crashing.

### Unit Tests (`Tests/DetoursWordDocumentTests.swift`)

- [x] **T18** `testParagraphsAndRunsParse` - Plain paragraphs and their text parse in order, with preserved spacing, tabs and line breaks intact.
- [x] **T19** `testHeadingStylesResolveToLevels` - A style whose identifier is not English resolves to its heading level through its name and outline level.
- [x] **T20** `testNumberingResolvesToOrderedAndUnorderedLists` - Numbered and bulleted paragraphs group into the right list type at the right nesting level.
- [x] **T21** `testRunEmphasisIsCarried` - Bold, italic and underline survive into the model, and an underline value of none does not.
- [x] **T22** `testTablesParseIntoRowsAndCells` - A table parses with its rows and cells intact, and a horizontally spanned cell keeps its span.
- [x] **T23** `testDrawingsBecomePlaceholders` - A drawing yields a placeholder rather than being dropped.
- [x] **T24** `testUnknownElementsAreIgnored` - Unexpected elements parse without failing the document.

### Unit Tests (`Tests/DetoursExcelWorkbookTests.swift`)

- [x] **T25** `testSheetOrderAndFirstSheetPartResolve` - Sheets come back in workbook order and the first sheet's part path resolves through the relationships part.
- [x] **T26** `testSharedStringsResolve` - A shared-string cell returns its text.
- [x] **T55** `testRichTextSharedStringJoinsItsParts` - An entry split into runs returns its joined text and leaves later indices correct.
- [x] **T56** `testInlineStringCellResolves` - A cell carrying its string inline returns that text.
- [x] **T27** `testFormulaCellUsesItsCachedValue` - A formula cell returns the stored result.
- [x] **T57** `testBooleanAndErrorCellsRender` - A boolean cell returns TRUE or FALSE and an error cell returns its error text.
- [x] **T28** `testDateFormattedNumberBecomesAReadableDate` - A date-formatted serial number converts to a date, from a built-in identifier and from a custom format code.
- [x] **T58** `testMacDateSystemShiftsSerials` - The same serial in a 1904-system workbook yields the date Excel shows, and an early 1900-system serial clears the phantom leap day.
- [x] **T29** `testNonDateNumbersStayVerbatim` - Long identifiers and leading zeros survive unchanged.
- [x] **T59** `testSparseRowPlacesCellsByAddress` - A row skipping columns places its values under the right column letters.
- [x] **T30** `testTrailingEmptyRowsAndColumnsAreTrimmed` - A sparse sheet trims to its used range.
- [x] **T31** `testNeededPartMissingFailsCleanlyAndUnusedPartMissingDoesNot` - A workbook referencing shared strings without the part reports failure, while one that never references it parses.
- [x] **T60** `testStrictFormatWorkbookIsUnsupported` - A strict-namespace workbook reports unsupported rather than parsing as empty.
- [x] **T65** `testHiddenFirstSheetIsSkipped` - A workbook whose first sheet is hidden parses the first visible one instead.

### Unit Tests (`Tests/DetoursPreviewKindTests.swift`)

- [x] **T32** `testDelimitedExtensionsClassifyAsTable` - `.csv`, `.tsv` and `.tab` classify as the delimited table kind.
- [x] **T33** `testOfficeExtensionsClassifyAsDocumentAndSpreadsheet` - `.docx` and `.xlsx` classify as their own kinds despite their container bytes.
- [x] **T34** `testBinaryDataWithACSVExtensionIsRejected` - A binary file named `.csv` stays unsupported.

### Integration Tests (`Tests/DetoursPreviewGeneratorTests.swift`)

- [x] **T35** `testDelimitedPreviewRendersAHeaderAndRowNumbers` - Generated markup contains header cells from the first line and rows numbered from one.
- [x] **T36** `testDelimitedPreviewEscapesCellContent` - Markup-shaped cell values appear escaped, not live.
- [x] **T37** `testGridPreviewKeepsValuesVerbatim` - Leading zeros and long digit strings survive into the markup unchanged.
- [x] **T38** `testNumericColumnsAreAlignedRight` - A digits-only column carries the alignment class and a mixed column does not.
- [x] **T39** `testLongDelimitedFileChunksItsRows` - A file beyond the eager row limit emits chunks and a body carrying the chunk attributes.
- [x] **T61** `testGeneratedGridStylesheetCarriesColumnWidths` - The preview folder holds a generated grid stylesheet whose rules cover every column and the table width, and the document links it.
- [x] **T40** `testWrapSettingChangesTheTableBodyClass` - Wrapped and unwrapped requests differ in the generated body class.
- [x] **T41** `testGridPreviewCarriesTheStickyStyling` - The generated stylesheet contains the separated-border, fixed-layout and sticky rules the grid depends on, with the header offset below the toolbar.
- [x] **T42** `testWordPreviewRendersStructure` - Generated markup contains headings, list items and a table from a Word fixture.
- [x] **T43** `testWordPreviewEscapesDocumentText` - Markup-shaped document text appears escaped, not live.
- [x] **T44** `testWordPreviewRendersLinksAsInertText` - A hyperlink appears as text with no navigable address.
- [x] **T45** `testOfficePreviewCarriesNoEmbeddedContent` - Generated markup contains no image, object or script element.
- [x] **T62** `testOfficePreviewCarriesNoLossyDecodeNotice` - A Word preview's markup contains no lossy decoding warning.
- [x] **T46** `testWorkbookPreviewRendersGridWithHeaders` - Generated markup contains column letters, the sheet's own row numbers and cell values.
- [x] **T47** `testWorkbookPreviewShowsTheFirstSheetOnly` - A two-sheet fixture renders the first sheet's values and none from the second.
- [x] **T63** `testLongWorkbookSheetChunksItsRows` - A sheet beyond the eager row limit emits chunks and a body carrying the chunk attributes.
- [x] **T48** `testSingleColumnFileFallsBackToTheSystemPreview` - A one-column data file returns the original source URL.
- [x] **T66** `testFileBeyondTheColumnLimitFallsBackToTheSystemPreview` - A data file with more than 512 columns returns the original source URL.
- [x] **T49** `testEncryptedDocumentFallsBackToTheSystemPreview` - An encrypted fixture returns the original source URL.
- [x] **T50** `testUnsupportedOfficeFormatsFallBackToTheSystemPreview` - PowerPoint, strict-format and older-format fixtures return the original source URL.
- [x] **T51** `testOversizedDelimitedFileUsesThePlainTextFallback` - A data file beyond the input guard generates the existing fallback banner.
- [x] **T64** `testOversizedOfficeFileFallsBackToTheSystemPreview` - An Office file beyond the input guard returns the original source URL rather than a banner.

### Test Fixtures (`Tests/Fixtures/Office/`)

- [x] **T52** `OfficeFixtureBuilder` - A helper writing Office Open XML parts and packing them into a container, so every Office fixture is built in the test rather than committed as an opaque binary.

---

## Build Log

- **C1** `DetoursPreviewKind` gained `delimitedTable(delimiter:)`, classified from `csv`, `tsv` and `tab`, with a cache component keyed by the separator's scalar and `plaintext` as its highlight language.
- **C2** `src/QuickLook/DetoursDelimitedTable.swift` parses rows with a state machine: a quotation mark only opens a field at its start, a doubled mark inside one is a literal mark, and separators and line breaks inside one are content. CRLF, LF and a trailing line break at end of file all resolve to the same rows.
- **C3** Separator detection scores comma, semicolon and tab over the first 20 rows of a 64 KB sample by how many rows share the modal field count. A modal count of one disqualifies a candidate, and the extension's separator is scored first so a tie falls to it.
- **C4** Rows are padded to the widest row, the first row becomes the header, and the rest become the numbered data rows.
- **C24** The file's bytes are read as UTF-8, then as Windows-1252, so a Windows-made European export shows its accented characters without reaching the generator's lossy decode.
- **C5** `src/QuickLook/DetoursOfficeArchive.swift` finds the end-of-directory record, walks the central directory including the ZIP64 extra field, and locates one named part's bytes through its own local header.
- **C6** Stored parts are copied and deflated parts inflated through the `Compression` framework; any other method is refused by name.
- **C7** A part is refused before a byte is read if it declares more than 64 MB, the running total is refused past 256 MB, and an encrypted entry fails rather than returning bytes.
- **C8** `src/QuickLook/DetoursWordDocument.swift` reads paragraphs, runs, tables and cells, keeps preserved spacing, turns tabs and line breaks into their characters, and honours a horizontal cell span.
- **C9** Heading level comes from the style's own name or its outline level, never from the English style identifier, and numbering resolves through the numbering definition to an ordered or unordered list nested by level.
- **C10** Bold, italic and underline are carried from run properties, an underline of `none` counts as absent, and drawings, pictures and embedded objects become labelled placeholders with their contents skipped entirely.
- **C11** `src/QuickLook/DetoursExcelWorkbook.swift` reads the sheet order, takes the first sheet that is not hidden, resolves its part through the workbook relationships, refuses the strict Office namespace, and places every cell by the address it carries.
- **C12** Cell text resolves from a shared string index, an inline string, a formula's cached result, a boolean or an error; shared entries join their runs and skip phonetic parts; an empty entry keeps its index; the string table is only required when a cell points into it.
- **C13** Date cells are decided from the built-in format identifiers and from sniffing custom format codes, then converted against the workbook's own date system with the 1900 phantom leap day corrected.
- **C14** `docx` and `xlsx` classify as their own kinds and skip the binary sniff, which their container bytes would otherwise fail.
- **C26** `htmlDocument` and `lossyWarning` are internal, and `PreviewChrome` gained an option that links one stylesheet generated for a single preview.
- **C25** `DetoursPreviewGrid` measures each column across every parsed row, capped at 60 characters, never below its own header, and refuses a grid wider than 512 columns.
- **C15** `src/QuickLook/DetoursPreviewGenerator+Table.swift` draws the shared grid, taking header cells and a gutter label per row so it serves both the data table and the workbook grid, escaping every value.
- **C27** The measured widths are written as `grid.css` into the preview's support folder beside `theme.css` and linked through the chrome option; the security policy forbids styling written into the page itself.
- **C16** The grid body carries the chunk attributes and the lazy-loading script, so rows past the eager limit arrive in chunks with no JavaScript change.
- **C17** A column whose non-empty values are all numbers carries the alignment class, decided from the parsed text for data files and from the cell type for workbooks.
- **C18** `src/QuickLook/DetoursPreviewGenerator+Office.swift` draws Word documents through the existing chrome, reusing the `blocked-image` class for placeholders and emitting no anchor at all, so a link is text that goes nowhere.
- **C19** The workbook renderer feeds the first sheet through the shared grid with column letters as headers and the sheet's own row numbers in the gutter.
- **C20** `preview.css` gained the grid and document rules: separated borders and fixed layout, a header sticking below the 43 pixel toolbar and a sticky gutter, both on the theme's surface colour, and trimmed versus wrapped cells driven by the existing wrap class.
- **C21** `generatePreview` routes the three new kinds and keeps Office containers out of the text decode, so no lossy notice can appear over a document.
- **C22** Every failure returns the original URL: one column or more than 512, an encrypted, strict, damaged or incomplete container, a tripped expansion cap, and for Office kinds the input-size, output-size and timeout guards too. Oversized data files keep the fallback banner.
- **C28** The document format version and the asset manifest version were raised so previews already cached are rebuilt.
- **C23** `resources/docs/text-previews.md` documents the supported types, the separator, encoding and row-numbering conventions, the measured column widths and trimming, the placeholder and inert-link behavior, the date and formula conventions, the first-sheet rule, and everything that keeps its system preview.
- **T1-T10, T53, T54** `Tests/DetoursDelimitedTableTests.swift`, 12 cases. `swift test --filter DetoursDelimitedTableTests` on Foundry. Quoted separators, quoted line breaks, doubled quotes, CRLF, byte-order marks, ragged rows, separator detection and its tie-break, Windows-1252 decoding, and the measured column widths.
- **T11-T17** `Tests/DetoursOfficeArchiveTests.swift`, 7 cases. Stored and deflated parts, a missing part, an encrypted part, both expansion ceilings, and a truncated container.
- **T18-T24** `Tests/DetoursWordDocumentTests.swift`, 7 cases. Paragraphs with preserved spacing, tabs and breaks, a heading resolved through a non-English style, nested ordered and unordered lists, emphasis including an underline of `none`, a table with a spanned cell, drawings as placeholders, and unknown elements ignored.
- **T25-T31, T55-T60, T65** `Tests/DetoursExcelWorkbookTests.swift`, 14 cases. Sheet order and part resolution, a hidden first sheet, shared and rich-text strings, inline strings, cached formula values, booleans and errors, both date systems and the phantom leap day, verbatim identifiers, sparse rows, trimming, a required part missing, and the strict format.
- **T32-T34** `Tests/DetoursPreviewKindTests.swift`. Data extensions classify with their separator, Office extensions survive the binary sniff their container bytes would fail, and a binary file named `.csv` stays unsupported.
- **T35-T51, T61-T64, T66** `Tests/DetoursPreviewGeneratorTests.swift`, 50 cases. Header and row numbers, escaping, verbatim values, alignment, chunking for both data files and long sheets, the generated width stylesheet, the wrap class, the sticky rules, Word structure, inert links, no embedded content, no lossy notice, the workbook grid, first-sheet-only, and every fallback to the system preview.
- **T52** `Tests/Fixtures/Office/OfficeFixtureBuilder.swift` writes Office parts and packs them into a container, so no fixture is a committed binary.
- **A1-A15** Confirmed by the suites above. `swift test --filter "DetoursPreview|PreviewWindow|PreviewLazyLoading|FileListResponderTests|BuildCacheTests|DetoursDelimitedTable|DetoursOfficeArchive|DetoursWordDocument|DetoursExcelWorkbook"` on Foundry executed 189 tests with 0 failures.
- **Simplification pass** Long files and grids now share one chunking routine; column widths moved onto the table's column group so the header and rows resolve `ch` in the same font; cell padding is stated in that same unit; measuring and numeric detection fused into one pass; padding, byte-order-mark stripping and separator detection stopped doing work they discard; and `readsAsText` and `hasPlainTextFallback` moved onto the preview kind so the router carries no list of kinds. Full Foundry suite green afterwards: 1026 XCTest cases plus 47 Swift Testing cases with 0 failures, and 19 login-session cases.
