# ACP connection recovery

## Intent

An ACP chat must offer a way forward when connection setup stalls or fails. After an active attach has spent 30 seconds connecting, the pane offers **Restart connection**. A failed attach offers **Try again** immediately. Restart keeps the transcript, draft, and queued messages in the same chat. A read-only mirror never offers a writer-side restart.

The action must still work when the first attach is suspended in setup, broker startup, or an ACP request. It must not wait indefinitely for that attempt to return. A late result from the abandoned attempt must not replace the new connection, release its lease, or change the chat's state.

## Current behavior and gap

The transcript already has a recovery card for disconnected, waiting, reconnecting, and exhausted states. It offers actions while waiting and after exhaustion, but not during an active reconnect. Some attach failures show only an error banner. Empty chats can render a connecting view in place of the transcript, hiding the recovery card.

The current manager coalesces attach calls by session ID. Detach marks an in-flight attach for disposal, but a replacement still waits for the old `performAttach` to finish. Broker detach and several pre-connection operations can wait without a deadline. Merely adding a button therefore leaves the hung case unresolved.

## Approach

Give each attach an attempt ID and make it the owner of its connection, waiters, and lease token. The manager records one current attempt per session. Ordinary concurrent callers still join that current attempt. Restart invalidates it synchronously, cancels work that can be cancelled, and starts a replacement without waiting for the abandoned operation to return.

After each suspension point in attach, code checks that its attempt ID is still current before it publishes session state, registers a runner, persists a remote session ID, or sends queued work. An obsolete attempt only cleans up resources it owns. Cleanup compares attempt ID and lease token before removing a connection, heartbeat, runner, waiter, or lease, so a late completion cannot tear down its successor. Superseded waiters complete with an explicit superseded result rather than joining the old attempt forever.

Teardown closes an old connection with a two-second budget. A timeout releases the manager's wait on that close; late completion remains fenced to the old attempt. Register the broker client as an attempt-owned connection before awaiting broker startup, so restart can terminate its local client even when `open` or `attach` is suspended. When the broker responds, the replacement may adopt its confirmed generation through a new broker client. When it does not respond, the replacement creates an isolated local helper transport for this session, leaving the shared service used by other chats alone. It starts a fresh broker generation and restores the persisted chat; it must not treat the unresponsive broker as a healthy adopted connection.

The replacement reacquires writer ownership before attaching. Lease release and cleanup use the token acquired by the old attempt. If the manager cannot establish writer ownership or start a fresh transport, it publishes a concrete failure and keeps **Try again** available. It never remains in an actionless `Reconnecting…` state.

## User-visible flow

1. Starting an attach records its start time. The recovery card, first-run connecting view, and empty-chat placeholder show **Restart connection** once 30 seconds have elapsed. No restart action appears in a mirror pane.
2. Clicking the action invalidates the current attempt immediately. The pane continues to show that a restart is in progress, with duplicate clicks disabled.
3. The manager ends the old transport within its teardown budget and begins a new attach for the same chat. It retains the transcript, draft, remote session identity where valid, and queued message records.
4. On success, the pane returns to the connected state and flushes eligible queued messages through the new runner. On failure, it shows the error and **Try again** immediately.

An ordinary failed attach offers **Try again** without waiting 30 seconds. Existing automatic remote retry delays remain in place; a manual action supersedes the pending timer. Restart does not close or delete the persisted chat.

## Queue and broker safety

Teardown normalizes an in-flight queue head to pending as it does today. A new runner must not flush the queue until the replacement has writer ownership and session restoration has completed. Existing durable broker operation keys remain attached to queued items so a responsive broker can deduplicate replay.

If the old broker cannot confirm whether a queued operation completed and a fresh broker generation is required, the manager retains any queued item that was sending or carries an operation key from that generation but blocks its automatic resend. The chat explains that delivery is uncertain and lets the user decide whether to retry that item. It must not silently duplicate a prompt. Messages known to be unsent may flush normally.

## Verification

Use Swift Testing with controlled suspension points to cover:

- The 29-second and 30-second action boundary, empty-chat visibility, immediate failed-state retry, and mirror exclusion.
- A first attach held in setup before any connection exists. Restart reaches a ready replacement while the first remains suspended. Releasing the old setup later cannot change the new session or lease.
- A first attach held in broker startup or `initialize`, including an old detach that exceeds the two-second budget. Restart either connects through a fresh transport or publishes a retryable failure within a bounded time.
- A late old response after the replacement is ready. The runner, remote session ID, broker generation, queued work, and writer lease still belong to the replacement.
- Preservation of transcript, draft, and queue; no duplicate queued send when broker delivery is uncertain; repeated restart clicks create one replacement.

Run the affected ACP session, broker, and UI policy suites. Do not run the full local test plan by default, per `AGENTS.md`.

## Scope

This change covers attach and reconnect recovery in the macOS ACP chat pane. It does not change the ACP wire protocol, automatic retry backoff, session deletion, or normal turn cancellation.
