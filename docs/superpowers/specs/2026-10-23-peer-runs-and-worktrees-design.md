# Peer run scripts and worktree controls: phase 2 design

## Intent

A Mac paired with another host can work that host's sessions. The host is either a Mac mini running the headless `alas-host` or another Mac running the app. Phase 1 (PRs #2178, #2183, #2184) delivered that. The user wants the peer view to reach parity with local use wherever possible. Phase 2 covers the next two things the user does locally:

- run the worktree's run scripts;
- archive and delete worktrees.

Terminals and live output are phase 3.

## Current state (found during recon)

- The host serves a full host protocol over the Remote link as `host` messages (`RemoteSessionGateway.serveHost`, `HostProtocolServer`). It covers `snapshot`, `subscribe`/`subscribeAccepting` with `HostEvent`s, `startRun`, `stopRun`, `runOutput`, `deleteWorktree`, `archiveWorktree` and `unarchiveWorktree`.
- Hosts advertise `host.v1`, `host.events.v1` and `host.runs.output.v1` (among others) in `hello`.
- **The Mac client never uses the host protocol.** Nothing in `Alas/` sends `HostClientMessage`. A `.host` reply arriving on a peer link falls through `RemotePeerManager.handle` into federation and is dropped.
- The peer sidebar (`NativePeerSidebarView` / `NativePeerSidebarSnapshot`) groups session and console rows by worktree. Worktree rows have no context menu.
- The peer right pane offers Changes, Files and Agent. `RightPaneTab.peerAvailable` deliberately leaves out Run.
- Worktree identity for delete and archive (`lineageID`, `branch`) exists only in `HostSnapshot.worktrees`, not in `RemoteWorktreeSummary`.
- No host request lists run scripts. They live on disk (`<worktree>/.alas/scripts` and the global scripts directory), and the server resolves a `scriptKey` itself. `startRun` is strictly a start; restart exists in `RunsAPI` but not on the wire.
- `runOutput` returns output only for finished runs (`.notFinished` while one is active). A headless host's runs are plain processes with no live stream.

## Goals

1. **Host-channel client on the Mac.**
   - Add an `onHostMessage` hook in `RemotePeerManager`, mirroring `onConsoleEvent`. It delivers `.host` replies directly, never through federation.
   - Add a per-peer client. It:
     - sends `HostClientMessage` with its own request ids over `sendToPeer` and matches responses, with a timeout;
     - gates on the peer's `host.v1` / `host.events.v1` capabilities;
     - takes a `snapshot`, then `subscribe(after:)`;
     - applies `HostEvent`s;
     - re-snapshots on `resync` and on reconnect.
   - Its state is the peer's projects, worktrees (with `lineageID`, `isArchived`, `operation`) and run records.
   - Peers without the capabilities, such as older hosts, simply don't offer the new controls.
2. **Every worktree in the peer sidebar (user's decision).**
   - Like the local sidebar, the peer sidebar lists every visible (non-archived) worktree of each project on the host. That includes worktrees with no session or console.
   - The source is the host snapshot's worktrees, joined with the existing session and console rows by path / project id. Worktrees of hosts without the host-channel capabilities keep today's session-derived grouping.
   - Selecting an idle worktree opens it in the peer view (Changes, Files, Run, and a new session from there) as a worktree with sessions does.
   - This rework belongs in PR 1.
3. **Worktree controls in the peer sidebar.**
   - A context menu on peer worktree rows offers Archive, Delete…, and Delete, Keep Branch… The keep-branch item appears under the same rule as locally (`config.worktrees.deleteBranchOnRemove` on this Mac).
   - Items are hidden for the main worktree, folder projects and Workspace-owned worktrees, and disabled with an explanation for remote (SSH) projects.
   - Delete follows the local flow:
     1. The same "Delete worktree '<branch>'?" confirmation, with the same message about whether the branch is kept.
     2. Send `deleteWorktree(force: false)` with the host snapshot's `lineageID`/`branch`.
     3. On `needsForce`, show the same force-delete alert and resend with `force: true`.
     4. Show every other refusal's message.
   - Archive is a single request; refusals show their message.
   - The row shows `operation` states (deleting, delete failed, …) as the local row does.
   - A worktree the user deleted or archived disappears from the peer sidebar, with no manual refresh.
4. **Typed refusals and explicit discard for delete and archive (my call, from the anti-goal).**
   - The host maps "unsaved editor changes" and "owned by a Workspace checkout" to typed errors instead of `HostError.failed(message:)`. Today that text is CLI-worded ("rerun with --force").
   - The Mac shows them properly. For unsaved changes, it must never blindly retry with `force: true`. The user is told that the host Mac has unsaved edits, and a force delete would discard them. Retrying is an explicit choice with that warning.
   - Today `force` on delete also skips the unsaved-edits check (`refusesUnsavedEdits = !force`), and the git-dirty preflight runs first. So "force because git has changes" would silently discard host editor buffers too. Archive has no unsaved-edits check at all: the app's quiesce closes the editors.
   - **Split the two decisions on the wire.** `deleteWorktree` and `archiveWorktree` gain a separate `discardUnsavedEdits` acknowledgement. Without it, both refuse with the typed unsaved-edits error, whatever `force` says; `force` keeps meaning only "delete despite git changes".
   - The Mac asks for each consequence separately, with the local dialogs' wording, and sends each acknowledgement only after the user confirms.
   - The new behaviour is advertised as `host.worktrees.lifecycle.v1`. **The peer Archive and Delete controls appear only for hosts that advertise it**, so an older host, which would silently discard edits, gets no peer controls.
5. **Run tab in the peer right pane.**
   - Add `.run` to the peer-available tabs. Rows reuse the local Run tab's presentation (`RunTabPresentation`): status labels, detail ("exit 42 · 12s · 3m ago") and allowed actions.
   - Actions are Run, Stop and Rerun. Rerun uses a new host restart request. Edit and Open Terminal are not offered.
   - A finished run's output is shown on request via `runOutput`, as the local "Open report" does.
   - A run started or stopped elsewhere, locally on the host or by another client, updates the tab from host events.
6. **Runs on an app host (my call).** A run started from a peer behaves like one started on that Mac: the script's `alas-console` setting decides whether its terminal tab is visible. It never changes what is selected or focused on the host's screen. `listRunScripts` lists what the host's Run tab lists.
7. **Host protocol additions (additive, capability-gated):**
   - `listRunScripts(worktree:)` returns the worktree's scripts: key, name, scope, and the metadata the row needs. It is backed by the server's existing script discovery.
   - `restartRun(scriptKey:worktree:)` follows `RunsAPI.restart` semantics.
   - A new capability string advertises both, e.g. `host.runs.scripts.v1`.
   - Older Macs never send these requests. A new Mac checks the capability before showing the Run tab, so an older host shows no Run tab rather than a broken one.

## Non-goals (phase 2)

- Live run output while a run is going, and terminals on a headless host. Both are phase 3. The user confirmed that status plus output after completion is enough for now.
- Run history beyond each script's latest record.
- A delete preview listing what would be lost (dirty files, sessions, running scripts).
- Unarchive from the peer view. Archived worktrees aren't listed there today; unarchive stays on the host.
- Creating, editing or scheduling run scripts remotely.
- Web/phone client changes.

## Anti-goals

- No path where a peer action discards unsaved work on the host without the user explicitly confirming that consequence.
- Delete and archive must target exactly the checkout the user saw. Send the host snapshot's `lineageID`/`branch`, and keep the server's existing lineage and on-disk checks.
- No regression for older hosts or older Macs. New requests are gated on capabilities, and new response or error cases must not break older decoders.
- The core package gains no UI imports.

## Constraints

- AGENTS.md:
  - Swift Testing;
  - the testing policy (few sharp tests; extend existing suites; test decision logic and the host-channel client's ordering and resync, not SwiftUI views);
  - Conventional Commits with no attribution.
- The app target can't be fully built on the developer's machine, so CI is the first full compile. Keep app-side changes straightforward, and put logic in testable plain types.
- Delivered as two PRs:
  1. The host-channel client, every worktree in the peer sidebar, the worktree controls, and the typed refusals with the explicit discard.
  2. The Run tab and the run requests.

## Left to the builder

- The client type's name and placement, provided the request/response and snapshot/event logic sits in a plain type the tests can drive with a fake link.
- How peer sidebar worktrees are joined to `HostSnapshot` worktrees (path and project id).
- The exact fields of the run-script listing, beyond what the row presentation needs.
- Error wording for the new typed refusals, in the tone of the local dialogs.
