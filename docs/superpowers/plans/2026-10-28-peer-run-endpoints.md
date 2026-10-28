# Peer run endpoint forwarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open a running host run's declared endpoint from the Mac by forwarding a Mac `127.0.0.1` port over the peer connection to the host's loopback port.

**Architecture:** A new peer message family carries the TCP streams: open, data, credit and close, keyed by a stream id the Mac chooses. In core, a host-side `PeerPortForwardHost` dials the run's loopback port, and a Mac-side `PeerPortForwarder` owns a loopback `NWListener`. Both are UI-free and are tested end to end in one process. The host gateway routes the messages. The Mac app starts a forward from the peer Run tab and opens the URL in the default browser.

**Tech Stack:** Swift 5.9+, Network.framework, Swift Testing, AlasCore SwiftPM package, SwiftUI app.

**Spec:** docs/superpowers/specs/2026-10-28-peer-run-endpoints-design.md

## Global Constraints

- Swift Testing only. Keep tests minimal and sharp per AGENTS.md. Use real loopback sockets and never a fixed `Task.sleep`; await events or poll with the repo's deadline helper.
- Core imports no UI. Public cross-module types are `Sendable`.
- No xcodebuild locally: the app's first build is CI. `swift test --package-path Packages/AlasCore` is fine.
- The Mac never sends a host or a port. It sends a run id, and the host resolves the port from its own run store, loopback only.
- The Mac's listener binds `127.0.0.1` only.
- Conventional Commits, no attribution trailers.

## Review Focus

1. **A dev server that streams more than the window,** such as a large bundle. No bytes are lost or reordered, and neither side buffers beyond its window. Tested by Task 2's e2e test (a payload several windows long, echoed back intact).
2. **The run stops while a browser connection is open.** The host closes the stream, and the Mac closes the accepted socket and its listener. Tested by Task 2.
3. **A stale run id, or a run that isn't running.** It is refused at open, and no socket is dialled. Tested by Task 1.
4. **The endpoint's port is busy on the Mac.** The forwarder binds an ephemeral port, and the URL it reports keeps scheme, host, path and query with the new port. Tested by Task 2.
5. **A peer that ignores its window.** The stream is closed, not buffered. Tested by Task 1.

---

### Task 1: Protocol and host-side forward

**Files:**
- Create: `Packages/AlasCore/Sources/AlasHostCore/Remote/Forward/PeerPortForwardProtocol.swift`
- Create: `Packages/AlasCore/Sources/AlasHostCore/Remote/Forward/PeerPortForwardHost.swift`
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Protocol/RemoteProtocol.swift` (new `case portForward(...)` on the client and server message enums, coded like `.console`, so older peers skip it as an unknown type)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/PeerPortForwardTests.swift` (new suite: no existing suite covers this type)

**Interfaces:**
- Produces:
  - `PeerPortForwardCapability.v1 = "host.runs.forward.v1"`.
  - `PeerPortForwardRequest` (Mac to host): `open(stream: UUID, runID: <RunRecord.id type>)`, `data(stream:, bytes: Data)`, `credit(stream:, bytes: Int)`, `close(stream:)`.
  - `PeerPortForwardEvent` (host to Mac): `opened(stream:)`, `refused(stream:, message: String)`, `data`, `credit`, `closed(stream:)`.
  - `PeerPortForwardLimits`: `window` (bytes), `maxChunk`, `maxStreamsPerRun`, `maxStreamsPerConnection` and `maxStreamsTotal`. Use values in line with `PeerConsoleOutbox` (64 KiB chunk, 512 KiB window) and the console attachment caps.
  - `PeerPortForwardHost`, built with:
    - `resolve: (runID) async -> Int?`, which returns the loopback port only for the current active `.running` run with a loopback endpoint;
    - a `send(connectionID, PeerPortForwardEvent)` sink.

    It exposes `receive(_ request:, from connectionID:)`, `connectionClosed(_:)` and `runEnded(_ runID:)`.
  - `PeerPortForwardEndpoint.isLoopback(URL) -> Bool`, true for `localhost`, `127.0.0.1`, `::1` and `[::1]`.

- [ ] **Step 1: Write the failing tests.**
  - `aStaleOrStoppedRunIsRefusedWithoutDialling`: `resolve` returns nil. `open` answers `refused` and nothing connects to a test listener.
  - `aPeerExceedingItsWindowLosesTheStream`: open against a real loopback echo server, then send `data` beyond `window` without credit. The host answers `closed`.
  - `loopbackEndpointsAreRecognised(arguments:)`: `http://localhost:3000`, `http://127.0.0.1:5173/x`, `http://[::1]:8080` give true; `http://dev.example:3000` and `http://0.0.0.0:3000` give false.
- [ ] **Step 2: Run them.** `swift test --package-path Packages/AlasCore --filter PeerPortForwardTests`. Expected: the build fails, because the types don't exist.
- [ ] **Step 3: Implement the protocol types and `PeerPortForwardHost`.** Each stream:
  - an `NWConnection` to `127.0.0.1:<port>`;
  - a receive loop that pauses when the Mac's window is used up and resumes on `credit`;
  - writes from Mac `data`, granting `credit` back once each write completes;
  - streams kept in a table per connection, with the caps enforced at `open`.
- [ ] **Step 4: Run them.** Expected: they pass. Then run the whole core suite, which also passes.
- [ ] **Step 5: Commit.** `feat(alas-host): forward a run's loopback endpoint over the peer connection`

### Task 2: Mac-side forwarder and end-to-end test

**Files:**
- Create: `Packages/AlasCore/Sources/AlasHostCore/Remote/Forward/PeerPortForwarder.swift`
- Test: extend `PeerPortForwardTests.swift`

**Interfaces:**
- Consumes: Task 1's types.
- Produces: `PeerPortForwarder`.
  - Built with the run id, the endpoint `URL`, and a `send(PeerPortForwardRequest)` sink.
  - `start() async throws -> URL` binds `127.0.0.1` at the endpoint's port, or an ephemeral port when that is busy, and returns the endpoint URL with only the port replaced.
  - `receive(_ event:)` handles events.
  - `stop()` closes the listener and every stream.

- [ ] **Step 1: Write the failing test** `aForwardedConnectionRelaysBothWaysAndEndsWithTheRun`. Wire a `PeerPortForwarder` to a `PeerPortForwardHost` in one process, with each side's `send` calling the other's `receive`, and point it at a real loopback echo server. Then:
  - Connect a client to the URL `start()` returned. Send a payload four windows long and read it back byte-for-byte.
  - Occupy the endpoint's port first. `start()` then returns a different port, with the same scheme, host, path and query.
  - Call `host.runEnded(runID)`. The client socket sees EOF, and a new connection to the forwarded port is refused once the forwarder stops.
- [ ] **Step 2: Run it.** Expected: the build fails.
- [ ] **Step 3: Implement it.** Each accepted connection gets a new stream id, sends `open` and buffers nothing before `opened`. A `refused` or `closed` event cancels the socket. Credit is handled symmetrically with Task 1. When the host reports the run ended, `stop()` follows.
- [ ] **Step 4: Run it, plus the whole core suite.** Expected: everything passes.
- [ ] **Step 5: Commit.** `feat(remote): relay a Mac loopback port to a host run's endpoint`

### Task 3: Host wiring

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Gateway/RemoteSessionGateway.swift` (route `.portForward` requests from a verified peer connection, as `.console` is routed)
- Modify: `Packages/AlasCore/Sources/alas-host/main.swift` (build a `PeerPortForwardHost` and advertise `PeerPortForwardCapability.v1` beside the console capabilities)
- Modify: the run lifecycle in `AlasCoreContext+Runs.swift`, so a run leaving `.running` calls `runEnded`
- Test: none new unless routing has its own decision logic; Task 2 pins the behaviour.

- [ ] **Step 1:** Route the requests and notify on connection close.
- [ ] **Step 2:** Make `resolve` read `RunRecordStore` (`isCurrentActiveRun`, `.running`, `PeerPortForwardEndpoint.isLoopback`) and return the endpoint's port. When the URL names no port, use the scheme's default.
- [ ] **Step 3:** Call `runEnded` when a run stops or exits.
- [ ] **Step 4:** Run `swift test --package-path Packages/AlasCore`. Expected: everything passes.
- [ ] **Step 5: Commit.** `feat(alas-host): serve run endpoint forwarding to paired Macs`

### Task 4: Mac app wiring (PR 2)

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Peer/RemotePeerManager.swift` (deliver `.portForward` events, as `.console` events are delivered at ~:1159, and let the app send requests)
- Modify: `Alas/Sources/Remote/Native/NativePeerHosts.swift` (forwards keyed by server id and run id, `servesForward(serverId:)`, all dropped on disconnect, reconnect or removal, and on the run leaving `.running`)
- Modify: `Alas/Sources/Right/RunTabPresentation.swift` (`peerRow` passes `record.endpoint`)
- Modify: `Alas/Sources/Right/NativePeerRunTabView.swift` (`.openEndpoint`)

- [ ] **Step 1:** `peerRow` carries the endpoint. Extend the existing `RunTabPresentation` test: a running peer row with an endpoint offers `.openEndpoint`.
- [ ] **Step 2:** `.openEndpoint` on a peer row does one of three things:
  - With a loopback endpoint and `servesForward`, it starts or reuses the forward and opens the returned URL in the default browser (`NSWorkspace.shared.open`).
  - With a non-loopback endpoint, it opens the URL as declared.
  - With an older host, the action is absent.

  Errors go through `hosts.showError`.
- [ ] **Step 3:** Run `swiftformat --lint` on the changed files and the extended test suite through CI. No xcodebuild.
- [ ] **Step 4: Commit.** `feat(remote): open a host run's endpoint from the Mac`
