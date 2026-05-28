# ACP Composer Draft Persistence Design

## Context

ACP composer text currently lives only inside the AppKit `NSTextView` used by
`ACPInputField`. Switching away from an ACP pane can tear down that view, and
returning to the pane creates a fresh text view with no saved draft. ACP
sessions and transcripts already persist through `ACPSessionStore`, so the
draft should be persisted as part of the ACP session rather than as transient
SwiftUI/AppKit view state.

## Goals

- Preserve unsent ACP composer contents when switching worktrees or tabs.
- Restore the draft when reopening the same ACP session after app restart.
- Preserve ordered text and `@mention` file chips so the restored composer
  displays the same prompt content and submits the same prompt attachments.
- Clear the persisted draft only after the prompt is accepted for sending.
- Keep drafts scoped to one ACP session and delete them when the session is
  deleted.

## Non-Goals

- Persist caret position, selection, undo history, slash-picker state, or focus.
- Persist generated markdown styling attributes. Styling can be regenerated from
  the literal text.
- Share one draft across different ACP sessions in the same worktree.

## Approach

Use `ACPSessionStore` as the source of truth for unsent ACP composer drafts.
Add a `composer_drafts` table keyed by `session_id`, with a JSON payload and an
`updated_at` timestamp. The table must reference `sessions(id)` with
`ON DELETE CASCADE` so deleting an ACP session also removes its draft.

The JSON payload must represent an ordered list of segments:

- `text`: plain composer text.
- `mention`: a file chip with `displayName` and `uri`.

This avoids flattening chips into plain text. It also lets the composer rebuild
an attributed string containing `ACPMentionChipAttachment` instances, so a
restored draft submits the same visible text and the same resource-link
attachments as before.

## Data Flow

1. `ACPSessionManager.openSession(id:)` loads the persisted draft from
   `ACPSessionStore` and assigns it to the `ACPSession`.
2. `ACPInputField` receives the session draft when it mounts and initializes
   the underlying `NSTextView` once, before the user starts editing.
3. On composer edits, the coordinator serializes the current attributed string
   to the draft payload and asks the manager/store to upsert it.
4. If the composer becomes empty, the stored draft is deleted.
5. On submit, the current extraction path still builds prompt text and
   attachments from the attributed string.
6. When `onSubmit` returns `true`, the text view is cleared and the stored draft
   is deleted. When `onSubmit` returns `false`, the text view and persisted
   draft remain intact.

## Components

### Draft Model

Add a small codable model near the ACP session code, for example
`ACPComposerDraft`, with segment cases for text and mention. Keep conversion
helpers close to the composer UI because they depend on AppKit attributed
string details.

### Session Store

Extend `ACPSessionStore` with:

- schema migration from version 1 to version 2;
- `loadComposerDraft(sessionId:)`;
- `upsertComposerDraft(sessionId:draft:updatedAt:)`;
- `deleteComposerDraft(sessionId:)`.

The migration must be idempotent and preserve existing databases.

### Session Manager

Expose narrow draft operations from `ACPSessionManager` so the UI does not
write to SQLite directly. Loading a session should populate the in-memory
draft. Clearing a sent draft should update both memory and persistence.

### Composer UI

`ACPInputField.Coordinator` serializes the attributed text on edits. It
rebuilds the attributed text from the stored draft on mount. Restoring happens
only once per text view instance so SwiftUI updates do not
overwrite active user typing.

## Error Handling

Draft persistence failures must not block typing or sending. The app should
best-effort save, mirroring existing ACP persistence behavior. If saving fails,
the live text remains in the composer for the current view lifetime.

If a stored draft payload cannot decode, ignore it and leave the composer empty.
This avoids breaking access to the ACP session because of a corrupt draft.

## Testing

Add focused Swift Testing coverage for:

- schema migration to version 2 on fresh and existing databases;
- draft upsert/load/delete round trip;
- draft deletion when the owning ACP session is deleted;
- manager `openSession` restoring an existing draft;
- manager clear operation removing the draft from memory and store;
- pure composer draft serialization for text plus mention-chip ordering using
  `NSAttributedString` and `ACPMentionChipAttachment`.

## Acceptance Criteria

- Typing in an ACP composer, switching to another worktree, and returning to
  the ACP pane restores the draft.
- Quitting and relaunching the app restores the same draft when the ACP session
  is reopened.
- `@mention` file chips survive restore and submit as attachments.
- Pressing send while the session is not ready keeps the draft.
- A successful send clears the composer and removes the persisted draft.
- Deleting an ACP session removes its stored draft.
