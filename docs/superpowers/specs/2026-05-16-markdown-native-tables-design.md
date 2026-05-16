# Markdown Native Tables Design

## Context

Alas already has a Markdown preview path built on `swift-markdown` and an AppKit `NSTextView`.
Markdown files are parsed in `MarkdownTabView`, rendered by `MarkdownRenderer` into a single
`MarkdownRenderResult.attributedString`, and installed by `MarkdownPreviewController`.

GFM tables are already parsed as `Markdown.Table` nodes. The current renderer handles them by
emitting aligned monospace pipe-table text. This is functional, but it does not look like a native
Markdown preview table and makes table-heavy documents harder to scan.

## Goal

Render GFM tables in the Markdown preview pane as native-looking bordered tables while preserving
inline Markdown inside cells.

The chosen visual direction is a bordered table with:

- a tinted header row,
- subtle alternating body row backgrounds,
- thin cell borders,
- comfortable cell padding,
- theme-derived colors,
- GFM left, center, and right column alignment.

## Non-Goals

- Replacing the Markdown preview with a SwiftUI block renderer.
- Adding nested horizontal scroll views for wide tables in this pass.
- Making image-heavy table cells a first-class scenario.
- Supporting arbitrary block Markdown layout inside table cells beyond reasonable inline flattening.
- Changing Markdown parsing, tab state, settings, or preview mode behavior.

## Architecture

Keep the preview as a single `NSTextView` driven by `MarkdownRenderResult.attributedString`.
The implementation should stay primarily in `MarkdownRenderer.visitTable`.

`visitTable` will stop emitting pipe-delimited monospace text. Instead it will emit table cell
paragraphs styled with TextKit table APIs:

- `NSTextTable` to represent the table,
- `NSTextTableBlock` values attached to paragraph styles for each cell,
- paragraph alignment derived from `Markdown.Table.columnAlignments`,
- paragraph background/border styling for header and body cells.

This approach keeps the existing preview controller, selection behavior, scroll behavior, theme
updates, and link handling intact.

## Cell Rendering

Each table cell must preserve these inline Markdown forms:

- strong and emphasis font traits,
- strikethrough,
- inline code font/background,
- links through the existing `.link` attribute,
- plain text and soft/line breaks.

The renderer should use a scoped helper to render a cell into a temporary attributed string rather
than using `cell.plainText`. This avoids losing inline attributes and keeps table rendering consistent
with the rest of the document.

The helper must avoid paragraph-level blank lines inside cells. If unexpected block content appears
inside a table cell, flatten it into inline text rather than attempting nested block layout.

## Styling

Table styling must use existing `Theme` colors instead of hard-coded colors. Use this mapping unless
an existing theme key is missing, in which case use the closest existing theme color:

- border: faint or muted foreground/background separator color,
- header background: secondary preview background,
- banded rows: two subtle background variants close to the preview background,
- text: normal foreground,
- header text: semibold foreground.

Cell padding must be applied through TextKit table block margins or paragraph attributes. Borders
should remain thin and unobtrusive so tables fit the existing app chrome.

## Alignment

Use `Markdown.Table.columnAlignments` for each column:

- `.left` and `nil` map to left alignment,
- `.center` maps to center alignment,
- `.right` maps to right alignment.

Header and body cells in the same column should use the same paragraph alignment.

## Wide Tables

The first implementation should rely on TextKit wrapping within cells and the existing preview
scroll view. It should not introduce a nested horizontal scroller. If TextKit table layout proves
unreadable for very wide tables, that should be handled as a follow-up design.

## Tests

Update `MarkdownRendererTests` around table rendering. Tests should verify:

- table text is still present,
- old pipe-table separator output is no longer emitted for rendered tables,
- table cells carry paragraph styles with table blocks,
- header/body cell styling is present enough to prove native table rendering is active,
- inline links and bold/inline-code attributes survive inside cells,
- GFM center and right alignment map to paragraph alignment.

Existing parser tests for GFM table recognition should remain unchanged.

## Risks

`NSTextTable` behavior can be under-documented and may have layout quirks in `NSTextView`. If it
cannot satisfy bordered, padded, selectable cells with link attributes intact, the fallback should be
to keep the current preview architecture and either simplify the TextKit styling or write a follow-up
design for a richer block renderer. Do not switch to image attachments for tables, because that would
break the inline Markdown and link requirements.

## Implementation Boundary

Expected files:

- `Alas/Sources/Code/Markdown/MarkdownRenderer.swift`
- `AlasTests/MarkdownRendererTests.swift`

No `project.yml` change is expected. If implementation discovers a source-file addition is needed,
regenerate the Xcode project with `xcodegen` as required by project rules.
