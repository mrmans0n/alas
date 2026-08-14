# Remote Web Session Repository Ordering Design

## Context

The remote web UI renders one flat session list. It puts sessions backed by an open Alas tab before closed sessions, but otherwise preserves backend arrival order. Each resolved worktree summary already includes the repository display name, while the persisted ACP session row already tracks `updatedAt`. Neither a stable repository identity nor `updatedAt` is currently sent to the browser.

## Goals

- Separate sessions into repository sections.
- Order repository sections by their most recently updated session.
- Within each repository, show active sessions first and inactive sessions last, with each group ordered by most recent update.
- Keep unresolved sessions visible in an `Other` section at the bottom.

## Non-Goals

- No collapsing or filtering of repository sections.
- No visible relative activity timestamp.
- No backend-specific grouped response type.
- No change to the meaning of active: a session remains active when backed by an open Alas tab.

## Protocol

Extend `RemoteSessionSummary` with:

- `projectId: String?`, the stable `ProjectConfig.id` used for grouping.
- `updatedAt: Int64`, the persisted session update time in Unix seconds.

Decode missing values as `nil` and `0` respectively. This preserves compatibility with older payloads and lightweight test fixtures. The existing `worktree.projectName` remains the section's display label.

When AppState deduplicates multiple stored rows for the same remote session identity, the resulting summary uses the greatest `updatedAt` across every candidate. Repository identity comes from the resolved project associated with the session's worktree.

## Web Rendering and Ordering

`renderSessions` groups summaries before creating DOM nodes:

1. Sessions with a `projectId` and resolved worktree are grouped by `projectId`.
2. The group heading uses `worktree.projectName`.
3. Sessions without resolved repository data are grouped under `Other`.
4. Repository groups are sorted descending by their greatest session `updatedAt`.
5. `Other` is always last.

Within each group, sessions are sorted by:

1. Active before inactive.
2. `updatedAt` descending.
3. Title using a stable case-insensitive comparison.
4. Session ID as the final deterministic tie-breaker.

Each group renders as a section with a heading and its session rows. Because the heading already names the repository, a resolved row's identity line shows only the worktree name instead of repeating `projectName / worktreeName`. Existing status, active/closed treatment, metrics, rename, and open actions remain unchanged.

## Error Handling and Compatibility

Missing repository data is ordinary fallback behavior, not an error: the session appears under `Other`. A missing or legacy `updatedAt` becomes `0`, placing the session behind summaries with known activity while retaining deterministic tie-breaking.

The browser continues to accept `isActive` being absent as active, matching current behavior. No session is omitted because grouping metadata is unavailable.

## Tests

- Extend `RemoteProtocolTests` to cover encoding and decoding `projectId` and `updatedAt`, including absent-field defaults.
- Extend `RemoteAppStateAccessTests` to verify repository identity projection and that deduplicated summaries use the greatest candidate `updatedAt`.
- Extend `RemoteWebAssetTests` to require the repository grouping, section ordering, session ordering, `Other` fallback, and section styles.
- Bump the remote web asset URLs and service-worker cache version so installed PWAs receive the JavaScript and CSS changes.

Manual verification should cover two repositories with mixed active and inactive sessions, equal timestamps, and one unresolved session.

Final verification uses the project commands:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```
