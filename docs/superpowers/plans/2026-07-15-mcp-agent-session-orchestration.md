# MCP Agent Session Orchestration Implementation Plan

> **For implementers:** Execute this plan task-by-task. Keep each task
> independently tested and commit at the listed boundary before moving on.

**Goal:** Add `session_list`, `session_new`, and `session_send` to the built-in
Alas MCP server and CLI so a root ACP session can delegate work to direct child
sessions in current, existing, or newly created worktrees while Alas preserves
authorization, writer leases, durable delivery, honest UI attribution, and
user-owned lifecycle.

**Design:**
[`2026-07-15-mcp-agent-session-orchestration-design.md`](../specs/2026-07-15-mcp-agent-session-orchestration-design.md)

**Architecture:** Add an app-level SQLite orchestration store and a main-actor
coordinator. The store owns only parent-child edges, asynchronous creation
phase, pending initial prompts, and a short-lived message inbox. Existing
per-worktree ACP databases remain authoritative for sessions, queues,
transcripts, and writer leases. Swift enforces graph permissions and routes
operations; Rust keeps CLI and MCP parsing in parity over the existing socket
request.

**Tech Stack:** Swift 5.9+, SwiftUI, Foundation, SQLite3, Swift Testing, Rust,
Serde/serde_json, MCP JSON-RPC, XcodeGen.

---

## File Structure

Create focused orchestration files:

- `Alas/Sources/ACP/Orchestration/ACPOrchestrationModels.swift`
  - Persisted edge, worktree request, phase, inbox message, public state, and
    stable response DTOs.
- `Alas/Sources/ACP/Orchestration/ACPOrchestrationStore.swift`
  - Synchronous SQLite schema and transactional operations.
- `Alas/Sources/ACP/Orchestration/ACPOrchestrationPersistence.swift`
  - Lazy, actor-isolated store owner matching `ACPSessionPersistence`.
- `Alas/Sources/ACP/Orchestration/ACPSessionOrchestrationPolicy.swift`
  - Pure graph authorization, request validation, and public-state projection.
- `Alas/Sources/ACP/Orchestration/ACPSessionOrchestrationCoordinator.swift`
  - App-level creation, routing, reconciliation, and observable summaries.
- `Alas/Sources/ACP/Orchestration/ACPDelegatedPromptSource.swift`
  - Codable prompt/message provenance shared by queues and transcript rows.
- `Alas/Sources/ACP/UI/ACPDelegatedSessionsPolicy.swift`
  - Pure row ordering, labels, status, and navigation policy for SwiftUI.

Create focused tests:

- `AlasTests/ACP/Orchestration/ACPOrchestrationStoreTests.swift`
- `AlasTests/ACP/Orchestration/ACPSessionOrchestrationPolicyTests.swift`
- `AlasTests/ACP/Orchestration/ACPSessionOrchestrationCoordinatorTests.swift`
- `AlasTests/ACP/Orchestration/ACPDelegatedMessageDeliveryTests.swift`
- `AlasTests/ACP/UI/ACPDelegatedSessionsPolicyTests.swift`

Modify these existing ownership points:

- `Alas/Sources/Persistence/Paths.swift`
- `Alas/Sources/Harness/AlasCLIRequest.swift`
- `Alas/Sources/App/AlasActionService.swift`
- `Alas/Sources/App/AlasCLICommandRouter.swift`
- `Alas/Sources/App/AppState.swift`
- `Alas/Sources/App/WorktreeLaunchSurface.swift`
- `Alas/Sources/ACP/Session/ACPSession.swift`
- `Alas/Sources/ACP/Session/ACPSessionManager.swift`
- `Alas/Sources/ACP/Session/ACPSessionPersistence.swift`
- `Alas/Sources/ACP/Session/ACPMessage.swift`
- `Alas/Sources/ACP/Session/ACPMessageWire.swift`
- `Alas/Sources/ACP/Session/QueuedPrompt.swift`
- `Alas/Sources/ACP/Session/BuiltInAlasMCP.swift`
- `Alas/Sources/ACP/UI/ACPMessageList.swift`
- `Alas/Sources/ACP/UI/ACPSessionsButton.swift`
- `Alas/Sources/ACP/UI/ACPToolbar.swift`
- `AlasCLI/crates/alas-client/src/lib.rs`
- `AlasCLI/crates/alas/src/parse.rs`
- `AlasCLI/crates/alas/src/mcp.rs`

New files are picked up by recursive source groups. Regenerate
`Alas.xcodeproj` with `xcodegen`; do not edit `project.yml` unless source-group
behavior proves otherwise.

## Shared Verification Notes

- Prefix every command with `rtk`.
- Run Xcode test invocations serially; do not overlap them against the same
  build database.
- Use `ALAS_FFF_TARGET_ARCH=arm64` if the local Ghostty/fff build requests an
  unavailable x86_64 Rust target.
- Focused Swift tests use `-only-testing:AlasTests/<SuiteName>`.
- Run Rust tests from `AlasCLI` or with `--manifest-path AlasCLI/Cargo.toml`.

### Task 1: Add Durable Orchestration Models And Store

**Files:**
- Create: `Alas/Sources/ACP/Orchestration/ACPOrchestrationModels.swift`
- Create: `Alas/Sources/ACP/Orchestration/ACPOrchestrationStore.swift`
- Create: `Alas/Sources/ACP/Orchestration/ACPOrchestrationPersistence.swift`
- Modify: `Alas/Sources/Persistence/Paths.swift`
- Test: `AlasTests/ACP/Orchestration/ACPOrchestrationStoreTests.swift`
- Regenerate: `Alas.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing store tests**

Cover:

- schema creation on a new database;
- delegation insert/load/list by parent/list by child;
- unique child ID and one-parent constraints;
- current, existing, and new-worktree request round trips;
- phase, child worktree, failure, and timestamp updates;
- pending initial prompt retention and atomic clear;
- inbox insert/load and source/target edge fields;
- atomic message claim by one instance/token;
- delivered-message tombstone or ID deduplication;
- reopening the same file preserves all records; and
- an older/empty database migrates without main-actor I/O.

Use a temporary SQLite path per test and a short busy timeout. Assert typed
records, not raw SQL rows.

- [ ] **Step 2: Run the focused test and verify failure**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/ACPOrchestrationStoreTests test \
  ALAS_FFF_TARGET_ARCH=arm64
```

Expected: compilation fails because orchestration types do not exist.

- [ ] **Step 3: Implement the persisted model**

Define:

```swift
enum ACPDelegatedWorktreeRequest: Codable, Equatable, Sendable {
    case current(worktreeId: String)
    case existing(worktreeId: String)
    case new(branch: String, base: String?, destinationPath: String, optimisticId: String)
}

enum ACPDelegationPhase: String, Codable, Equatable, Sendable {
    case creatingWorktree
    case starting
    case ready
    case failed
    case closed
}

struct ACPDelegationRecord: Equatable, Sendable {
    let childSessionId: String
    let parentSessionId: String
    let projectId: String
    let parentWorktreeId: String
    var childWorktreeId: String?
    let agentId: String
    let worktreeRequest: ACPDelegatedWorktreeRequest
    var pendingInitialPrompt: String?
    var phase: ACPDelegationPhase
    var failureMessage: String?
    let createdAt: Int64
    var updatedAt: Int64
}
```

Add an inbox record with stable message ID, source/target IDs, prompt, creation
time, optional claim owner/token/time, and delivery marker. Do not store
transcript excerpts, agent output, or permission data.

- [ ] **Step 4: Implement SQLite and actor ownership**

Follow `ACPSessionStore`/`ACPSessionPersistence` conventions:

- lazy open on an actor executor;
- WAL and busy timeout;
- explicit schema version/migrations;
- parameterized statements only;
- transactional claim/delivery operations; and
- deterministic row decoding with typed errors.

Add:

```swift
static var acpOrchestrationDB: URL {
    appSupportRoot.appendingPathComponent("acp-orchestration.sqlite")
}
```

The claim transaction must make two consumers racing for one inbox message
produce exactly one winner.

- [ ] **Step 5: Run focused tests and inspect SQL safety**

Run Step 2 again, then:

```bash
rtk rg -n 'exec\(|query\(|prepare\(' Alas/Sources/ACP/Orchestration
```

Review every match to confirm user values are bindings, not SQL interpolation.

- [ ] **Step 6: Commit the store**

```bash
rtk git add Alas/Sources/ACP/Orchestration \
  Alas/Sources/Persistence/Paths.swift \
  AlasTests/ACP/Orchestration/ACPOrchestrationStoreTests.swift \
  Alas.xcodeproj/project.pbxproj
rtk git commit -m "feat(acp): persist session delegation state"
```

### Task 2: Add Pure Authorization And State Projection

**Files:**
- Create: `Alas/Sources/ACP/Orchestration/ACPSessionOrchestrationPolicy.swift`
- Test: `AlasTests/ACP/Orchestration/ACPSessionOrchestrationPolicyTests.swift`

- [ ] **Step 1: Write the authorization matrix first**

Test pure inputs for:

- root creation accepted;
- child creation rejected;
- parent-to-child send accepted;
- child-to-parent send accepted;
- sibling, unrelated, cross-project, missing, failed, and closed send rejected;
- forged target/worktree IDs rejected even when names collide;
- list visibility limited to self, parent, and direct children;
- omitted agent inherits the parent agent;
- explicit agent must be enabled and ACP-capable;
- blank prompts rejected;
- `worktree` and `new_worktree` mutual exclusion; and
- auto-run state has no effect on graph authorization.

Write state-projection tests for every public state:

- stored creation/start/failure/closed phases;
- ready plus idle/sending/streaming/permission/question/elicitation runtime;
- missing archived endpoint; and
- last activity as the maximum safe timestamp.

- [ ] **Step 2: Verify the policy suite fails**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/ACPSessionOrchestrationPolicyTests test \
  ALAS_FFF_TARGET_ARCH=arm64
```

- [ ] **Step 3: Implement a side-effect-free policy**

Keep the policy independent of AppState, SQLite, SwiftUI, and live managers.
Use small snapshots for caller, edge, agent capability, worktree availability,
and target runtime state. Return typed failures that later map to stable error
strings.

Define stable public DTOs for list/new/send responses here or in the models
file. Encode them with sorted keys and snake_case field names.

- [ ] **Step 4: Run focused tests and commit**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/ACPSessionOrchestrationPolicyTests test \
  ALAS_FFF_TARGET_ARCH=arm64
rtk git add Alas/Sources/ACP/Orchestration/ACPSessionOrchestrationPolicy.swift \
  Alas/Sources/ACP/Orchestration/ACPOrchestrationModels.swift \
  AlasTests/ACP/Orchestration/ACPSessionOrchestrationPolicyTests.swift
rtk git commit -m "feat(acp): define session orchestration policy"
```

### Task 3: Add Swift Request Decoding And App Router Boundaries

**Files:**
- Modify: `Alas/Sources/Harness/AlasCLIRequest.swift`
- Modify: `Alas/Sources/App/AlasActionService.swift`
- Modify: `Alas/Sources/App/AlasCLICommandRouter.swift`
- Test: `AlasTests/AlasCLIRequestTests.swift`
- Test: `AlasTests/AlasCLICommandRouterTests.swift`

- [ ] **Step 1: Add failing request tests**

Cover params-envelope decoding for:

```json
{"command":"session_list","params":{}}
{"command":"session_new","params":{"prompt":"Task"}}
{"command":"session_new","params":{"prompt":"Task","agent":"codex","worktree":"feature"}}
{"command":"session_new","params":{"prompt":"Task","new_worktree":{"branch":"child","base":"origin/main"}}}
{"command":"session_send","params":{"session_id":"child","prompt":"Follow up"}}
```

Also cover missing/wrong-typed/blank values, mutually exclusive worktree
selectors, unknown extra transport fields, and preservation of every existing
request decoder.

- [ ] **Step 2: Add failing router tests**

Inject orchestration closures into `AlasCLICommandRouter` and verify:

- each typed command forwards the resolved ACP origin;
- directory-only and regular terminal origins return
  `session commands require an originating ACP session`;
- existing open/worktree/review/notify routing remains unchanged; and
- responses contain one deterministic JSON line.

- [ ] **Step 3: Run the two suites and verify failure**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/AlasCLIRequestTests \
  -only-testing:AlasTests/AlasCLICommandRouterTests test \
  ALAS_FFF_TARGET_ARCH=arm64
```

- [ ] **Step 4: Implement typed request and service cases**

Add `sessionList`, `sessionNew`, and `sessionSend` command cases. Decode every
new argument from `params`; do not add legacy flat fields. Keep origin lookup in
the router and add a narrow `resolveACPSessionOrigin` dependency rather than
making `AlasActionService` search managers.

The action service should expose async typed closures and remain ignorant of
SQLite and SwiftUI.

- [ ] **Step 5: Run tests and commit**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/AlasCLIRequestTests \
  -only-testing:AlasTests/AlasCLICommandRouterTests test \
  ALAS_FFF_TARGET_ARCH=arm64
rtk git add Alas/Sources/Harness/AlasCLIRequest.swift \
  Alas/Sources/App/AlasActionService.swift \
  Alas/Sources/App/AlasCLICommandRouter.swift \
  AlasTests/AlasCLIRequestTests.swift AlasTests/AlasCLICommandRouterTests.swift
rtk git commit -m "feat(cli): route session orchestration commands"
```

### Task 4: Add Rust CLI And MCP Parity

**Files:**
- Modify: `AlasCLI/crates/alas-client/src/lib.rs`
- Modify: `AlasCLI/crates/alas/src/parse.rs`
- Modify: `AlasCLI/crates/alas/src/mcp.rs`
- Test: colocated Rust unit tests and existing transport tests

- [ ] **Step 1: Add failing command/request tests**

Add `Command::SessionList`, `Command::SessionNew`, and
`Command::SessionSend`. Test exact params objects and verify the surrounding
request still carries the injected local ACP `session_id`.

- [ ] **Step 2: Add failing CLI parser tests**

Cover:

```text
alas session list
alas session new --prompt Task
alas session new --prompt Task --agent codex --worktree feature
alas session new --prompt Task --new-worktree child --base origin/main
alas session send CHILD Follow-up
```

Cover missing values, duplicate flags, unknown flags, mutual exclusion, blank
strings, and trailing arguments. Update `USAGE_ALL`.

- [ ] **Step 3: Add failing MCP tests**

Assert the three tool definitions, required fields, descriptions, and
`command_for_tool` validation. Descriptions must state direct parent/child
scope, asynchronous acceptance, text-only prompts, and no automatic focus.

- [ ] **Step 4: Verify Rust tests fail**

```bash
rtk cargo test --manifest-path AlasCLI/Cargo.toml
```

- [ ] **Step 5: Implement commands, parser, and MCP translation**

Use the params envelope for every new argument. Keep worktree resolution and
authorization in Swift. Rust performs only shape, non-blank, enum, and mutual
exclusion validation.

MCP results should forward the app's JSON text as normal text content. Do not
parse and reserialize app responses in Rust.

- [ ] **Step 6: Run Rust tests and commit**

```bash
rtk cargo fmt --manifest-path AlasCLI/Cargo.toml -- --check
rtk cargo test --manifest-path AlasCLI/Cargo.toml
rtk git add AlasCLI/crates/alas-client/src/lib.rs \
  AlasCLI/crates/alas/src/parse.rs AlasCLI/crates/alas/src/mcp.rs
rtk git commit -m "feat(mcp): add session orchestration tools"
```

### Task 5: Add Preallocated Session IDs And Delegated Prompt Provenance

**Files:**
- Create: `Alas/Sources/ACP/Orchestration/ACPDelegatedPromptSource.swift`
- Modify: `Alas/Sources/ACP/Session/QueuedPrompt.swift`
- Modify: `Alas/Sources/ACP/Session/ACPMessage.swift`
- Modify: `Alas/Sources/ACP/Session/ACPMessageWire.swift`
- Modify: `Alas/Sources/ACP/Session/ACPSession.swift`
- Modify: `Alas/Sources/ACP/Session/ACPSessionManager.swift`
- Test: `AlasTests/ACP/Session/QueuedPromptTests.swift`
- Test: `AlasTests/ACP/Session/ACPMessageTests.swift`
- Test: `AlasTests/ACP/Session/ACPMessageWireTests.swift`
- Test: `AlasTests/ACP/Session/ACPSessionManagerTests.swift`

- [ ] **Step 1: Write provenance compatibility tests**

Test:

- legacy queued prompts/messages decode with nil provenance;
- delegated source round-trips through queue JSON and user-message payload;
- message ID/source session survive hydration;
- stable message identity remains based on existing message ID/UUID rules;
- Markdown export keeps message text and does not leak internal IDs; and
- retries do not duplicate a delegated user bubble.

- [ ] **Step 2: Write manager tests for preallocated creation and enqueue**

Test:

- `createSession(id:agentId:autoRunDefault:)` uses the exact supplied ID;
- the UUID-generating convenience remains unchanged;
- duplicate supplied IDs are rejected without replacing a live/persisted row;
- delegated enqueue persists before its completion returns;
- delegated enqueue always preserves FIFO while ready/busy/recovering;
- completion does not wait for the ACP turn response; and
- the queue kicks attach/reconnect exactly once where needed.

- [ ] **Step 3: Run focused tests and verify failure**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/QueuedPromptTests \
  -only-testing:AlasTests/ACPMessageTests \
  -only-testing:AlasTests/ACPMessageWireTests \
  -only-testing:AlasTests/ACPSessionManagerTests test \
  ALAS_FFF_TARGET_ARCH=arm64
```

- [ ] **Step 4: Implement backward-compatible provenance**

Add an optional `ACPDelegatedPromptSource` to `QueuedPrompt` and the user
message payload. Update the `ACPMessage.user` associated value and all
exhaustive pattern matches mechanically. Do not encode nil provenance, so old
payload shape remains valid and ordinary prompts remain unchanged.

Use a stable delegated message ID as the queue item's transfer/deduplication
identity. Do not encode parent/child labels into prompt text or ACP wire
content.

- [ ] **Step 5: Implement the manager API**

Add an internal preallocated-ID creation overload and an async
`enqueueDelegatedPrompt` that returns after the queue write is durable. It must
not reuse `sendPrompt` completion because ACP `session/prompt` can remain open
for the full agent turn.

- [ ] **Step 6: Run tests and commit**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/QueuedPromptTests \
  -only-testing:AlasTests/ACPMessageTests \
  -only-testing:AlasTests/ACPMessageWireTests \
  -only-testing:AlasTests/ACPSessionManagerTests test \
  ALAS_FFF_TARGET_ARCH=arm64
rtk git add Alas/Sources/ACP/Orchestration/ACPDelegatedPromptSource.swift \
  Alas/Sources/ACP/Session/QueuedPrompt.swift \
  Alas/Sources/ACP/Session/ACPMessage.swift \
  Alas/Sources/ACP/Session/ACPMessageWire.swift \
  Alas/Sources/ACP/Session/ACPSession.swift \
  Alas/Sources/ACP/Session/ACPSessionManager.swift \
  AlasTests/ACP/Session/QueuedPromptTests.swift \
  AlasTests/ACP/Session/ACPMessageTests.swift \
  AlasTests/ACP/Session/ACPMessageWireTests.swift \
  AlasTests/ACP/Session/ACPSessionManagerTests.swift
rtk git commit -m "feat(acp): persist delegated prompt provenance"
```

### Task 6: Build The Coordinator For Current And Existing Worktrees

**Files:**
- Create: `Alas/Sources/ACP/Orchestration/ACPSessionOrchestrationCoordinator.swift`
- Modify: `Alas/Sources/App/AppState.swift`
- Modify: `Alas/Sources/App/AlasActionService.swift`
- Modify: `Alas/Sources/App/AlasCLICommandRouter.swift`
- Test: `AlasTests/ACP/Orchestration/ACPSessionOrchestrationCoordinatorTests.swift`
- Test: `AlasTests/AlasCLICommandRouterTests.swift`

- [ ] **Step 1: Define an injected coordinator environment**

Keep tests independent of a full AppState by injecting closures for:

- current project/worktree snapshots;
- ACP origin lookup;
- enabled ACP agent lookup;
- existing worktree resolution;
- manager lookup/creation;
- session row/runtime snapshot lookup;
- app instance ID and clock; and
- orchestration change notification.

- [ ] **Step 2: Write failing creation/list tests**

Cover:

- current worktree child creation;
- existing worktree child creation;
- omitted agent inheritance;
- explicit valid agent;
- durable record written before response;
- child created with preallocated ID;
- initial prompt persisted then cleared from orchestration storage;
- attach/flush begins without opening a tab;
- no worktree/window focus callback fires;
- all agreed validation/authorization failures; and
- list DTO ordering and transcript-free contents.

- [ ] **Step 3: Run the focused suite and verify failure**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/ACPSessionOrchestrationCoordinatorTests test \
  ALAS_FFF_TARGET_ARCH=arm64
```

- [ ] **Step 4: Implement current/existing creation**

The coordinator flow is:

1. Resolve caller and root authority.
2. Validate prompt, agent, and target within the project.
3. Allocate child ID.
4. Persist `starting` record plus pending initial prompt.
5. Return/encode the accepted response.
6. Create the target manager/session asynchronously.
7. Enqueue the prompt with parent provenance.
8. Clear pending prompt and set `ready`.
9. Notify observers.

Do not require an ACP tab to exist. Add AppState wiring at the existing
`AlasCLICommandRouter` construction point and preserve every existing closure.

- [ ] **Step 5: Run tests and commit**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/ACPSessionOrchestrationCoordinatorTests \
  -only-testing:AlasTests/AlasCLICommandRouterTests test \
  ALAS_FFF_TARGET_ARCH=arm64
rtk git add Alas/Sources/ACP/Orchestration/ACPSessionOrchestrationCoordinator.swift \
  Alas/Sources/App/AppState.swift Alas/Sources/App/AlasActionService.swift \
  Alas/Sources/App/AlasCLICommandRouter.swift \
  AlasTests/ACP/Orchestration/ACPSessionOrchestrationCoordinatorTests.swift \
  AlasTests/AlasCLICommandRouterTests.swift
rtk git commit -m "feat(acp): create delegated sessions"
```

### Task 7: Add Atomic Fresh-Worktree Creation Without Focus

**Files:**
- Modify: `Alas/Sources/App/AppState.swift`
- Modify: `Alas/Sources/App/WorktreeLaunchSurface.swift`
- Modify: `Alas/Sources/ACP/Orchestration/ACPSessionOrchestrationCoordinator.swift`
- Test: `AlasTests/AppStateCreateWorktreeLaunchSurfaceTests.swift`
- Test: `AlasTests/AppStateCreateWorktreeSymlinkTests.swift`
- Test: `AlasTests/ACP/Orchestration/ACPSessionOrchestrationCoordinatorTests.swift`

- [ ] **Step 1: Write failing worktree completion tests**

Cover a shared creation primitive that:

- returns optimistic ID/path immediately;
- exposes one completion result for the real Git operation;
- supports a no-focus policy;
- preserves existing UI/CLI focus behavior for current callers;
- reuses branch validation, base selection, path templates, fetch, startup
  scripts, remote destination handling, and project refresh; and
- reports a typed failure without requiring published-state polling.

- [ ] **Step 2: Write coordinator fresh-worktree tests**

Cover accepted `creating_worktree` response, later session startup, no focus,
failure persistence, optimistic/real worktree reconciliation, and initial
prompt exactly-once delivery.

- [ ] **Step 3: Verify tests fail**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/AppStateCreateWorktreeLaunchSurfaceTests \
  -only-testing:AlasTests/AppStateCreateWorktreeSymlinkTests \
  -only-testing:AlasTests/ACPSessionOrchestrationCoordinatorTests test \
  ALAS_FFF_TARGET_ARCH=arm64
```

- [ ] **Step 4: Refactor the shared creation core**

Do not duplicate `performCreateWorktree` or create a second project-refresh
path. Return a small handle/result from the shared coordinator or add a
completion hook that is completed exactly once. Existing callers may continue
to ignore the completion.

Delegated creation passes no-focus/no-tab behavior. After success, bind the
resolved worktree to the delegation and continue Task 6's child creation.

- [ ] **Step 5: Add relaunch reconciliation**

For `creatingWorktree`/`starting` rows:

- continue if the planned worktree or child session can be proven to exist;
- resume initial prompt transfer using its stable ID; and
- otherwise mark `failed` with an interruption reason rather than repeating a
  Git mutation.

- [ ] **Step 6: Run tests and commit**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/AppStateCreateWorktreeLaunchSurfaceTests \
  -only-testing:AlasTests/AppStateCreateWorktreeSymlinkTests \
  -only-testing:AlasTests/ACPSessionOrchestrationCoordinatorTests test \
  ALAS_FFF_TARGET_ARCH=arm64
rtk git add Alas/Sources/App/AppState.swift \
  Alas/Sources/App/WorktreeLaunchSurface.swift \
  Alas/Sources/ACP/Orchestration/ACPSessionOrchestrationCoordinator.swift \
  AlasTests/AppStateCreateWorktreeLaunchSurfaceTests.swift \
  AlasTests/AppStateCreateWorktreeSymlinkTests.swift \
  AlasTests/ACP/Orchestration/ACPSessionOrchestrationCoordinatorTests.swift
rtk git commit -m "feat(acp): launch delegated worktrees"
```

### Task 8: Deliver `session_send` Through The Durable Inbox

**Files:**
- Modify: `Alas/Sources/ACP/Orchestration/ACPOrchestrationStore.swift`
- Modify: `Alas/Sources/ACP/Orchestration/ACPOrchestrationPersistence.swift`
- Modify: `Alas/Sources/ACP/Orchestration/ACPSessionOrchestrationCoordinator.swift`
- Modify: `Alas/Sources/ACP/Session/ACPSessionManager.swift`
- Test: `AlasTests/ACP/Orchestration/ACPDelegatedMessageDeliveryTests.swift`
- Test: `AlasTests/ACP/Session/ACPSessionManagerLeaseTests.swift`

- [ ] **Step 1: Write end-to-end delivery tests with controlled stores**

Cover:

- parent-to-child and child-to-parent accepted;
- unauthorized sends leave no inbox row;
- accepted response occurs after inbox persistence but before ACP turn finish;
- target busy/starting/disconnected preserves FIFO;
- prompt reaches transcript with source provenance;
- source instance without target lease cannot mutate the target queue;
- target owner consumes and deletes the inbox row;
- crash after target queue persistence but before inbox cleanup does not
  duplicate the prompt;
- competing instances produce one delivery; and
- failed/closed targets return stable errors.

- [ ] **Step 2: Verify delivery tests fail**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/ACPDelegatedMessageDeliveryTests \
  -only-testing:AlasTests/ACPSessionManagerLeaseTests test \
  ALAS_FFF_TARGET_ARCH=arm64
```

- [ ] **Step 3: Implement inbox observation and claim**

Use a short-name `ACPChangeNotifier`-style notification plus a bounded polling
fallback. A consumer must:

1. atomically claim an inbox row;
2. resolve/lazily load the target worktree manager;
3. acquire or confirm the target writer lease;
4. enqueue using the inbox message ID and source session;
5. confirm target persistence; and
6. mark delivered/remove the inbox row.

Release or expire claims when delivery cannot proceed. Never bypass the target
lease merely because the graph edge is valid.

- [ ] **Step 4: Run tests and commit**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/ACPDelegatedMessageDeliveryTests \
  -only-testing:AlasTests/ACPSessionManagerLeaseTests test \
  ALAS_FFF_TARGET_ARCH=arm64
rtk git add Alas/Sources/ACP/Orchestration \
  Alas/Sources/ACP/Session/ACPSessionManager.swift \
  AlasTests/ACP/Orchestration/ACPDelegatedMessageDeliveryTests.swift \
  AlasTests/ACP/Session/ACPSessionManagerLeaseTests.swift
rtk git commit -m "feat(acp): route delegated session prompts"
```

### Task 9: Add Delegation-Aware MCP Instructions

**Files:**
- Modify: `Alas/Sources/ACP/Session/BuiltInAlasMCP.swift`
- Modify: `Alas/Sources/ACP/Session/ACPSessionManager.swift`
- Modify: `Alas/Sources/App/AppState.swift`
- Modify: `AlasCLI/crates/alas/src/mcp.rs`
- Test: `AlasTests/ACP/Session/BuiltInAlasMCPTests.swift`
- Test: Rust MCP/env unit tests

- [ ] **Step 1: Add failing injection tests**

Test root injection unchanged and child injection containing a validated
`ALAS_PARENT_SESSION_ID`. Ensure user-configured `alas` MCP override behavior
and disabled/unavailable cases remain unchanged.

- [ ] **Step 2: Add failing dynamic-instructions tests**

For child env, MCP initialize instructions must identify the parent, state that
the caller cannot spawn descendants, and direct results/questions through
`session_send`. Root instructions describe direct-child fan-out. No prompt or
transcript content appears in instructions.

- [ ] **Step 3: Implement metadata lookup at attach**

Expose a cheap in-memory parent lookup from the coordinator to the built-in MCP
provider. Do not synchronously open SQLite from `ACPSessionManager.attach` or
the main actor. Refresh coordinator cache from persisted changes/relaunch
reconciliation.

Extend Rust `McpEnv` and `initialize_result` to produce role-aware instructions.
Swift remains authoritative if stale metadata causes a child to attempt
`session_new`.

- [ ] **Step 4: Run Swift and Rust tests, then commit**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/BuiltInAlasMCPTests test \
  ALAS_FFF_TARGET_ARCH=arm64
rtk cargo test --manifest-path AlasCLI/Cargo.toml
rtk git add Alas/Sources/ACP/Session/BuiltInAlasMCP.swift \
  Alas/Sources/ACP/Session/ACPSessionManager.swift Alas/Sources/App/AppState.swift \
  AlasCLI/crates/alas/src/mcp.rs AlasTests/ACP/Session/BuiltInAlasMCPTests.swift
rtk git commit -m "feat(mcp): describe delegated session context"
```

### Task 10: Add Parent/Child UI And Honest Message Attribution

**Files:**
- Create: `Alas/Sources/ACP/UI/ACPDelegatedSessionsPolicy.swift`
- Modify: `Alas/Sources/ACP/UI/ACPSessionsButton.swift`
- Modify: `Alas/Sources/ACP/UI/ACPToolbar.swift`
- Modify: `Alas/Sources/ACP/UI/ACPMessageList.swift`
- Modify: `Alas/Sources/App/AppState.swift`
- Test: `AlasTests/ACP/UI/ACPDelegatedSessionsPolicyTests.swift`
- Test: relevant ACP message-list policy/snapshot tests

- [ ] **Step 1: Write pure presentation-policy tests**

Cover:

- section visibility for root/child/unrelated sessions;
- child row ordering by active attention then last activity;
- labels for creating, starting, idle, running, awaiting, failed, and closed;
- safe failure tooltip truncation;
- retry visibility only for retryable creation failure;
- parent backlink label/fallback title; and
- delegated source label without exposing raw internal IDs when title/worktree
  metadata is available.

- [ ] **Step 2: Add navigation and retry tests around AppState helpers**

Test cross-worktree navigation opens/focuses the exact target session, does not
create another session, and activates only on user click. Retry reuses the
recorded child ID and pending prompt.

- [ ] **Step 3: Implement existing-surface UI**

- Add **Delegated sessions** to the existing sessions popover.
- Render agent, branch/worktree, live status, unread/awaiting/failure state.
- Show rows immediately during `creating_worktree`.
- Add **Delegated by [parent]** backlink for children.
- Hide descendant creation affordance for child context where applicable.
- Add Retry for failed child creation.
- Keep all creation/send operations non-focusing.

Do not add a dashboard, page-level card, nested card, or modal completion
surface.

- [ ] **Step 4: Render delegated prompt provenance**

Update the existing user-message branch in `ACPMessageList` to show a compact
source label/backlink when provenance exists. Preserve ordinary user bubbles,
copy behavior, markdown rendering, pagination, and stable row identity.

- [ ] **Step 5: Run focused tests and inspect at two widths**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/ACPDelegatedSessionsPolicyTests \
  -only-testing:AlasTests/ACPMessageTests \
  -only-testing:AlasTests/ACPMessageListPaginationTests test \
  ALAS_FFF_TARGET_ARCH=arm64
```

Manually verify normal and narrow center-pane widths. Confirm row text wraps or
truncates without overlapping icons/status, and keyboard/VoiceOver labels name
navigation and retry actions.

- [ ] **Step 6: Commit the UI**

```bash
rtk git add Alas/Sources/ACP/UI/ACPDelegatedSessionsPolicy.swift \
  Alas/Sources/ACP/UI/ACPSessionsButton.swift \
  Alas/Sources/ACP/UI/ACPToolbar.swift \
  Alas/Sources/ACP/UI/ACPMessageList.swift \
  Alas/Sources/App/AppState.swift \
  AlasTests/ACP/UI/ACPDelegatedSessionsPolicyTests.swift \
  AlasTests/ACP/Session/ACPMessageTests.swift
rtk git commit -m "feat(acp): show delegated session activity"
```

### Task 11: Integration, Compatibility, And Final Verification

**Files:**
- Test: `AlasTests/ACP/Orchestration/ACPSessionOrchestrationIntegrationTests.swift`
- Modify: implementation files only for failures found by this task

- [ ] **Step 1: Add one complete socket-path integration test**

Exercise MCP/CLI-shaped requests through Swift decoding/router/coordinator:

1. Root lists itself.
2. Root creates a child in an existing worktree.
3. Child receives its initial prompt.
4. Parent sends a follow-up while child is busy.
5. Child sends a result to parent.
6. Both list calls see only the authorized graph.
7. Child creation of a grandchild fails.

Assert stable JSON keys and no focus callbacks.

- [ ] **Step 2: Run all focused orchestration coverage**

```bash
rtk cargo test --manifest-path AlasCLI/Cargo.toml
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/ACPOrchestrationStoreTests \
  -only-testing:AlasTests/ACPSessionOrchestrationPolicyTests \
  -only-testing:AlasTests/ACPSessionOrchestrationCoordinatorTests \
  -only-testing:AlasTests/ACPDelegatedMessageDeliveryTests \
  -only-testing:AlasTests/ACPDelegatedSessionsPolicyTests \
  -only-testing:AlasTests/AlasCLIRequestTests \
  -only-testing:AlasTests/AlasCLICommandRouterTests \
  -only-testing:AlasTests/BuiltInAlasMCPTests test \
  ALAS_FFF_TARGET_ARCH=arm64
```

- [ ] **Step 3: Run repository-required generation and build**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -quiet build ALAS_FFF_TARGET_ARCH=arm64
```

- [ ] **Step 4: Run the full Swift test suite serially**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  test ALAS_FFF_TARGET_ARCH=arm64
```

Do not run another Xcode build/test concurrently. If the broad suite stalls,
capture the concrete process/build state before deciding whether CI must be the
broad gate.

- [ ] **Step 5: Manual end-to-end verification**

With the built-in Alas MCP enabled:

1. Open a root ACP session and call `session_list`.
2. Create a child in the same worktree and verify no focus change.
3. Create a child in a fresh worktree and observe `creating_worktree` then
   `starting`/`running`.
4. Send a follow-up while the child is active and verify FIFO delivery.
5. Have the child report through `session_send`; verify the parent bubble is
   attributed to the child, not the user.
6. Click parent/child navigation in both directions.
7. Trigger a worktree failure and verify persistent failure plus user Retry.
8. Attempt grandchild and unrelated-session operations and verify rejection.
9. Close/relaunch Alas during creation and verify honest reconciliation.
10. Repeat a send across two Alas instances to verify writer-safe delivery.

- [ ] **Step 6: Review scope and final diff**

```bash
rtk git diff --check origin/main...HEAD
rtk git status --short --branch
rtk git log --oneline origin/main..HEAD
```

Confirm the branch contains only issue #795 orchestration work, the approved
spec/plan, generated project changes required by new files, and focused tests.

- [ ] **Step 7: Commit final integration fixes when needed**

```bash
rtk git status --short
rtk git add AlasTests/ACP/Orchestration/ACPSessionOrchestrationIntegrationTests.swift
rtk git commit -m "test(acp): cover session orchestration flow"
```

Stage any implementation fixes individually after reviewing `git status`; do
not replace the exact add above with a broad source-directory add. Skip this
commit when the integration task required no code or test changes.
