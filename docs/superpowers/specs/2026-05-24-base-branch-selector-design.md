# Base Branch Selector in Changes Panel

## Summary

Add a clickable base-branch chip to the Commits section header in the right pane. Tapping it opens a picker that lets the user choose which ref to compare HEAD against, changing the commits shown in the "Commits" list and the behind-base chip.

## Motivation

Currently the comparison ref (`origin/main`, `main`, or upstream) is shown as a static label in the Commits header. Users cannot change it without editing the global "Base branch" setting in Settings → Worktrees. For repos with multiple mainline branches (e.g., `main` and `develop`) or when reviewing a feature branch against a different trunk, users want to switch the comparison on the fly per worktree.

## Design

### UI

- **Chip placement:** The existing `comparisonRef` row in `CommitsSectionView`’s header trailing slot becomes a tappable chip.
- **Chip styling:** Same look as today — branch icon + monospace ref name in `fg-faint`. On hover, the text shifts to `accent` and the cursor becomes a pointing hand.
- **Popover:** Opens below the chip. Contains:
  1. A search field (filters the list).
  2. A scrollable list of branches with a checkmark marking the current selection.
  3. An "Other…" row at the bottom that opens a free-text field for arbitrary refs (or reuses the existing `BranchPicker` dialog).

### Smart Shortlist

The picker shows a smart shortlist of branches rather than every branch in the repo. The list is computed per-worktree when the popover opens.

Priority / sections:
1. **Mainline branches** — Any branch whose short name matches `main`, `master`, `develop`, or `trunk`. Both local and remote-tracking forms are included.
2. **Current upstream** — If the active branch has an upstream tracking ref (e.g., `origin/feature-x`), include it.
3. **Recently selected** — Up to 3 branches previously chosen for this worktree (kept in-memory on `RightPaneState`).
4. **Deduplicated and sorted** — Local branches first, then remotes, alphabetically within each group.

If a previously selected branch no longer exists (e.g., a stale remote branch), it still appears in the recent list with a "not found" note, but remains selectable so the user can see the empty state.

### Data Flow

```
User taps chip
  → popover opens with smart list
User selects branch
  → baseBranch on RightPaneState is updated
  → RightPaneStore propagates change to cached state
  → RightPaneState.refresh() triggered
    → re-fetches commitsAhead(baseBranch:)
    → re-fetches refreshSyncStatus()
  → Commits list + behind-chips update reactively
```

### Component Architecture

- **`BaseBranchSelector`** — New SwiftUI view. Owns the chip + popover.
  - Inputs: `@Binding var baseBranch: String`, `worktree: Worktree`, `currentRef: String?`, `onSelect: (String) -> Void`.
  - Internally computes the smart list when the popover opens.
- **`CommitsSectionView`** — Replaces the inline `comparisonRef` HStack with `BaseBranchSelector` in the trailing slot.
- **`RightPaneState`** — Gains a `recentBaseBranches: [String]` ring buffer (max 3) that is populated when the user selects a new base. The property is in-memory only (not persisted).

### Error Handling

- **Unresolvable branch:** If the selected branch does not resolve, `commitsAhead` returns empty commits and `nil` `comparisonRef`. The UI shows the "no comparison branch" empty state. No crash, no alert.
- **Network fetch failure:** During `refreshSyncStatus`, fetch errors are logged via `os.Logger`. The UI keeps the last successful behind-chip state.

## Testing Plan

- Swift Testing unit tests for `BaseBranchSelector.smartList(branches:current:upstream:recent:)` covering:
  - Ordering (mainlines → upstream → recent)
  - Deduplication when upstream is also a mainline
  - Capping recent list at 3
  - Handling empty input gracefully
- `RightPaneState` tests:
  - Changing `baseBranch` triggers `refresh()` and updates `commits`/`comparisonRef`.
  - Selecting a new base appends it to `recentBaseBranches`.
  - An unresolvable branch results in empty commits and `nil` `comparisonRef`.

## Out of Scope

- Persisting the overridden base branch across app relaunches. This can be added later by writing per-worktree overrides into `AppConfig` without changing the component interface.
- Changing the global Settings default from the picker. The picker is strictly a per-worktree override.

## Risks / Open Questions

- **Remote branch staleness:** If the user selects `origin/main` and later fetches, the comparison ref stays `origin/main`. This is the same behavior as today and is acceptable.
- **Performance on huge repos:** The branch list is fetched with `git branch --list` + `git branch --remotes`, which is fast even on large repos. The smart list computation is in-memory string filtering.
