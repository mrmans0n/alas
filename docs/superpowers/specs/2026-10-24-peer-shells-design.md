# Opening a shell on a paired host — phase 3 design (part 1)

## Intent

The user pairs a laptop with a Mac mini running the headless `alas-host`, and wants parity with local use. Phases 1–2 delivered sessions, worktrees and run scripts. The user's top remaining need is **opening a shell in a worktree on the host** from the laptop's peer view. It should work against a headless host and, for parity, against a Mac running the app.

## Current state (from recon)

- **Peer consoles exist between Macs running the app.** The protocol is `PeerConsoleProtocol.swift`, with capabilities `peerConsole.v1` and `peerConsoleTerminate.v1`. Its requests are `list`, `attach`, `takeControl`, `releaseControl`, `input`, `resync`, `detach` and `terminate`.
- `PeerConsoleHost` (core) serves consoles by attaching passively to a **zmx** session socket (`ZmxPassiveClient`, zmx IPC in `AlasPlatform/Zmx`). It relays `Capture` snapshots and `Output` frames, and sends input with zmx `Send`.
- The viewing Mac renders a console in a Ghostty transient surface fed by `PeerConsoleBridge`. The host side needs **only zmx**, not Ghostty.
- **No request creates a console.** A peer can only list, attach to and terminate existing ones.
- **No request resizes a console.** On a Mac running the app the size comes from the host's Ghostty grid. A headless zmx daemon without a TTY defaults to 24×120.
- The headless host serves no consoles. It sends `servesPeerConsoles: false`, and `HeadlessSessionPresenter.peerConsoleHost` is nil.
- zmx is a standalone binary (Zig, `ThirdParty/zmx`, built by `scripts/build-zmx.sh`). It ships in `Alas.app/Contents/Resources/zmx/zmx`, but **not** in the `alas-host` cask zip (`scripts/package-alas-host.sh`). `ZmxEnv.resolveBinaryURL` looks under `Bundle.main.resourceURL/zmx/zmx`, which doesn't fit the bare tool.
- zmx sessions are `setsid` daemons that outlive their launcher. The app names them `ZmxSessionName.derive(worktreeId:leafId:)` = `alas-<wtHash>-<leafHash>`. At boot it sweeps sessions under known worktrees whose leaf it doesn't know (`TerminalService.orphanSessionNames`). The app and host share `ZMX_DIR` but never run at once (data-directory lock).
- A Mac running the app already has **hidden terminal tabs** (hidden run consoles). `peerConsoleSummaries` lists every local zmx-backed terminal session, hidden ones included.

## Goals

1. **Open a shell from the peer view.**
   - A "New Terminal" action on a peer worktree sends a new console request: open a shell in that worktree.
   - On success the new console appears among that worktree's consoles in the peer sidebar and opens in the existing console viewer, already attached. The requester holds control, so it can type straight away.
   - On failure the user sees the host's reason.
2. **Headless host serves consoles.**
   - `alas-host` starts shells in zmx sessions.
   - The shell is the user's login shell, in the worktree directory, with the same environment the host gives agents: login-shell PATH first, as `ACPProcessEnvironment.baseEnvironment`.
   - It serves them through `PeerConsoleHost`, with core-side environment closures:
     - list from a host console registry;
     - resolve to the zmx socket and current size;
     - local input suppression is a no-op;
     - terminate kills the zmx session.
   - It advertises `peerConsole.v1` and `peerConsoleTerminate.v1` (`servesPeerConsoles: true`), plus the new capabilities below.
3. **Shells survive host restarts.**
   - The registry is persisted in the profile (id, worktree, title, zmx name, size). On boot, entries whose zmx session is gone are dropped.
   - Host-created zmx names use a distinct prefix that the app's orphan sweep never matches, so the app doesn't kill them when it later runs on the profile.
4. **Sizing.**
   - A new request lets the control holder set the console's size from its viewer.
   - A headless host applies it with zmx `Resize` and reports `geometry` to every attachment.
   - A Mac running the app keeps sizing its consoles from its own Ghostty grid, and ignores the request or refuses it cleanly.
5. **Mac running the app opens a hidden tab.** It handles the open request by creating a **hidden, non-activating** terminal tab in that worktree. That tab's zmx session then appears as a peer console like any other. The host user's selection and focus never change. *(The user had no strong view; the hidden option is my call, because it is the simpler one and reuses existing hidden tabs.)*
6. **Packaging.**
   - The `alas-host` cask ships zmx next to the binary.
   - `alas-host` finds zmx there, resolving symlinks like the web client lookup, and falls back to the app bundle's copy.
   - If zmx isn't found, the host doesn't advertise the console capabilities, and the open request fails with a clear message.

## Decisions from the builder check

- **Authorization (user's decision):** being paired is enough to open a shell. There is no extra host setting, matching agent sessions and run scripts.
- **Each side sees only its own shells (my call):**
  - Host-created zmx names use a prefix that does **not** start with `alas-` (e.g. `alashost-<wtHash>-<id>`). The app's orphan sweep, the Settings "Open sessions" list and its "Kill idle orphans", and `ZmxPreFreezeMigration` therefore never touch them.
  - While the app runs on the profile, host shells stay alive but are not listed. They reappear when the host is back.
  - Shells opened as hidden app tabs belong to the app, and the host doesn't list them.
  - Cost if wrong: a later shared registry.
- **Peer-opened hidden tabs on an app host become visible after that Mac relaunches (my call).** The hidden flag isn't persisted for non-run tabs, so the host user then sees an ordinary terminal tab they can close. This is accepted rather than adding hidden-state persistence. Cost if wrong: one follow-up.
- **No `ALAS_*` CLI variables in host shells for now (my call).** The `alas` CLI talks to the app, which a headless host doesn't have.
- **Resize on zmx (from code):** zmx accepts `Resize` only from its leader client. The host keeps a dedicated sizing client per console to apply sizes. The builder verifies this against the real binary.

## Non-goals (this part)

- Running scripts inside zmx, which would make run consoles attachable, and live run output in the Run tab. These are the next part, on the same machinery.
- Consoles for SSH-project worktrees on the host (remote zmx). They are refused with a clear reason.
- Web and phone clients. Consoles already serve only paired Macs.

## Anti-goals

- A peer must never take focus or change selection on a host user's screen.
- No regression for older peers or hosts. New requests are capability-gated, and older decoders ignore what they don't know.
- The app's orphan sweep must never kill host-created shells.
- No UI imports in the core package. zmx is executed as a binary, never linked.

## Constraints

- AGENTS.md:
  - Swift Testing; the testing policy applies (test the registry, request handling and naming, not views);
  - Conventional Commits with no attribution.
- The app target can't be built on the developer's machine, so CI is the first build. Keep app-side changes small; put logic in core.
- The headless host runs as a launchd agent:
  - Nobody can answer a privacy (TCC) prompt there, so shells in protected folders may fail silently. Document this.
  - `ProcessType: Background` throttles child processes. Decide whether interactive shells need `Standard`.

## Left to the builder

- Exact new request and capability names, e.g. `PeerConsoleRequest.open(worktreeId:)` and `.resize(attachmentId:rows:columns:)`, with capabilities like `peerConsoleOpen.v1` and `peerConsoleResize.v1`. Whether `open` replies through an `attached` for the new console or a fresh `list`.
- The registry file name and format.
- How the shell command is built (`zmx attach <name> <shell> -l` style, with the cwd and env), provided interactive input works when the daemon's launcher has no TTY. Verify this on the real binary.
- Where "New Terminal" lives in the peer sidebar: the worktree context menu, a "+" next to the console badges, or both.
- Whether the launch agent's ProcessType changes.
