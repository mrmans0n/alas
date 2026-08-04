# Capped Commit Details

## Goal

Keep the center pane's tab strip visible when a commit has a long message.

## Design

`CommitHeaderView` remains the shared read-only commit-details view. Its compact row stays fixed. When expanded, the details block is wrapped in a native vertical `ScrollView` and capped at 180 points. Content shorter than the cap keeps its natural height; longer content scrolls within the header instead of growing the center pane.

The existing editable commit-message views are unchanged because their `TextEditor` already has a 150-point maximum height and scrolls internally.

## Verification

Add one Swift Testing regression test that hosts an expanded header with a very long body and verifies that its rendered height is bounded. Run the focused test, then the project's required `xcodegen`, build, and test commands.
