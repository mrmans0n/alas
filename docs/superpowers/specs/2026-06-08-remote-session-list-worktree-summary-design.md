# Remote Session List Worktree Summary Design

## Context

The remote web UI currently lists ACP sessions with only a title and streaming status. When multiple sessions are available, the user cannot tell which worktree a session belongs to, whether that worktree has local changes, or whether it has commits waiting relative to the same comparison logic used by the native Changes pane.

The remote UI is bundled with the macOS app, so this design can evolve the wire payload and web renderer together. The existing `RemoteSessionSummary` payload carries only `id`, `title`, `agentId`, `status`, and `canDrive`.

## Goals

- Make the remote sessions list distinguish sessions by worktree.
- Surface current lightweight git state for each session's worktree.
- Match the native right pane's definition of commits ahead.
- Keep the list compact and scannable on mobile.
- Preserve fallback behavior when git probing fails.

## Non-Goals

- No file preview list.
- No staged vs. unstaged breakdown.
- No inline diff details.
- No per-row asynchronous loading state in the web UI.

## UX

Render each session as a compact mini-card.

The primary row shows:

- Session title on the left.
- Session status on the right.

The second line shows:

- `project name / worktree name`

The metadata line shows only non-empty segments:

- `N commits` for commits ahead of the comparison ref.
- `N conflicts` when conflicted files exist.
- `N files` when uncommitted changed files exist.
- `+A -D` when uncommitted line counts are non-zero.
- `clean` only when metrics are available and commit count, changed file count, and conflict count are all zero.

Example:

```text
Fix remote auth prompt          awaiting input
alas / nacho-improve-remote-sessions
3 commits · 7 files · +184 -39
```

Conflict example:

```text
Resolve stuck checkout          streaming
alas / bugfix-zmx-launch
1 commit · 2 conflicts · 5 files · +62 -18
```

Clean example:

```text
Plan sidebar polish             idle
alas / main
clean
```

Avoid `dirty worktree` copy because visible file and line counts already communicate uncommitted changes.

## Data Model

Extend `RemoteSessionSummary` with an optional worktree summary payload.

Suggested shape:

```swift
struct RemoteWorktreeSummary: Codable, Equatable, Sendable {
    let projectName: String
    let worktreeName: String
    let branch: String
    let path: String
    let metricsAvailable: Bool
    let comparisonRef: String?
    let commitCount: Int
    let changedFileCount: Int
    let addedLines: Int
    let deletedLines: Int
    let conflictCount: Int
}

struct RemoteSessionSummary: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let agentId: String
    let status: String
    let canDrive: Bool
    let worktree: RemoteWorktreeSummary?
}
```

The payload stays optional so old minimal summaries and test fixtures remain easy to decode.

## Backend Flow

Change `RemoteSessionsProvider.sessionSummaries()` to async so list refresh can compute fresh lightweight git data.

When the gateway handles `listSessions`:

1. Await `provider.sessionSummaries()`.
2. Emit one `sessionList` message with complete rows.

In `AppState.sessionSummaries()`:

1. Iterate live ACP managers as today.
2. For each session row, resolve `manager.worktreeId` to a known `Worktree` and `ProjectConfig`.
3. Build the base session fields from the ACP row and runner state.
4. If the worktree resolves, compute the worktree summary with:
   - `GitService.status(worktreePath:)`
   - `GitService.commitsAhead(at:baseBranch:ignoreUpstream:)`
5. Use the app config's right-pane semantics:
   - `baseBranch = config.worktrees.baseBranch`
   - `ignoreUpstream = !config.changes.trackUpstreamForCommits`

The commit count is `commitsAhead(...).commits.count`. The comparison ref is the returned `comparisonRef`.

The changed file count is the number of `ChangedFile` entries from `status`. The conflict count is the number of entries whose `conflict` is non-nil. Added and deleted lines are totals across those `ChangedFile` entries.

## Error Handling

Git summary failures must not remove a session from the list.

Fallback rules:

- If git probing fails but worktree identity is known, include project/worktree identity with `metricsAvailable = false`; numeric counts should be zero and ignored by the browser.
- If the worktree cannot be resolved, send the old minimal session summary with `worktree = nil`.
- The browser renders a minimal row when `worktree` is missing.
- The browser renders `changes unavailable` when identity exists but `metricsAvailable` is false.

## Web Rendering

Update `Alas/Resources/RemoteWeb/app.js` so `renderSessions` creates card rows:

- Title and status header.
- Worktree identity line when `s.worktree` exists.
- Metadata line computed from summary fields.
- Minimal legacy row when no worktree payload exists.

Update `Alas/Resources/RemoteWeb/style.css` to replace the current flat `.session-row` with mini-card styling:

- Keep rows as real `<button>` elements for mobile tap behavior.
- Use no nested cards; each session button is the card.
- Preserve safe-area and current dark theme tokens.
- Support long project/worktree/session names with ellipsis.

## Tests

Add focused tests:

- `RemoteProtocolTests` covers `RemoteSessionSummary` encoding and decoding with and without worktree summary payload.
- `RemoteSessionGatewayTests` covers async `listSessions` emission.
- Backend summary projection tests cover:
  - Commit count.
  - Changed file count.
  - Added/deleted line totals.
  - Conflict count.
  - Worktree resolution fallback.
  - Git metrics failure fallback.

If direct `AppState` testing becomes too heavyweight, factor the count/metadata projection into a small helper with injected inputs and test that helper directly.

Manual verification should include a static remote web sample or a local remote session list showing:

- Clean worktree.
- Commits only.
- Uncommitted changes only.
- Commits plus uncommitted changes.
- Conflicts.

Final implementation verification should use the project commands:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```
