# Worktree Import Timestamps Design

## Problem

When Alas discovers the worktrees of a newly added local repository, it derives
`lastActivity` from Git ref-file modification times. If branches are stored in
`packed-refs`, every affected worktree receives the modification time of the
same shared file. The sidebar therefore displays an identical timestamp for
worktrees whose HEAD commits were updated at different times, and automatic
last-update sorting cannot distinguish them.

## Semantics

- `createdAt` continues to represent the worktree folder's filesystem creation
  date, with the existing folder modification-date fallback.
- `lastActivity` represents the commit time of the commit currently checked out
  at the worktree's HEAD.
- Filesystem and ref modification times remain best-effort fallbacks when Git
  cannot resolve a HEAD commit timestamp.

This definition is consistent for loose refs, packed refs, and detached HEADs,
and matches the existing remote-repository behavior.

## Design

After parsing `git worktree list --porcelain`, `WorktreeService.list` resolves
the HEAD commit time for each discovered worktree with:

```text
git log -1 --format=%ct HEAD
```

The lookups run concurrently, as the current SSH implementation already does.
Successful results replace the provisional `lastActivity` populated by the
synchronous porcelain parser. Failed or empty-history lookups leave that
provisional value unchanged.

The same enrichment path handles local and SSH repositories so timestamp
semantics do not depend on transport. No new persistence fields or UI changes
are required; `ProjectsManager` already sorts by `lastActivity`, and the
sidebar already displays it.

## Alternatives Considered

1. Use commit time only when a loose ref is absent. This reduces subprocesses
   but makes `lastActivity` mean ref-write time for some branches and commit
   time for others.
2. Batch branch timestamps from the main repository. This uses fewer processes
   but complicates detached HEAD handling and mapping Git's worktree-specific
   state.
3. Use worktree folder modification time. Generated files, builds, and other
   non-Git filesystem activity make it a noisy measure of repository updates.

Per-worktree HEAD commit lookup is preferred because it is consistent and
reuses the behavior already used for SSH worktrees.

## Testing

Add an integration regression test that:

1. Creates a repository with multiple linked worktrees.
2. Gives each worktree's HEAD commit a distinct commit time.
3. Packs and prunes the repository's refs.
4. Calls `WorktreeService.list`.
5. Verifies that each worktree receives its own HEAD commit time rather than the
   shared `packed-refs` modification time.

Existing worktree-ordering tests continue to cover ascending and descending
sorting once distinct `lastActivity` values reach `ProjectsManager`.

## Scope

The change only corrects initial and refreshed `lastActivity` discovery. It
does not add a separate "last opened in Alas" metric, alter creation-time
semantics, or change the main-worktree pinning rule.
