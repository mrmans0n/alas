# Stashes UI Design

## Context

Issue [#587](https://github.com/mrmans0n/alas/issues/587) asks for git stash support in the Changes tab: park current work-in-progress, optionally include untracked files, list existing stashes with preview, and support apply, pop, and drop. Branch creation from a stash is useful but is deferred from the first pass.

The design follows the existing right-pane Changes architecture. `ChangesTabView` controls section order, `WorkingTreeSectionView` owns the Working tree header menu, `RightPaneState` coordinates sidebar operations and refreshes, and `GitService` owns git command execution and parsing.

## User Flow

The feature uses "Park Changes..." for the action and "Stashes" for the list section.

The Working tree section header menu gains a **Park Changes...** item. Selecting it opens a small sheet with:

- an optional message field
- an **Include untracked files** checkbox
- a **Park Changes** primary action

An empty message is allowed. When the user parks changes, Alas runs `git stash push`, refreshes the right-pane state, and shows the newly created stash in the Stashes section.

The **Stashes** section appears directly below Working tree and above Commits when at least one stash exists. It is hidden when there are no stashes in the first version. This keeps clean repositories quiet while making parked work visible next to current work.

Clicking a stash row expands it inline. The expanded row shows a compact file summary and aggregate additions/deletions. Clicking a file opens a stash diff preview in the center pane. Row actions live in the row menu and context menu:

- **Apply**
- **Pop**
- **Drop...**

`Drop...` requires confirmation. **Create Branch from Stash...** is not included in v1.

## UI Structure

`WorkingTreeSectionView` gets an optional `onParkChanges` callback and adds **Park Changes...** to the section header menu. The action is disabled when there are no working-tree changes or when a merge/rebase/cherry-pick operation is active.

`ChangesTabView` renders the right-pane sections in this order:

1. operation and error surfaces
2. conflicts
3. preparation card
4. Working tree
5. Stashes
6. Commits

`StashesSectionView` is a new collapsible section using the existing `SectionHeader` pattern. It owns only presentation state: section expansion, row expansion, row menus, and rendering stash file rows.

`ParkChangesSheet` is a small SwiftUI sheet for the message and untracked-files option. It is hosted from `RightPaneView`, matching the existing ownership of right-pane confirmations that must remain available even if the child Changes view changes. The sheet state is driven by `RightPaneState`.

## State And Operations

`RightPaneState` owns stash state and operations:

- `stashes: [GitStash]`
- `stashesExpanded`
- expanded stash identity
- pending park sheet state
- pending drop confirmation state
- `parkChanges(message:includeUntracked:)`
- `applyStash(_:)`
- `popStash(_:)`
- `requestDropStash(_:)`
- `confirmDropStash(_:)`

Stash operations follow the existing sidebar operation rhythm: clear `sidebarError`, run git work asynchronously, refresh, then surface failures through `sidebarError`.

## Git Service

`GitService` adds stash primitives:

- list stashes
- push current changes with optional message and optional untracked files
- load file summary for a stash
- load diff for a stash file
- apply stash
- pop stash
- drop stash

Use `git stash push` rather than legacy `git stash save`. If the message is empty, omit the message argument and let Git generate its normal stash message. If **Include untracked files** is checked, pass `--include-untracked`.

List parsing should preserve stable stash references such as `stash@{0}` and the user-visible subject. File summaries should use Git output intended for parsing, such as name-status and numstat data, instead of scraping porcelain text.

## Diff Preview

The expanded stash row lists files changed by the stash. Selecting a file opens a stash-specific diff preview in the center pane.

Use a stash-specific center selection and loader backed by the existing diff display primitives. This keeps the preview read-only and avoids pretending the stash file is part of the live working tree.

The preview must show the stash contents without applying the stash to the working tree.

## Error Handling

Failed park/apply/pop/drop operations surface stderr or a localized fallback in `sidebarError`.

Apply and pop can produce conflicts. In that case Alas refreshes the working tree so conflicted files appear in Working tree. If Git returns a useful message, it should be shown in `sidebarError`. The stash remains intact for `apply`; for `pop`, Git normally keeps the stash when the apply step fails.

Drop requires confirmation because it deletes the stash entry.

## Testing

Add focused tests around the risky boundaries:

- `GitService` parsing tests for stash list output.
- `GitService` parsing tests for stash file summary output.
- `RightPaneState` tests for pending park/drop state and operation refresh behavior using injected git-operation seams already available in tests, or narrower state tests if direct git injection is not available.
- View or model tests for Stashes section visibility, menu labels, and confirmation copy.

Manual verification should cover:

- park tracked changes with no message
- park tracked changes with a message
- park including untracked files
- list and expand stashes
- preview a stash file diff
- apply a stash
- pop a stash
- drop a stash after confirmation
- apply/pop conflict behavior

## Deferred

`git stash branch` / **Create Branch from Stash...** is deferred. It adds branch naming, checkout side effects, and additional failure states that are not needed for the first usable version.
