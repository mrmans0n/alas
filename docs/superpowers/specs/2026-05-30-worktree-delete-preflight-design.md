# Worktree Delete Preflight – Design

**Date:** 2026-05-30
**Status:** Design approved, ready for implementation plan

## Problem

Deleting a worktree currently starts with a generic confirmation. Alas then
tries `git worktree remove` without `--force`; if Git rejects the remove
because the worktree is dirty or contains initialized submodules, Alas shows a
second "Force Delete" confirmation.

That reactive flow is correct, but it makes the first confirmation incomplete:
the user is asked to delete before Alas tells them that the delete may require
force or may remove uncommitted/untracked files.

## Goal

Move the force-delete decision ahead of the first confirmation whenever Alas
can safely classify the worktree. The user should see one context-aware delete
confirmation that explains why `--force` is required before any remove attempt
runs.

This also makes the proposed Worktrees preference unnecessary for the normal
path: submodule-only deletes are confirmed once with accurate copy instead of
being confirmed once generically and once reactively.

## Non-Goals

- Do not weaken the existing dirty-worktree protections.
- Do not force-delete submodules merely because submodules exist.
- Do not remove the current reactive fallback; Git state can change after the
  preflight, and Git error wording can vary by version.
- Do not change branch deletion semantics.

## User-Facing Behavior

Before showing the delete confirmation, Alas runs a delete preflight for the
selected worktree and classifies it as:

- `clean`: show the existing normal delete copy and remove without force.
- `dirty`: show destructive copy that says the worktree has modified or
  untracked files and force delete will remove them; remove with force after
  confirmation.
- `containsInitializedSubmodules`: show copy that says initialized submodules
  require force delete; include an extra warning if preflight found local-only
  submodule state; remove with force after confirmation.
- `dirtyAndContainsSubmodules`: show copy that includes the dirty/untracked
  warning and the submodule warning; remove with force after confirmation.
- `unknown`: show the existing normal confirmation, then rely on the current
  reactive failure path if Git later requires force.

This makes the proposed "skip submodule force-delete confirmation" setting
unnecessary for the normal path. If Alas can safely know that initialized
submodules are the only reason force is required, the first dialog says so and
the confirmed delete proceeds with force. Dirty/untracked worktrees get their
own destructive first-confirmation copy.

## Architecture

### Delete preflight

Add a small preflight API near `WorktreeService`:

```swift
struct WorktreeDeletePreflight: Equatable {
    var requiresForce: Bool
    var reasons: Set<WorktreeDeletePreflightReason>
    var submoduleLocalState: SubmoduleLocalState
}

enum WorktreeDeletePreflightReason: Equatable {
    case dirty
    case containsInitializedSubmodules
}

enum SubmoduleLocalState: Equatable {
    case none
    case present
    case unknown
}
```

Implementation can reuse the existing helper logic in `WorktreeService`:

- worktree clean check: `git status --porcelain --ignore-submodules=none
  --untracked-files=all`
- initialized submodule presence check: `git submodule status --recursive`,
  treating entries not prefixed by `-` as initialized
- initialized submodule cleanliness:
  `areInitializedSubmodulesClean`
- initialized submodule local-state check:
  `initializedSubmodulesHaveNoLocalState`

Submodule local-state checks should inform the first confirmation copy. They do
not block force delete after an explicit user confirmation; they replace the
current generic first confirmation plus second force confirmation with one
better-informed destructive confirmation.

### AppState delete flow

`AppState.deleteWorktree(_:keepBranch:)` becomes an async state-driven flow:

1. Save or discard dirty editor buffers using the existing in-app buffer prompt.
2. Resolve project, repo path, branch deletion behavior, and removed index.
3. Run `WorktreeService` delete preflight off the main actor.
4. Show a single `NSAlert` whose title, message, and destructive button copy
   reflect the preflight result.
5. If confirmed, call `performDeleteWorktree(... force: preflight.requiresForce)`.

If the preflight is `unknown`, keep the existing non-force attempt and reactive
fallback.

### Reactive fallback

Keep `pendingForceDeleteWorktree` and the SwiftUI alert in `RootView`.

This remains necessary for:

- Git state changing between preflight and removal.
- Git failures not detectable by preflight.
- Git versions whose stderr does not match the preflight assumptions.
- Unknown preflight results where the user still chose the normal delete path
  and Git later reports a force-delete requirement.

There is no new config field or Settings UI in this design. The simplified UX
comes from preflight detection, not from a preference.

## Alert Copy

Use one delete confirmation path with copy derived from the preflight:

- Clean: existing copy.
- Dirty: "This worktree has modified or untracked files. Force delete will
  permanently remove them from disk."
- Submodules: "This worktree contains initialized submodules. Git requires
  force delete to remove it."
- Dirty + submodules: include both sentences.

The destructive button can remain `Delete` for clean deletes and become
`Force Delete` when preflight requires force.

## Error Handling & Edge Cases

- **Preflight throws:** classify as `unknown`; continue with the existing
  delete confirmation and reactive fallback.
- **Submodule local-state check fails:** set `submoduleLocalState` to
  `.unknown` and include conservative copy. If the user confirms, proceed with
  force just as the current second confirmation would.
- **Dirty editor buffers:** keep the existing prompt first. It protects unsaved
  in-app buffers before Git status is meaningful.
- **Branch deletion:** continue using
  `resolveDeleteBranchIfMerged(globalDeleteOnRemove:keepBranch:)`.
- **Main worktree:** no behavior change beyond improved copy if the delete path
  reaches preflight.

## Testing

Unit/integration tests should cover:

- Preflight reports `clean` for a clean worktree.
- Preflight reports `dirty` for modified or untracked files.
- Preflight reports `containsInitializedSubmodules` when initialized
  submodules are present.
- Preflight distinguishes clean submodules from submodules with local-only
  state, and from unknown local-state checks.
- `AppState` resolves first-confirmation copy and force behavior for clean,
  dirty, submodule-only, and combined cases.
- Reactive `forceDeleteReason(for:)` still handles dirty and submodule Git
  stderr.
- Submodule-only preflight shows one context-aware confirmation and then deletes
  with force when confirmed.
- Unknown or raced submodule-only fallback still presents the second
  confirmation.

## Files Touched

- `Alas/Sources/Git/WorktreeService.swift`
- `Alas/Sources/App/AppState.swift`
- `Alas/Sources/App/RootView.swift`
- `AlasTests/WorktreeServiceTests.swift`
- `AlasTests/AppStateCleanupTests.swift`
