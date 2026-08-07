---
title: "AppKit diff and review scrollers"
date: 2026-08-06
project: alas
phase: design
prior_art:
  - docs/superpowers/specs/2026-07-07-center-diff-scroll-performance-design.md
  - docs/superpowers/specs/2026-07-19-wrapped-diff-scroll-performance-design.md
  - Alas/Sources/ACP/UI/Scroller
---

## TL;DR

Replace SwiftUI-owned vertical scrolling in Alas's diff and review surfaces
with one feature-flagged AppKit virtualization engine. AppKit will own the
`NSScrollView`, row geometry, viewport selection, scroll anchoring, and host
recycling. Existing SwiftUI controls and the existing AppKit text renderer will
remain the row content.

The experiment covers multi-file review streams, internally scrolling
`DiffPaneView` instances, and the GG split preview. It provides full behavior
parity before landing, defaults on in debug builds and off in release builds,
and leaves the legacy SwiftUI implementations available behind one toggle.

## Context

The shared multi-file review stream currently combines a SwiftUI `ScrollView`,
`LazyVStack`, `ForEach`, `scrollTargetLayout`, and
`onScrollTargetVisibilityChange`. Individual file sections contain further
lazy hunk and feedback stacks. Large reviews have produced main-thread hangs in
SwiftUI's view-graph and lazy-layout machinery, including stacks through
`GraphHost.flushTransactions`, `LazyVStack`, and `ForEachState`.

The rendered code rows are already AppKit-backed through
`DiffPaneTextDocumentView`, and the unchanged-update path avoids rebuilding
identical text documents. The remaining high-cost ownership boundary is the
vertical SwiftUI list and its target-visibility/layout reconciliation.

The AppKit ACP transcript migration established a useful boundary: AppKit owns
scrolling, tiling, and offset compensation while SwiftUI remains responsible
for the contents of each hosted row. This design applies that boundary to
diffs without modifying or generalizing the now-stable ACP scroller.

## Goals

- Remove the outer and nested SwiftUI lazy scrolling machinery from the
  experimental diff/review path.
- Keep mounted view count bounded to the viewport plus overscan.
- Preserve the visible content when rows above the viewport are inserted,
  removed, or remeasured.
- Preserve every existing text, image, feedback, draft-comment, navigation,
  context-expansion, LSP, selection, and mutation behavior.
- Cover multi-file review streams, standalone diff panes, and the GG split
  preview with one shared AppKit engine and one experiment toggle.
- Retain the legacy implementations as a release-safe fallback.
- Provide deterministic geometry and recycling tests plus manual profiling on
  large synthetic and real reviews.

## Non-Goals

- Do not rebuild diff headers, comments, composers, or image controls as native
  AppKit views.
- Do not replace TextKit or the existing AppKit diff text renderer.
- Do not refactor the ACP transcript scroller into a generic shared component.
- Do not change parsing, syntax highlighting, render budgets, comment models,
  review persistence, or provider APIs.
- Do not preserve the exact scroll position when the experiment is toggled at
  runtime; toggling deliberately recreates the scrolling subtree.
- Do not add analytics, persisted presentation state, or wall-clock CI
  performance thresholds.

## Architecture

### Diff-Specific Hosted-Row Engine

Add a diff-specific `NSViewRepresentable` backed by one `NSScrollView`, a
lightweight flipped document view, a tiling controller, a hosting pool, and a
reconciler. The engine accepts an ordered row plan. Each row specification
contains:

- a stable row identifier
- an owning file identifier when the row belongs to a review file
- an equality/version token for visible content
- an estimated height used before first measurement
- a retention policy for rows that must remain mounted while focused
- a lazy `AnyView` builder

The engine mounts only rows intersecting the viewport extended by a fixed
overscan band. A mounted `NSHostingView` pins its SwiftUI root to the current
content width and reports intrinsic-height invalidations. Hosts outside the
mount band return to a reuse pool unless their retention policy pins them.

The engine's implementation may port the algorithms and invariants proven by
the ACP transcript scroller, but its types and policy remain diff-specific.
This keeps transcript behavior untouched while allowing the three diff
surfaces to share one implementation.

### Tiling And Reconciliation

The tiling controller owns the ordered row geometry and an ID-to-index map. It
supports whole-plan replacement, insertion, removal, height updates, viewport
queries, direct target lookup, and mount-band calculation.

Reconciliation compares stable IDs and equality tokens:

- unchanged rows retain their host and measured height
- changed mounted rows receive a new root view and are remeasured
- inserted rows begin with their estimate and are corrected after mounting
- removed rows release their host and presentation-state references
- callbacks are updated through a live relay even when visual equality allows
  the hosted root to remain unchanged

Before a structural or width-sensitive update, the coordinator records the top
visible row and its intra-row offset. After retiling it restores that anchor.
An insertion, removal, or height change contributes offset compensation only
when it occurs entirely at or above the viewport top. Changes within or below
the viewport do not move the current scroll origin.

Zero-width layout passes do not alter measurements or hosted roots. A later
positive-width pass performs the pending reconcile. Duplicate IDs trigger a
debug assertion and use a deterministic last-entry lookup in release rather
than crashing.

### Shared Rendering Factories

Extract non-scrolling SwiftUI factories for the existing visual units instead
of duplicating their UI:

- file headers and file-level feedback
- render-budget placeholders and image content
- hunk headers and hunk bodies
- attributed text segments
- provider threads and annotations
- draft comments and draft composers
- GG split image and non-textual-file rows

The legacy SwiftUI stacks and the new AppKit row-plan builders both consume
these factories. The existing `DiffPaneView` static-height mode remains a
non-scrolling composition tool for legacy hosts; the AppKit paths build their
flat plans directly from the shared factories.

### Presentation State

Rows can be recycled, so interactive state must not remain owned solely by a
temporary hosted SwiftUI view. Introduce keyed presentation-state holders at
the owning surface.

The review state store is keyed by `DiffReviewFileID` and retains:

- pending draft anchor, text, and focus request generation
- collapsed-context expansion IDs
- loaded context, pending context requests, generation, and inline error
- image loading and presentation state
- hovered or active feedback identifiers
- the explicit "Show full diff" override
- the render-context cache

The standalone diff holder retains collapsed-context IDs and active feedback
state for its current display model. State holders expose observable values to
hosted row views and generation-guard async results against the current file
and content signature.

The store prunes files or hunks absent from the current model. It applies the
same reset boundaries as the legacy views: a changed file identity, render
budget reset signal, or context signature clears only the state that currently
resets for that event. Unmounting a row alone never clears state.

Focused text editors and active composers are temporarily pinned in the host
pool so AppKit does not remove the first responder while the user is typing.
Draft text also resides in presentation state, preventing content loss if
focus ends and the row later recycles.

## Surface Adapters

### Multi-File Review Stream

`DiffReviewSurface` keeps its file rail and optional review-summary rail in
SwiftUI. Its central stream chooses between the legacy SwiftUI implementation
and the AppKit representable.

The AppKit adapter builds one flat ordered plan containing file headers,
file-level feedback, image or placeholder rows, hunk headers, text segments,
inline feedback, draft rows/composers, and inter-file spacing. Existing
per-file and aggregate render-budget decisions are applied before the plan is
built. Deferred content produces its existing placeholder and hidden-comment
targets rather than constructing hidden hunk rows.

The tiling controller derives the active file from the topmost file-owned row
intersecting the viewport. That replaces `scrollTargetLayout` and
`onScrollTargetVisibilityChange` for the AppKit path. User-driven selection
updates the existing selected-file binding unless a programmatic-scroll token
is suppressing intermediate updates.

Rail navigation scrolls the target file header to the viewport top using the
current short animation. Provider-feedback and draft-comment navigation
centers their exact row. If the requested row is unavailable because a diff is
deferred, navigation centers the owning placeholder. A missing target falls
back to the owning file header.

### Standalone Diff Panes

For `.internalScroll`, `DiffPaneView` keeps its toolbar outside the scrolling
representable and builds one AppKit plan from hunk and feedback rows. Split and
stacked layout, wrapping, whitespace, font changes, context expansion, hunk
actions, line selection, text selection, LSP interactions, and horizontal
unwrapped behavior use the existing content factories and renderer.

For `.staticHeight`, `DiffPaneView` remains non-scrolling. AppKit-aware parent
surfaces consume its row-plan factory instead of nesting a second vertical
scroller.

### GG Split Preview

The GG split preview replaces its outer diff-preview `ScrollView` and
`LazyVStack` with the shared AppKit engine. Its plan contains file headers and
hunks followed by resulting-image and non-textual-file rows in the existing
order. The surrounding split controls and action bar remain SwiftUI and do not
move into the scroller.

## Updates And Failure Handling

Model refreshes, comment changes, context expansion, image loading, staged
mutations, preference changes, and session replacement produce a new row plan.
Unchanged equality tokens prevent unrelated parent updates from rebuilding or
remeasuring mounted content. The live callback relay ensures actions always
invoke the latest closure generation despite that visual reuse.

Image and context requests retain their existing inline loading, failure, and
retry states. Results are accepted only when the file ID, content signature,
and request generation still match. A recycled row does not cause an older
request to mutate replacement content.

No AppKit review stream or GG split preview contains another vertical
scroller. Standalone panes contain exactly one. Existing horizontal diff
scrolling, accessibility identifiers, menus, keyboard focus, hover behavior,
and selection remain available through the hosted SwiftUI/AppKit subtree.

## Experiment Toggle

Add `AppKitDiffScrollerFlag` with the defaults key
`alas.diff.appKitScroller`. It follows the transcript experiment's semantics:

- explicit `UserDefaults` overrides win
- no override resolves to enabled in debug builds and disabled in release
- `setOverride` writes the value and posts an override-change notification
- Settings > Advanced > Experiments exposes one "AppKit diff scrollers"
  toggle

Every affected surface caches the resolved flag in view state and observes the
notification. A changed value resets scroll bookkeeping and recreates only the
scrolling subtree. Parent-owned loaded sessions, selected files, and persisted
drafts survive; exact scroll positions reset and the Settings description
states that behavior.

No application schema or wire format changes. Users may also set the override
with:

```bash
defaults write io.nlopez.alas alas.diff.appKitScroller -bool YES
```

## Verification

Use Swift Testing and real AppKit objects where geometry matters.

Pure and coordinator tests cover:

- flag resolution, persistence, notification, and surface selection
- unique stable IDs and equality-token changes for every row-plan kind
- presentation-state retention, reset boundaries, and pruning
- insertion, removal, reordering, and remeasurement compensation
- top-visible anchors and intra-row offset restoration
- width, wrap, font, and split/stacked invalidation
- viewport mount bands and bounded host counts
- host reuse, focused-row pinning, and callback-relay freshness
- direct file, feedback, draft, and deferred-placeholder target resolution
- active-file selection and programmatic-scroll suppression
- duplicate IDs and zero-width recovery

Surface tests cover:

- many files and a single file with many hunks
- text, image, unavailable, and render-budget-deferred files
- provider feedback, annotations, drafts, and focused composers
- same-file and cross-file navigation
- context expansion and stale async result rejection
- staged file and hunk actions
- split/stacked, wrap, whitespace, font, and resize changes
- session replacement and removal of state-store entries
- stash and commit panes
- GG split text, image, and non-textual rows
- immediate flag switching with deliberate scroll reset

Keep all legacy diff/review tests as regression gates. Add a deterministic
stress fixture at or beyond the current 20,000-row aggregate budget and assert
that mounted hosts remain bounded by the viewport plus overscan and that
dynamic updates preserve visible geometry.

Finally, profile the same large synthetic fixture and a real large review with
both flag values. Acceptance requires responsive continuous scrolling, no
visible offset jumps during dynamic updates, no beachball, and no outer
diff/review `LazyVStack` or `ForEachState` layout frames in the AppKit-path
sample. Do not add brittle elapsed-time assertions to CI.

Before completion run project generation, SwiftFormat lint, focused
diff/review and new scroller suites, a clean macOS build, and the full macOS
test suite.
