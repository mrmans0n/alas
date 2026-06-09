# Remote Session Rename Design

## Goal

Allow a paired Alas Remote client to rename ACP sessions from both the remote
sessions list and an open session detail screen. The rename is cosmetic, so it
does not require taking over the session writer lease.

## Current Context

The remote UI is the bundled web client in `Alas/Resources/RemoteWeb`. It
communicates with the Mac app through `RemoteClientMessage` and
`RemoteServerMessage`, handled by `RemoteSessionGateway`.

Native ACP session renaming already exists:

- `ACPSessionManager.renameSession(id:title:source:)` updates the live session
  and persisted session row.
- `TabsManager.renameACPSession(worktreeId:tabId:title:)` updates persisted tab
  title state.
- `AppState.renameACPSessionTab` uses both paths and marks the session title as
  `.manual`, preventing generated titles from overwriting the user rename.

Remote renaming will reuse these semantics.

## User Experience

### Sessions List

Each remote session row gets a compact edit action beside the status. Tapping
the row still opens the session. Tapping edit stops row navigation and opens the
rename sheet.

### Session Detail

The detail header shows the current session title and a compact edit action.
This gives users a rename path while reading or driving a session without
returning to the list.

### Rename Sheet

Both entry points use the same sheet:

- Text input seeded with the current title.
- `Rename` and `Cancel` actions.
- Submit trims leading and trailing whitespace.
- Empty-after-trim titles are not sent.

The sheet is intentionally lightweight and does not expose writer/takeover
state because renaming is cosmetic.

## Protocol

Add a client message:

```swift
case renameSession(sessionId: String, title: String)
```

Wire shape:

```json
{ "type": "renameSession", "sessionId": "...", "title": "..." }
```

Add a server message:

```swift
case sessionRenamed(sessionId: String, title: String)
```

Wire shape:

```json
{ "type": "sessionRenamed", "sessionId": "...", "title": "..." }
```

`sessionRenamed` keeps detail-screen title sync focused and avoids overloading
`sessionConfig`, which is about model, mode, auto-run, and capabilities.

## Server Flow

1. `RemoteSessionGateway.handle(.renameSession)` trims the title.
2. If the trimmed title is empty, the gateway ignores the request.
3. The gateway calls `RemoteSessionsProvider.renameSession(for:title:)`.
4. On success, the gateway sends `sessionRenamed` to the connection and
   refreshes the session list.
5. On unknown session or failed rename, the gateway sends `error`.

No writer lease check is performed. A paired client already has access to read
the session transcript, and title changes are low-risk cosmetic state.

## Provider Flow

Extend `RemoteSessionsProvider`:

```swift
func renameSession(for id: String, title: String) -> Bool
```

`AppState` implementation:

1. Find the owning `ACPSessionManager` by live session or stored session row.
2. If the session is not live, materialize it with `mgr.placeholderSession(id:)`
   so the existing manager rename path can update both in-memory and persisted
   session state.
3. Call `mgr.renameSession(id:title:source: .manual)`.
4. Update every open ACP tab whose `ACPSessionTabState.sessionId` matches the
   renamed session.
5. Return `true` only when the title was applied.

The tab update will be implemented as a small helper on `TabsManager` that
renames ACP session tabs by `sessionId`, avoiding duplicated tab traversal in
`AppState`.

## Data Consistency

The source of truth remains the ACP session row. Open tabs mirror the title for
tab display and persistence, matching native behavior. Generated title updates
must not overwrite a remote rename because the rename is stored with
`ACPSessionTitleSource.manual`.

Concurrent renames use last-writer-wins behavior. This is acceptable for a
cosmetic title field and keeps the protocol simple.

## Error Handling

- Empty titles: ignored client-side and server-side.
- Unknown session: gateway sends `error`.
- Session owned by a mirror that cannot rename due to manager lease rules:
  provider returns `false`; gateway sends `error`.
- The web UI keeps the draft in the sheet if an error is received while the
  rename sheet is open.

## Testing

Add Swift Testing coverage for:

- `RemoteClientMessage.renameSession` encoding and decoding.
- `RemoteServerMessage.sessionRenamed` encoding and decoding.
- Gateway handling does not require `isWriter`.
- Gateway trims titles and ignores empty titles.
- Gateway sends `sessionRenamed` and refreshes `sessionList` after success.
- AppState/provider rename updates ACP session title as manual and keeps open
  ACP tab titles in sync.
- TabsManager helper updates matching ACP session tabs and ignores unrelated
  tabs.

For the web client, add or extend remote asset tests where existing coverage
supports it:

- The remote bundle contains rename controls/sheet elements.
- The client sends `renameSession` from both list and detail paths.

## Out of Scope

- Renaming terminal sessions from Alas Remote.
- Permission or writer-lease enforcement for title changes.
- Multi-client conflict UI.
- Bulk rename.
