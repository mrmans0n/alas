# Diff Text Selection Design

## Context

The central diff pane renders parsed git hunks through `HunkView`, shared by
working-tree diffs and commit diffs. Each diff row is currently built from
separate SwiftUI `Text` values inside row `HStack`s, with
`.textSelection(.enabled)` applied to the hunk container.

That structure allows selecting text within a row, but does not provide a
single continuous native text surface for drag selection across multiple diff
lines. Users should be able to select and copy multiple lines from the central
diff pane.

## Goals

- Allow native multi-line text selection in central text diff panes.
- Copy selected diff content without visual gutters: no old/new line numbers,
  no change markers, and no hunk header text unless the user explicitly selects
  header text outside the diff body.
- Preserve the current diff readability: hunk headers, stage/discard actions,
  code font settings, syntax colors, and add/delete/context row treatments.
- Apply the behavior to both working-tree diffs and commit diffs through the
  shared hunk renderer.

## Non-Goals

- Do not change image diff behavior.
- Do not add custom selection semantics such as rectangular selection.
- Do not include diff gutters in copied text.
- Do not redesign the central pane layout beyond what is needed for selection.

## Recommended Approach

Replace the selectable SwiftUI diff body rows with a small read-only AppKit text
surface, exposed to SwiftUI through `NSViewRepresentable`. The hunk chrome
remains SwiftUI: hunk header, stage/discard buttons, spacing, and surrounding
layout stay in `HunkView`.

The text surface builds one continuous attributed string from `ParsedDiff.Hunk`
line content:

- Each storage line contains only `ParsedDiff.Hunk.Line.text`.
- Lines are joined with newline characters so AppKit can select across them
  natively.
- The text view is selectable but not editable.
- The text view uses the same code font resolution as the editor and current
  SwiftUI diff rows.
- Syntax highlighting is applied to the attributed string with the existing
  `TreeSitterHighlighter` tokenization.

Because gutters are not part of the text storage, normal copy operations produce
only the selected code content.

## Visual Gutters And Row State

The visible line-number/change-marker gutter should remain non-selectable UI.
There are two acceptable implementation shapes:

1. Keep gutters in SwiftUI beside the AppKit text surface if alignment can be
   kept stable with fixed line metrics.
2. Draw gutters and row backgrounds as non-text decoration in the AppKit-backed
   view if that produces better alignment.

The implementation should choose the smaller, more reliable option after a
short prototype pass. In both cases, copied text must come from code-only text
storage.

Row background colors should continue to distinguish added, deleted, and context
lines. If drawing full-width AppKit line backgrounds proves too invasive, a
first implementation may keep the existing SwiftUI row background treatment as
long as selection remains continuous and visually understandable.

## Components

### `DiffSelectableTextView`

An `NSViewRepresentable` wrapper that owns a read-only `NSTextView` inside an
`NSScrollView`-free AppKit container. The surrounding SwiftUI `ScrollView`
continues to own scrolling for the whole diff pane.

Responsibilities:

- Configure selectable, non-editable plain text behavior.
- Disable unwanted rich text editing features.
- Apply font, paragraph style, syntax colors, and theme colors.
- Size vertically to fit all hunk body lines.
- Update text storage when the hunk, theme, file extension, font family, or font
  size changes.

### `DiffAttributedTextBuilder`

A small pure helper for building attributed code-only hunk text. It should be
testable without hosting SwiftUI or AppKit views.

Responsibilities:

- Join hunk line text with newlines.
- Preserve empty lines.
- Apply per-token syntax attributes.
- Map hunk line kinds to any line-level metadata needed by the view.

### `HunkView`

`HunkView` keeps hunk header and hunk action buttons. Its body delegates the
selectable code content to `DiffSelectableTextView` instead of rendering each
line as independent selectable SwiftUI text.

## Data Flow

1. `DiffTabView` and `CommitDiffView` load a `ParsedDiff`.
2. Each `ParsedDiff.Hunk` is passed into shared `HunkView`.
3. `HunkView` renders non-selectable header/actions and creates the selectable
   diff body.
4. `DiffAttributedTextBuilder` converts hunk lines into code-only attributed
   text.
5. `DiffSelectableTextView` displays the attributed text in one native text
   surface, enabling multi-line selection and code-only copying.

## Error Handling

This feature does not introduce new recoverable runtime errors. If syntax
highlighting fails to produce spans, the builder should fall back to plain
foreground styling for the affected line, matching the current defensive
behavior.

Invalid or unavailable configured font families should continue to fall back
through `CenterTypography.resolveCodeFont`.

## Testing

Add focused tests for the pure builder:

- Multi-line hunk text joins only `line.text` values.
- Added/deleted/context markers and line numbers are excluded from produced
  string content.
- Empty diff lines are preserved.
- Plain text file extensions render without crashing.

Keep or update the existing `DiffSelectableTextTests` smoke tests so `HunkView`
and `CommitDiffView` still render without crashing for hunks, empty hunks, and
custom code font settings.

Manual verification should include selecting multiple lines in:

- A working-tree diff.
- A commit diff.
- A hunk containing add, delete, context, and empty lines.

The copied clipboard text should contain only selected code content.
