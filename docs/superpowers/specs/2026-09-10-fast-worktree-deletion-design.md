# Fast local worktree deletion

## Problem

Alas waits for `git worktree remove` to unlink every file before it treats a
worktree as deleted. Large build directories make that delay proportional to
the number of files. A local benchmark with an Alas checkout and 100,000
untracked files spent 3.14 seconds in `git worktree remove --force`.

Alas also performs a detailed preflight before confirmation. That work is
intentional: initialized submodules may contain local-only commits, refs,
reflogs, notes, stashes, or tags that Git's own worktree checks do not protect.
This change must preserve that warning and confirmation behavior.

Worktrunk makes removal feel immediate by moving a worktree into a trash
directory with a same-filesystem rename, unregistering it from Git, and
deleting its files in a detached process. In the same 100,000-file benchmark,
`wt remove --force` returned with the original path gone in 0.14 seconds while
file cleanup continued in the background.

## Goals

- Make successful local deletion independent of the worktree's file count on
  the user-visible path.
- Preserve the current dirty-file, lock, and local-only submodule checks.
- Preserve branch deletion semantics and mutation serialization.
- Let file cleanup survive normal Alas termination and recover from an
  interrupted or failed cleanup.
- Fall back to the current removal path whenever staging is unavailable.

## Non-goals

- Changing the preflight's safety policy or confirmation copy.
- Speeding up SSH worktree deletion in this change.
- Applying staged deletion to multi-repository Workspace Checkouts in this
  change. Their coordinator has a separate removal and rollback protocol.
- Finding or terminating arbitrary processes whose current directory is under
  the worktree. Alas will stop only sessions and runners it owns.
- Reporting background file cleanup as part of deletion progress. Once the
  original path and Git registration are gone, deletion is complete from the
  user's perspective.

## Design

### Staging location

Resolve the repository's common Git directory with `git rev-parse
--git-common-dir`, resolving a relative result against the command's working
directory and standardizing the resulting URL. Create an Alas-owned trash
directory at `<git-common-dir>/alas/trash/`. Each staged worktree uses a unique
name made from the original directory name, a timestamp, and a random suffix.

The service must validate that every cleanup target is an immediate child of
this trash directory. Cleanup commands receive paths as arguments rather than
interpolated shell text.

### Removal flow

The existing preflight and user confirmation remain unchanged. After
confirmation, the operation continues under `ProjectMutationGate`:

1. Verify that the target still represents the registered worktree selected
   by the user. Recheck cleanliness unless the user confirmed force deletion.
2. Stop Git's built-in fsmonitor daemon for the target on a best-effort basis.
3. Rename the worktree directory into the repository's Alas trash directory.
4. Remove the original, now-missing path from Git's worktree registry. Supply
   the force level already approved by the user, including double force for a
   locked worktree.
5. Apply the current best-effort merged-branch deletion policy.

If the rename fails because the worktree and common Git directory are on
different volumes, because permissions deny it, or for any other filesystem
reason, use the existing synchronous `git worktree remove` implementation.
SSH worktrees always use that implementation.

The staged path is an implementation detail. It must never appear as a live
worktree in `ProjectsManager`, recent-worktree state, or selection state.

Staging is exposed as a new, explicit local-removal operation rather than a
behavior change to `WorktreeService.remove`. AppState opts into it and receives
a cleanup ticket when staging succeeds. Existing direct callers, including the
Workspace Checkout coordinator, retain synchronous `git worktree remove`
behavior. A synchronous fallback returns no cleanup ticket.

### Commit point and rollback

The Git registry removal is the commit point. Before it succeeds, a failure
must attempt to rename the staged directory back to its original path. If that
rollback also fails, report both paths in the deletion error and leave the
staged directory untouched for manual recovery.

After the registry removal succeeds, failure to delete the optional branch
does not restore the worktree. This matches the current best-effort branch
deletion behavior.

Failure to launch background cleanup also does not restore the worktree. The
stale sweep owns recovery after the commit point.

### Application cleanup

Once staging, registry removal, and branch handling return successfully,
`AppState` performs its existing `cleanupWorktreeState` work immediately. This
detaches terminal surfaces, stops ACP runners, and requests shutdown of Alas's
zmx sessions. If the removal returned a cleanup ticket, AppState then hands it
to the detached cleanup launcher. This ordering prevents file deletion from
racing application-owned session shutdown. A synchronous fallback returns no
ticket and needs no further cleanup.

The worktree row then disappears, selection moves to a surviving worktree,
and project worktrees refresh through the existing path. No UI waits for file
cleanup.

External editors, watchers, and build processes are outside Alas's ownership.
They may keep writing through an open directory descriptor after the rename.
The cleanup process may therefore leave a non-empty trash entry. That is a
recoverable cleanup failure, not a failed worktree deletion.

### Detached cleanup and stale recovery

Launch a low-priority detached process with standard input, output, and error
disconnected from Alas. It recursively deletes the one validated staged path.
The launcher must return after a successful spawn and must not await process
termination.

Before spawning the cleaner, request application-owned session shutdown. A
short delay in the detached process gives those asynchronous zmx termination
requests time to finish without delaying the UI.

On application startup and after each successful staged deletion, resolve and
deduplicate the common Git directories belonging to configured local projects,
then scan their Alas trash directories. Entries older than 24 hours are cleanup
candidates. Spawn one detached cleanup operation for those validated entries.
Ignore younger entries because another Alas process may still be deleting them.
Projects that are remote, missing, or no longer Git repositories are skipped.

Malformed names and filesystem objects outside an Alas trash directory are
never swept. Sweep failures are logged and retried on a later run.

### Preflight performance

Preflight optimization is a separate follow-up. The first implementation keeps
its current sequence and remote submodule tag checks so the deletion safety
policy does not change at the same time as the removal mechanism.

## Alternatives considered

### Hide the row while `git worktree remove` continues

This would improve animation but leave the path and Git registration occupied.
Creating the worktree again at the same path would still block, and late
errors would require restoring optimistic state. It does not deliver the
behavior that makes Worktrunk useful.

### Invoke Worktrunk

This would add a runtime dependency and inherit Worktrunk's configuration,
hooks, branch integration rules, output parsing, and submodule safety policy.
Those semantics do not match Alas closely enough for a core destructive
operation.

### Skip local-only submodule auditing

This is faster before confirmation but can delete state that exists only in a
submodule's per-worktree Git directory. The current protection is deliberate
and covered by regression tests, so this design keeps it.

## Testing

Add focused Swift Testing coverage for:

- Successful same-volume staging removes the original path and Git worktree
  registration before a controllable cleanup process finishes.
- Dirty worktrees still require explicit force and clean worktrees still fail
  closed if they become dirty between preflight and staging.
- Initialized submodules retain all existing local-only-state warnings.
- Locked worktrees use the approved double-force registry removal.
- A rename failure invokes the existing synchronous fallback.
- A registry-removal failure restores the original path.
- A failed rollback reports both the original and staged paths without
  deleting the staged contents.
- A cleanup-launch failure leaves a recoverable trash entry while deletion
  remains successful.
- The stale sweep selects only valid entries older than 24 hours.
- SSH worktrees never enter the local staging path.
- App state and selection finish before a suspended background cleanup is
  released.

Do not assert wall-clock thresholds in the test suite. The behavioral boundary
is that removal completion does not wait for cleanup completion.

Before finishing, run the repository's required `xcodegen`, macOS build, and
test commands.
