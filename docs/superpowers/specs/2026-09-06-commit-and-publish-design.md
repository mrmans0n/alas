# Commit and Publish

## Summary

Add a second commit path that creates the commit and publishes it in one
recoverable workflow. For normal Git branches, publishing pushes the branch and
creates a pull or merge request when one does not already exist. For active GG
stacks, publishing runs `gg sync` after the commit.

The action appears in both the Changes pane's Prepare card and the draft commit
composer. The Prepare choice sets the composer's default action. The existing
configurable commit shortcut runs that default action, while its Shift variant
runs the alternate action.

## Goals

- Add a one-click commit-and-publish path without removing the existing local
  commit path.
- Keep the Prepare entry point and the final composer action consistent.
- Create a regular review request by default, with a per-draft option to create
  it as a draft.
- Update an existing review request by pushing without trying to create a
  duplicate.
- Map the same interaction to commit-and-sync in GG mode.
- Make partial success retryable without creating a second commit, repeating a
  successful push, or creating a duplicate review request.
- Preserve existing draft commit state across tab closure and app relaunch.

## Non-goals

- Do not generate a separate review request title or description. The commit
  subject and body are used directly.
- Do not open the existing review request draft editor as part of this path.
- Do not automatically open a browser or review tab after success.
- Do not add a separate configurable shortcut for publishing.
- Do not add automatic force-push behavior.
- Do not change GG's review request policy or add a Draft PR override to
  `gg sync`.
- Do not make publish checkpoints a general-purpose background job system.

## User experience

### Prepare card

For a normal Git branch, the Prepare card shows two destinations when a commit
draft is available:

- **Draft commit** opens or focuses the draft with local commit selected.
- **Commit & PR** opens or focuses the draft with publishing selected when the
  branch has no review request.
- **Commit & push** replaces **Commit & PR** when the current branch already has
  a review request.

Choosing either destination preserves any existing draft text and changes the
preferred action on a live or stashed draft. Other ways of opening a draft use
local commit as the default.

For a supported review host, the publish destination is disabled with a concise
help reason while review state is loading or when preflight detects an
actionable blocker. Blockers include an unavailable or unauthenticated provider
CLI when a new review request is needed, selecting the base branch, a stale or
diverged upstream, and another active operation. A repository with no supported
review host hides the publish destination instead of showing a review-request
action that cannot succeed.

GG mode adds **Commit & sync** beside **New stack commit**, **Amend current**,
and **Absorb into stack**. The four GG actions use a two-column, two-row grid:

1. New stack commit
2. Commit & sync
3. Amend current
4. Absorb into stack

The existing Review current changes action remains above this grid. Choosing
either action in the first row opens the same draft composer and selects the
corresponding default. Amend and Absorb remain immediate GG mutations.

### Draft commit composer

The composer shows **Commit** and one contextual publish action:

- **Commit & PR** when normal Git can create a new review request;
- **Commit & push** when the branch already has one;
- **Commit & sync** when the worktree has an active GG stack.

The action selected from Prepare uses the accent treatment and the configured
commit shortcut. The alternate action uses the Shift variant of that shortcut.
Button order remains stable, with Commit before the publish action. If the
configured shortcut already contains Shift, the alternate removes Shift so the
bindings remain distinct.

For a normal Git branch without an existing review request, a **Draft PR**
checkbox appears beside the composer actions. Its value is persisted with the
commit draft and defaults to off. It remains available even when Commit is the
selected default because the user can invoke the alternate publish action. The
checkbox is hidden for an existing review request and in GG mode.

While the workflow runs, the selected button reports the active phase, such as
Committing, Pushing, Creating PR, or Syncing. All mutation controls are disabled
until that phase finishes or fails.

## Shortcut behavior

`commitInComposer` remains the only configurable shortcut. The composer first
resolves its effective binding using the existing fallback behavior. The
preferred action receives that binding. The alternate action receives the same
key and modifiers with Shift toggled.

For the default binding:

- Entering through Draft commit makes `Command-Return` commit and
  `Command-Shift-Return` publish.
- Entering through Commit & PR, Commit & push, or Commit & sync makes
  `Command-Return` publish and `Command-Shift-Return` commit.

Single-action callers of `CommitMessageEditorView`, including commit-message
editing and the existing review request composer, keep their current behavior.

## Persisted draft state

`DraftCommitTabState` gains:

- a preferred action, commit or publish;
- the Draft PR choice;
- an optional publish checkpoint.

The checkpoint records the created commit SHA, the comparison base needed by
the eventual commit editor, the publish kind, and the next unfinished phase.
The publish kind distinguishes normal Git review publication from GG sync. A
normal Git checkpoint also retains the branch, remote, base branch, provider,
review request existence, Draft PR choice, and commit message values captured
by preflight so later UI changes cannot alter an in-progress operation.

Decoding is tolerant of all fields being absent. Existing persisted drafts load
as commit-first, regular review request, with no checkpoint.

Closing a tab after the commit phase keeps the checkpoint in the stashed draft.
Reopening the draft presents the appropriate retry action. A successfully
completed workflow clears the checkpoint through the existing draft-to-commit
editor replacement.

## Components and ownership

`ChangesPreparationModel` owns the labels, visibility, enablement, and disabled
reasons for the new destinations. `ChangesPreparationCard` renders the normal
pair and the GG grid. `ChangesTabView` passes the selected intent to
`TabsManager.openOrFocusDraftCommit`.

`TabsManager` persists the intent on new, live, and stashed drafts without
clearing their subject, body, Draft PR choice, or file selection. Its existing
reset-for-new-stack-commit behavior still clears Amend.

`CommitMessageEditorView` accepts an optional alternate action. It owns only
button presentation and shortcut assignment. Existing callers can continue to
provide one primary action.

A focused commit-publish coordinator owns preflight and phase sequencing. It
uses `GitService` for commit and remote-state probes, the existing review loop
and code-host provider for review request lookup and creation, and the existing
GG mutation coordinator for sync and progress events. The SwiftUI view observes
the coordinator and persists checkpoint changes through `TabsManager`; it does
not run the multi-step sequence itself.

GG mutation plumbing gains an awaitable result for this workflow while
preserving the current stack progress, pause, error, undo, refresh, and
serialization behavior used by `RightPaneState`.

## Preflight

Preflight runs before creating a commit. It captures the message and destination
metadata and rejects known blockers while the draft is still fully editable.

Normal Git publication requires:

- a non-empty subject and staged changes;
- a feature branch distinct from the selected base branch;
- a supported code-host remote;
- no stale or diverged upstream state;
- no conflicting review action;
- an available, authenticated provider with create capability when no review
  request exists.

GG publication requires an active GG context, a usable stack head, no paused or
in-flight GG mutation, and no blocking Git operation.

Amend receives an additional safety check. If the current HEAD is already
reachable from the tracked upstream, the combined publish action is disabled.
The user may still amend locally, but publishing rewritten history remains an
explicit follow-up outside this feature. Amending an unpushed HEAD may use the
combined action because a normal push remains fast-forward.

## Normal Git workflow

The coordinator performs these steps:

1. Run preflight and capture its immutable publication target.
2. Create or amend the commit with the existing `GitService.commit` operation.
3. Persist a checkpoint containing the new SHA before starting network work.
4. Push with upstream tracking using the same remote and branch resolution as
   the existing review-loop Push action.
5. Persist that push completed and refresh remote review state.
6. If a review request now exists, skip creation. Otherwise create one with the
   captured commit subject and body and the captured Draft PR choice.
7. Mark publication complete, refresh right-pane review state, and replace the
   draft with the existing commit editor.

An empty commit body produces an empty review request description. Only the
subject is required. A successful create returns its URL, but the workflow does
not navigate away from the commit editor.

When a review request existed at preflight, the sequence ends after push and
refresh. Its UI label is Commit & push, and Draft PR has no effect.

## GG workflow

The coordinator performs these steps:

1. Run GG preflight.
2. Create the commit through the existing commit operation.
3. Persist a checkpoint containing the new SHA and sync as the unfinished
   phase.
4. Start `gg sync` through the existing mutation coordinator and await its
   result.
5. Keep using the current GG sync progress presentation, conflict pause state,
   error mapping, and stack refresh behavior.
6. On success, clear the checkpoint and replace the draft with the existing
   commit editor.

`gg sync` remains responsible for creating or updating every review request in
the stack. Alas does not invoke a provider create operation in this path.

## Failure and recovery

Preflight and commit failures leave the draft editable and do not create a
checkpoint. Existing inline error presentation shows the failure.

After commit succeeds, the commit is never rolled back. The message, Amend,
Draft PR, and alternate commit action become read-only. The publish action
changes to the unfinished operation:

- **Retry push**
- **Retry create PR**
- **Retry sync**

Before any retry, the coordinator verifies that the worktree's HEAD still
matches the checkpointed commit. A mismatch stops automatic recovery and
explains that the branch changed after the commit; the user can finish from the
Changes pane. Alas does not move HEAD or publish a different commit.

Push retry first refreshes or probes the upstream. If the recorded commit is
already present remotely, it advances the checkpoint without pushing again.
This covers a push that reached the remote before the local process reported an
error.

Review request retry first queries the provider for the current branch and
base. If a request exists, it advances without creating another one. This
covers a provider request that succeeded remotely but returned an ambiguous
local error.

GG sync retries the existing idempotent sync operation. Partial stack progress
and paused conflicts continue to use GG's existing recovery controls.

Once the last remote mutation succeeds, checkpoint completion is authoritative.
A later sidebar refresh failure does not expose a retry that could repeat the
mutation; normal refresh error UI handles that independently.

## Testing

### Presentation and shortcuts

- Normal Git uses Commit & PR without a request and Commit & push with one.
- GG uses Commit & sync and the four actions render in the intended order.
- Prepare selection updates the preferred action on new, live, and stashed
  drafts without changing message contents.
- Preferred and alternate buttons receive the base and Shift-variant shortcuts
  for default and customized bindings, including a customized binding that
  already contains Shift.
- Single-action composer callers remain unchanged.
- Draft PR appears only for a creatable normal Git review request.

### Persistence

- Existing encoded drafts decode with default values for every new field.
- Preferred action, Draft PR, and each checkpoint phase round-trip.
- Closing and reopening a partially published draft retains its retry phase.
- Successful replacement clears live and stashed recovery state.

### Preflight and amend safety

- Missing remote, provider availability, authentication, capability, base-branch
  selection, stale upstream, diverged upstream, and conflicting operation each
  block publication before commit.
- Published amended HEAD disables publication without disabling local Amend.
- An unpushed amended HEAD may publish with a normal push.
- GG paused, in-flight, inactive, stale-head, and blocking-operation states
  prevent commit-and-sync.

### Workflow sequencing

- Commit-only behavior remains unchanged.
- New review publication runs commit, push, lookup, then create with the exact
  captured subject, body, base, and Draft PR value.
- Existing review publication runs commit and push but never create.
- GG publication runs commit then one GG sync through existing mutation state.
- Each failure persists the correct next phase and exposes the matching retry
  label.
- Retrying after commit never calls commit again.
- A remote-complete push probe skips a duplicate push.
- A provider lookup that finds a request skips duplicate creation.
- A HEAD mismatch stops retry without performing a remote mutation.
- A refresh failure after remote success does not reactivate a completed phase.

## Verification

Run focused draft-state, preparation-model, shortcut, coordinator, review-loop,
and GG tests first. Then run the repository-required verification serially:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```
