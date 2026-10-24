# The `alas` CLI and MCP tools on a headless host — design

## Intent

A paired Mac uses a headless `alas-host` (the Mac mini) as a peer, and the user wants parity with local sessions wherever possible. Agents started by the app get the built-in `alas` MCP server and the `alas` CLI. They use these to delegate sub-sessions, work with reviews and PRs, show visual aids and manage worktrees. Agents started by `alas-host` get none of this, so they can't delegate, review or ship. This design gives them every tool that can work without a screen.

## Current state (from recon)

- **CLI:** a Rust binary (`AlasCLI/`).
  - It talks to the app over a per-process Unix socket in `/tmp/alas-<uid>/pid-<pid>`. Each connection carries one JSON request (`kind: "cli"`) and gets one reply (`ok`, `lines`, `error`, `exit_code`).
  - It finds its target through `ALAS_SOCKET_PATH` and `ALAS_SESSION_ID`, or else by scanning live `pid-*` sockets.
- **MCP server:** `alas mcp`, in `AlasCLI/crates/alas/src/mcp.rs`. Each tool call becomes the same CLI request over the same socket.
  - It needs `ALAS_SOCKET_PATH`, `ALAS_WORKTREE_DIR` and `ALAS_SESSION_ID`.
  - Tool scopes already exist: `ALAS_MCP_WORKSPACE_ONLY`, the relay scopes, and the child-only filter.
- **Socket server:** `AgentHookSocketServer` (core). The headless host already binds it through `AlasCoreContext.harness`, but nothing sets `onCLIRequest`, so every request gets "Alas CLI is not available."
- **Dispatch:** `AlasCLICommandRouter` lives in the app (`Alas/Sources/App/AlasCLICommandRouter.swift`).
  - It holds an `AlasHost` and UI closures; most closures already default to refusals.
  - Most commands go straight to core `AlasHost` APIs: `delegation`, `reviews`, `prs`, `sessions.showVisualAid`, `worktrees`, `workspaces`, `attention`.
- **Injection:** the app wires up the MCP server and env for each agent.
  - The MCP server comes from `ACPSessionManager.builtInMCPProvider` (`BuiltInAlasMCP.injection`).
  - The `ALAS_*` env and the `PATH` entry come from `alasCLIEnvProvider` (`AlasCLIEnvInjection.environment`), with a per-session socket link (`linkSession`).
  - All the building blocks are in core. The headless `sessionManagerFactory` sets none of them.
- **Packaging:** the `alas-host` cask ships `alas-host`, `RemoteWeb/` and `zmx/zmx`, but not the CLI. `TerminalCLIInjection.bundledBinaryURL()` looks inside `Bundle.main`.
- **Host shells** (#2193) strip `ALAS_*` from their environment.
- **Headless environment gaps:**
  - `createDelegatedWorktree` refuses, so `session_new --new-worktree` fails.
  - `reviewReplyAdded` and `providerReviewOriginalPath` are no-ops.
- **Attention doesn't reach peers.** `notify` raises the harness's external activity. A Remote client's session status comes only from the ACP streaming state (`RemoteSessionGateway.stateString`), so a `notify` on the host is invisible to the paired Mac.

## Goals

1. **Agents on the host get the `alas` MCP server.**
   - Every ACP session `alas-host` starts gets the built-in `alas` MCP server, as in the app: stdio, with the same env (`ALAS_SOCKET_PATH`, `ALAS_WORKTREE_DIR`, `ALAS_SESSION_ID`, and `ALAS_PARENT_SESSION_ID` for children).
   - Project MCP servers configured for the worktree are passed too, if core already resolves them without UI.
2. **The CLI works from the host's agents and shells.**
   - The `alas` and `ao` binaries are on `PATH` for host agents and host shells.
   - Host shells get the CLI's context variables, reversing the shells-design call; see the decisions below. The CLI then reaches the host from a shell the user opened from the laptop.
3. **The host answers CLI requests.** `alas-host` serves the existing CLI socket protocol. No new protocol and no `HostRequest`s. With the router in core, these work through existing core APIs:
   - `agent_list` and `session_list`, `session_new`, `session_send`, `session_read`, `session_search`, `session_wait`, `session_interrupt`.
   - `review_comments`, `review_reply`, `review_resolve`, `review_comment_add`, `review_finish`.
   - `review <target>`: it opens the review session and returns its id, with no tab.
   - `pr_create`, `pr_status`, `stack_ship`.
   - `visual_show`: the card lands in the transcript, and the paired Mac shows and answers it.
   - `wt list`, `wt new`, `wt delete`, `resolve`, `workspace list`, `workspace show`.
   - `session_new --new-worktree`, through a real `createDelegatedWorktree`.
4. **Screen-bound tools are hidden and refused.** On a headless host, the MCP server omits:
   - `open`;
   - `preview_*` and `computer_*`;
   - `worktree_switch`, `workspace_switch`, `workspace_focus`;
   - local-changes `review`.

   The CLI refuses the same commands with "Not available on a headless host." Exit code is non-zero.
5. **`notify` reaches the paired Mac.** On a headless host, `notify` raises no system banner, so it can't crash or silently fail without a bundle. Instead:
   - the message reaches every connected Mac paired with the host, which shows it as a banner like a local notify;
   - with `--needs-input`, the host reports the session as waiting, so every client shows it until the session's next prompt or turn end.
6. **Packaging.**
   - The cask ships the CLI next to the host, at `alas-cli/alas`, the same way as zmx.
   - The host resolves it with the same order as zmx: an override env var, then beside the binary (resolving symlinks), then the app bundle's copy.
   - It installs it where agents' `PATH` points.
   - If the CLI isn't found, agents get no `alas` MCP server and the host logs why. Everything else works.

## Decisions from the builder check

All of these are my calls.

- **The "waiting" state lives on the host.**
  - `notify --needs-input` keeps setting the host's external activity. The host's session summary reports the session as `awaitingInput` while that activity says so. Reconnecting Macs, web and phone all see it with no new state on the Mac.
  - It clears the way it does in the app: on the session's next prompt, or when its turn ends.
  - The message itself, title plus body, travels as a capability-gated peer event. The Mac shows it as a banner and has no other state. A Mac that is offline at the time misses the banner but still sees the waiting status.
  - Only federated Macs get the banner. Web and phone see the status.
  - Cost if wrong: a later event for web and phone.
- **Host shells get context, not identity.**
  - Host shells get `PATH` (the CLI), `ALAS_WORKTREE` and `ALAS_REPO`. They don't get `ALAS_SOCKET_PATH` or `ALAS_SESSION_ID`, because a zmx shell outlives the host process and a pinned socket would go stale.
  - The CLI's existing scan finds the one live host socket. Shell calls are anonymous `.cli` callers resolved from the working directory, as for a plain terminal outside Alas.
  - A `notify` from a shell has no session, so it is not relayed to peers in this step. It is logged.
  - Cost if wrong: a stable socket link and terminal-owner tracking later.
- **Local-changes review is hidden by schema.** In headless scope, `review` requires `target`, and `review_comment_add` and `review_finish` require `session_id`. The Rust filter rewrites those schemas and the CLI refuses the bare forms.
  - Cost if wrong: one schema change, if the host turns out to support a local-changes review.
- **Several commands are new headless code, not a move.** `review <target>`, `wt new`, `wt delete`, `workspace list/show` and `createDelegatedWorktree` each get a small headless implementation over core (`host.reviews.open`, `AlasCoreContext.createWorktree`, `WorktreesAPI`).
  - Work is split into PRs: the router move (with `AlasActionService`, behaviour-neutral for the app) goes in first, and the headless implementations, injection and packaging follow.
- **Workspaces are kept only if they have data.** If the host has no workspace backing (`workspaceCheckout(id:)` is nil), `workspace_list` and `workspace_show` move to the hidden list.
- **Hooks for worktrees an agent creates on the host** use the non-prompting peer policy from phase 2. Startup scripts run as they do for peer-created worktrees.

## Non-goals

- Forwarding screen-bound tools (`open`, `preview_*`, `computer_*`, focus) to a paired Mac. That is a later step, on the peer protocol.
- Letting Remote clients (laptop, web, phone) issue CLI commands to the host. They keep using the host protocol.
- MCP over HTTP on the host (`alas mcp --http`). Stdio only.
- Changes to how the app serves the CLI, beyond moving the router into core.

## Anti-goals

- No behaviour change in the app. It keeps passing its UI closures, and every command behaves as today.
- No tool advertised to a host agent that can only fail.
- No weaker socket trust than the app's. Same-uid only. The design may add a `getpeereid` check to `AgentHookSocketServer` for both, but must not remove anything.
- No regression for older peers. The notify relay is capability-gated, and older Macs simply don't show it.

## Constraints

- AGENTS.md:
  - Swift Testing;
  - the testing policy (test the headless routing decisions, the tool filter and the binary lookup, not wiring);
  - no UI imports in the core package;
  - Conventional Commits, no attribution.
- The app target can't be built locally, so CI is the first build. Moving the router is a mechanical app-and-core change. Keep it a pure move plus defaults.
- The Rust CLI has its own tests (`Rust tests (AlasCLI)` in CI). The tool filter goes in there.
- Verify on the mini after merge:
  - an agent delegates a child;
  - `visual_show` appears on the laptop;
  - `notify` appears on the laptop;
  - `alas wt list` works from a host shell.

## Left to the builder

- How the CLI tells it's headless. Options: an env var set by the host's injection, such as `ALAS_MCP_HEADLESS=1`, next to `ALAS_MCP_WORKSPACE_ONLY`; or a capability the socket reports at `mcp_hello`. Prefer whichever keeps one source of truth for the hidden list.
- Where the router lands in core (`AlasHostCore`), and the names of its headless closures.
- How `notify` travels to peers: a peer-protocol event, or a field in the session summary. The Mac's side reuses the app's existing notification path.
- Install location for the host's CLI copy: `<appSupport>/bin` as the app does, or straight from the cask path.
- Whether `wt delete` on the host has a dirty-tab preflight. It has no tabs, so probably `WorktreesAPI.delete` alone.
