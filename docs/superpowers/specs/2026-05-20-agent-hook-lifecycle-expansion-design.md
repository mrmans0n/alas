# Agent Hook Lifecycle Expansion Design

Date: 2026-05-20
Status: Approved for implementation planning

## Goal

Expand Alas' agent hook support in two directions:

- richer normalized lifecycle events, so terminal status can distinguish work, permission prompts, session attachment, and session detachment;
- more built-in hook-capable agents, starting with Gemini, OpenCode, Pi, and Copilot after the existing Claude, Codex, and Cursor integrations are updated.

This design is informed by an audit of `superset-sh/superset` at commit `e344f27`. Superset's strongest pattern is its lifecycle taxonomy: it maps many native agent event names into a small set of app-level events, especially separating `SessionStart` / `SessionEnd` from per-turn work.

## Non-Goals

- Do not replace Alas' UNIX socket hook transport with HTTP.
- Do not add broad PATH wrapper management for every agent in the first implementation.
- Do not change the existing notification preferences or badge UI beyond what is necessary to represent the new states.
- Do not require every new agent to support every lifecycle event before it can be added.

## Normalized Lifecycle Model

Extend the current `ActivityEvent` / `ActivityState` model with these event meanings:

- `busy`: the agent is actively processing a user prompt or doing work.
- `awaiting_input`: the agent needs user-facing input, such as an ask-user-question flow.
- `idle`: the agent completed a turn.
- `permission_request`: the agent is blocked on tool, shell, MCP, patch, or approval permission.
- `attached`: an agent session is associated with an Alas terminal.
- `detached`: an agent session ended or detached from an Alas terminal.

`attached` and `detached` are session-binding signals, not work signals. They should not trigger "finished" notifications. `permission_request` can initially reuse the same user-facing notification pathway as `awaiting_input`, but it must remain distinct in the model and tests.

Unknown future native events should continue to be ignored successfully, preserving the current defensive behavior.

## Native Event Mapping

Add a small mapping layer that translates native hook event names to normalized Alas lifecycle events. Keep the mapping local to the harness domain rather than spreading equivalent decisions across each installer.

The initial alias set should include:

- Session attachment: `SessionStart`, `sessionStart`, `session_start`
- Session detachment: `SessionEnd`, `sessionEnd`, `session_end`
- Work start/progress: `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure`, `BeforeAgent`, `AfterTool`, `userPromptSubmitted`, `postToolUse`, `task_started`
- Permission/input needed: `PermissionRequest`, narrowed `Notification` matchers, `PreToolUse`, `preToolUse`, `exec_approval_request`, `apply_patch_approval_request`, `request_user_input`
- Work stop: `Stop`, `stop`, `AfterAgent`, `task_complete`, `agent-turn-complete`

Mappings should be tested as pure logic. Agent installers can still choose which native events they register, but once an event arrives the app should classify it through the shared mapper.

## Existing Agent Updates

### Claude

Keep the current high-signal Claude hooks for prompt submit, tool use, notification, and stop. Add `SessionStart` / `SessionEnd` only if the currently supported Claude hook schema emits them reliably enough to bind and clear terminal identity without false work states.

`PermissionRequest` should map to `permission_request` where supported. Existing `Notification` matchers for permission and idle prompts should continue to avoid broad false positives.

### Codex

Keep `UserPromptSubmit` and `Stop`. Add `SessionStart` / `SessionEnd` if Codex native hooks support them in the installed hooks format Alas already manages.

Codex approval-related events should map to `permission_request` if they become available through the current hooks surface. Do not depend on wrapper-only session log parsing for the first pass.

### Cursor

Extend Cursor hook registration beyond prompt/response/stop:

- `sessionStart` -> `attached`
- `sessionEnd` -> `detached`
- `beforeSubmitPrompt` -> `busy`
- `beforeShellExecution` -> `permission_request`
- `beforeMCPExecution` -> `permission_request`
- `stop` -> `idle`

Cursor's existing idle debounce should remain. Permission events should cancel pending idle debounce the same way `busy` and `awaiting_input` do.

## New Built-In Agents

### Gemini

Add Gemini hook support using its settings file if the current CLI hook schema supports it:

- `SessionStart` -> `attached`
- `SessionEnd` -> `detached`
- `BeforeAgent` -> `busy`
- `AfterTool` -> `busy`
- `AfterAgent` -> `idle`

The hook command must print whatever minimal valid response Gemini expects so it never blocks the agent loop. If that requirement cannot be satisfied with the same shell command envelope Alas uses today, Gemini should get a small agent-specific command script rather than forcing complexity into `AlasHookCommand`.

### OpenCode

Prefer OpenCode's plugin mechanism over global wrapper-only behavior. The plugin should activate only inside Alas terminals and should:

- emit `attached` and `detached` for root sessions;
- emit `busy` on root-session busy transitions;
- emit `idle` once per busy period on root-session idle/error;
- emit `permission_request` on permission ask events;
- filter child or subagent sessions where the OpenCode event data exposes parent/root session identity.

Do not write a global OpenCode plugin path if an Alas-scoped config path can avoid dev/prod or multi-instance conflicts.

### Pi

Add Pi hook support through its extension/plugin mechanism if available:

- session start/end -> `attached` / `detached`
- before agent start -> `busy`
- tool execution end -> `busy`
- agent end or session shutdown -> `idle`

The implementation should skip non-interactive/subagent contexts when Pi exposes a reliable UI/session flag. If that flag is absent, default to supporting interactive sessions and document the possible subagent flicker.

### Copilot

Add Copilot after the first three new agents unless its hook format proves simpler than expected. Copilot appears to rely on project-level hook files, so the implementation should avoid permanently dirtying repositories:

- write a dedicated managed hook file only when launching Copilot from an Alas terminal;
- add that hook file to `.git/info/exclude` when possible;
- preserve any existing project hook files;
- map session start/end, user prompt submit, post-tool-use, and pre-tool-use events into the normalized lifecycle.

## Installer Structure

Keep `AgentInstallerRegistry` explicit. Add installers one at a time rather than making every `AgentDefinition` automatically hook-capable.

Each installer should expose:

- the managed agent kind/id;
- the settings or plugin file it mutates, if any;
- a canonical event map used for install-state comparison;
- install, uninstall, and stale-managed-entry pruning behavior;
- tests covering preservation of user hooks and detection of outdated managed hooks.

If an agent requires a generated script or plugin file, that file should be versioned with a managed marker so future app versions can identify and replace stale entries without removing user-owned configuration.

## Data Flow

1. An agent-native hook fires.
2. The managed hook command or plugin emits a versioned Alas envelope through `ALAS_SOCKET_PATH`.
3. `AgentHookSocketServer` decodes the envelope and ignores unknown events successfully.
4. The shared mapper converts native names or already-normalized names to an Alas lifecycle event.
5. `HarnessService` updates session state:
   - `busy`: running state, cancel pending idle debounce;
   - `awaiting_input`: awaiting state and optional input notification;
   - `permission_request`: permission-needed state and optional attention notification;
   - `idle`: finished state and optional completion notification;
   - `attached`: bind agent/session identity without marking work;
   - `detached`: clear active binding and transient running/permission state.

## Error Handling

Hook failures must never break the agent command. All hook commands should remain best-effort and time-bounded.

Malformed hook envelopes should still return an error response where possible. Unknown but well-formed events should be acknowledged and ignored.

For settings files:

- invalid JSON should not be overwritten;
- user-owned hooks must be preserved;
- managed entries should be compared per event so stale placement is detected;
- managed entries from older Alas hook versions should be pruned by marker/path when possible.

## Testing

Add focused Swift Testing coverage for:

- native event mapping aliases;
- decoding new normalized events;
- `HarnessService` handling for `attached`, `detached`, and `permission_request`;
- no completion notification for `attached` or `detached`;
- permission events canceling Cursor idle debounce;
- installer install-state comparisons for new event placements;
- user hook preservation for each new installer;
- stale managed hook replacement for each generated settings/plugin file.

Manual verification should run the standard project checks:

```sh
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Manual agent smoke checks should cover Claude, Codex, Cursor, Gemini, OpenCode, Pi, and Copilot where installed locally.

## Rollout

Implement in reviewable slices:

1. Lifecycle model and mapper, with tests and no new agents.
2. Update Claude, Codex, and Cursor installers to use the richer lifecycle.
3. Add Gemini installer.
4. Add OpenCode installer/plugin.
5. Add Pi installer/extension.
6. Add Copilot project-hook support.

Each slice should leave the app usable if later agents are not installed on the user's machine.
