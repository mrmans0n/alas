# Reopen Closed Tabs Design

## Summary

Add the standard `Command-Shift-T` action to reopen tabs closed during the
current Alas process. Repeated invocations walk one app-wide, most-recently
closed-first history. Reopening can switch back to the tab's owning worktree,
and terminal tabs return with their prior pane layout but fresh shell sessions.

## Goals

- Add a **Reopen Closed Tab** menu command with the fixed `Command-Shift-T`
  shortcut.
- Reopen multiple explicitly closed tabs in reverse close order.
- Keep one app-wide history across worktree-local tabs and global Mission tabs.
- Restore a worktree-local tab in its owning worktree and select that worktree.
- Restore tabs near their original position and activate the reopened tab.
- Recreate a terminal tab's pane layout with fresh sessions rooted at the last
  known working directory for each pane.
- Treat explicit bulk actions such as Close Others, Close All, Close Tabs to
  Left, and Close Tabs to Right as reopenable closures.
- Keep automatic lifecycle cleanup out of reopen history.

## Non-goals

- Do not persist closed-tab history across app launches.
- Do not add a history browser, recently closed menu, or tab preview UI.
- Do not revive a terminated terminal process or rerun a Run Script.
- Do not make Close Tab or Reopen Closed Tab configurable shortcuts.
- Do not make tabs removed by worktree deletion, archival, or other automatic
  cleanup reopenable.
- Do not change tab persistence formats.

## User Experience

The existing tab command group gains **Reopen Closed Tab** next to **Close
Tab**. It uses `Command-Shift-T` and is disabled when the session history has no
reopenable entry. The shortcut remains owned by Alas while a Ghostty terminal
surface has focus.

Each invocation reopens one entry. If it belongs to another worktree, Alas
selects that worktree before activating the restored tab. If the same stable
tab ID is already open, Alas focuses the existing tab and consumes the history
entry instead of creating a duplicate stable-ID tab.

Explicit bulk closure records each removed tab as an individual history entry.
Entries are added in visible left-to-right order, so the rightmost removed tab
reopens first. Collection-local neighbor anchors ensure that continuing to
invoke the shortcut reconstructs the original ordering, including when tabs on
both sides of a kept tab were closed.

## Closed-Tab History

Add a small, in-memory `ClosedTabHistory` owned by `AppState`. It holds at most
50 entries. Pushing entry 51 removes the oldest entry. The history is not
encoded by `AppState`, `TabsManager`, or `GlobalTabsManager`.

Each entry contains:

- the complete `Tab` or `GlobalTab` value captured immediately before removal;
- the owning worktree ID for a worktree-local tab;
- the preceding and following tab IDs within the same underlying collection;
- the original collection-local ordinal as a fallback insertion point.

Reinsertion prefers the surviving following neighbor, then the surviving
preceding neighbor, then the clamped original ordinal. This preserves placement
across repeated restoration of a bulk close without coupling the history model
to the rendered composition of global and worktree-local tabs.

The history exposes focused operations for push, peek/pop, and purging every
entry owned by a worktree. Its ordering and placement decisions are pure and
unit-testable; resource cleanup remains in `AppState`.

## Explicit and Automatic Closure Boundaries

`AppState` remains the lifecycle owner. User-facing closure paths capture the
snapshot only after any close confirmation succeeds and immediately before
the existing teardown begins. These paths include:

- a tab-bar close button;
- `Command-W` when it closes a tab rather than one pane of a split terminal;
- Close Others, Close All, Close Tabs to Left, and Close Tabs to Right.

Low-level manager removal and cleanup APIs do not implicitly write history.
Worktree deletion, worktree archival, disappearing-worktree reconciliation,
operation-driven tab removal, and other automatic cleanup continue to call
those raw paths. Deleting or archiving a worktree also purges older history
entries owned by that worktree.

This boundary prevents an automatic cleanup from unexpectedly becoming the
next result of `Command-Shift-T` while keeping every explicit tab-management
action undoable.

## Restoring Non-Terminal Tabs

`TabsManager` and `GlobalTabsManager` gain internal insertion operations that
accept a saved tab plus its placement anchors. The operation inserts the tab,
activates it, and persists the normal open-tab collection using the existing
format.

Before insertion, `AppState` resolves the owner:

1. A global Mission tab uses `GlobalTabsManager` and does not require a
   worktree switch.
2. A worktree tab requires a currently available owning worktree. Alas selects
   it, inserts the snapshot, clears global-Mission presentation, and activates
   the restored tab.
3. If the same tab ID already exists in the target collection, Alas activates
   that existing tab and treats the reopen as successful.

The complete saved value retains the tab-specific view state already modeled
by `Tab`, such as editor reveal state, draft text, review selection, and diff
configuration. Normal view lifecycle code recreates disposable resources such
as editor buffers and ACP attachments when the tab becomes visible.

## Restoring Terminal Tabs

Closing a terminal tab continues to terminate its sessions. Reopen therefore
reconstructs the tab rather than routing through persisted-session restoration.

The reconstruction preserves:

- the terminal tab ID and title;
- the split topology, axes, fractions, and focused-pane position;
- each leaf's `lastCwd`.

It replaces every terminal leaf ID/session ID with a fresh identity, maps the
focused leaf to its replacement, and clears `runScriptKey` and
`runScriptLeafId`. A closed Run Script tab therefore returns as ordinary fresh
shells and never reruns the script merely because the user invoked
`Command-Shift-T`.

Terminal reconstruction is asynchronous and transactional:

1. Resolve the worktree and prepare the existing remote terminal prerequisites
   when needed.
2. Build the replacement pane tree and open one fresh session per leaf, passing
   the old leaf's `lastCwd` as its forced working directory.
3. Register each successfully opened session with existing terminal and
   harness ownership.
4. Insert and activate the reconstructed terminal tab only after every leaf
   succeeds.
5. If a leaf fails, close and unregister sessions created by that attempt,
   leave the UI unchanged, retain the history entry for retry, and show
   **Reopen Tab Failed** through the existing app error presentation.

The history entry is consumed only after successful reconstruction and
insertion. This avoids the existing relaunch restoration rule that deliberately
drops stale terminal tabs when terminal persistence is disabled.

## Command and Shortcut Wiring

`AlasApp` posts a dedicated reopen notification from **Reopen Closed Tab**.
`RootView` receives it and starts `AppState.reopenLastClosedTab()` in a
main-actor task. The command's disabled state reads whether history currently
contains an entry.

`Command-Shift-T` joins `ShortcutAction.reservedBindings` alongside the fixed
Close Tab and tab-number shortcuts. That both prevents assignment to a
configurable action and makes `ShortcutReservations` keep the key equivalent
away from a focused Ghostty surface.

## Stale Entries and Failure Semantics

Worktree removal proactively purges its entries. As a defensive fallback, if
reopen encounters an entry whose owning worktree can no longer be resolved, it
discards that entry and continues to the next entry during the same invocation.
If no valid entry remains, the command is a quiet no-op.

A non-terminal snapshot remains reopenable even if its underlying file,
commit, review, or other resource changed after closure. The restored tab uses
the existing per-tab loading, missing-resource, and unavailable-state behavior
rather than adding a second validation system to closed-tab history.

Terminal setup is the only new fallible restoration stage. Its transactional
rollback and retained history entry make the failure retryable without leaving
a partial tab or leaked sessions.

## Testing

### History Model

- Entries pop in most-recently-closed-first order.
- The history retains only its 50 newest entries.
- Visible left-to-right bulk input reopens right-to-left.
- Following-neighbor, preceding-neighbor, and ordinal fallback placement each
  produce the expected insertion point.
- Reopening every entry from Close Others reconstructs the original order.
- Purging a worktree removes only that worktree's entries.

### Tab Managers and AppState

- Local and global insertion restore and activate a snapshot at its resolved
  position.
- An already-open stable tab ID is focused rather than duplicated.
- A confirmed explicit single close records one entry; a canceled confirmation
  records none.
- Explicit bulk close records every removed local and global tab in visible
  order.
- `Command-W` closing a terminal pane records nothing; closing the last pane's
  tab records the tab.
- Worktree cleanup records nothing and purges prior entries for that worktree.
- Reopening a local tab selects its owning worktree and activates the tab.
- A missing-worktree entry is skipped in favor of the next valid entry.

### Terminal Reconstruction

- A single-pane terminal reopens with a fresh leaf/session identity and its
  prior `lastCwd`.
- A split terminal retains topology, fractions, and focused-pane position while
  every leaf receives a fresh identity.
- Run Script ownership is cleared.
- Injected failure after one or more successful session opens rolls those
  sessions back, inserts no tab, and retains the history entry for retry.

### Shortcut Integration

- Default and configured reservation snapshots include `Command-Shift-T`.
- Ghostty recognizes `Command-Shift-T` as an app-reserved key equivalent.
- The shortcut recorder rejects `Command-Shift-T` for configurable actions.
- The menu command is disabled with empty history and enabled with a valid
  entry.

## Verification

Run focused history, tab-manager, AppState, terminal, and shortcut tests first.
Then run the repository-required verification serially:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```
