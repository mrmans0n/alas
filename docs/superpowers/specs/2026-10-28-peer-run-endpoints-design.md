# Opening a host run's web endpoint from the Mac — design

## Intent

The user pairs a Mac with a headless `alas-host` and wants parity with local work. Locally, a run script that declares an endpoint (`# alas-url: http://localhost:3000`) gets an "Open" action while it runs, which opens the dev server in the in-app web preview. On a host worktree the Run tab can start, stop and watch the same script, but the endpoint does nothing.

The obvious fix, opening `http://<host>:3000`, rarely works. Dev servers (vite, next, rails and others) listen only on the host's own localhost by default. A host reached only through Tailscale Serve exposes nothing but its Alas port. And a server that does bind every interface is then open to the whole LAN or tailnet with no Alas authentication.

The user chose port forwarding, the way `ssh -L` does it. The Mac listens on its own `127.0.0.1` and relays each connection over the already authenticated peer connection. The host connects to its own localhost port for that run. The dev server works on the Mac as if it were local, including hot reload, WebSockets and cookies.

## Current state (from recon, origin/main 117614843)

- **Endpoints are declared, not detected.**
  - A script's endpoint comes from its `# alas-url:` header (`RunEndpointPolicy.endpoint(from:)`). It is http or https with a host.
  - `RunRecord.endpoint: URL?` is copied from the script at launch.
  - No listening port is ever discovered. The only port logic is a bind probe for conflicts at launch.
- **Local open.**
  - `RunTabPresentation.actions` offers `.openEndpoint(url)` while the run is `.running`.
  - `AppState.openRunEndpoint` opens an in-app WebKit preview tab (`tabs.openWebPreview`).
  - For SSH projects a loopback endpoint is refused with "forward the port over SSH" (`.blockedRemoteLoopback`). `docs/web-previews.md` states that Alas creates no tunnels.
- **The endpoint already reaches the Mac.**
  - `RunRecord` travels in `HostSnapshot.runs` and `HostEvent.runChanged` (`PeerHostChannel.State.runs`).
  - The peer Run tab drops it: `RunTabPresentation.peerRow` builds a `RunScript` with no endpoint, and `NativePeerRunTabView` ignores `.openEndpoint`.
- **Transport.**
  - The Mac and host talk over one WebSocket per paired host (`RemotePeerConnection`). It carries a bearer token and an Ed25519-pinned host identity, with a signed hello challenge.
  - The only byte streams are peer consoles (`PeerConsoleRequest`/`PeerConsoleEvent`). These have per-attachment ids, credit and backpressure (`PeerConsoleOutbox`, `PeerConsoleLeaseBook`).
  - Nothing forwards TCP and nothing proxies HTTP.

## Goals

1. **Open a host run's endpoint from the Mac.**
   - While a host run with a declared endpoint is running, its Run tab row shows the same Open action as local.
   - Open starts forwarding for that run, if it isn't already, and opens the forwarded URL. For now it opens in the default browser: see the builder-check decisions.
2. **Forwarding is transparent to the dev server.**
   - The Mac listens on `127.0.0.1` at the endpoint's port when that port is free, and on an ephemeral port otherwise.
   - Every TCP connection the Mac accepts becomes one stream over the peer connection. The host connects that stream to `127.0.0.1:<port>` and relays bytes both ways until either side closes.
   - Plain HTTP, HTTPS dev servers (bytes are relayed as-is), WebSockets and hot reload all work.
   - Using the endpoint's port keeps the page's absolute `localhost:<port>` links and its cookies working.
3. **Scoped to the run.**
   - The host only connects to the endpoint port of a run that is active on that host, and only on loopback. It reads the run and port from its own run store, never from the Mac.
   - When the run stops or exits, its forward ends: the host closes its streams and refuses new ones, and the Mac closes its listener.
   - Forwards also end when the host disconnects, is unpaired or removed, or the app quits.
4. **Errors are shown.** If the host refuses or can't connect (the server isn't up yet, or it listens elsewhere), the Mac closes that connection. The preview shows its usual load error, and the Run tab row gives a short note.
5. **Capability-gated and compatible.**
   - A new headless-only capability gates the forward messages.
   - Older hosts keep today's Run tab, with no Open action.
   - Older Macs are unaffected.

## Non-goals

- Detecting listening ports, or forwarding ports a script didn't declare.
- Forwarding arbitrary host ports, or any host address other than loopback.
- Exposing the forwarded port beyond the Mac's loopback.
- Forwarding for SSH projects. They keep their message about `ssh -L`.
- Rewriting HTTP. The forward relays bytes; it is not a proxy.

## Anti-goals

- **No SSRF.** The Mac never names a host or a port for the host to connect to. It names a run, and the host resolves that run's declared loopback port.
- **No listener beyond `127.0.0.1` on the Mac.**
- **No unbounded buffering.** Streams are flow-controlled like consoles, and the number of streams per run is capped.
- **No change to local runs, previews or SSH behaviour.**

## Constraints

- AGENTS.md:
  - Swift Testing, minimal sharp tests;
  - no UI imports in core; public cross-module types Sendable;
  - Conventional Commits, no attribution.
- Tests use real loopback sockets in-process (a tiny echo or HTTP server on an ephemeral port), not fakes of TCP. They never use fixed sleeps.
- The app can't be built locally, so CI is its first build. Split long SwiftUI chains, avoid name collisions, and no shadowing `if let`.
- Use Network.framework (`NWListener` and `NWConnection`), which core already uses for the remote server.

## Decisions (my calls)

- **The forward lives in core on both ends.**
  - A host-side piece accepts `open(stream, run)`, connects to the run's loopback port and relays.
  - A Mac-side piece owns the `127.0.0.1` listener and maps accepted connections to streams.
  - Both are UI-free and testable together in one process. The app only adds the Open action and the preview tab.
- **Messages follow the console pattern:** open, data, close, and credit, keyed by a stream id the Mac picks. They ride the existing peer WebSocket. Data is sent in bounded chunks.
- **One forward per run, reused.** Open on a run that is already forwarded just opens the preview again.
- **Same port when free.** The endpoint's own port is tried first, then an ephemeral one; the URL opened uses whichever was bound.
- **The loopback host is checked on the host.** An endpoint whose host isn't `localhost`, `127.0.0.1` or `::1` is not forwarded. Its Open action falls back to opening the URL as declared, which is what local does.
- **Two PRs.**
  1. The core forward (both ends, protocol, capability, host wiring) with an end-to-end test over real loopback sockets.
  2. The Mac wiring: the Run tab action, the preview, and the forward lifecycle tied to the run and the connection.

## Decisions from the builder check (my calls)

- **The Mac names a run by its `RunRecord.id`.** The host forwards only when that id is still the current active run of its worktree and is `.running`. A stale id, such as one from before a restart, is refused.
- **Flow control is explicit in both directions.**
  - Consoles pace only host to Mac and may drop output with a resync. TCP can't drop bytes.
  - Each side therefore grants the other a byte window per stream, and returns credit as it writes the bytes to its socket.
  - A side with no window left stops reading its socket.
  - A peer that sends beyond its window gets the stream closed.
- **Caps per run, per connection and in total,** in line with the console attachment limits. A stream over a cap is refused at open.
- **A reconnect drops every forward.** The manager is keyed by host connection, so the same host on a new connection starts clean. The Mac's listeners close, and the next Open starts again.
- **The opened URL keeps the endpoint's scheme, host, path and query, and replaces only the port** when the endpoint's port was busy on the Mac.
- **Whether an endpoint is loopback is decided once, in core:** `localhost`, `127.0.0.1` and `::1`/`[::1]`. A peer run's endpoint does not go through the SSH `.blockedRemoteLoopback` rule.
- **For now, the forwarded URL opens in the default browser.**
  - A peer worktree has no center tab strip: the peer UI shows one document and one console viewer. Web preview tabs, their persistence and their activation all assume local worktrees.
  - Bringing them into the peer view is a separate change, and a follow-up.
  - The browser still gets a true `localhost` origin, so hot reload, WebSockets and cookies work.
- **Errors use the peer error alert** (`hosts.showError`), as other peer run actions do.

## Left to the builder

- Exact names of the capability, the messages and the types.
- Chunk size, credit window and the per-run stream cap. Pick values in line with consoles.
- Whether data frames use the WebSocket's binary frames or the JSON encoding consoles use.
