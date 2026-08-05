# Stash Changes Terminology Design

## Goal

Make the working-tree action clearly communicate that it creates a Git stash by replacing its stash-specific “park” terminology with “stash.”

## Scope

- Change the working-tree context-menu action from “Park Changes…” to “Stash Changes…”.
- Change the sheet title and confirmation button from “Park Changes” to “Stash Changes”.
- Change the stash creation fallback error to “Could not stash changes.”
- Rename stash-specific Swift files, types, state, callbacks, and methods from `Park…`/`park…` to `Stash…`/`stash…`.
- Keep the existing explanatory text, options, Git command, and behavior unchanged.

Occurrences of “park,” “parked,” or “parking” that describe suspended tasks, continuations, processes, or viewport positions are unrelated and remain unchanged. No stash-specific “unpark” terminology currently exists.

## Components and Data Flow

The existing working-tree menu continues to request presentation of the existing sheet. Submitting the sheet continues to pass the optional message and untracked-files choice through right-pane state to `GitService.pushStash`. Only the names presented to users and the stash-specific Swift identifiers along this path change.

## Error Handling

Existing error propagation is unchanged. Only the empty-output fallback for a failed stash push changes from park terminology to stash terminology.

## Verification

- Do not add a new unit-test seam solely for static UI copy. Verify the exact new strings and the absence of stash-semantic park terminology with source searches; let compilation cover renamed Swift symbols.
- Search production code and tests to confirm no stash-semantic `park` or `unpark` occurrences remain.
- Regenerate the Xcode project because the Swift source file is renamed.
- Run the required macOS build and test commands.
