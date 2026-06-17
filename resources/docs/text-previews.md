# Detours-Native Text Previews

Detours generates its own Quick Look HTML previews for common developer text files. Unsupported files continue through the system Quick Look path.

## Supported Files

- Markdown: `.md`, `.markdown`, `.mdown`
- Source: Swift, JavaScript, TypeScript, Python, shell, CSS, HTML/XML, SQL, diff/patch
- Configuration: JSON, YAML, TOML, INI, plist, `.env` files, `.gitignore`-style files
- Plain text: `.txt`, `.text`, `.log`, and extensionless UTF-8-like text

Files that sniff as binary are left on the system Quick Look path.

## Markdown Safety

Markdown previews render with raw HTML disabled. User-authored links are made inert, user-authored images are replaced with text placeholders, and the generated preview uses a restrictive content security policy. Preview files reference only Detours-owned local support files copied beside the generated HTML; they do not load external network resources.

## Remote Files

Remote Quick Look keeps the existing size behavior:

- Under 1 MB: download silently.
- 1 MB through 100 MB: show download progress.
- Over 100 MB: show the existing too-large error before any download starts.

After a remote file is downloaded into the local cache, Detours runs it through the same native text-preview generator used for local files.

## Cache

Generated previews live in the user caches directory:

```text
~/Library/Caches/Detours/previews/
```

Cache entries are keyed by source metadata, preview kind, active theme, font size, and preview asset manifest version. Directory permissions are user-only. Stale previews are cleaned opportunistically on preview-generator startup.

## Updating Vendored Assets

1. Check current package versions with `npm view markdown-it version` and `npm view highlight.js version`.
2. Replace the files under `resources/PreviewAssets/vendor/`.
3. Update `resources/PreviewAssets/manifest.json` with the pinned versions, source URLs, and license filenames.
4. Run the focused preview tests and `resources/scripts/build.sh --no-install` to confirm the app bundle contains `Contents/Resources/PreviewAssets/`.
