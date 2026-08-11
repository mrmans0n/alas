# Full GG Stack in Changes

## Summary

When a GG-managed worktree is checked out below the stack tip, the Changes tab currently shows only commits reachable from `HEAD`. Always show the complete GG stack in the Commits section while preserving the ordinary Git list for non-GG repositories and for non-presentation logic.

The current stack entry keeps the existing blue leading rail. When it is not the tip, its metadata line also shows a compact `Current · X of N` capsule. The capsule is omitted at `N of N` because the rail already identifies the current commit.

## Data Flow

`gg ls --json` remains the canonical stack source. It already provides every entry's SHA, position, and `isCurrent` state, so this feature requires no git-gud command or schema change.

Add a focused Git batch loader that accepts the stack-entry SHAs and runs one `git log --no-walk=unsorted --stdin` query using the existing commit record format. Parse the results into full `CommitInfo` values keyed by resolved SHA; do not depend on Git's output order.

After the current-stack query succeeds, `RightPaneState` hydrates every reported entry, then projects the rows in descending GG position. This keeps the stack tip at the top and the base-most entry at the bottom, matching the existing history direction. Stack metadata and hydrated rows publish together under the existing snapshot-generation, GG-refresh-generation, and cancellation guards so stale or partial generations never render.

Keep the ordinary reachable `commits` collection unchanged. Ahead counts, push/preparation decisions, initial-tab selection, comparison logic, and non-GG behavior continue to use it. The hydrated full-stack collection is a GG-specific presentation source used by the Commits section only. Existing older-history rows remain below the comparison-base divider and retain the current Load Older behavior.

If the GG query or batch hydration fails, produces malformed records, or cannot resolve every reported entry, do not publish a partial stack. Preserve the ordinary reachable commit rows and route the GG presentation through the existing failed-state Retry path. A newer refresh always supersedes an older hydration result.

## Row Presentation and Actions

The Commits section count and primary rows use the complete hydrated stack whenever that GG presentation is loaded. Existing entry-derived PR/CI chips, merged-row opacity, batching, selection, and details continue to work through the entry-to-SHA association.

The entry whose GG metadata reports `isCurrent` receives the blue rail. When its position is less than the stack's total, add `Current · X of N` to the metadata line. The label must remain compact without reducing the commit subject's available width and must expose accessibility text identifying the current GG commit and its position. If the current position is absent or inconsistent, omit the numeric label rather than inventing a position.

Rows above the current position remain selectable and expose safe read/navigation actions: commit details, review, copy SHA/message/GG-ID, remote commit and review-request links, and GG Checkout. GG-native mutations remain available through the existing stable-entry targeting, guards, and confirmation flows. Hide generic Git Edit Commit, Cherry-pick, and Revert actions for upper entries because those paths assume or act on commits reachable from the current `HEAD`. Current and lower reachable entries retain today's actions.

## Verification

Add Swift Testing coverage for:

- Batch-loading arbitrary commit SHAs and mapping records correctly regardless of Git output order.
- Full-stack projection in descending position, exact entry-to-commit matching, and complete section counts.
- Current-row classification, off-tip `Current · X of N` visibility, tip-label omission, inconsistent-position fallback, and accessibility text.
- Safe, generic, and GG-native action availability for entries above, at, and below the current position.
- Older-history divider/load behavior and existing merged-entry styling with full-stack primary rows.
- Hydration failure, missing objects, malformed output, cancellation, and stale-generation suppression without mixed partial rows.
- Unchanged non-GG commit lists, ahead counts, preparation/push behavior, and existing stack-tip presentation.

Run focused suites first, followed by SwiftFormat lint and `git diff --check`. Run `rtk xcodegen` only if source/test membership changes require project regeneration. Finish with the repository's required macOS build and test commands, serially.

## Out of Scope

- Changing git-gud output or stack semantics.
- Navigating or checking out a commit merely by selecting its row.
- Changing the ordering of ordinary non-GG history.
- Redesigning GG chips, the stack drawer, or generic commit details.
