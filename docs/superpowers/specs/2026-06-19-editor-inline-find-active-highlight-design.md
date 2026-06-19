# Editor Inline Find Active Highlight Design

## Context

Alas already has a custom inline editor find/replace flow for `Cmd-F` and
related find commands. The current implementation computes all matches in
`EditorFindController`, selects the active match in the `CodeTextView`, and
uses `EditorFindHighlightRenderer` to paint non-active matches with temporary
background attributes.

The active match is currently skipped by the renderer because it is represented
by the native `NSTextView` selection. That makes the current match less
visually consistent with other editors when focus is in the find field or when
the selection appearance is subtle.

## Goal

While inline find or replace mode is open, every current match should be
visually marked in the editor. The active/current match should be distinct from
the inactive matches, following the standard behavior in editors such as VS
Code, IntelliJ, and Zed.

The highlighting should clear when:

- The find/replace UI closes.
- The query becomes empty.
- The query has no matches.
- The editor tab detaches or disappears.

## Non-Goals

- Do not change match finding semantics.
- Do not change replace behavior.
- Do not introduce minimap, scrollbar, or overview-ruler markers.
- Do not reuse the content-search reveal behavior directly, because reveal
  highlights whole lines temporarily while inline find needs exact match ranges
  for as long as find mode is open.
- Do not customize global AppKit selection colors.

## Design

`EditorFindController` remains the source of truth for:

- The current find string.
- Case sensitivity.
- The non-overlapping match ranges.
- The active match index.
- The native text selection and scroll-to-visible behavior.

`EditorFindHighlightRenderer` should render both inactive and active matches
using temporary layout-manager attributes. It should no longer skip the active
range entirely. Instead, it should apply:

- A muted warm background to inactive match ranges.
- A stronger warm background to the active match range.

The active native selection remains in place. It still drives replacement,
keyboard navigation, caret behavior, and scroll position. The temporary active
highlight is an additional visual marker, not a replacement for selection.

The first implementation should use background colors only. Exact-range
underlines or outlines are a separate follow-up and are out of scope for this
change.

## Data Flow

1. `EditorTabView` receives a find command and shows the find or replace bar.
2. `EditorFindController.refreshMatches` computes `matches` and optionally
   selects an active match.
3. `EditorTabView.updateFindStatus` updates status text and calls
   `renderFindHighlights`.
4. `EditorFindHighlightRenderer.render` clears stale find-owned temporary
   attributes, then paints inactive and active match ranges.
5. Navigation changes the active index through `EditorFindController`, then
   re-renders highlights.
6. Closing find mode, empty queries, no-match state, tab detach, and tab
   disappearance call `clearFindHighlights`.

## Edge Cases

- Invalid or stale ranges should be ignored during rendering. This mirrors the
  current renderer behavior and avoids temporary-attribute operations outside
  the current text length.
- Empty matches are ignored.
- When document text changes while find is open, `EditorTabView` already
  recounts matches through `handleEditorTextChanged`; the renderer should
  simply render the refreshed ranges.
- Temporary find highlighting should not remove unrelated temporary attributes
  more broadly than necessary. The current renderer removes `.backgroundColor`
  across the document for find cleanup; this change should keep cleanup limited
  to the background attributes used for find highlights.

## Testing

Add focused tests around the renderer and existing find controller integration:

- Rendering includes the active match instead of skipping it.
- Inactive matches and the active match receive different temporary visual
  attributes.
- Clearing find highlights removes the temporary attributes used by the
  renderer.
- Existing find controller navigation and replace tests continue to pass.

Run focused verification:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/EditorFindControllerTests -only-testing:AlasTests/EditorBufferTests -quiet test
swiftformat Alas AlasTests --lint --reporter github-actions-log
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```
