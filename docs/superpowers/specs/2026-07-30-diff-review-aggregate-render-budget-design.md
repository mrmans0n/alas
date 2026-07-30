# Diff Review Aggregate Render Budget

## Problem

The diff review surface automatically renders every loaded file inside one
`LazyVStack`. SwiftUI materializes lazy children as they are visited but does
not recycle them, so the retained layout tree grows throughout a long review.
The existing 20,000-row limit applies independently to each file and therefore
does not bound aggregate layout work.

Captured hangs show the main thread remaining inside one SwiftUI transaction,
with most samples in recursive stack layout and explicit alignment traversal.
The same failure exists before the recently added static-height width
measurement, so that unconfirmed feedback edge is not part of this fix.

## Design

### Aggregate Eligibility

Extend `DiffReviewRenderEligibility` to calculate automatic render eligibility
from ordered file IDs and their post-collapse row counts. Files remain
automatically eligible in deterministic review order while their cumulative
row count fits within a session-wide cap. Once the cap is exhausted, later
renderable files are deferred.

Non-text files and files without a display model do not consume the row budget.
The aggregate cap matches the existing per-file cap so any file that is valid
under the current policy can still render automatically when it fits.

This is a fixed eligibility decision for a loaded session, not a viewport
window. Scrolling therefore does not replace already laid-out sections or
change preceding section heights.

### Deferred Sections

Pass aggregate eligibility from `DiffReviewSurface` into
`DiffReviewFileSection`. A section defers when either:

- its own display model exceeds the per-file budget, or
- the session-wide automatic render budget excludes it.

The existing placeholder, comment scroll anchors, and per-section "Show full
diff" override remain the interaction model. Placeholder copy distinguishes an
individually oversized file from a file deferred because the review is large.
An explicit user override is allowed to exceed the automatic aggregate cap.

The aggregate eligibility flag participates in the equatable wrapper's render
identity so a session reload cannot leave stale section content.

### Redundant Highlight Invalidations

`DiffPaneTextDocumentContainerView.update` assigns
`activeCommentHighlight` to all panes before its content-signature early
return. Add equality checks at that assignment boundary so unchanged values do
not propagate into text and ruler views and mark them for display again.

## Out Of Scope

- Changing the static-height width preference or estimator without evidence of
  width oscillation.
- Dynamically recycling sections around the viewport.
- Replacing the SwiftUI stream with an AppKit collection view.
- Broad stack flattening or alignment changes.
- Changing intrinsic-content-size invalidation behavior without a confirmed
  oscillation.

## Testing

Add focused Swift Testing coverage for aggregate eligibility:

- cumulative rows at the cap remain eligible;
- the first file that exceeds the remaining aggregate budget and later files
  are deferred;
- files without renderable text do not consume the cap;
- ordering and row metadata remain stable.

Add a focused AppKit test showing that assigning the same active highlight
does not re-invalidate the pane descendants, using a small observable helper if
direct `needsDisplay` assertions are unreliable.

Run:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

The captured hang is not deterministic, so runtime success is additionally
defined as preserving ordinary review navigation and allowing deferred files
to be opened explicitly without automatic tree growth beyond the cap.
