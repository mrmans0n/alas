# New Worktree Stacked Diffs Initial Input

Date: 2026-07-28
Status: Approved design

## Problem

`NewWorktreeDialog` resolves its initial repository before the first render, but
its stacked-diffs mode still starts as `.off`. The first render therefore binds
the focused name field to the regular `branch` draft. During `.onAppear`, the
dialog resolves the repository policy and can switch the mode to `.on`, which
rebinds the same visible field to the independent `stackName` draft.

If the user types before that transition completes, the input is stored in
`branch` and immediately disappears when the field switches to `stackName`.
This makes the first keystroke appear to be dropped.

## Desired Behavior

- The initial name field uses the correct regular-branch or stack-name draft
  before it can accept input.
- A keystroke entered immediately after the dialog appears remains visible.
- Regular branch and stack-name drafts remain independent when the user
  manually toggles Stacked Diffs Mode.
- Selecting another repository continues to replace the current mode with that
  repository's resolved default.
- Existing focus, validation, creation, and branch-composition behavior remains
  unchanged.

## Design

Resolve the initial repository and its effective stacked-diffs mode together in
the dialog initializer. Seed both `projectId` and `ggMode` state before SwiftUI
evaluates the first body.

The initial mode uses the existing policy path:

1. Resolve the valid preset project, falling back to the first project.
2. Read whether that repository has GG configuration.
3. Pass the project's policy and configuration result through
   `GGWorktreeContextResolver.isPolicyEnabled`.
4. Store the result as the explicit `.on` or `.off` dialog mode.

Keep the existing `.onAppear` mode application as a defensive fallback for
state that changes between view construction and presentation. In the normal
path, it reapplies the already-selected value and does not change the field's
binding.

Keep the repository-change handler unchanged. It must continue to resolve the
new repository's explicit default after the user chooses a different
repository.

No changes are needed in `AlasField`, the input filter, or the independent
`branch` and `stackName` state.

## Alternatives Considered

### Use one shared name draft

This would give the editor a stable binding, but would remove the approved
behavior where regular-branch and stack-name drafts survive manual mode
toggles independently.

### Hide or disable the field until appearance initialization completes

This would prevent early typing, but would add a visible presentation and focus
transition.

### Delay focus asynchronously

This would narrow the race without removing it and would make correctness
depend on event timing.

## Testing

Add focused Swift Testing coverage for the initial-state resolver:

- a repository whose effective policy is enabled starts in `.on`;
- a repository whose effective policy is disabled starts in `.off`;
- a valid preset is used instead of the first repository;
- a missing preset falls back to the first repository;
- no repositories produces an empty project ID and `.off`.

Retain the existing tests that prove regular branch and stack-name drafts are
independent and that repository changes resolve a new explicit mode.

Run the focused `NewWorktreeDialogTests`, SwiftFormat lint, `xcodegen`, the
required macOS build, and the required test suite before completion.
