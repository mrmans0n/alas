# Host checkpoint robustness: recovering an interrupted restore, and oversized replies — design

## Intent

These are two follow-ups left by the host checkpoints work. Both can leave a paired Mac stuck with no way out. The user asked for this phase to run unattended, so the calls below are mine.

1. **An interrupted restore bricks a host worktree for the Mac.**
   - If `alas-host` dies mid-restore, the restore journal stays nonterminal. From then on, the host gate refuses every git change and file save on that worktree with "A checkpoint restore is pending on the host; finish it there first."
   - Locally the app offers Recover (`RightPaneState.recoverCheckpointRestore` → `WorktreeCheckpointService.recoverInterruptedRestore`). A headless host has no UI, and nothing on the host calls recovery. The worktree stays stuck.
2. **A large checkpoint can drop the whole peer link.**
   - `.checkpointManifest`, which is also the reply to create, and `.checkpointRestorePreview` grow with the number of paths. Capture caps bytes, not paths, so an unignored `node_modules` can push a reply past the 16 MB WebSocket frame limit.
   - The host sends it anyway. The Mac's `URLSessionWebSocketTask` fails `receive()`, the link drops and reconnects, and the request times out. The user sees a disconnect, not an error.

## Goals

1. **Recover from the Mac.**
   - When a host worktree has an interrupted restore, its checkpoints section on the Mac says so and offers Recover, as local does.
   - Recover runs the host's existing recovery, which restores the pre-restore recovery checkpoint, then refreshes. After that, git actions and saves work again.
2. **No reply ever drops the link.**
   - The host never sends a server message larger than the frame limit allows.
   - A reply that would be too large is replaced by a failure for the same request, so the Mac shows an error ("This checkpoint has too many files to show from a paired Mac.") and the link stays up.
3. **Capability-gated and compatible.** Older hosts and Macs behave as today.

## Non-goals

- Making prompts not wait for the automatic checkpoint. The checkpoint must finish before the agent writes, or it isn't a "before" state. That needs its own design.
- Capping how many paths a checkpoint captures. Local has the same capture, and a cap changes what checkpoints mean. A too-large checkpoint stays usable locally and on the host's own UI, if any.
- Splitting `RightPaneState.swift`. It is maintenance only.
- Checkpoint section polish. Nothing concrete was specified.

## Decisions (my calls)

- **Recovery.**
  - The manifest the Mac reads gains `interruptedRestore: Bool`. It is decoded leniently, so older hosts read as false.
  - A new `HostWorktreeChange.recoverCheckpointRestore` sits under a new headless-only capability. It names no operation: the host recovers its own nonterminal journals for that worktree through `recoverInterruptedRestore`, in journal order, with the same coordination snapshot local builds. The Mac never sends an operation id.
  - It runs through the checkpoint path of `mutateListedWorktree`, but must be allowed while recovery is pending. That is the one change the pending-recovery refusal lets through.
- **The size guard sits centrally in the host's server-message send.**
  - If the encoded message exceeds a budget under `WebSocketFrame.maxPayloadLength`, the host doesn't send it.
  - For a reply to a request, it sends that request's failure instead, with the message above, or a generic "too large to send" for non-checkpoint replies.
  - For an unsolicited event, it drops the event and logs it.
  - That covers every reply type, not just checkpoints.
- **One PR,** host plus Mac.

## Left to the builder

- Exact names and the budget, for example 15 MB, leaving room for envelopes.
- Where the failure for an oversized reply is built, so it matches the request's own failure shape.
- The Mac copy and placement of Recover. Follow local's checkpoint section.
