# Remote Web New Session Design

## Goal

Allow a paired remote web client to create a new ACP session without touching the Mac first. The remote user chooses a worktree, chooses an ACP-capable agent, creates an empty session, and lands in the transcript composer. The Mac app also opens and activates the matching ACP tab so the same session is ready for handoff when the user returns to the computer.

## Existing Context

Alas already serves a paired RemoteWeb client over the local `RemoteServer`. The browser authenticates through pairing, then uses a WebSocket protocol handled by `RemoteSessionGateway`.

The current remote protocol can list existing sessions, subscribe to a transcript, rename a session, take over the writer lease, send prompts, stop a turn, and change session config. Existing session summaries can include `RemoteWorktreeSummary` metadata.

Native session creation currently lives in `AppState.openNewACPSession(agentID:initialPrompt:)`, which creates an `ACPSession` for the selected worktree and appends a native ACP tab. The ACP runner is attached by `ACPTabView` when the tab appears, so remote-created sessions need an explicit attach path if they must be usable from the phone immediately.

## Decisions

- The remote creation flow chooses the target worktree explicitly.
- The remote creation flow chooses the agent explicitly.
- The agent list is limited to enabled ACP-capable agents.
- The native ACP default is preselected in the remote agent picker when available.
- The session is created empty; the first prompt is composed in the normal transcript view.
- Creating the session from remote opens and activates the corresponding Mac worktree/tab.
- Creating the session also starts ACP attach immediately so the phone can send the first prompt without waiting for the Mac UI lifecycle.
- The implementation extends the existing WebSocket protocol rather than adding REST endpoints.

## Protocol

Add remote protocol models:

- `RemoteWorktreeOption`
  - `id`
  - `projectName`
  - `worktreeName`
  - `branch`
  - `path`
  - `metricsAvailable`
  - `comparisonRef`
  - `commitCount`
  - `changedFileCount`
  - `addedLines`
  - `deletedLines`
  - `conflictCount`
- `RemoteAgentOption`
  - `id`
  - `name`
  - `isDefault`

Add client messages:

- `listWorktrees`
- `listAgents`
- `createSession(worktreeId: String, agentId: String)`

Add server messages:

- `worktreeList(worktrees: [RemoteWorktreeOption])`
- `agentList(agents: [RemoteAgentOption])`
- `sessionCreated(session: RemoteSessionSummary)`
- `createSessionFailed(message: String)`

The gateway should keep `listSessions` separate from creation metadata. Session list refresh remains about browsing existing sessions; the create sheet asks for worktrees and agents when it opens or needs refreshed data.

## Provider And AppState

Extend `RemoteSessionsProvider` with creation metadata and creation actions:

- `remoteWorktrees() async -> [RemoteWorktreeOption]`
- `remoteAgents() -> [RemoteAgentOption]`
- `createRemoteSession(worktreeId: String, agentId: String) async -> RemoteCreateSessionResult`

`RemoteCreateSessionResult` has two cases:

- success with `RemoteSessionSummary`
- failure with the user-facing error message for `createSessionFailed`

`AppState.remoteWorktrees()` returns all visible worktrees across all projects. Rows are grouped by project in the web UI, but the provider returns a flat list so the client can search and group locally. Hidden, deleting, and failed/deleted worktrees are excluded through the existing visible-worktree APIs. Each row attempts the same git status and commit-ahead summary used by existing remote session worktree metadata; failures keep the row visible with `metricsAvailable == false`.

`AppState.remoteAgents()` returns enabled agents that have an `ACPLaunchCatalog` spec. It marks the native ACP default as `isDefault` when that default is present in the filtered list.

`AppState.createRemoteSession(worktreeId:agentId:)`:

1. Resolves the visible target worktree.
2. Validates that the agent is enabled and ACP-capable.
3. Gets or creates the worktree's `ACPSessionManager`.
4. Creates a new empty ACP session with the configured auto-run default.
5. Switches `selectedWorktreeId` to the target worktree.
6. Appends and activates a native ACP tab for the session.
7. Starts `manager.attach(to:freshlyCreated:)` for the new session immediately.
8. Returns a success result containing `RemoteSessionSummary` with worktree metadata, or a failure result with one of the defined create-session error messages.

The attach task may still be running when `sessionCreated` is sent. The remote client should subscribe immediately and render the same connecting, setup, auth, or ready states used for existing sessions.

## Remote Web UI

Add a compact `+ New` action on the sessions screen header. Tapping it opens a bottom sheet with two steps:

1. Worktree picker
   - Shows all visible worktrees across all projects.
   - Supports search by project, worktree name, branch, and path.
   - Groups or labels rows by project.
   - Shows branch/path and available clean/changed/conflict metrics.

2. Agent picker
   - Shows enabled ACP-capable agents only.
   - Preselects the default ACP agent when present.
   - Allows changing the selection.
   - The primary action creates the session.

On success:

- Close the sheet.
- Merge or refresh the returned session into the session list.
- Open the transcript screen for the created session.
- Send `subscribe` for that session.
- Let existing transcript/config rendering show the attach progress and composer state.

The remote web flow does not include an initial-prompt field. Attachments, model/mode selection, auto-run, prompt submission, and stop all remain in the transcript view.

## Error Handling

Creation errors are surfaced in the create sheet:

- No visible worktrees: show an empty state in the worktree step.
- No enabled ACP-capable agents: show an empty state in the agent step.
- Worktree disappeared or became hidden before submit: `createSessionFailed("Worktree is no longer available.")`.
- Agent disappeared, was disabled, or is no longer ACP-capable before submit: `createSessionFailed("Agent is no longer available.")`.
- Unexpected session creation failure: `createSessionFailed("Could not create session.")`.

Agent setup/auth failures after the session row is created are not creation failures. The remote should still open the transcript, where the existing ACP setup/auth state can explain and recover from the problem.

## Tests

Add focused Swift Testing coverage:

- `RemoteProtocolTests`
  - Round-trip `listWorktrees`, `listAgents`, `createSession`, `worktreeList`, `agentList`, `sessionCreated`, and `createSessionFailed`.
  - Preserve existing message decode behavior.

- `RemoteSessionGatewayTests`
  - `listWorktrees` emits provider worktrees.
  - `listAgents` emits provider agents.
  - successful `createSession` emits `sessionCreated`.
  - failed creation emits `createSessionFailed`.
  - creation does not block unrelated subscribe/list operations longer than the provider call requires.

- `RemoteAppStateAccessTests`
  - creating remotely selects the target worktree.
  - creating remotely appends and activates a native ACP tab.
  - creating remotely returns a summary with worktree metadata.
  - hidden/missing worktrees are rejected.
  - disabled, missing, or non-ACP agents are rejected.

- Remote web asset/static tests
  - Bundle includes the new controls.
  - JS contains the new message type strings and success/failure handlers.

Manual verification:

1. Pair the remote web client.
2. Tap `+ New`.
3. Pick a worktree and agent.
4. Confirm the phone lands in the new transcript.
5. Confirm the Mac app switches to the same worktree and opens the ACP tab.
6. Send the first message from the phone.

## Out Of Scope

- Creating new worktrees from the remote web.
- Creating terminal sessions from the remote web.
- Sending an initial prompt as part of the create sheet.
- Adding unauthenticated HTTP creation endpoints.
- Remote editing of agent definitions or project settings.
