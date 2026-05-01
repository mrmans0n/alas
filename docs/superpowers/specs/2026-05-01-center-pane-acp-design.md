# Center Pane ACP Support Design

Date: 2026-05-01

## Goal

Add Agent Client Protocol (ACP) support to Alas as a first-class center-pane tab. The new Agent Chat tab lets users configure installed ACP providers, authenticate them from Alas, create and resume durable agent sessions, send prompts, view streamed transcript/tool updates, and service ACP filesystem and terminal callbacks.

The first implementation should establish the full contracts needed for Claude, Codex, OpenCode, and other ACP-compatible providers, while keeping provider installation, update, and registry management out of scope.

## Context

Previous research in commit `0d5047c80b6ceb6720594ee8be3bf44d8c8ef9b9` found that ACP support is feasible but should be implemented as a center-tab surface rather than layered onto terminal state. Since that research, Alas already has a generic center tab model with Terminal, File, and Markdown content. ACP should extend that model with Agent Chat content.

Relevant current code areas:

- `src/app/workspace.rs`: `WorkspaceTab`, `WorkspaceTabKind`, `WorkspaceTabContent`, tab lifecycle.
- `src/ui/workspace.rs`: center workspace tab bar and `+` action.
- `src/ui/shell.rs`: active tab routing and terminal/file/markdown pane selection.
- `src/terminal/*`: existing terminal process and Ghostty rendering infrastructure.
- `src/config/*`: global app config and repository config persistence.

## Scope

### In scope

- Add an Agent Chat center tab kind.
- Add global manual ACP provider configuration.
- Add provider settings and in-app auth surfaces.
- Store provider credentials in OS secure storage only.
- Launch configured providers as ACP stdio subprocesses.
- Implement the ACP lifecycle: initialize, authenticate, session creation, session load/resume, prompt, cancel, and streamed updates.
- Implement core client callbacks:
  - `session/request_permission`,
  - filesystem read/write callbacks,
  - terminal create/output/wait/kill/release callbacks.
- Use protocol-only terminal command execution in the first implementation.
- Persist local chat metadata, transcript snapshots, drafts, debug metadata, and ACP session ids.
- Require durable ACP resume for continued prompting after app restart.
- Fall back to read-only local transcript display when a provider cannot resume a restored session.
- Add configurable trust modes with **Allow Everything** as the default across the whole machine.

### Out of scope

- ACP registry integration.
- Provider installation or update management.
- Full provider-specific install flows for Claude, Codex, or OpenCode.
- Editor buffer integration or unsaved-file semantics.
- Ghostty-backed interactive ACP terminals in V1.
- Diff/editor review surfaces beyond transcript/tool-call rendering.

## Product Decisions

- Provider support targets multiple ACP providers equally from day one, but providers must already be installed.
- Manual providers live in global app config first.
- New Agent Chat tabs are created from the existing `+` tab control through a Terminal vs Agent Chat picker.
- The default Agent Chat layout is a single vertical chat surface.
- Terminal callbacks are protocol-only in V1, with interfaces designed for future Ghostty-backed terminal tabs.
- Persistence is local, but continuing an old session requires ACP session load/resume success.
- If resume is unsupported or fails, Alas shows the transcript read-only and disables the composer.
- Trust mode defaults to Allow Everything for filesystem and terminal callbacks across the whole local machine.
- Credentials and tokens are stored only through OS secure storage, such as macOS Keychain or the platform credential store.

## Architecture

ACP is added as a new center-tab content type, not as a terminal feature.

### Workspace tab model

Extend the workspace model with Agent Chat state:

- `WorkspaceTabKind::AgentChat`
- `WorkspaceTabContent::AgentChat(AgentThreadState)`

`AgentThreadState` should track:

- provider id,
- ACP session id when available,
- selected worktree path,
- title,
- lifecycle status,
- transcript entries,
- plan state,
- tool-call state,
- pending permission decisions,
- advertised slash commands,
- advertised modes/models/config options,
- composer draft,
- resume capability/result,
- bounded redacted debug log metadata.

Terminal-specific state and mutations must continue to reject non-terminal tabs. Mixed-tab behavior should remain consistent for selecting, moving, and closing tabs.

### Provider configuration

Add global app-level provider definitions. A provider definition includes:

- stable id,
- display name,
- command,
- args,
- non-secret env values or secure-store references,
- working-directory policy,
- enabled flag,
- default trust mode,
- optional provider metadata such as known provider kind.

Config files must not store secrets. They may store secure credential keys or metadata needed to retrieve secrets from the OS credential store.

### ACP runtime layer

Introduce an ACP runtime module that owns protocol integration:

- provider subprocess launch over stdio,
- JSON-RPC/ACP connection using the official Rust `agent-client-protocol` crate where practical,
- initialization and capability negotiation,
- auth orchestration,
- session new/load/resume,
- prompt/cancel,
- streamed `session/update` handling,
- client callback dispatch,
- debug logging.

Separate provider process/connection state from user-visible thread state. A provider connection may fail or restart while the local Agent Chat tab retains transcript and recovery information.

### Credential store adapter

Add an abstraction for OS secure storage. The first implementation should support the host platform needed for development, and expose clear errors when secure storage is unavailable.

The adapter stores and retrieves secrets by provider id and auth field. The app config stores only the reference metadata.

### Callback services

Callback handling is split into explicit services:

- permission policy service,
- filesystem callback service,
- protocol-only terminal callback service.

The terminal callback service should expose internal command handles and streamed output events. This keeps Agent Chat state independent from the V1 execution backend and leaves room for replacing command execution with Ghostty-backed terminal tabs later.

### Persistence store

Persist local Agent Chat records separately from transient runtime connections. Persisted records include:

- tab id or stable thread id,
- provider id,
- worktree path,
- ACP session id,
- title,
- transcript snapshot,
- draft text,
- last known lifecycle state,
- resume status,
- redacted debug/error metadata.

A persisted tab is not considered live until the provider reconnects and ACP resume succeeds.

## UI and User Flow

### New tab flow

The existing `+` workspace tab button opens a small picker with at least:

- Terminal,
- Agent Chat.

Selecting Agent Chat opens a provider picker when multiple enabled providers exist. If no providers exist, Alas opens provider settings with an empty-state explanation.

### Provider settings

A global provider settings surface supports daily manual provider use:

- add provider,
- edit provider command/args/env metadata,
- remove provider,
- enable/disable provider,
- select trust mode,
- view auth status,
- run auth actions,
- view recent provider errors/debug log.

Provider installation and updates are intentionally deferred.

### Authentication UX

Alas supports in-app auth surfaces for ACP-advertised auth methods and provider metadata:

- **Agent-handled auth**: call the provider's ACP auth method and show provider-supplied instructions/status.
- **Env-var auth**: collect required values in Alas, store secrets in OS secure storage, restart the provider with injected env, and retry auth.
- **Terminal auth**: run the provider's setup/login flow from Alas when the provider advertises terminal auth support.

Provider-specific polish for Claude, Codex, and OpenCode can be implemented behind the same auth interface. The design does not require install/update flows.

### Agent Chat tab

The tab is a single vertical chat surface:

- compact header with provider name, session status, auth/resume state, and advertised mode/model/config selectors,
- scrollable transcript,
- visible user messages,
- streamed agent message chunks,
- thoughts when available,
- plans,
- tool-call cards,
- permission decisions,
- errors,
- bottom composer with draft, Send, and Cancel while running,
- debug log accessible from the tab/provider UI but hidden by default.

### Resume UX

On app restart, persisted Agent Chat tabs reappear.

- If ACP resume succeeds, transcript is restored and composer is enabled.
- If ACP resume fails or the provider does not support durable resume, transcript remains visible but composer is disabled with a clear read-only message.
- The user may start a new session from the read-only tab.

## Data Flow and ACP Lifecycle

### Provider launch

1. Resolve global provider config.
2. Resolve non-secret env values and secure-store secrets.
3. Start the provider subprocess over stdio.
4. Use the selected worktree as workspace root or cwd according to provider policy.
5. Attach redacted lifecycle/debug logging.

### Initialize

Send ACP `initialize` with Alas client info and supported capabilities, including filesystem callbacks, terminal callbacks, permission handling, and terminal auth support when implemented.

### Authenticate

1. Inspect provider auth status and advertised methods.
2. Route missing auth through the in-app auth UI.
3. Store required secrets only in OS secure storage.
4. Restart and reinitialize the provider when env-var auth changes process environment.

### Session setup

- For new chats, call `session/new`.
- For restored chats, prefer `session/load` or `session/resume` according to provider capability.
- Register local thread state before load/resume completes so replayed updates attach to the correct tab.

### Prompt turn

1. User sends composer text through `session/prompt`.
2. Stream `session/update` notifications into transcript, tool-call, plan, mode, and config state.
3. While running, `Cancel` calls `session/cancel` and marks the local turn interrupted.

### Client callbacks

- `session/request_permission` consults the configured trust mode. The default Allow Everything mode approves without prompting across the whole machine.
- Filesystem read/write callbacks operate on disk paths after policy approval.
- Terminal callbacks run background protocol-only commands in V1 and stream output/status into tool-call cards.
- Terminal callbacks expose command handles that support output, wait, kill, and release semantics.

### Persistence

After meaningful thread changes, persist local metadata and transcript snapshots. Do not persist live connection state. After restart, restored tabs must reconnect to the provider and resume through ACP before accepting new prompts.

## Error Handling and Safety

### Provider errors

Startup failure, stdio disconnect, invalid JSON-RPC, and protocol errors put the tab in a recoverable failed state with actions:

- Retry,
- Edit Provider,
- View Debug Log.

### Auth errors

Auth errors show provider-supplied instructions when available. Env-var auth validates required fields before restart. Secrets remain in OS secure storage and are redacted from logs.

### Resume errors

Resume errors preserve local transcript history, disable the composer, and label the session read-only unless the user starts a new session.

### Callback errors

- File read/write errors return ACP errors and append transcript/debug entries.
- Terminal command failures include exit status and captured output.
- Callback failures should not crash the app or corrupt unrelated tabs.

### Trust modes

The policy model should support at least:

- Allow Everything,
- Ask,
- Worktree-only,
- Deny.

The chosen default is Allow Everything across the whole machine. Even when a callback is auto-approved, file and terminal side effects must be visible in transcript/tool-call cards.

### Debug logging

Each provider/thread stores a bounded redacted debug log containing lifecycle events, protocol method names, errors, and redacted parameters. Logs must not include secrets, tokens, or raw secure env values.

## Testing Strategy

### Workspace model tests

- Agent Chat tabs coexist with Terminal/File/Markdown tabs.
- Tab selection, closing, moving, and fallback behavior work across mixed tab kinds.
- Terminal-specific mutations reject Agent Chat tabs.

### Provider config tests

- Global provider config serializes and deserializes.
- Secrets are not written to config files.
- Trust mode defaults to Allow Everything.
- Secure-store references remain stable across provider edits.

### ACP runtime tests

Use fake ACP providers where possible.

- Lifecycle transitions: uninitialized, auth needed, ready, running, failed.
- New session vs load/resume behavior.
- Resume failure produces read-only transcript state.
- Streamed updates append to transcript/tool/plan state.
- Cancel maps to ACP cancellation and local interrupted state.

### Callback tests

- Allow Everything auto-approves permission requests.
- Filesystem read/write callbacks handle success and disk errors.
- Protocol-only terminal callbacks stream output, report exit status, and support kill/release.
- Callback errors are scoped to the active tool call/thread.

### UI/view-model tests

- Provider empty state.
- Provider auth states.
- Agent tab failed state.
- Read-only resume-failed state.
- Running/cancel state.
- Transcript/composer updates.

## Manual Acceptance

The first implementation is accepted when a user can:

1. Add a global provider for an already installed ACP agent.
2. Authenticate it from Alas using a supported in-app auth flow.
3. Open `+ → Agent Chat`.
4. Send prompts and see streamed transcript/tool/plan updates.
5. Let the agent perform filesystem and terminal callbacks under Allow Everything.
6. Restart Alas.
7. See existing chats restored.
8. Continue restored chats only when ACP resume succeeds.
9. Use provider settings/auth UI comfortably for daily manual provider use.

## Risks and Mitigations

- **Provider auth variability**: use an auth-method abstraction and keep provider-specific behavior behind it.
- **Durable resume variability**: make unsupported resume explicit and safe by restoring transcript read-only.
- **Powerful default trust mode**: document Allow Everything clearly and keep policy hooks for safer modes.
- **External process opacity**: add redacted debug logging early.
- **Terminal callback complexity**: start with protocol-only execution but keep backend boundaries clear for future Ghostty integration.
- **Large UI surface**: keep Agent Chat as one vertical surface and avoid split/diff/editor UI in this subproject.

## References

- Research commit: `0d5047c80b6ceb6720594ee8be3bf44d8c8ef9b9`.
- ACP docs: initialization, session setup, prompt turn, tool calls, filesystem, terminals, Rust library.
- ACP RFD: authentication methods.
- Zed external-agent architecture patterns noted in prior research.
