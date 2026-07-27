# Stacked Diffs Mode Naming and Icon

Date: 2026-07-27
Status: Approved design

## Context

Alas already presents the feature as `Stacked diffs` in Settings, but two mode
controls still use `GG mode` and the commit contextual submenu is titled `GG`.
The mode controls and sidebar also use a custom three-line stack glyph, while
the commit submenu uses the `square.stack.3d.up` SF Symbol.

The user-facing feature name should be consistent without hiding which tool
provides commit-specific operations. Its icon should also be consistent across
these surfaces.

## Goals

- Rename the New Worktree field to `Stacked Diffs Mode`.
- Rename the worktree sidebar submenu to `Stacked Diffs Mode`.
- Rename the commit contextual submenu to `Stacked Diffs (GG)`.
- Use the commit submenu's `square.stack.3d.up` symbol everywhere the shared GG
  stack icon currently appears.
- Preserve the existing diagonal slash that distinguishes the Off variant.

## Non-goals

- Renaming GG-specific actions, installation controls, diagnostics, errors,
  tooltips, or internal identifiers.
- Changing stacked-diffs configuration, policy resolution, worktree creation,
  stack operations, or menu availability.
- Changing icon sizing, colors, spacing, or accessibility behavior.
- Broadly replacing every user-facing occurrence of `GG` or `gg`.

## User Interface

The affected labels are:

| Surface | Current | New |
|---|---|---|
| New Worktree field | `GG mode` | `Stacked Diffs Mode` |
| Worktree sidebar submenu | `GG Mode` | `Stacked Diffs Mode` |
| Commit contextual submenu | `GG` | `Stacked Diffs (GG)` |

`Stacked Diffs Mode` makes the feature the primary concept in routine
configuration. `Stacked Diffs (GG)` retains the provider name where the
submenu exposes GG-specific commit operations.

All three surfaces use `square.stack.3d.up` as their stack symbol. The New
Worktree Off segment uses the same symbol with the existing diagonal slash
overlay. The sidebar retains its current muted metadata styling and progress
text.

## Implementation Approach

Keep `GGStackIcon` as the shared SwiftUI presentation component. Replace its
custom three-stroke shape with an `Image` using `square.stack.3d.up`, while
preserving the component's size, color, and normal/slashed variants.

Expose the symbol name from the shared component and use it for the commit
submenu's `systemImage` argument. This gives all affected surfaces one source
of truth without changing their layout or behavior.

Update the existing label constants or call sites in `NewWorktreeDialog`,
`WorktreeRowView`, and `CommitRow`. No model, persistence, or service changes
are required.

## Testing and Verification

Focused tests should verify:

- The New Worktree field uses `Stacked Diffs Mode`.
- The worktree sidebar submenu uses `Stacked Diffs Mode`.
- The commit contextual submenu uses `Stacked Diffs (GG)`.
- The shared stack icon and commit submenu reference the same SF Symbol.
- Existing mode choices and the normal/slashed icon variants remain intact.

Before completion:

1. Run SwiftFormat lint.
2. Regenerate the Xcode project.
3. Run the focused New Worktree, sidebar, and commit-row tests.
4. Run a macOS build.

