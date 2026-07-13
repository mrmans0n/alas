# ACP Question Notification Design

## Context

ACP sessions already model agent questions as `ACPQuestionRequest` values. When a request arrives, `ACPSessionRunner.awaitQuestionResponse(_:)` sets the transcript state to `.awaitingInput`, stores `transcript.pendingQuestion`, and waits for the native or remote UI to answer it.

Alas already has macOS notifications for harness lifecycle events through `NotificationService`, including "needs input", "needs permission", and "finished". ACP activity is mirrored into `HarnessService` by `ACPHarnessBridge`, but that bridge intentionally has no notification side effects.

## Goals

- Notify the user when an ACP agent asks a question or elicitation.
- Show the notification even when Alas is foregrounded.
- Keep the notification clickable with the existing project, worktree, and session routing metadata.
- Avoid duplicate notifications for the same question request.
- Reuse existing notification infrastructure without turning generic ACP activity bridging into a notification source.

## Non-Goals

- Do not add a new settings toggle. ACP question notifications use the existing `config.harness.notifyOnAwaiting` setting.
- Do not add cancellation or resolved notifications.
- Do not change the native or remote question-answer UI.
- Do not route ACP question notifications through socket-driven harness events.

## Behavior

When an ACP client receives a question request, Alas posts a macOS notification after the pending question is installed on the session. The notification appears even if Alas is foregrounded, using the existing `NotificationDelegate.willPresent` behavior.

Notification copy:

- Title: `"<Agent display name> has a question"`.
- Body: prefer `ACPQuestionRequestParams.title`, then the first non-empty question prompt, then `"Session is waiting for an answer."`.

Clicking the notification uses the same `projectId`, `worktreeId`, and `sessionId` metadata as the current harness notifications, so it opens the existing project/worktree/session route.

A single ACP question request posts at most one notification for the lifetime of the runner. A new request id may notify again.

## Architecture

Add a dedicated ACP question notification path near the source event:

1. `NotificationService` gets a new `notifyACPQuestion(agent:body:projectId:worktreeId:sessionId:requestId:)` method.
2. The method reuses the existing private content builder, default sound, userInfo click-through metadata, and logo attachment support.
3. The notification request identifier is question-specific, for example `"<sessionId>-question-<requestId>"`, where `requestId` is the JSON-RPC id rendered through a stable string helper.
4. `ACPSessionManager` accepts an optional `onQuestionAwaiting` callback and passes it into each `ACPSessionRunner` during attach.
5. `ACPSessionRunner` accepts the callback and invokes it immediately after setting:
   - `session.transcript.streamingState = .awaitingInput`
   - `session.transcript.pendingQuestion = .init(id: request.id, params: request.params)`
6. `AppState.acpManager(for:)` binds the callback because it already knows the `worktreeId` for the manager being created and can resolve the owning `projectId` through the existing project/worktree lookup helpers.

The AppState callback maps `session.agentId` through the existing ACP-to-`AgentKind` mapping, checks `config.harness.notifyOnAwaiting`, derives the body text from the request params, and calls `harness.notifications.notifyACPQuestion(...)`.

This keeps lower ACP protocol/session code free of project lookup logic while still notifying at the exact point where the session becomes blocked on user input.

## Edge Cases

- If `config.harness.notifyOnAwaiting` is false, ACP question notifications are suppressed.
- If a request has no useful title or prompt, the notification body is `"Session is waiting for an answer."`.
- If the runner is stopped, detached, or taken over while a question is pending, the question is cancelled without a separate notification.
- If the same request is observed again by the same runner, it does not notify again.
- Foreground delivery remains enabled by the existing notification delegate.

## Testing

Add focused Swift Testing coverage:

- `NotificationServiceTests`: verify the ACP question request identifier, title, body, sound, click-through metadata, and logo attachment.
- `ACPSessionRunnerTests`: verify a question request triggers the callback once and still waits for and returns the user's answer.
- Manager/AppState wiring can be covered if an existing test seam supports attach construction cleanly. If not, keep coverage at the notification service and runner callback level to avoid brittle setup-heavy tests.

## Verification

Before finishing implementation, run:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```
