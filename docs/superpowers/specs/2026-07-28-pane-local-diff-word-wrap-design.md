# Pane-Local Diff Word Wrap

## Goal

Every diff pane that exposes the word-wrap toggle starts with word wrapping off. Enabling word wrap affects only that pane for its current lifetime and does not affect existing or future panes.

## Design

Each diff-pane root owns a local `wrapLines` state initialized to `false`. The root passes that state through the existing `DiffPreferenceBindings` seam to the toolbar and diff-rendering views. Lower-level toggle and rendering behavior remains unchanged.

`DiffPreferenceBindings` continues to expose the globally persisted diff layout mode, but its word-wrap binding is supplied by the pane instead of reading or writing `AppConfig`. Whitespace display remains pane-local as it is today.

The persisted `diffWrapLines` configuration field is retired. Older configuration files may contain the key; normal `Decodable` handling ignores it. Consequently, a previously saved `true` value cannot enable wrapping in a newly opened pane.

Surfaces that already own local word-wrap state, including stash diffs and GG split-commit diffs, retain their current behavior.

## State Flow

1. A diff-pane root is created with `wrapLines == false`.
2. The root supplies `$wrapLines` to `DiffPreferenceBindings`.
3. The toolbar reads and toggles that local binding.
4. The renderer reads the same binding and updates only that pane.
5. Closing the pane discards the state; a new pane starts at `false`.

## Testing

A focused binding test will create two independent pane-local word-wrap bindings and verify:

- both begin off;
- enabling wrap through one binding does not change the other;
- enabling wrap does not update or save application configuration;
- changing the shared layout mode still updates and saves application configuration.

Existing configuration tests will be updated to verify that legacy configuration containing `diffWrapLines` still decodes successfully while the obsolete value has no runtime effect. Relevant diff tests and a macOS build will provide integration coverage.

## Scope

This change does not alter the word-wrap toggle's appearance, diff layout defaults, whitespace behavior, or rendering implementation.
