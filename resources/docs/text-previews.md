# Detours-Native Text Previews

Detours generates its own Quick Look HTML previews for common developer text files. Unsupported files continue through the system Quick Look path.

## Supported Files

- Markdown: `.md`, `.markdown`, `.mdown`, with Rendered and Source views
- HTML: `.html`, `.htm`, with Rendered and Source views
- Source: Swift, JavaScript, TypeScript, Python, shell, CSS, XML, SQL, diff/patch
- Configuration: JSON, YAML, TOML, INI, plist, `.env` files, `.gitignore`-style files
- Plain text: `.txt`, `.text`, `.log`, and any file whose bytes read as text
- Security tooling: nmap output and scripts, Nessus reports, captured web sessions, registry exports, VPN profiles, directory dumps, detection rules, wordlists, hash lists, certificates and keys
- Data: `.csv`, `.tsv`, `.tab`, shown as a table
- Documents: `.docx`, shown as themed document text
- Workbooks: `.xlsx`, shown as a grid of the first visible sheet

An unrecognised extension is not a refusal. A file whose bytes read as text gets the plain-text preview whatever its name ends in, so output from a tool Detours has never heard of is readable without waiting for the extension to be added. A recognised extension only decides which colouring the file gets.

Files that sniff as binary are left on the system Quick Look path, as are the formats macOS draws better than any text preview could: PDF, SVG, PostScript, RTF, calendar entries and contact cards are all text underneath, and previewing their markup instead of the page would be a loss. Office files are exempt from the binary check, because a container of compressed parts always sniffs as binary.

Text is read as UTF-8. A file that opens with a UTF-16 byte order mark is read as UTF-16 instead, which is what Windows writes registry exports and much tool output as; without that they would be turned away as binary on the NUL beside every Latin character.

## Data Files

The separator is detected from the file's content, not its name: comma, semicolon and tab are scored over the first 20 rows of a 64 KB sample by how many rows share the same field count, and a modal count of one disqualifies a candidate. The extension's own separator is scored first, so a tie falls to it.

Field parsing follows RFC 4180 with two relaxations: a lone line feed ends a row as readily as a carriage return pair, and a row carrying fewer fields than the widest one is padded rather than shifted. A quotation mark only opens a quoted field at the start of one, a doubled mark inside one is a literal mark, and separators and line breaks inside one are content.

Bytes are read as UTF-8 and then as Windows-1252, which is what Excel on Windows writes for the semicolon exports the detection exists to serve.

The first row becomes the column names. Row numbers count rows, not file lines, so a value carrying a line break inside its quotes stays one numbered row.

A data file that yields one column, or more than 512, keeps its system Quick Look preview: one column means the separator was never found.

## Grids

Data tables and workbook grids share one renderer. Column names stick below the toolbar while scrolling down and row numbers stick at the left while scrolling sideways.

Column widths are measured across every parsed row before any markup is written, capped at 60 characters and never narrower than the column's own name, and written into a `grid.css` generated beside the preview. The table then uses fixed layout, so appending further rows never re-measures the rows already drawn. Widths cannot be written into the page itself: the preview's content security policy admits a stylesheet from the preview folder and no inline styling.

With wrapping off, a value wider than its column is trimmed with an ellipsis; with wrapping on the cell grows tall enough to show it whole. The toolbar names the outcome rather than the setting, so a table reads `Full values` or `One line per row` where a text preview reads `Wrapped` or `Not wrapped`. Columns whose non-empty values are all numbers align right. Every value is drawn exactly as stored, escaped and never passed through the highlighter or a number formatter, so leading zeros and long identifiers survive.

## Office Files

Office files are ZIP containers of XML parts, read one part at a time. Encrypted entries are refused, and expansion is capped at 64 MB per part and 256 MB per document so a container cannot claim a small size and unpack into an enormous one.

Word previews carry headings, paragraphs, bulleted and numbered lists, tables and bold, italic and underlined runs. Heading level is resolved from the style's own name or outline level rather than an English style identifier, so a document written in another language keeps its structure. Pictures, drawings and embedded objects become labelled placeholders and their contents are never read. Hyperlink text is kept and its destination dropped, so a link reads as plain text.

Workbook previews show the first sheet that is not hidden. Cell text resolves from the shared string table, an inline string, a formula's cached result, a boolean shown as `TRUE` or `FALSE`, or an error's own text. A date is a number whose style says to show it as a date: built-in format identifiers 14 to 22 and 45 to 47 count as dates, custom format codes are sniffed for date and time tokens, and the serial is converted against the workbook's own date system with Excel's phantom 29 February 1900 corrected. Everything else is left exactly as stored.

Password-protected files, damaged files, PowerPoint files, strict-format workbooks and the older binary Word and Excel formats keep their system Quick Look preview. So does an Office file that is too large, too slow to read, or that trips an expansion cap, because reading a container as text shows a screenful of compressed bytes.

## Markdown Safety

Markdown previews render with raw HTML disabled. User-authored links are made inert, user-authored images are replaced with text placeholders, and the generated preview uses a restrictive content security policy. Preview files reference only Detours-owned local support files copied beside the generated HTML; they do not load external network resources.

Markdown previews are rendered exclusively by the bundled markdown-it 14.2.0 library. Detours configures it with raw HTML, linkification, navigation, and remote images disabled; fenced code uses the bundled highlight.js library with Detours theme colors. The severity summary bar remains available through a strict markdown-it block plugin that accepts only the documented structure and fixed severity classes, escapes its text, and leaves malformed variants as inert source text.

## HTML Safety

HTML previews are sanitized offline with the bundled DOMPurify 3.4.13 library and then loaded into a scriptless sandboxed frame. Scripts, event handlers, forms, navigation targets, embedded frames, linked resources, and external URLs are removed. Inline CSS and self-contained `data:image` images are preserved. The frame's sandbox and content security policy independently block scripts, navigation, forms, network requests, nested frames, plugins, fonts, and media.

The Source view always shows the original HTML. The Rendered view shows only the sanitized document. The same behavior applies to local and remote files.

## Remote Files

Remote Quick Look opens the same themed Detours preview window used for local files, then downloads the selected file into the local cache. A delayed spinner appears in that window when the transfer is not immediate. Files over 100 MB are rejected before download.

After download, supported text, Markdown, HTML, and image files remain in the Detours preview window. PDFs and unsupported types fall back to the system Quick Look panel.

## Presentation

Long lines wrap by default. Change this globally with **Wrap long lines** in Preferences > General, or for the current preview with View > Wrap Lines in Preview (`Option-W`).

Source and plain-text previews initially render the first 900 lines, and data tables and workbook grids the first 900 rows. As the preview approaches the end of the rendered content, Detours appends the next 1,200-line chunk. This keeps large files responsive without truncating them.

Markdown and HTML previews provide Rendered and Source controls inside the preview. The global wrapping preference applies to source views, not to rendered document layout.

View > Open in System Preview (`Option-P`) closes the Detours preview and hands the file it was showing to the macOS Quick Look panel. It is offered only while a Detours preview is on screen, and it applies to that one file: changing selection previews the next file the usual way.

## Cache

Generated previews live in the user caches directory:

```text
~/Library/Caches/Detours/previews/
```

Cache entries are keyed by document format version, source path, size and modification time, preview kind, local or remote context, active theme, font size, wrapping preference, and preview asset manifest version. Directory permissions are user-only. Stale previews are cleaned opportunistically on preview-generator startup.

## Updating Vendored Assets

1. Check current package versions with `npm view markdown-it version`, `npm view highlight.js version`, and `npm view dompurify version`.
2. Replace the files under `resources/PreviewAssets/vendor/`.
3. Update `resources/PreviewAssets/manifest.json` with the pinned versions, source URLs, and license filenames.
4. On Foundry, run the focused preview tests and `resources/scripts/build.sh --no-install` to confirm the app bundle contains `Contents/Resources/PreviewAssets/`.
