# GG Prepare Sync Action

## Problem

The Changes pane hides its Prepare card for a clean GG worktree because
`ChangesPreparationModel` currently considers only working-tree changes and
draft state. A GG stack can still require reconciliation when its commits have
not been published, a published commit has been rewritten, or the stack is
behind its base. In those states the stack drawer offers the appropriate
action, but the more prominent Prepare surface does not.

## Design

Use `GGStackReadinessModel` as the single source of truth for stack
reconciliation actions. `ChangesTabView` will derive the same readiness model
used by `GGStackDrawer` and pass its current reconciliation action into
`ChangesPreparationModel`.

Prepare will surface only readiness actions whose kind is `sync` or `rebase`:

- An unpublished or rewritten stack entry shows **Sync stack**.
- A stack behind its base shows **Sync stack** when sync is allowed to perform
  the configured rebase. Its detail states that the action includes a rebase.
- A stack that requires a separate manual rebase shows
  **Rebase onto `<base>`**. After that succeeds and state refreshes, Prepare
  shows **Sync stack** if publication work remains.
- A fully synchronized stack with no working-tree preparation actions keeps
  Prepare hidden.

The existing GG destination actions remain unchanged. The reconciliation
action is added to the same Prepare card and routes through the existing
`RightPaneState.onGGStackAction` path. The GG drawer remains unchanged.

## State And Safety

The Prepare action copies its title, detail, enabled state, and in-flight state
from `GGStackReadinessModel.Action`. This preserves the existing GG mutation
gate, blocking Git-operation handling, live base-behind override, and effective
GG sync configuration without duplicating policy.

Local staged or unstaged files do not change sync semantics. Sync continues to
exclude working-tree changes, while the existing preparation destinations
remain available for those files.

## Testing

Focused model and routing tests will cover:

- unsynced stack commits make Prepare visible with **Sync stack**;
- a publishable entry still selects Sync when the synced count matches;
- base divergence selects Sync with auto-rebase detail;
- manual-rebase configuration selects Rebase first;
- a fully synchronized stack does not make an otherwise empty Prepare card
  visible;
- the new Prepare actions route to the existing `.sync` and `.rebase` stack
  actions.

Existing `GGStackReadinessModel` tests remain the authoritative coverage for
the underlying reconciliation decision.
