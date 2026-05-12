---
task_id: 785
title: "Group changed files by directory tree in Changes panel"
date: 2026-05-12
project: alas
phase: groomed
prior_art:
  - Alas/Sources/Right/WorkingTreeSectionView.swift
  - Alas/Sources/Right/FilesTabView.swift
  - Alas/Sources/Git/FileTreeBuilder.swift
  - Alas/Sources/Git/GitTypes.swift (FileTreeNode, ChangedFile)
  - AlasTests/FileTreeBuilderTests.swift
---

## TL;DR

The Changes panel currently shows a flat list with directory-path labels.
The Files panel already renders a full nested tree via `FileTreeBuilder` +
`FilesTabView`. This task reuses that infrastructure to render changed files
as a collapsible directory tree, adding **path compaction** (fusing
single-child intermediate directories like `a/b/c/` into one row) which
neither panel has today. Scope is well-contained: one new pure function
(`ChangesTreeBuilder`), edits to `WorkingTreeSectionView`, and new tests.
No Git-layer changes needed.

## Scope confirmation

### In scope (v1)

- Build a `ChangesTreeBuilder` that converts `[ChangedFile]` into a
  `[FileTreeNode]` tree, with compaction of single-child directory chains.
- Replace the flat `directoryGroups` rendering in `WorkingTreeSectionView`
  with recursive tree rendering (expand/collapse per directory).
- Track expanded directory state — either reuse `RightPaneState.openPaths`
  or add a separate `changesOpenPaths: Set<String>` to avoid colliding with
  the Files tab's expand state.
- Preserve existing change summary/count behavior (`+add −del`, status
  badges, staged/unstaged subsections).
- Add focused tests for tree-building and compaction logic.

### Out of scope (v1)

- **Drag-and-drop staging/unstaging** — orthogonal UX feature, not related
  to grouping. Can be added later on tree rows.
- **Inline directory-level aggregate counts** (e.g., `+12 −3` on a
  directory row) — nice-to-have but adds complexity; defer until UX
  feedback requests it.
- **Shared tree component** between Files tab and Changes tab — the
  rendering needs differ enough (Changes rows carry `+add −del` and status
  badges; Files rows carry only optional badge) that factoring a shared
  component is premature. Revisit if they converge.
- **Path compaction in the Files tab** — out of scope, separate task if
  desired.

## Architectural alignment

### Current state

**WorkingTreeSectionView** (`:1–99`)
- `directoryGroups(_:)` at line 80 groups files by their parent directory
  string, returning `[(String, [ChangedFile])]`.
- `subsection(title:files:expanded:)` at line 54 renders each group with a
  `DirectoryRowLabel` header followed by `ChangedRow` entries.
- No nesting, no expand/collapse per directory.

**FileTreeBuilder** (`:1–67`)
- `build(paths:badges:)` converts flat path strings into nested
  `[FileTreeNode]` with `.dir` / `.file` kinds.
- Does **not** compact single-child chains — each directory level is its
  own node.
- Used only by the Files tab today.

**FileTreeNode** (GitTypes.swift `:38–47`)
- Already has `name`, `path`, `kind`, `children`, `badge` fields.
- `name` is the display label — for compacted paths this would become
  `"d/e/f"` instead of just `"d"`.

**FilesTabView** (`:1–72`)
- `renderNode(_:depth:)` recursively renders directories (with
  chevron + folder icon, toggle on `openPaths`) and files.
- Uses `AnyView` type erasure for the recursive return.

**RightPaneState** (`:1–80`)
- `changes: [ChangedFile]` — the flat list, already split by `.stage`.
- `openPaths: Set<String>` — currently used by Files tab only.

### Reuse plan

1. **New `ChangesTreeBuilder`** — a pure `enum` similar to
   `FileTreeBuilder` but:
   - Input: `[ChangedFile]` (not raw paths).
   - Output: `[FileTreeNode]` with compacted single-child dirs.
   - Badges derived from `ChangedFile.status`.
   - Each leaf `FileTreeNode.path` maps back to the `ChangedFile.path`
     for the `onSelect` callback.

2. **Compaction algorithm**: After building the nested tree, walk it
   top-down. If a `.dir` node has exactly one child and that child is also
   a `.dir`, merge them: `name = "parent/child"`, `path = child.path`,
   `children = child.children`. Repeat until stable.

3. **WorkingTreeSectionView** gets a recursive `renderNode` function
   (similar to `FilesTabView`) that renders:
   - **Directory rows**: chevron + folder icon + compacted name, toggle
     expand/collapse. Styled consistently with Files tab but using the
     existing Changes panel spacing.
   - **File rows**: existing `ChangedRow` component, with added left
     padding based on depth.

4. **State**: Add `changesOpenPaths: Set<String>` to
   `WorkingTreeSectionView` as `@State` (local to the view, does not need
   persistence across refreshes — directories re-expand is fine). This
   avoids polluting the shared `openPaths` used by Files tab.

## Acceptance criteria

1. Changed files in the Working Tree section are grouped under a
   collapsible directory hierarchy matching the repo path structure.
2. Staged and Unstaged subsections each render their own independent tree.
3. Single-child directory chains are compacted (e.g., `a/b/c/` shows as
   one row when `a/` and `b/` have no other children).
4. File rows preserve existing behavior: file-type icon, basename,
   `+add −del` counts, status badge (`A`/`M`/`D`/`R`).
5. Directory rows are expand/collapse toggleable with chevron indicator.
6. Root-level files (no parent directory) render without a directory
   wrapper, same as today.
7. `ChangesTreeBuilder` has unit tests covering:
   - Basic nesting (files in different directories).
   - Compaction of single-child chains.
   - Mixed depth: root files + nested files.
   - Empty input returns empty output.
   - Badge propagation from `ChangedFile.status`.
8. Existing `FileTreeBuilderTests` continue to pass unchanged.
9. Build succeeds: `xcodebuild build -scheme Alas -destination 'platform=macOS'`.
10. Tests pass: `xcodebuild test -scheme Alas -destination 'platform=macOS'`.

## Open questions

1. **Should directories start expanded or collapsed?**
   Recommendation: Start all expanded (matches current flat-list behavior
   where all files are visible). Users can collapse to reduce noise.

2. **Should compaction apply when a directory has one file child (not dir)?**
   Recommendation: No — only compact chains of directories. A directory
   with a single file should still show as `dir/ > file` so the file row
   retains its own click target and status badge.

3. **Should `openPaths` persist across refreshes?**
   Recommendation: Use `@State` in the view. On refresh the tree rebuilds
   and all dirs re-expand. This is simpler and matches the "start expanded"
   default. If users complain about losing collapse state, we can promote
   to `RightPaneState` later.

## Implementation order

1. **`Alas/Sources/Git/ChangesTreeBuilder.swift`** (new file)
   - Pure function: `static func build(files: [ChangedFile]) -> [FileTreeNode]`
   - Internal helper for compaction pass.

2. **`AlasTests/ChangesTreeBuilderTests.swift`** (new file)
   - Tests per AC #7.

3. **`Alas/Sources/Right/WorkingTreeSectionView.swift`** (edit)
   - Replace `directoryGroups` + flat rendering with tree-based rendering.
   - Add `@State private var openPaths: Set<String> = []` (or start with
     all paths open).
   - Add recursive `renderNode(_:depth:)` function.
   - Adjust `ChangedRow` usage to pass depth for indentation.

4. **`Alas/Sources/Right/ChangedRow.swift`** (edit)
   - Add optional `depth: Int = 0` parameter for left-padding calculation.
   - Default preserves existing call sites.

5. **Verify build + tests.**

## Risks / things to watch

- **`AnyView` type erasure**: `FilesTabView` uses `AnyView` for recursive
  rendering. This is a known SwiftUI performance concern for large trees.
  Changes panel trees are small (typically <100 files) so this is fine, but
  if the Files tab ever moves away from `AnyView`, the Changes tree should
  follow.

- **Compaction edge case**: Paths like `a/b` where `a/` has two children
  (`b/` and a file) must NOT compact `a/`. The compaction predicate must
  check that the dir has exactly one child AND that child is a dir.

- **`openPaths` collision**: If we reuse `RightPaneState.openPaths`,
  expanding a directory in Changes would also expand it in Files and vice
  versa. Using view-local `@State` avoids this entirely.

- **Refresh rebuilds the tree**: `WorkingTreeSectionView` receives
  `changes` as a `let` — when `RightPaneState.refresh()` fires, SwiftUI
  will re-render with new data. The tree is rebuilt each render. For
  typical change counts (<100 files) this is negligible. If it becomes
  an issue, memoize in `RightPaneState`.

## Definition of done (handoff sign-off)

- Grooming doc reviewed and accepted.
- All architectural claims verified against current code (line numbers,
  type signatures, existing helpers).
- No blockers or unresolved questions that would prevent a designer or
  implementer from starting immediately.
- Task is ready for Design/Implementation phase.
