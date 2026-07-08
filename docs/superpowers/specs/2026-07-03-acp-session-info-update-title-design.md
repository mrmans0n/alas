# ACP Session Info Update Title Design

## Context

Claude's ACP adapter emits `session/update` notifications with
`sessionUpdate: "session_info_update"` near turn end. The payload may include a
generated session `title` and `updatedAt`.

Alas currently generates a provisional ACP session title from the first user
prompt and tracks title ownership with `ACPSessionTitleSource`:

- `.placeholder` for "New session"
- `.generated` for app-generated titles
- `.manual` for user-renamed sessions

Issue #613 requires Alas to decode the adapter notification and adopt the title
only while the user has not manually renamed the session.

## Goals

- Decode ACP `session_info_update` notifications with optional `title` and
  `updatedAt`.
- Apply non-empty adapter titles to sessions whose title source is not
  `.manual`.
- Persist accepted titles and mark them as `.generated`.
- Update matching ACP tab fallback titles so reopened tabs use the generated
  title.
- Ignore missing, empty, whitespace-only, archived, and manual-protected title
  updates.

## Non-Goals

- Do not parse or trust remote `updatedAt` for local persistence ordering.
  Decode it for protocol completeness, but keep using local persistence
  timestamps.
- Do not change manual rename behavior.
- Do not refactor ACP update routing beyond the title notification path.

## Protocol Model

Add an `ACPSessionInfoUpdate` payload with:

- `title: String?`
- `updatedAt: String?`

Extend `ACPSessionUpdate` with:

- `.sessionInfoUpdate(ACPSessionInfoUpdate)`

Decode wire updates where `sessionUpdate == "session_info_update"`. Missing
`title` is valid and decodes successfully. Malformed title values decode as
`nil` so the notification is ignored instead of dropping the whole update.

Encoding mirrors the payload for test symmetry, even though Alas does not emit
this notification.

## Runtime Behavior

Handle `.sessionInfoUpdate` in `ACPSessionRunner`, alongside other incoming ACP
updates. The runner already owns update consumption, write-lease checks, and
session-row persistence.

When a notification arrives:

1. Return without changing state if `title` is nil.
2. Trim whitespace and newlines.
3. Return without changing state if the trimmed title is empty.
4. Return without changing state if `session.titleSource == .manual`.
5. Attempt to persist the title with a store helper guarded by
   `title_source != 'manual'` and `archived = 0`.
6. On successful persistence, set the live session title to the trimmed title
   and set `titleSource = .generated`.
7. Call `onSessionTitleUpdated(trimmed)` so app-level glue can rename matching
   ACP tabs.
8. If persistence refuses the update because the stored row is now manual,
   reload the stored row and restore the live session title/source.

This allows adapter titles to replace both `.placeholder` and existing
`.generated` titles, including the first-prompt fallback title. It never
overwrites `.manual`.

## Persistence

Add this `ACPSessionStore` helper:

```swift
func updateGeneratedTitleIfNotManual(id: String, title: String, updatedAt: Int64) throws -> Bool
```

The SQL update should:

- set `title = ?`
- set `title_source = 'generated'`
- set `updated_at = ?`
- match `id = ?`
- require `archived = 0`
- require `title_source != 'manual'`

Keep the existing placeholder-only helper for the first-prompt fallback so that
local prompt-derived titles still only replace untouched placeholders.

## Tab Synchronization

Open tab rendering already prefers a live `ACPSession.title` through
`titleLookup`, falling back to `ACPSessionTabState.title`. Accepted adapter
titles must also update matching stored ACP tabs so fallback titles remain
correct after app restart or session eviction.

Keep `TabsManager` out of ACP session internals. Add an
`onSessionTitleUpdated: (ACPSession.ID, String) -> Void` callback to
`ACPSessionManager`, pass it into each `ACPSessionRunner` as a runner-local
`onSessionTitleUpdated: (String) -> Void`, and let app-level wiring call:

```swift
tabs.renameACPSessionTabs(worktreeId: manager.worktreeId,
                          sessionId: session.id,
                          title: trimmed)
```

The callback should also refresh recent session rows so sidebars and remote
session lists can observe the updated title.

## Error Handling

- Missing title: ignore.
- Whitespace-only title: ignore.
- Manual live title: ignore without touching storage.
- Manual stored title discovered during persistence: restore the live title and
  source from storage.
- Archived session: persistence returns false; do not update live title or tabs.
- Unknown ACP update kinds continue to decode as `.unknown`.

No user-facing error is needed. These notifications are opportunistic metadata.

## Tests

Add focused Swift Testing coverage:

- Protocol decode:
  - decodes title and `updatedAt`
  - decodes when title is absent
  - keeps unknown update handling unchanged
- Store:
  - updates `.placeholder` rows to `.generated`
  - updates `.generated` rows to `.generated`
  - refuses `.manual`
  - refuses archived rows
- Runner integration:
  - `ACPMockClient` `session_info_update` updates live title and persistence
  - generated title can replace first-prompt generated title
  - manual title is preserved
  - empty/whitespace title is ignored

Run relevant ACP protocol/session tests first, then the normal project build and
test commands when moving from implementation to completion.
