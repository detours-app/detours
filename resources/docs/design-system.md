# Detours design system

## Application

Quiet Pro is the implemented visual direction. [Theme](../../src/Utilities/Theme.swift) defines semantic colour and font roles; [ThemeManager](../../src/Utilities/ThemeManager.swift) resolves appearance and changes. Reuse those roles rather than adding local palette values.

Use native system typography, with tabular digits for numeric columns. Keep file content visually primary, surfaces warm-neutral and chrome compact. Colour indicates selection, focus, Git state or a message. Inactive selections remain visible without dimming file content.

Appearance supports System, Light and Dark. The accent follows macOS, using Detours teal under Multicolor. Font size, row density and alternating row stripes are user preferences. Stripes continue through the pane height when enabled. Folder icons use the accent, with a lighter treatment on selected rows.

The [October design brief](261002-design-brief.md) records the choice and its alternatives. It is historical context, not authority for reverting later implemented changes to folder tint or stripe coverage.

## GitHub presentation

The public surface is a README, not a custom website. Use GitHub-supported Markdown and simple HTML for centred identity, image widths and collapsible reference sections. Do not rely on JavaScript, custom fonts, layout classes or inline CSS in the README.

The local review page uses a dark GitHub-style reading surface: system font, 16 px body text, 1.5 line height, a 980 px maximum outer width and responsive article padding. Its surrounding preview label is not part of the README. Render the draft Markdown into that shell so the preview and proposed public content cannot drift.

Use the deep-sea icon at 112 px and preserve its existing transparency. Keep screenshot content unaltered, with descriptive alt text and proportional scaling. Marco approved deterministic corner masks on 10 October 2026: remove only captured desktop pixels outside the rounded window edge by changing corner alpha, preserving all RGB values and every non-corner pixel. Retain the original captures and inspect masked edges against dark and light backgrounds. Primary captures use dark appearance, compact rows and stripes. Do not pair light and dark scenes in the primary sequence.

At narrow widths, text reflows, images scale within the article, and tables and code blocks scroll within their own bounds. No page-level horizontal overflow. Inspect the rendered output at desktop and narrow widths before review.

The [positioning document](261010-product-positioning.md) owns the message hierarchy, screenshot purposes and publication boundary.
