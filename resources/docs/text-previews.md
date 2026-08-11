# Detours-Native Text Previews

Detours generates its own Quick Look HTML previews for common developer text files. Unsupported files continue through the system Quick Look path.

## Supported Files

- Markdown: `.md`, `.markdown`, `.mdown`, with Rendered and Source views
- HTML: `.html`, `.htm`, with Rendered and Source views
- Source: Swift, JavaScript, TypeScript, Python, shell, CSS, XML, SQL, diff/patch
- Configuration: JSON, YAML, TOML, INI, plist, `.env` files, `.gitignore`-style files
- Plain text: `.txt`, `.text`, `.log`, and extensionless UTF-8-like text

Files that sniff as binary are left on the system Quick Look path.

## Markdown Safety

Markdown previews render with raw HTML disabled. User-authored links are made inert, user-authored images are replaced with text placeholders, and the generated preview uses a restrictive content security policy. Preview files reference only Detours-owned local support files copied beside the generated HTML; they do not load external network resources.

The normal Markdown path is currently rendered in Swift. The bundled markdown-it 14.2.0 library is a fallback used only when a generated preview has no rendered Markdown content; it is not the primary renderer. Consolidating Markdown onto the library is a separate behavior change because the Swift renderer also owns Detours-specific trusted components.

## HTML Safety

HTML previews are sanitized offline with the bundled DOMPurify 3.4.13 library and then loaded into a scriptless sandboxed frame. Scripts, event handlers, forms, navigation targets, embedded frames, linked resources, and external URLs are removed. Inline CSS and self-contained `data:image` images are preserved. The frame's sandbox and content security policy independently block scripts, navigation, forms, network requests, nested frames, plugins, fonts, and media.

The Source view always shows the original HTML. The Rendered view shows only the sanitized document. The same behavior applies to local and remote files.

## Remote Files

Remote Quick Look opens the same themed Detours preview window used for local files, then downloads the selected file into the local cache. A delayed spinner appears in that window when the transfer is not immediate. Files over 100 MB are rejected before download.

After download, supported text, Markdown, HTML, image, and PDF files remain in the Detours preview window. Unsupported types fall back to the system Quick Look panel.

## Presentation

Long lines wrap by default. Change this globally with **Wrap long lines** in Preferences > General, or for the current preview with View > Wrap Lines in Preview (`Option-W`).

Source and plain-text previews initially render the first 900 lines. As the preview approaches the end of the rendered content, Detours appends the next 1,200-line chunk. This keeps large files responsive without truncating them.

Markdown and HTML previews provide Rendered and Source controls inside the preview. The global wrapping preference applies to source views, not to rendered document layout.

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
