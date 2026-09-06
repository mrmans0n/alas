# Remote Web Changes and Files Design

## Context

The remote web client can drive sessions but cannot inspect the code those
sessions produce. It renders a session list grouped by repository, a transcript
with paging, a composer with queue and steer, permission/question/elicitation
sheets, session config, and worktree-plus-session creation. Reviewing what an
agent actually changed requires walking back to the Mac.

Comparable mobile harness clients (T3 Code) treat diff review and file browsing
as core surfaces. Alas already owns the pieces on the Swift side: `DiffParser`,
`FileTreeBuilder`, `ChangesTreeBuilder`, `GitIgnoreService`, `GitService`
status/diff/tree entry points, and `RemoteWorktreeSummaryBuilder`, which already
ships per-worktree changed-file and line counts over the wire. What is missing
is protocol surface and client views, not git plumbing.

`RemoteSessionSummary` carries a `RemoteWorktreeSummary` but no worktree id, so
the client can name a session but not a worktree. Client navigation is
imperative show/hide over `.view` sections with no router and no History API.
Pure client logic is conventionally extracted into standalone scripts
(`worktree-creation.js`, `session-ordering.js`) with node tests under
`scripts/tests/`, while `RemoteWebAssetTests` asserts script tag order, the
`sw.js` precache list, and `?v=` bumps.

## Goals

- Browse the changed files of a session's worktree, relative to its comparison
  ref, and read a per-file diff.
- Browse the worktree's file tree and read a file's contents.
- Keep both surfaces read-only and available to any paired device that can
  already see the session, without a writer lease.
- Refresh changed files when a turn ends, and on explicit request.
- Reuse the existing WebSocket transport, pairing, and test spine.

## Non-Goals

- No git mutations: no staging, discarding, committing, or pushing.
- No terminal.
- No turn-by-turn diff attribution, which would require per-turn tree snapshots
  Alas does not record.
- No syntax highlighting, client-side or server-side, in this version.
- No split diff view. The hunk payload keeps it available later.
- No editing of files.
- No change to the session-list badges. They keep their current meaning
  (`git status` counts plus a separate `commitCount`), and the Changes tab
  labels its own comparison ref and counts so each number is legible where it
  appears.

## Transport

All four features ride the existing WebSocket. `RemoteHTTPResponder` serves
static assets only and gains no data endpoints: adding an authenticated HTTP
path would duplicate the pairing and authorization story that
`RemoteAccessPolicy` already solves for the socket, and the payload caps below
keep frames far under the 16 MB `WebSocketFrame.maxPayloadLength`.

Requests key off `sessionId`, not a worktree id. The server resolves
`sessionId -> ACPSession -> worktree -> project`. This avoids widening
`RemoteSessionSummary` and confines a device to worktrees it can already see.

## Protocol

Four request/response pairs are added to `RemoteClientMessage` and
`RemoteServerMessage` in the existing hand-rolled `Codable` style, correlated by
natural key as `listBranches` -> `branchList` already is.

| Client message | Server response | Failure response | Correlation |
| --- | --- | --- | --- |
| `listChanges(sessionId)` | `changeList(sessionId, comparisonRef, metricsAvailable, files, truncated)` | `changeListFailed(sessionId, reason)` | `sessionId` |
| `fileDiff(sessionId, path)` | `fileDiffResult(sessionId, path, hunks, truncated)` | `fileDiffFailed(sessionId, path, reason)` | `sessionId` + `path` |
| `listFiles(sessionId, path?)` | `fileTree(sessionId, path?, nodes)` | `fileTreeFailed(sessionId, path?, reason)` | `sessionId` + `path` |
| `readFile(sessionId, path)` | `fileContents(sessionId, path, text, truncated)` | `fileUnavailable(sessionId, path, reason, byteSize?)` | `sessionId` + `path` |

`listFiles` with a nil `path` fetches the worktree root; a non-nil `path`
fetches one directory's children.

### Wire types

Lossy projections, not the git types themselves, so the wire format stays
independent of internal refactors:

- `RemoteChangedFile`: `path`, `status`, `add`, `del`, `conflict`, `renameFrom`.
- `RemoteDiffHunk`: `header`, `oldStart`, `newStart`, and `lines` of
  `{ kind, oldNumber, newNumber, text }` where `kind` is `context`, `add`, or
  `delete`.
- `RemoteFileNode`: `name`, `path`, `kind`, `badge`, `childrenState`,
  `isSubmodule`.

### Failure reasons

A single `RemoteFileAccessReason` string enum shared across the failure
messages: `sessionUnknown`, `worktreeUnavailable`, `pathRejected`, `notFound`,
`binary`, `tooLarge`, `gitFailed`. `gitFailed` carries a message string.
Decoding an unrecognized reason maps to a generic case so an older client keeps
working against a newer host.

## Server

### Provider methods

Four methods are added to `RemoteSessionsProvider` and implemented in the
`AppState` extension that already holds `remoteWorktreeSummary`:

```swift
func remoteChangeList(sessionId: String) async -> RemoteChangeListResult
func remoteFileDiff(sessionId: String, path: String) async -> RemoteFileDiffResult
func remoteFileTree(sessionId: String, path: String?) async -> RemoteFileTreeResult
func remoteFileContents(sessionId: String, path: String) async -> RemoteFileContentsResult
```

Each resolves the session and its worktree first and returns
`sessionUnknown` or `worktreeUnavailable` when that fails. Each is `@MainActor`
at the entry point and immediately awaits `GitService`'s process-backed calls,
matching `remoteWorktreeSummary`.

### Git work

- **Changed files vs base.** `commitsAhead(at:baseBranch:resolution:)` supplies
  `comparisonRef`, using the same resolution `remoteWorktreeSummary` already
  uses, so the tab and the badges agree on which base. Tracked changes come from
  a new base-relative numstat (`git diff --numstat <ref>`); untracked entries
  come from `status(worktreePath:)`. Results are merged per path and sorted by
  path.
- **Per-file diff.** A new `GitService.diff(worktreePath:againstRef:file:)`,
  sibling to the existing `diff(worktreePath:sha:file:)` and
  `diffAgainstHEAD(...)`, returning `ParsedDiff`. Untracked files diff against
  `/dev/null`.
- **File tree.** `fileTree(worktreePath:statusEntries:)` for the root and
  `fileTreeChildren(worktreePath:path:)` for lazy expansion. Both already fold
  in `.gitignore` visibility; nodes whose visibility is `ignored` or `excluded`
  are filtered at the wire boundary.
- **File read.** Bytes are read from disk under the cap below, with
  `GitService.looksBinary` deciding the `binary` reason before any decode.

### Caps

Server-enforced and always reported, never silently applied:

- File read: 512 KB. Over the cap returns `tooLarge` with `byteSize` so the
  client can name the actual size.
- Per-file diff: 2,000 lines. Beyond it hunks are truncated and `truncated` is
  true. Binary files short-circuit to `binary` before diffing.
- Change list: 500 files, truncated with a count.

### Load discipline

Requests are deduplicated per `(sessionId, path)` while one is in flight, and
the idle-triggered refresh is debounced, so a session flipping repeatedly
between streaming and idle cannot queue a pile of `git diff` runs. There is no
server-side caching in this version.

## Security

1. Every incoming `path` is canonicalized with symlinks resolved and must
   resolve under the resolved worktree root. Absolute paths, `..` traversal, and
   symlinks escaping the tree return `pathRejected`.
2. `.git` is excluded from both the tree and `readFile`. A worktree's git config
   can hold remote URLs with embedded credentials.
3. These operations are read-only and require no writer lease. A device that can
   see a session can browse its diffs without taking over. This is a deliberate
   widening relative to the drive-gated commands, and it holds only because no
   mutation is in scope.

## Client

### Navigation

The detail header gains a segmented control: **Chat | Changes | Files**. It
renders only when the open session's summary has a non-null `worktree`;
worktree-less sessions keep the current layout. Two sections join `#transcript`
as siblings: `#changes` and `#files`. The composer and drivebar are already
children of `#transcript` and therefore hide with the Chat tab.

The subscription stays alive across tabs, so returning to Chat is instant and
the client keeps receiving `transcriptDelta.streamingState`.

List-to-detail within a tab is a second level, tracked by an explicit
`{ tab, path }` stack that the existing `‹` button consults: diff or viewer back
to the tab's list, then back to Sessions. No History API is introduced.

Per-session state (change list, fetched diffs, expanded directories, active tab)
is cleared in `openSession` and `showSessions` alongside `messages` and
`messageNodes`, so switching sessions cannot show another worktree's files.

### Changes tab

A header line shows the comparison ref and totals (`vs origin/main · 7 files ·
+214 −31`) with a refresh button. Below it, a flat, path-sorted file list with
the directory prefix dimmed, the basename emphasized, and the status letter plus
± counts trailing. Flat rather than a tree: expand/collapse costs taps and buys
little for the list sizes this serves, and `ChangesTreeBuilder` remains
available if that proves wrong.

Conflicted files carry a distinct marker. `metricsAvailable: false` renders an
explanatory empty state rather than a misleading zero.

### Diff view

Tapping a file opens a full-screen unified diff for that path: hunk headers as
sticky separators, one row per line with old and new line numbers and add/delete
backgrounds, horizontal scroll for long lines, and a truncation footer when
`truncated` is set.

### Files tab

A lazy tree. Directories render collapsed; expanding issues
`listFiles(sessionId, path)`. `RemoteFileNode.badge` marks changed files inline
so the two tabs cross-reference visually. Tapping a file opens the viewer:
monospace text, line numbers, horizontal scroll, and a placeholder card for
binary or over-cap files.

### Refresh

The change list is fetched when the Changes tab opens, on the explicit refresh
control, and when `streamingState` transitions to `idle` while the tab is open.
The last of these is entirely client-side; the server holds no per-tab state and
gains no push machinery.

### Errors

Every failure response renders an inline card naming the reason. No path
produces a silently empty list.

### File layout

Pure logic goes into two new scripts loaded before `app.js`:

- `changes-view.js`: change-list sorting and merging, diff row model, ±
  aggregation, truncation labels.
- `file-browser.js`: tree node merge, lazy-children bookkeeping, path
  formatting.

DOM wiring and event handlers land in `app.js`. Each new script requires a
script tag in `index.html`, an entry in the `sw.js` precache list, `?v=` bumps,
and matching `RemoteWebAssetTests` assertions.

## Testing

- `RemoteProtocolTests`: round-trip encode/decode for all twelve new messages
  (four client requests, eight server responses), including forward
  compatibility for an unrecognized failure reason.
- `RemoteSessionGatewayTests`: dispatch for each request, every failure path,
  and path rejection cases against the existing fake provider.
- `RemoteAppStateAccessTests`: the four new provider methods.
- `scripts/tests/remote-web-changes` and `scripts/tests/remote-web-file-browser`:
  node tests for the two extracted scripts.
- `RemoteWebAssetTests`: script tags, ordering, `sw.js` precache, `?v=` bumps.

## Open Questions

None. Split diff, syntax highlighting, git mutations, and a terminal are
deferred by choice and recorded as non-goals.
