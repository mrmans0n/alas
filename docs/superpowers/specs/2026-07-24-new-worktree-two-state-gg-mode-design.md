# New Worktree Two-State GG Mode

Date: 2026-07-24
Status: Approved design

## Context

The new-worktree dialog currently exposes `Inherit`, `On`, and `Off` as three
text-only GG mode segments. `Inherit` is a persisted policy choice rather than
a creation outcome, so the selected segment still needs helper text to explain
whether the new worktree will actually use GG.

The dialog should instead present the concrete result the user is about to
create. Repository policy still provides the default, but it should not remain
as a third visible or hidden state after the dialog initializes.

## Goals

- Replace the three GG mode segments with explicit `On` and `Off` choices.
- Initialize that choice from the selected repository's effective inherited
  policy.
- Persist the visible choice as an explicit worktree override.
- Add the existing three-line GG stack glyph to the `On` segment.
- Represent `Off` with the same glyph crossed by a diagonal slash.
- Reuse one GG glyph implementation in the dialog and sidebar.

## Non-goals

- Removing `.inherit` from `GGWorktreeMode` or changing existing worktrees.
- Changing the sidebar worktree GG mode menu.
- Changing project-level `Off`, `Auto`, or `On` policy semantics.
- Changing GG availability, branch naming, stack-base pinning, or remote
  project behavior.

## User Interface

When GG stack creation is available, the dialog shows a segmented control with
two choices:

- The `On` segment contains the three-line GG stack glyph followed by `On`.
- The `Off` segment contains the same glyph with a diagonal slash followed by
  `Off`.

The icon size, label typography, selection treatment, focus behavior, and
spacing follow the existing `Open after create` segmented control.

The three-line shape is extracted from its sidebar-only location into a shared
presentation component. The component supports a normal and slashed rendering
while keeping the same deterministic custom geometry as the existing sidebar
badge. It does not use `line.3.horizontal`, because that generic symbol does
not exactly match the established GG glyph.

The existing helper text remains and describes the explicit selected result:

- `GG enabled for this worktree.`
- `GG disabled for this worktree. Creates a regular Git branch.`

The control retains its current visibility rules. Remote projects and projects
where the app-wide or installation gates fail do not gain a GG mode control.

## Initial State And Repository Changes

The dialog resolves the selected repository's policy for a new linked worktree
into a Boolean result:

| Project policy | Repository has GG config | Initial selection |
|---|---:|---|
| `Off` | Either | `Off` |
| `On` | Either | `On` |
| `Auto` | Yes | `On` |
| `Auto` | No | `Off` |

This uses the existing GG policy resolver with an inherited worktree mode and
`isMainWorktree` set to `false`. The resulting Boolean maps immediately to
`.on` or `.off`.

The dialog performs this initialization when it first selects a repository and
again whenever the repository selection changes. A choice made for one
repository therefore never leaks into another repository.

There is no untouched or hidden inheritance state. Even if the user accepts
the initial selection without interacting with the control, creation receives
the corresponding explicit `.on` or `.off` value.

## Creation Behavior

The selected explicit mode continues to drive the existing `createsGGStack`
calculation:

- `On` uses the stack-name field, GG branch composition, and configured
  stack-base pinning.
- `Off` uses the regular branch-name field and freely selected base.

The dialog passes only `.on` or `.off` to `createWorktree`. The existing
creation and persistence path stores that explicit override under the created
worktree's stable identity. Later changes to project policy or repository GG
configuration do not change this worktree's selected mode.

If `On` is selected but `branch_username` is unavailable, the existing
configuration hint and disabled confirmation behavior remain unchanged.

## Implementation Approach

The recommended approach is a shared SwiftUI GG icon component:

1. Move the current custom three-stroke shape out of
   `WorktreeRowView.swift` into a reusable GG presentation file.
2. Add a slashed variant by overlaying a deterministic diagonal stroke on the
   same stack geometry.
3. Use the shared normal glyph in the sidebar and the normal/slashed variants
   in the new-worktree dialog.
4. Change the dialog's segment definitions and initialization helpers to
   expose only explicit modes.

Using an SF Symbol would be less code but would change the established GG
geometry. Duplicating the shape inside the dialog would keep the immediate diff
small but create two sources of truth for the same product icon.

## Testing

Focused Swift Testing coverage should verify:

- `Off`, `On`, and `Auto` project policies resolve to the expected initial
  explicit mode, including `Auto` with and without repository GG config.
- Changing repositories replaces the current choice with the newly selected
  repository's resolved explicit default.
- The segment model contains exactly `On` and `Off` in that order.
- Both segments declare the intended normal or slashed GG icon.
- The dialog never passes `.inherit` for a user-visible creation choice.
- Existing explicit-mode descriptions, stack-name selection, branch preview,
  pinned-base behavior, and missing-configuration validation continue to pass.
- The shared normal glyph preserves the sidebar marker's layout and
  accessibility behavior.

Before completion, run the focused new-worktree and sidebar tests, regenerate
the Xcode project if project configuration changes, and run the repository's
required macOS build and test commands.
