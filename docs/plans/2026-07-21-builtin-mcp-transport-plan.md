# Built-in Alas MCP: transport toggle + registration detection — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Let the built-in `alas` MCP server run over localhost HTTP (default stays stdio), detect when the harness silently drops the injected server, and surface a one-click "switch to HTTP" fix — so enterprise-policy MCP blocks stop failing invisibly.

**Architecture:** The MCP protocol + tool schemas stay in the Rust `alas` binary (single source of truth). HTTP is a new `alas mcp --http` mode the app spawns & supervises per session. Both transports send a one-shot `mcp_hello` over the existing unix socket; the app records it and, if no hello arrives after the first turn + grace, marks the server `notRegistered` and offers a transport switch. See design: `docs/plans/2026-07-21-builtin-mcp-transport-design.md`.

**Tech Stack:** Swift 5.9 / SwiftUI (app), Swift Testing (`import Testing`), Rust 1.97 (`AlasCLI/` cargo workspace), std-only hand-rolled HTTP.

**Conventions:**
- App tests live under `AlasTests/` (mirror the `Alas/Sources/` path). `import Testing` + `@testable import Alas`.
- Rust tests are `#[cfg(test)] mod tests` in the same file.
- English only in code/comments/UI. No AI attribution in commits/PRs.
- App build: `xcodegen && xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build`. App tests: same with `test`.
- Rust build/test: `cd AlasCLI && cargo test` (fast) and `cargo build --release` (or `scripts/build-alas-cli.sh` for the fat binary the app bundles).
- Commit after every task. Keep changes small.

---

## Phase 0: Baseline

### Task 0: Verify baseline build + tests green

**Step 1:** Run `cd /Volumes/Workspace/ttdsrc/.worktrees/alas/nacho-mcp-not-found && cd AlasCLI && cargo test 2>&1 | tail -20`. Expected: PASS.

**Step 2:** Run `xcodegen && xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build 2>&1 | tail -20`. Expected: BUILD SUCCEEDED. (First build may be slow — GhosttyKit cache warms.)

**Step 3:** Run the app test suite: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test 2>&1 | tail -30`. Expected: tests pass. Record any pre-existing failures so later phases don't get blamed.

No commit (no changes).

---

## Phase A: Preamble honesty (Swift, independent, smallest)

Adds a CLI-fallback sentence to the `.mcp` preamble path so even a blocked session's agent knows `alas review resolve` works in a shell.

### Task A1: `.mcp` preamble mentions the CLI fallback

**Files:**
- Modify: `Alas/Sources/ACP/Session/ACPMCPPromptPreamble.swift` (function `mcpText`, ~lines 76-121)
- Test: `AlasTests/ACP/Session/ACPMCPPromptPreambleTests.swift`

**Step 1: Write the failing test.** Add to `ACPMCPPromptPreambleTests`:

```swift
@Test("mcp mode notes the alas CLI fallback for blocked servers")
func mcpMentionsCLIFallback() {
    let text = ACPMCPPromptPreamble.text(
        builtInInjected: true,
        isDelegated: false,
        userServerNames: [],
        mode: .mcp
    )
    #expect(text?.contains("alas") == true)
    // The fallback sentence must name the shell CLI explicitly.
    #expect(text?.contains("`alas` CLI") == true)
}
```

**Step 2: Run, verify it fails.** `xcodebuild ... test` filtered to this suite. Expected: FAIL (`.mcp` text lacks "`alas` CLI").

**Step 3: Implement.** In `mcpText`, inside `if builtInInjected { ... }`, after the existing `line += " Prefer these tools ..."` and `lines.append(line)`, append one more line:

```swift
lines.append(
    "If these MCP tools do not appear in your inventory (some harnesses "
    + "restrict MCP servers by policy), the same actions are available via "
    + "the `alas` CLI in your shell: `alas open`, `alas notify`, "
    + "`alas wt …`, `alas review …` (comments/reply/resolve/finish), "
    + "`alas session …`.")
```

**Step 4: Run, verify pass.** Expected: PASS. Also re-run the whole `ACPMCPPromptPreamble` suite so `rootBuiltIn`/`toolNameInventory` still pass (adjust only if an exact-string assertion breaks; prefer `contains` assertions).

**Step 5: Commit.** `git add -A && git commit -m "feat(acp): note alas CLI fallback in MCP preamble"`

---

## Phase B: Config field + settings picker

### Task B1: Add `AlasMCPTransport` enum + `harness.alasMCPTransport`

**Files:**
- Modify: `Alas/Sources/Persistence/AppConfig.swift` (the `Harness` struct, ~lines 220-276)
- Test: `AlasTests/Persistence/AppConfigTests.swift` (create if absent; otherwise the existing config-decode test file — grep for `Harness` under `AlasTests/`)

**Step 1: Write the failing test.** Verify the default and round-trip:

```swift
@Test("harness alasMCPTransport defaults to stdio when absent")
func alasMCPTransportDefaultsStdio() throws {
    let json = Data(#"{"exposeAlasMCP":true}"#.utf8)
    let harness = try JSONDecoder().decode(AppConfig.Harness.self, from: json)
    #expect(harness.alasMCPTransport == .stdio)
}

@Test("harness alasMCPTransport decodes http")
func alasMCPTransportDecodesHTTP() throws {
    let json = Data(#"{"alasMCPTransport":"http"}"#.utf8)
    let harness = try JSONDecoder().decode(AppConfig.Harness.self, from: json)
    #expect(harness.alasMCPTransport == .http)
}
```

(If `AppConfig.Harness` isn't directly decodable in isolation, decode a minimal full `AppConfig` JSON instead — check the existing test file's pattern.)

**Step 2: Run, verify it fails** (no such member). 

**Step 3: Implement.** In `AppConfig.swift`:
- Add near the top-level config enums (or just above `Harness`):
```swift
/// How the built-in "alas" MCP server is wired into local ACP sessions.
/// stdio (default) is spawned by the agent harness; http is served by a
/// supervised `alas mcp --http` process the app manages, for harnesses that
/// restrict stdio MCP servers by policy.
enum AlasMCPTransport: String, Codable, Equatable {
    case stdio
    case http
}
```
- In `Harness`: add `var alasMCPTransport: AlasMCPTransport` after `exposeAlasMCP`; add `alasMCPTransport` to `CodingKeys`; add `alasMCPTransport: AlasMCPTransport = .stdio` to the memberwise init and assign it; in `init(from:)` add `alasMCPTransport = (try? c.decode(AlasMCPTransport.self, forKey: .alasMCPTransport)) ?? .stdio`.

**Step 4: Run, verify pass.**

**Step 5: Commit.** `git commit -am "feat(config): add harness.alasMCPTransport (default stdio)"`

### Task B2: Transport picker in Agents settings pane

**Files:**
- Modify: `Alas/Sources/Settings/AgentsPane.swift` (Harness `SettingsGroup`, ~lines 63-67)

**Step 1:** No unit test (SwiftUI view wiring). Add a `SettingsRow` directly beneath the "Expose Alas tools to agents" row:

```swift
SettingsRow(name: "Alas MCP transport",
            desc: "How the built-in Alas MCP server is delivered. Use HTTP if your agent restricts stdio MCP servers by policy.") {
    Picker("", selection: state.bind(\.harness.alasMCPTransport)) {
        Text("Standard I/O (default)").tag(AlasMCPTransport.stdio)
        Text("HTTP (localhost)").tag(AlasMCPTransport.http)
    }
    .labelsHidden()
    .pickerStyle(.menu)
    .disabled(!state.harness.exposeAlasMCP)
}
```

(Match the existing `autoLaunchPicker` styling at line ~53 if it differs; keep `.disabled` gated on `exposeAlasMCP`.)

**Step 2:** Build only: `xcodebuild ... -quiet build`. Expected: SUCCEEDED.

**Step 3: Commit.** `git commit -am "feat(settings): add Alas MCP transport picker"`

---

## Phase C: Registration detection

### Task C1: Rust — `alas_client::send_hello`

**Files:**
- Modify: `AlasCLI/crates/alas-client/src/lib.rs`

**Step 1: Write the failing test.** In the `#[cfg(test)] mod tests` of `lib.rs`, add a test that the hello payload serializes with the expected shape. Since `send_hello` does socket IO, factor the payload builder out and test that:

```rust
#[test]
fn hello_payload_shape() {
    let v = hello_payload("SID-1", "stdio");
    assert_eq!(v["v"], 1);
    assert_eq!(v["kind"], "mcp_hello");
    assert_eq!(v["session_id"], "SID-1");
    assert_eq!(v["transport"], "stdio");
}
```

**Step 2: Run, verify fail.** `cd AlasCLI && cargo test -p alas-client hello_payload_shape`. Expected: FAIL (no `hello_payload`).

**Step 3: Implement.** Add to `lib.rs`:

```rust
/// The one-shot registration ping `alas mcp` sends over the unix socket so
/// the app knows the server actually started (stdio) or the adapter connected
/// (http). Modeled as its own `kind` so it never collides with the `"cli"`
/// request path or the hook-event path.
pub fn hello_payload(session_id: &str, transport: &str) -> serde_json::Value {
    serde_json::json!({
        "v": PROTOCOL_VERSION,
        "kind": "mcp_hello",
        "session_id": session_id,
        "transport": transport,
    })
}

/// Best-effort: send the hello and ignore the ack/errors — a failed hello must
/// never stop the MCP server from serving.
pub fn send_hello(socket: &Path, session_id: &str, transport: &str) {
    let payload = match serde_json::to_vec(&hello_payload(session_id, transport)) {
        Ok(p) => p,
        Err(_) => return,
    };
    if let Ok(mut stream) = UnixStream::connect(socket) {
        let _ = stream.set_read_timeout(Some(PROBE_TIMEOUT));
        let _ = stream.write_all(&payload);
        let _ = stream.flush();
        // Drain the ack so the app's write side doesn't error; ignore contents.
        let mut buf = Vec::new();
        let _ = stream.read_to_end(&mut buf);
    }
}
```

(`PROTOCOL_VERSION` is `1` at lib.rs line 7 — confirm it's an integer; if the app expects `"v":1` as a number, keep it numeric. Adjust the test's `v` expectation to match.)

**Step 4: Run, verify pass.** `cargo test -p alas-client`.

**Step 5: Commit.** `git commit -am "feat(alas-cli): add send_hello registration ping to alas-client"`

### Task C2: Rust — stdio `serve()` sends hello on startup

**Files:**
- Modify: `AlasCLI/crates/alas/src/mcp.rs` (`serve`, ~lines 688-711)

**Step 1: Test.** `serve` is a blocking stdio loop — assert behavior indirectly. Add a small test that a helper `hello_transport_label()` returns `"stdio"`, OR (simpler) just make the one-line change and rely on the client test + manual verification. Given IO, skip a dedicated unit test here; note it in the commit.

**Step 2: Implement.** At the very top of `serve`, before the `for line in ...` loop:

```swift
// Announce startup so the app can tell an injected-but-spawned server from
// one the harness silently dropped. Best-effort; never blocks serving.
alas_client::send_hello(&env.socket, &env.session_id, "stdio");
```
(Rust, not Swift — fenced for readability.)

**Step 3: Build.** `cd AlasCLI && cargo build 2>&1 | tail -5`. Expected: OK.

**Step 4: Commit.** `git commit -am "feat(alas-cli): send mcp_hello on stdio serve startup"`

### Task C3: Swift — socket server handles `mcp_hello`

**Files:**
- Modify: `Alas/Sources/Harness/AgentHookSocketServer.swift` (add callback + branch in `acceptAndHandle`, ~lines 138-163; `payloadKind` already reads `kind`)
- Create: `Alas/Sources/Harness/MCPHelloEvent.swift`
- Test: `AlasTests/Harness/MCPHelloEventTests.swift`

**Step 1: Write the failing test.**

```swift
import Testing
import Foundation
@testable import Alas

@Suite("MCPHelloEvent")
struct MCPHelloEventTests {
    @Test("decodes a well-formed hello")
    func decodes() throws {
        let data = Data(#"{"v":1,"kind":"mcp_hello","session_id":"S1","transport":"http"}"#.utf8)
        let hello = try MCPHelloEvent.decode(from: data)
        #expect(hello.sessionId == "S1")
        #expect(hello.transport == .http)
    }

    @Test("rejects empty session id")
    func rejectsEmpty() {
        let data = Data(#"{"kind":"mcp_hello","session_id":"","transport":"stdio"}"#.utf8)
        #expect(throws: (any Error).self) { try MCPHelloEvent.decode(from: data) }
    }

    @Test("unknown transport falls back to stdio")
    func unknownTransport() throws {
        let data = Data(#"{"kind":"mcp_hello","session_id":"S1","transport":"weird"}"#.utf8)
        let hello = try MCPHelloEvent.decode(from: data)
        #expect(hello.transport == .stdio)
    }
}
```

**Step 2: Run, verify fail** (no `MCPHelloEvent`).

**Step 3: Implement `MCPHelloEvent.swift`:**

```swift
import Foundation

/// The one-shot registration ping sent by `alas mcp` (see alas-client
/// `send_hello`). Its own socket `kind`, distinct from `AlasCLIRequest`
/// (`kind == "cli"`) and `AgentHookEvent` (no `kind`).
struct MCPHelloEvent: Equatable {
    let sessionId: String
    let transport: MCPTransportKind

    enum DecodeError: Error { case malformed }

    static func decode(from data: Data) throws -> MCPHelloEvent {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["kind"] as? String) == "mcp_hello",
              let sessionId = json["session_id"] as? String,
              !sessionId.isEmpty else {
            throw DecodeError.malformed
        }
        let raw = (json["transport"] as? String) ?? "stdio"
        // Only stdio/http are meaningful here; anything else is treated as
        // stdio so a forward-compat CLI can't wedge decoding.
        let transport: MCPTransportKind = (raw == "http") ? .http : .stdio
        return MCPHelloEvent(sessionId: sessionId, transport: transport)
    }
}
```

**Step 4:** Wire the server. In `AgentHookSocketServer.swift`:
- Add a callback next to `onEvent`/`onCLIRequest`:
```swift
var onMCPHello: ((MCPHelloEvent) -> Void)?
```
- In `acceptAndHandle`, add a branch before the `AgentHookEvent` decode (after the `"cli"` branch):
```swift
if Self.payloadKind(data) == "mcp_hello" {
    if let hello = try? MCPHelloEvent.decode(from: data) {
        Self.sendResponse(clientFD: clientFD, ok: true)
        let handler = onMCPHello
        DispatchQueue.main.async { handler?(hello) }
    } else {
        Self.sendResponse(clientFD: clientFD, ok: false, error: "Malformed request.")
    }
    return
}
```

**Step 5: Run, verify pass** (the `MCPHelloEventTests` suite). Build the app.

**Step 6: Commit.** `git commit -am "feat(harness): decode + dispatch mcp_hello socket events"`

### Task C4: Swift — `MCPRegistrationRegistry`

**Files:**
- Create: `Alas/Sources/ACP/Session/MCPRegistrationRegistry.swift`
- Test: `AlasTests/ACP/Session/MCPRegistrationRegistryTests.swift`

**Step 1: Write the failing test.**

```swift
import Testing
@testable import Alas

@MainActor
@Suite("MCPRegistrationRegistry")
struct MCPRegistrationRegistryTests {
    @Test("records and reports a hello")
    func records() {
        let r = MCPRegistrationRegistry()
        #expect(r.isRegistered(sessionId: "S1") == false)
        r.recordHello(sessionId: "S1", transport: .stdio)
        #expect(r.isRegistered(sessionId: "S1") == true)
    }

    @Test("clear on new attach epoch drops the record")
    func clear() {
        let r = MCPRegistrationRegistry()
        r.recordHello(sessionId: "S1", transport: .http)
        r.clear(sessionId: "S1")
        #expect(r.isRegistered(sessionId: "S1") == false)
    }
}
```

**Step 2: Run, verify fail.**

**Step 3: Implement.**

```swift
import Foundation

/// Tracks which sessions' built-in MCP server actually announced itself
/// (see `MCPHelloEvent`). Cleared per attach epoch so a reconnect re-proves
/// registration. Main-actor: mutated from the socket callback and read from
/// the session manager, both on the main queue.
@MainActor
final class MCPRegistrationRegistry {
    struct Record: Equatable {
        let transport: MCPTransportKind
    }

    private var records: [String: Record] = [:]

    func recordHello(sessionId: String, transport: MCPTransportKind) {
        records[sessionId] = Record(transport: transport)
    }

    func clear(sessionId: String) {
        records[sessionId] = nil
    }

    func isRegistered(sessionId: String) -> Bool {
        records[sessionId] != nil
    }

    func transport(sessionId: String) -> MCPTransportKind? {
        records[sessionId]?.transport
    }
}
```

**Step 4: Run, verify pass.**

**Step 5: Commit.** `git commit -am "feat(acp): add MCPRegistrationRegistry"`

### Task C5: Swift — registration state on the session + pure decision

**Files:**
- Modify: `Alas/Sources/ACP/Session/ACPSession.swift` (add observable field)
- Create: `Alas/Sources/ACP/Session/MCPRegistrationDecision.swift`
- Test: `AlasTests/ACP/Session/MCPRegistrationDecisionTests.swift`

**Step 1: Write the failing test** for the pure decision:

```swift
import Testing
@testable import Alas

@Suite("MCPRegistrationDecision")
struct MCPRegistrationDecisionTests {
    @Test("registered when hello seen")
    func registered() {
        #expect(MCPRegistrationDecision.resolve(helloSeen: true, turnStarted: true, graceElapsed: true) == .registered)
    }
    @Test("unknown before first turn completes")
    func unknownEarly() {
        #expect(MCPRegistrationDecision.resolve(helloSeen: false, turnStarted: false, graceElapsed: false) == .unknown)
    }
    @Test("notRegistered only after turn + grace with no hello")
    func notRegistered() {
        #expect(MCPRegistrationDecision.resolve(helloSeen: false, turnStarted: true, graceElapsed: true) == .notRegistered)
        #expect(MCPRegistrationDecision.resolve(helloSeen: false, turnStarted: true, graceElapsed: false) == .unknown)
    }
}
```

**Step 2: Run, verify fail.**

**Step 3: Implement.**

```swift
enum MCPServerRegistration: Equatable {
    case unknown
    case registered
    case notRegistered
}

/// Pure policy for resolving registration from observable signals so the
/// timing wiring in the session manager stays thin and this stays testable.
enum MCPRegistrationDecision {
    static func resolve(helloSeen: Bool, turnStarted: Bool, graceElapsed: Bool) -> MCPServerRegistration {
        if helloSeen { return .registered }
        if turnStarted && graceElapsed { return .notRegistered }
        return .unknown
    }
}
```

Add to `ACPSession` an observable stored property:
```swift
/// Registration state of the built-in "alas" MCP server for the current
/// attach. Drives the MCP status control's warning + transport-switch action.
@Published var builtInMCPRegistration: MCPServerRegistration = .unknown
```
(Match ACPSession's actual observation mechanism — if it's an `@Observable` class, use a plain `var`; if `ObservableObject`, use `@Published`. Grep the class declaration first.)

**Step 4: Run, verify pass.** Build.

**Step 5: Commit.** `git commit -am "feat(acp): registration decision + session state"`

### Task C6: Wire registry → session; schedule the grace check

**Files:**
- Modify: `Alas/Sources/App/AppState.swift` (own the registry; wire `socketServer.onMCPHello`; inject an `isBuiltInMCPRegistered` closure into the manager — near builtInMCPProvider ~lines 4810-4834 and manager construction)
- Modify: `Alas/Sources/ACP/Session/ACPSessionManager.swift` (clear registry on attach; after first turn, schedule grace check; set `session.builtInMCPRegistration`)

**Step 1:** No new unit test (integration wiring; the decision + registry are already covered). 

**Step 2: Implement — AppState:**
- Add `let mcpRegistrationRegistry = MCPRegistrationRegistry()` (place with other `@MainActor` app services).
- Where `harness.socketServer.onCLIRequest` is set (~line 2051), also set:
```swift
harness.socketServer.onMCPHello = { [weak self] hello in
    guard let self else { return }
    self.mcpRegistrationRegistry.recordHello(sessionId: hello.sessionId, transport: hello.transport)
    // Heal the live session immediately if it's already flipped to
    // notRegistered (a lazy/slow harness).
    if let session = self.liveACPSession(forSessionId: hello.sessionId) {
        session.builtInMCPRegistration = .registered
    }
}
```
(Find the existing helper that maps a sessionId → live ACPSession — the report notes `worktreeIdForLiveACPSession` / `acpManagers…liveSession(for:)`; reuse whatever exists.)
- Pass a registry-reading closure into the manager factory (add a parameter to `ACPSessionManager.init` mirroring existing closure params): `isBuiltInMCPRegistered: { [weak self] sessionId in self?.mcpRegistrationRegistry.isRegistered(sessionId: sessionId) ?? false }` and a `clearMCPRegistration:` closure `{ [weak self] sessionId in self?.mcpRegistrationRegistry.clear(sessionId: sessionId) }`.

**Step 3: Implement — ACPSessionManager:**
- Add the two closures as stored properties + init params (follow the existing pattern used for `builtInMCPProvider` at ~line 362/379).
- When an attach epoch begins (right where `builtInMCP` is computed, ~line 2537), call `clearMCPRegistration?(sessionId)` and set `session.builtInMCPRegistration = .unknown`. Only do this when a built-in server was actually injected (`builtInMCP != nil`); if not injected, leave `.unknown` and skip detection.
- After the first prompt turn of the epoch completes (find where the runner reports turn end / streaming completion; grep for where `agentState` becomes idle or the runner's turn-complete callback), schedule a one-shot check:
```swift
// Grace after the first turn: by now a working harness has registered its
// MCP servers. If ours never said hello, surface it as notRegistered.
Task { @MainActor [weak self, weak session] in
    try? await Task.sleep(for: .seconds(10))
    guard let self, let session else { return }
    let helloSeen = self.isBuiltInMCPRegistered?(sessionId) ?? false
    session.builtInMCPRegistration = MCPRegistrationDecision.resolve(
        helloSeen: helloSeen, turnStarted: true, graceElapsed: true)
}
```
Guard so this only runs once per epoch and only when the built-in server was injected. (If a turn-complete hook is awkward to find, an acceptable simpler trigger: schedule the check ~15s after `createdFreshRemoteSession`/attach, still gated on `builtInMCP != nil`. Prefer turn-based if a hook exists.)

**Step 4: Build + full app test suite.** Expected: SUCCEEDED / green.

**Step 5: Commit.** `git commit -am "feat(acp): detect unregistered built-in MCP server after first turn"`

---

## Phase D: Status UI + guided switch

### Task D1: Policy maps registration → warning row + action flag

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPMCPStatusPolicy.swift` (`ACPMCPStatusState`, `Row` ~lines 7-13, `row(...)` mapping ~lines 120-146; add a stored `showsSwitchToHTTPAction`)
- Test: `AlasTests/ACP/UI/ACPMCPStatusPolicyTests.swift`

**Step 1: Write the failing test.** The policy needs the built-in registration + current transport as inputs. Extend the state initializer with `builtInRegistration: MCPServerRegistration` and `transport: AlasMCPTransport` (defaulted so existing tests compile):

```swift
@Test("notRegistered on stdio offers the HTTP switch")
func offersالسwitch() { // rename to offersSwitch
    let status = MCPAttachmentServerStatus(
        id: "builtin-alas", name: "alas", transport: .stdio, disposition: .requested)
    let state = ACPMCPStatusState(
        statuses: [status],
        builtInRegistration: .notRegistered,
        transport: .stdio)
    #expect(state.showsSwitchToHTTPAction == true)
    #expect(state.hasBuiltInWarning == true)
}

@Test("notRegistered on http warns without the switch")
func warnsNoSwitchOnHTTP() {
    let status = MCPAttachmentServerStatus(
        id: "builtin-alas", name: "alas", transport: .http, disposition: .requested)
    let state = ACPMCPStatusState(
        statuses: [status],
        builtInRegistration: .notRegistered,
        transport: .http)
    #expect(state.showsSwitchToHTTPAction == false)
    #expect(state.hasBuiltInWarning == true)
}

@Test("registered shows no warning")
func registeredNoWarning() {
    let status = MCPAttachmentServerStatus(
        id: "builtin-alas", name: "alas", transport: .stdio, disposition: .requested)
    let state = ACPMCPStatusState(
        statuses: [status], builtInRegistration: .registered, transport: .stdio)
    #expect(state.hasBuiltInWarning == false)
}
```

**Step 2: Run, verify fail.**

**Step 3: Implement.** In `ACPMCPStatusState`:
- Add stored `let showsSwitchToHTTPAction: Bool` and `let hasBuiltInWarning: Bool`.
- Extend the init with `builtInRegistration: MCPServerRegistration = .unknown` and `transport: AlasMCPTransport = .stdio`. Compute:
```swift
let builtInIsNotRegistered = (builtInRegistration == .notRegistered)
self.hasBuiltInWarning = builtInIsNotRegistered
self.showsSwitchToHTTPAction = builtInIsNotRegistered && transport == .stdio
```
- Use `BuiltInAlasMCP.statusId` ("builtin-alas") to identify the built-in row if per-row rendering needs the flag.

**Step 4: Run, verify pass.**

**Step 5: Commit.** `git commit -am "feat(acp-ui): map unregistered built-in MCP to a warning + switch action"`

### Task D2: Status control renders warning + "Switch to HTTP" button

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPMCPStatusControl.swift` (build `ACPMCPStatusState` with the new inputs ~lines 13-21; render warning banner near the stale banner ~lines 95-107; add an action row modeled on `installActionRow` ~lines 156-188)

**Step 1:** No unit test (view). Wire:
- When constructing `ACPMCPStatusState`, pass `builtInRegistration: session.builtInMCPRegistration` and `transport: <config.harness.alasMCPTransport>`. The control needs access to the config transport + a switch action — thread them in from the parent (the view that owns `session` also has AppState/config access). Add a closure param to the control, e.g. `var onSwitchToHTTP: () -> Void`.
- In the popover, when `status.hasBuiltInWarning`, show a warning line: *"The agent harness didn't start the Alas MCP server — it may be blocked by an enterprise MCP policy (stdio servers are commonly restricted)."* On `status.showsSwitchToHTTPAction`, render an `AlasButton(title: "Switch to HTTP transport", style: .subtle)` that calls `onSwitchToHTTP`. When `!showsSwitchToHTTPAction` but `hasBuiltInWarning` (already http), show a hint: *"Already using HTTP; check whether your agent policy allows http://localhost MCP servers."*

**Step 2:** Wire `onSwitchToHTTP` at the call site (grep for `ACPMCPStatusControl(`): flip the setting + offer reconnect:
```swift
onSwitchToHTTP: {
    appState.updateConfig { $0.harness.alasMCPTransport = .http }
    appState.reconnectACPSession(sessionId: session.id)  // reuse existing reconnect path
}
```
(Use the real config-mutation + reconnect APIs — grep for how other settings mutate config and how a session reconnect is triggered, e.g. `scheduleAutoReconnect` or an explicit reconnect method.)

**Step 3: Build.** Expected: SUCCEEDED.

**Step 4: Commit.** `git commit -am "feat(acp-ui): warn + offer HTTP switch when built-in MCP is unregistered"`

---

## Phase E: HTTP transport

### Task E1: Rust — `alas mcp --http` argument detection

**Files:**
- Modify: `AlasCLI/crates/alas/src/main.rs` (`is_mcp_invocation` ~lines 77-79, `run_mcp` ~lines 81-96, dispatch ~lines 20-22)

**Step 1: Write the failing test.** In `main.rs` tests, assert a parser helper distinguishes modes:

```rust
#[test]
fn mcp_mode_detection() {
    assert_eq!(mcp_mode(&["mcp".into()]), Some(McpMode::Stdio));
    assert_eq!(mcp_mode(&["mcp".into(), "--http".into()]), Some(McpMode::Http));
    assert_eq!(mcp_mode(&["open".into()]), None);
}
```

**Step 2: Run, verify fail.**

**Step 3: Implement.** Add:
```rust
#[derive(Debug, PartialEq)]
enum McpMode { Stdio, Http }

fn mcp_mode(args: &[String]) -> Option<McpMode> {
    match args {
        [only] if only == "mcp" => Some(McpMode::Stdio),
        [first, second] if first == "mcp" && second == "--http" => Some(McpMode::Http),
        _ => None,
    }
}
```
Route in `main()`: replace the `is_mcp_invocation` check to use `mcp_mode(&args)`, calling `run_mcp(mode)` which branches to `mcp::serve(&env)` (stdio) or `mcp::serve_http(&env)` (http).

**Step 4: Run, verify pass.** `cargo test -p alas`.

**Step 5: Commit.** `git commit -am "feat(alas-cli): detect 'alas mcp --http' mode"`

### Task E2: Rust — `serve_http` MCP-over-HTTP server

**Files:**
- Modify: `AlasCLI/crates/alas/src/mcp.rs` (new `serve_http`; a small std-only HTTP request parser; token check; reuse `handle_line_with_parent` + `dispatch`)

**Step 1: Write the failing tests** for the pure HTTP-parsing + response helpers (not the socket loop):

```rust
#[test]
fn parses_post_body_and_token() {
    let raw = "POST /mcp HTTP/1.1\r\nAuthorization: Bearer TOK\r\nContent-Length: 2\r\n\r\n{}";
    let req = parse_http_request(raw.as_bytes()).unwrap();
    assert_eq!(req.bearer.as_deref(), Some("TOK"));
    assert_eq!(req.body, "{}");
}

#[test]
fn builds_json_http_response() {
    let resp = http_response(200, "application/json", "{\"ok\":true}");
    assert!(resp.starts_with("HTTP/1.1 200"));
    assert!(resp.contains("Content-Length: 11"));
    assert!(resp.ends_with("{\"ok\":true}"));
}
```

**Step 2: Run, verify fail.**

**Step 3: Implement.** Add to `mcp.rs`:
- `struct HttpRequest { method, path, bearer: Option<String>, body: String }` and `fn parse_http_request(&[u8]) -> Option<HttpRequest>` (split on `\r\n\r\n`, parse request line, headers case-insensitively for `authorization` (`Bearer <t>`) and `content-length`, read body of that length).
- `fn http_response(status: u16, content_type: &str, body: &str) -> String` — status line + `Content-Type` + `Content-Length` + `\r\n\r\n` + body. Include `200 OK`, `202 Accepted`, `401 Unauthorized`, `400 Bad Request` reasons.
- `pub fn serve_http(env: &McpEnv) -> std::io::Result<()>`:
  - Read the required token from env once at startup: `let token = std::env::var("ALAS_MCP_HTTP_TOKEN").unwrap_or_default();`
  - `let listener = TcpListener::bind("127.0.0.1:0")?;` then `println!("PORT {}", listener.local_addr()?.port());` and flush stdout.
  - Track a `hello_sent` bool. For each incoming stream: read request bytes until headers+body complete; if `parse_http_request` fails → 400; if `token.is_empty()` or `req.bearer != Some(token)` → 401 (empty body). Otherwise handle the JSON-RPC body via `handle_line_with_parent(&req.body, &env.worktree_dir, env.parent_session_id.as_deref(), |cmd| dispatch(env, cmd))`. If it returns `Some(reply)` → 200 with `reply.to_string()`. If `None` (notification) → 202 empty. On the first successfully-authenticated `initialize`, call `alas_client::send_hello(&env.socket, &env.session_id, "http")` once (set `hello_sent = true`).
  - Keep it single-threaded/accept-loop; alas tool calls are quick. Bound the request read (e.g. 1 MiB) → 400 on overflow.

**Step 4: Run, verify pass** (`cargo test -p alas`). Manual smoke: `ALAS_SOCKET_PATH=... ALAS_WORKTREE_DIR=$PWD ALAS_SESSION_ID=t ALAS_MCP_HTTP_TOKEN=TOK ./target/debug/alas mcp --http &` then `curl -s -H 'Authorization: Bearer TOK' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' http://localhost:<port>/mcp` returns the tool list; a wrong token returns 401.

**Step 5: Commit.** `git commit -am "feat(alas-cli): serve MCP over localhost HTTP with bearer auth"`

### Task E3: Swift — `BuiltInAlasMCP.injection` http variant

**Files:**
- Modify: `Alas/Sources/ACP/Session/BuiltInAlasMCP.swift`
- Test: `AlasTests/ACP/Session/BuiltInAlasMCPTests.swift`

**Step 1: Write the failing test.** Add an http-variant test. Introduce a `transport`/endpoint parameter to `injection` (keep stdio the default so existing tests pass):

```swift
@Test("builds an http wire entry when given an endpoint")
func buildsHTTPWireEntry() {
    let injection = BuiltInAlasMCP.injection(
        enabled: true,
        configuredServers: [],
        binaryPath: "/bin/alas",
        socketPath: "/tmp/s.sock",
        worktreePath: "/wt",
        sessionId: "S1",
        httpEndpoint: .init(url: "http://localhost:5599/mcp", token: "TOK"))
    guard case let .http(name, url, headers)? = injection?.server else {
        Issue.record("expected http server"); return
    }
    #expect(name == "alas")
    #expect(url == "http://localhost:5599/mcp")
    #expect(headers.contains(.init(name: "Authorization", value: "Bearer TOK")))
    #expect(injection?.status.transport == .http)
}
```

**Step 2: Run, verify fail.**

**Step 3: Implement.** Add a nested `struct HTTPEndpoint { let url: String; let token: String }` and an optional `httpEndpoint: HTTPEndpoint? = nil` param. When `httpEndpoint` is non-nil, build `.http(name: serverName, url: endpoint.url, headers: [.init(name: "Authorization", value: "Bearer \(endpoint.token)")])` and status `transport: .http`; otherwise the existing `.stdio(...)` path. Keep the user-override + enabled/nil guards unchanged for both.

**Step 4: Run, verify pass** (whole `BuiltInAlasMCP` suite — `buildsWireEntry` still asserts stdio).

**Step 5: Commit.** `git commit -am "feat(acp): http variant for BuiltInAlasMCP.injection"`

### Task E4: Swift — `AlasMCPHTTPSupervisor`

**Files:**
- Create: `Alas/Sources/ACP/Session/AlasMCPHTTPSupervisor.swift`
- Test: `AlasTests/ACP/Session/AlasMCPHTTPSupervisorTests.swift`

**Step 1: Write the failing test** for the pure parts (token gen + PORT line parsing + endpoint bookkeeping); the actual `Process` spawn is integration-verified:

```swift
@MainActor
@Suite("AlasMCPHTTPSupervisor")
struct AlasMCPHTTPSupervisorTests {
    @Test("parses the PORT announcement line")
    func parsesPort() {
        #expect(AlasMCPHTTPSupervisor.parsePort(from: "PORT 5599\n") == 5599)
        #expect(AlasMCPHTTPSupervisor.parsePort(from: "garbage") == nil)
    }
}
```

**Step 2: Run, verify fail.**

**Step 3: Implement.** A `@MainActor final class AlasMCPHTTPSupervisor`:
- `static func parsePort(from line: String) -> Int?` — parse `PORT <n>`.
- `struct Running { let process: Process; let port: Int; let token: String }` and `private var running: [String: Running]`.
- `func endpoint(binaryPath: String, socketPath: String, worktreePath: String, sessionId: String, parentSessionId: String?) async -> BuiltInAlasMCP.HTTPEndpoint?`:
  - If a live entry exists (`process.isRunning`), return its endpoint.
  - Else generate a token (`UUID().uuidString`), build a `Process` running `binaryPath` with args `["mcp", "--http"]` and env `ALAS_SOCKET_PATH`, `ALAS_WORKTREE_DIR`, `ALAS_SESSION_ID`, `ALAS_MCP_HTTP_TOKEN`, optional `ALAS_PARENT_SESSION_ID`. Pipe stdout; launch; read the first line, `parsePort`; store `Running`; return `.init(url: "http://localhost:\(port)/mcp", token: token)`. On failure (no port within a short timeout, or launch throws), return `nil` so the caller falls back to stdio.
- `func end(sessionId: String)` — terminate + remove.
- `func shutdown()` — terminate all (call from AppState teardown).

**Step 4: Run, verify pass.** Build.

**Step 5: Commit.** `git commit -am "feat(acp): AlasMCPHTTPSupervisor to spawn alas mcp --http"`

### Task E5: Wire transport choice into AppState `builtInMCPProvider`

**Files:**
- Modify: `Alas/Sources/App/AppState.swift` (`builtInMCPProvider` ~lines 4810-4834; own an `AlasMCPHTTPSupervisor`; terminate on session end + app teardown)

**Step 1:** No new unit test (integration). 

**Step 2: Implement.**
- Add `let mcpHTTPSupervisor = AlasMCPHTTPSupervisor()`.
- In `builtInMCPProvider`, after computing `binaryPath`/`parentSessionId`, branch on `self.config.harness.alasMCPTransport`:
  - `.stdio`: existing call (no `httpEndpoint`).
  - `.http`: `let endpoint = await self.mcpHTTPSupervisor.endpoint(binaryPath: binaryPath, socketPath: self.harness.socketServer.socketPath, worktreePath: worktreePath, sessionId: sessionId, parentSessionId: parentSessionId)`. If `endpoint == nil`, fall back to the stdio call (log a note). Else call `BuiltInAlasMCP.injection(..., httpEndpoint: endpoint)`.
  (`binaryPath` may be nil in tests — keep the existing nil-guard: return nil injection.)
- On session end/teardown (grep for where sessions are removed / `scheduleAutoReconnect` peers, or the ACP session close path), call `mcpHTTPSupervisor.end(sessionId:)`.
- On app teardown (where `harness.socketServer.shutdown()` is called / app termination), call `mcpHTTPSupervisor.shutdown()`.

**Step 3: Build + full app test suite.** Expected: green.

**Step 4: Commit.** `git commit -am "feat(app): serve built-in MCP over http when configured"`

---

## Phase F: Integration verification

### Task F0: Full build + test + fat CLI

**Step 1:** `cd AlasCLI && cargo test 2>&1 | tail -20` → PASS.
**Step 2:** `scripts/build-alas-cli.sh 2>&1 | tail -5` → builds the fat binary the app bundles.
**Step 3:** `xcodegen && xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build` → SUCCEEDED.
**Step 4:** `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test 2>&1 | tail -30` → green.
**Step 5:** If `project.yml` changed, ensure `xcodegen` was run and both files committed (per CLAUDE.md). New source files under `Alas/Sources/**` are globbed automatically — no project.yml edit needed unless a new top-level group is introduced.

No code commit unless fixes were needed.

---

## Notes & risks

- **New Swift files** under `Alas/Sources/**` and `AlasTests/**` are picked up by xcodegen's glob — no `project.yml` edit expected. Run `xcodegen` before building regardless.
- **Rust binary must be rebuilt** for the app to pick up hello/http changes: the app bundles the output of `scripts/build-alas-cli.sh` via a preBuildScript. A normal `xcodebuild` runs that script, but if iterating on Rust alone, run the script (or `cargo build --release`) so the bundled binary matches.
- **`v` field type** in the hello: confirm whether the app/CLI protocol uses numeric `1` (matches `AgentHookEvent`'s `version`). Keep the Rust `hello_payload` and the Swift decoder consistent; the Swift decoder above doesn't check `v`, so either is safe, but keep them aligned.
- **Grace-check trigger**: prefer hooking the first turn-complete callback; a timer-after-attach is an acceptable fallback. Never flip to `notRegistered` when no built-in server was injected.
- **HTTP fallback**: if the supervisor can't get a port, injection falls back to stdio for that attach — strictly better than no tools.
- **Reconnect after switch**: reuse the existing session-reconnect path; the adapter's session fingerprint includes `mcpServers`, so the transport change forces a query recreate on reattach (verified in adapter source).
