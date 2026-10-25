# Repo hook approval for work a paired Mac starts on a host — design

## Intent

A repo can ship `.alas/hooks/worktree-create.sh` (runs when a worktree is created) and `.alas/hooks/session-open.sh` (runs when a terminal opens). Locally, a new or changed hook is shown in an approval sheet, and the approved script's hash is stored per project. When a paired Mac creates a worktree or opens a shell on a host, an unapproved hook is silently skipped, so the user's setup never runs and nothing says why. On a Mac running the app that serves a peer, a peer's worktree creation instead pops the approval sheet on the host's screen and blocks the peer's request. The user wants peers to have parity with local use. This design lets the Mac that started the work approve the hook.

## Current state (from recon, origin/main)

- **The hooks and their trust.**
  - Hooks are defined by `RepoHook` (`AlasPlatform/RepoHooks`). Trust is a SHA256 over version, event and script bytes, stored in `ProjectConfig.approvedRepoHookHashes`.
  - Approval is checked and recorded through `ProjectsManager` and `persistRepoHookApproval` (core).
  - Scripts are capped at 256 KiB.
- **`RepoHookPrompter`** is a pair of closures:
  - `decide` and `decideFailure`, which return approve, skip, retry or cancel;
  - presets `.skipping` (headless default) and `.queue` (the app's sheet, `RepoHookApprovalSheet`).
  - `preparedRepoHook` consults it from `runWorktreeCreateScripts` (core) and from the app's terminal-opening paths.
- **Headless host, creating a worktree.** The worktree is created, and global and project scripts run. The repo hook is skipped (`.skipping`). The peer gets a normal reply with no signal.
- **Headless host, shells and run consoles** (`HostConsoles`, `HostShellLaunch`) never apply the session-open hook at all, approved or not.
- **App host serving a peer.**
  - Creating a worktree uses the app's `.queue`, so the sheet appears on the host and the peer's request waits on it until the peer's request timeout. This is a bug.
  - Peer-opened terminals skip session-open silently.
- **Patterns to reuse:**
  - typed refusals carried in `HostResponse.failure`;
  - capability-gated requests (`renameBranch`, `mutateWorktree`);
  - the Mac's existing approval sheet, which takes a `RepoHookApprovalRequest`.

## Goals

1. **Worktree creation from a paired Mac.** When the repo's worktree-create hook is unapproved, the host still creates the worktree and runs the other setup, as today. It does not run the hook, and it tells the requesting Mac that the hook is waiting for approval: event, path, source, full script text and hash.
   - The Mac shows the same approval sheet as local.
   - **Approve** sends a new request that records the approval on the host, after checking the hash still matches the script on disk, and runs the worktree-create hook on that worktree now.
   - **Skip** leaves the worktree without the hook, as local Skip does.
   - The worktree row shows the hook's run like local creation does, including a failure. A failing hook offers the same retry or skip choice as local, asked on the Mac.
2. **Shells opened from a paired Mac run the session-open hook** on hosts that can, with the same approval flow:
   - An approved hook runs as the shell opens, as in the app.
   - An unapproved one makes the open request reply that approval is needed, carrying the hook. The Mac shows the sheet.
   - **Approve** records the approval and reopens the shell, now running the hook.
   - **Skip** opens the shell without it.
   - This covers headless host shells. App hosts already open peer shells as hidden terminal tabs, so the same request flag routes them through this flow instead of skipping silently.
3. **No sheet ever appears on the host's screen for a peer's request.** An app host serving a peer uses this flow, never its local queue.
4. **No requester, no prompt.** Unattended work keeps skipping unapproved hooks, as today. This covers scheduled runs, agent-created worktrees and CLI calls on the host. The host logs a skip, and when the work has a worktree it sends a worktree notice ("Setup hook not run: it needs approval in Alas"), so the Mac learns about it.
5. **Capability-gated.** Approval needs both the new requests and the "needs approval" reply. Older Macs get today's silent-skip behaviour, and older hosts are never sent the new requests.

## Non-goals

- Run scripts. They have no approval of their own; locally the session-open hook gates terminals, and headless run consoles keep running only the run command.
- Workspace-member hooks on hosts, which today return nil.
- Showing a diff against the previously approved script. Only hashes are kept, the same as local.
- Approving hooks from web or phone clients.

## Anti-goals

- No hook ever runs unapproved.
- The host never blocks waiting for a human.
- No change to local approval behaviour.

## Constraints

- AGENTS.md:
  - Swift Testing;
  - testing policy: test the host's approve-request validation (hash must match the current script, project and event), the "needs approval" outcome for create and open, and the no-requester skip, using real files and template repos; don't test the sheet;
  - no UI imports in core;
  - Conventional Commits, no attribution.
- The app can't be built locally. Reuse `RepoHookApprovalSheet` by building a `RepoHookApprovalRequest` from the wire hook, and keep app edits mechanical.

## Decisions (my calls)

- **Refuse-then-approve, not a live question.** The host never waits on a prompt. It reports "needs approval" with the hook, and the Mac answers with a separate approve request. This avoids pending-question tracking and timeouts.
- **Creation succeeds without the hook.** Failing the whole create would leave a half-made worktree. The hook runs later when it is approved.
- **Approval is per project, as local.** One approval on the Mac covers every later worktree and shell for that project on that host, for that exact script.

## Decisions from the builder check (my calls; these refine the Goals above)

- **Creation asks first, before anything is created.**
  - The path is `RemoteRequest.createWorktreeSession`, which the Mac uses to create a worktree and start its agent session.
  - **When the Mac asks:** the request carries a "may ask" flag, set only by Macs that support approval. If the worktree-create hook is unapproved, the host replies "needs approval" with the hook and creates nothing.
  - **On the Mac:** Approve sends the approve request and then re-sends the same create. Skip re-sends it with "skip the repo hook".
  - **Order:** the combined create script (global, then the hook, then project) runs once, in order, before the session starts, exactly as locally.
  - **Who gets today's behaviour:** web and phone clients, and older Macs, don't set the flag. They keep the silent skip, plus a notice.
  - This replaces Goal 1's "create, then run the hook later".
- **No failure UI.** Goal 1's "row shows the hook's run, including a failure" is dropped; local has none either, because create scripts run fire-and-forget. A hook that can't be loaded (unreadable, or over 256 KiB) is skipped, as `decideFailure` skipping does on the host.
- **Headless shells run the full session-open script,** the same way app-host peer shells already do: global `startupScript`, then the approved repo hook, then the project script.
  - This is a behaviour change for headless hosts. Their shells used to run none of it, and it brings them to parity with app hosts and local.
  - For Macs that don't ask, including older ones, an unapproved hook is skipped silently, as on app hosts.
- **Notices only for worktree creation,** once per create that skipped an unapproved hook for a client that can't ask. Never for session-open, so there is no notice for every shell or run, and no new persisted state.
  - Older Macs don't receive worktree notices (an opt-in kind), so for them this stays silent, as today.
- **Gating.**
  - Shell approval rides on the console protocol: a new `PeerConsoleCapability` plus a "may ask" field on the open request.
  - The approve request and creation's "needs approval" reply use a new `HostProtocolCapability`.
  - The Mac offers approval only when the host advertises the capability for that path.

## Left to the builder

- Exact request and capability names (e.g. `approveRepoHook(project:event:hash:runOn:)`, `host.repoHooks.approve.v1`), and how the "needs approval" outcome rides on the create and open replies.
- How the Mac surfaces the pending approval: the sheet immediately after the reply, or a row badge with an "Approve setup hook" action. Mirror local timing, where the sheet appears as part of the action.
