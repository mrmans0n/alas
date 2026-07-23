# Image Diffs Across All Diff Panes

Date: 2026-07-23

## Summary

Alas will render supported image changes anywhere it presents a true file diff. The existing `ImageDiffView` behavior—side-by-side, overlay, swipe, and difference modes—becomes shared comparison machinery rather than behavior owned only by the working-copy and commit-editor tabs.

Multi-file review streams render a full inline image comparison. Image data loads lazily through a lightweight provider attached to each image file model, so opening a review does not decode every image up front. Local Git, stashes, commit ranges, draft review requests, and hosted GitHub or GitLab reviews adapt their exact before/after revisions into that provider.

Image review sections support existing file-level feedback but do not create line or coordinate anchors. GG Split Commit shows only the resulting image for a remainder-only image file. The merge-conflict pane keeps its current ours/theirs interface while sharing lower-level blob and LFS loading where useful.

## Goals

- Show a real image comparison in every true diff surface when either diff path is a supported image type.
- Reuse one comparison experience and one set of image-loading primitives.
- Preserve the exact revision semantics of working-copy, staged, commit, range, stash, draft-review, and hosted-review diffs.
- Keep multi-file reviews responsive by loading and decoding images lazily.
- Keep failures local to one image section and provide an explicit retry.
- Preserve existing review file headers, actions, file-level feedback, and navigation.
- Distinguish added, deleted, modified, renamed, and copied image changes accurately.

## Non-goals

- Spatial or coordinate-based image annotations.
- Line-anchored comments for image files.
- Whole-file assignment of image files while splitting a GG commit.
- A redesign of the conflict-resolution image UI.
- Animated comparison of every GIF frame. Existing first-frame behavior remains.
- General preview support for arbitrary non-image binary formats.

## Current State

The repository already contains:

- `ImageDiffView` and its side-by-side, overlay, swipe, and difference presentations.
- Working-copy image-pair loading for unstaged, staged, and compare-with-HEAD diffs.
- Commit image-pair loading.
- Git LFS pointer resolution, supported bitmap and SVG detection, rename handling, missing-side placeholders, zoom, pan, and reset behavior.
- Single-file image diffs in `DiffTabView` and `CommitDiffView`.
- A separate ours/theirs image viewer in `MergeConflictBinaryView`.

Image changes are deliberately converted to placeholders in the loaders that feed `DiffReviewSurface`. `StashDiffTabView` only attempts a text diff, and GG Split Commit lists non-textual files without a visual preview.

## Surface Coverage

### Full image comparison

The shared comparison appears in:

- Working-copy staged and unstaged file diff tabs.
- Compare-with-HEAD file diff tabs.
- Commit editor file diffs.
- Review Changes.
- Draft Commit.
- Commit Details and commit review.
- Review workspace working-copy, commit, and range sessions.
- Draft review-request diffs.
- Hosted GitHub pull-request and GitLab merge-request reviews.
- Stash diff tabs.

### Resulting-image preview only

GG Split Commit keeps image files remainder-only and non-assignable. In the remainder preview it displays the target commit's resulting image without comparison modes, before/after labels, or split controls.

### UI unchanged

Merge conflict resolution retains its existing LOCAL/ours and REMOTE/theirs presentation. Its stage-blob reading, LFS resolution, and decoding may be routed through the same low-level loader used by image diffs, provided this does not change conflict behavior.

## Architecture

### Lazy review image provider

`DiffReviewFileSectionModel` gains an optional lightweight image provider:

```swift
struct DiffReviewImageProvider {
    let id: DiffReviewImageProviderID
    let load: @Sendable () async -> ImageDiffPairLoadResult
}
```

This provider contract has two requirements:

1. `id` is a stable value that identifies the source, revisions, paths, stage, and mutable-content revision.
2. `load` resolves both sides without requiring `DiffReviewLoadedSession` to retain decoded images.

The provider follows the existing `DiffReviewContextProvider` pattern while using deterministic identity rather than closure identity. `DiffReviewFileSectionModel.hasSameRenderableContent(as:)` includes the image provider ID. A changed provider ID resets image presentation state, cancels stale work, and makes render equality reflect a changed image revision.

For immutable sources, provider identity contains repository identity, exact revision identifiers, and old/new paths. For mutable sources:

- The index side uses its blob object ID.
- A working-tree side uses cheap file metadata sufficient to invalidate an in-view load, such as size and modification time, together with the owning diff-session revision.
- A session reload generation is included where filesystem metadata alone cannot represent the owning model's refresh boundary.

The design does not hash or decode every working-tree image while building the review model.

### Source adapters

Each existing loader determines whether a file is image-backed. Text files continue to build `DiffDisplayModel`. Image files attach a provider and are considered renderable even though they have no text hunks.

Adapters resolve the following comparisons:

| Source | Before | After |
|---|---|---|
| Unstaged working copy | Index | Working-tree file |
| Staged working copy | HEAD, or empty tree for an unborn branch | Index |
| Compare with HEAD | HEAD | Working-tree file |
| Commit | First parent, or empty tree for a root commit | Commit |
| Two-dot range | Resolved left tree | Head |
| Three-dot range or draft review request | Merge base | Head |
| Stash | Stash first parent | Stash snapshot |
| Stash untracked file | Missing | Stash untracked parent |
| Hosted review | Provider's immutable reviewed base or merge-base revision | Provider's immutable reviewed head revision |

Renames and copies use the original path on the before side and the current path on the after side.

### Hosted providers

Hosted review image correctness must not depend on whether the contributor's branch or fork is already configured as a local remote.

The code-host abstraction gains a capability that resolves the immutable before/head revisions for the reviewed diff and loads raw file bytes at a revision and path. GitHub and GitLab implementations use provider metadata or APIs that describe the exact reviewed diff:

- GitHub resolves the reviewed head and comparison merge-base rather than reading a moving local base branch.
- GitLab uses the merge-request diff references associated with the reviewed head.

If the exact SHA exists locally, the adapter may read it through Git for lower latency. It must verify the exact object ID first. Otherwise it uses the provider API. Provider loading must work for forked review requests without adding remotes, fetching branches, or mutating the repository.

### Shared blob decoding

Raw blob acquisition and image decoding become separate responsibilities:

1. A source adapter returns raw bytes or a legitimate missing-side result.
2. Shared decoding resolves Git LFS pointers against the repository when applicable.
3. The supported bitmap or SVG data becomes an `NSImage`.
4. Frame-count metadata is recorded for the existing first-frame notice.

Conflict stage blobs use the same decoding path but retain their existing view.

### Image pair states

The image-pair model must distinguish:

- Loaded image.
- Legitimately missing side for an addition or deletion.
- Failed side with a user-presentable reason.

A decode, authentication, Git, provider, LFS, or network failure is never represented as a missing image. This prevents a modified image with a failed before-side fetch from looking like an addition.

`ImageDiffPairKind` adds a copied case. Copy comparisons support all modes that require both sides and display copy metadata rather than the current misleading rename label.

## Rendering

### Shared comparison composition

The existing image-diff presentation is split into reusable controls and comparison content:

- Mode selection and applicability.
- Side-by-side zoom, pan, and reset.
- Overlay.
- Swipe.
- Difference computation and percentage.
- Missing-side presentation.
- First-frame notices.

The standalone image diff composes those pieces with its existing path header. `DiffReviewFileSection` composes the same pieces with the review file header, keeping one authoritative header rather than nesting a second path toolbar.

The review header continues to own:

- Status and path.
- Original-path or copy/rename metadata.
- Source badge.
- Open File and Unstage actions.
- Existing review accessibility identifiers.
- Image mode controls and reset when the file is image-backed.

### Multi-file layout

Image comparisons render full width inside the file card. The comparison canvas uses a useful bounded height rather than the source image's native dimensions, keeping subsequent review files reachable. Side-by-side remains the default. Images fit proportionally on a checkerboard background; zoom and pan expose native detail.

The initial implementation should use one consistent canvas height across review surfaces, adjusted only by existing pane-width behavior. It should not introduce per-surface image sizing preferences.

### Review feedback

Existing file-level provider threads, annotations, and draft cards render above the image comparison using the current full-width feedback stacks. Image files do not synthesize text rows, line anchors, or coordinate anchors.

This feature does not add a new spatial-comment data model. Existing feedback actions—reply, resolve, edit, delete, stage reply, and summary-rail navigation—remain available when their provider and review context allow them.

### Loading and retry states

Before the pair loads, the file card keeps its normal header and shows the standard compact spinner in the comparison area.

If one or both sides fail:

- The successfully loaded side may remain visible.
- The failed side identifies whether before or after failed.
- The message describes the actionable failure without exposing opaque command output as the primary text.
- Retry reloads only that file's image provider.
- Rail navigation, file actions, and file-level feedback remain usable.

Unsupported non-image binaries continue to use the existing non-renderable placeholder.

## Lifecycle, Cancellation, and Caching

An image file section owns one task keyed by `DiffReviewImageProviderID`. A provider change:

1. Cancels the previous task.
2. Clears pair, error, mode-derived, percentage, and transform state.
3. Starts the new load only when the section is rendered.
4. Checks cancellation and provider identity before applying results.

Late results from a previous revision cannot overwrite the current file.

A bounded decoded-image cache avoids repeated immutable-blob decoding when a lazy section is recreated during scrolling. Cache keys include repository identity, exact revision, and path. In-flight requests for the same immutable key are coalesced. Mutable working-tree and index images are retained by the visible section but are not placed in the immutable cache unless their key includes a content-specific object ID or fingerprint.

The cache is cost-bounded by decoded pixel memory rather than entry count alone. It has no persistence across app launches.

## Stash Details

The stash adapter resolves normal tracked changes as first-parent versus stash commit. For files captured through `--include-untracked`, it reads the image from the stash's third parent and represents the before side as missing.

Deleted, renamed, and copied stash entries preserve their status and old path. A missing third parent is a legitimate absence only when the file metadata identifies an untracked addition; otherwise it is a load failure.

## GG Split Details

`GGSplitPreview` continues to classify image files as non-textual and remainder-only. The preview model provides enough immutable target information to load the resulting file from the commit being split.

The remainder pane shows:

- The normal file path header.
- A proportionally fitted resulting image.
- A loading state and a local per-file failure placeholder.

It does not show:

- Before/after labels.
- Overlay, swipe, or difference modes.
- Hunk or whole-file assignment controls.
- The image on the first-commit side.

## Error Handling

Errors remain scoped to the affected file:

- A hosted authentication or network error does not fail the surrounding review session.
- A missing immutable revision is reported as a revision-loading failure.
- An LFS pointer that cannot be resolved reports an LFS-specific failure.
- Unsupported or corrupt image data reports a decode failure.
- A working-tree file removed during loading reports a changed-on-disk failure unless the current diff status identifies a deletion.

Logs retain source, revision, path, and underlying diagnostic details using existing privacy conventions. User-facing messages avoid leaking credentials, response bodies, or raw file contents.

## Testing

### Pure resolution tests

- Added, deleted, modified, renamed, and copied pairs.
- Working-copy staged and unstaged semantics.
- Root commit and unborn-branch empty-tree behavior.
- Two-dot and three-dot range selection.
- Draft review-request merge-base selection.
- Stash tracked and untracked-parent behavior.
- Original-path selection for renames and copies.
- Missing versus failed side classification.

### Loader and model tests

- Every `DiffReviewSurface` loader attaches an image provider instead of the current placeholder.
- Image summaries remain in source order and are marked renderable.
- Text and unsupported binary behavior is unchanged.
- Provider identity participates in render equality.
- Mutable-source revision changes invalidate provider identity without eagerly decoding image data.
- Draft and hosted review adapters use exact immutable revisions.
- Forked hosted reviews fall back to provider bytes without local remote mutation.

### Async lifecycle and cache tests

- Loads begin lazily.
- Provider changes cancel old work.
- Late results are rejected.
- Retry affects only the failed section.
- Immutable cache hits avoid duplicate decoding.
- Concurrent identical immutable requests are coalesced.
- Cache cost eviction releases older decoded pairs.

### View and interaction tests

- A multi-file image section renders one file header and a full comparison canvas.
- All four modes are available for two-sided pairs.
- Only side-by-side is available when one side is legitimately missing.
- Copy and rename labels are distinct.
- File-level feedback stays above the comparison.
- Open File and Unstage actions remain available.
- Loading, per-side failure, and retry states expose stable accessibility markers.
- GG Split renders only the resulting remainder image.
- Standalone working-copy and commit image diffs retain current behavior.
- Merge-conflict image presentation retains LOCAL/ours and REMOTE/theirs behavior.

### Verification

Implementation verification will include:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Focused image-diff, review-loader, provider, stash, GG split, and render-equality tests should run before the full suite.

## Completion Criteria

The feature is complete when:

- Every true diff surface listed in this document renders supported images instead of the current review placeholder.
- Hosted GitHub and GitLab comparisons use the exact reviewed revisions, including forks.
- Multi-file sessions remain usable while images load and when individual images fail.
- File-level feedback and existing file actions remain available on image sections.
- GG Split shows the resulting remainder image without introducing image assignment.
- Conflict resolution and existing standalone image diffs pass regression coverage.
