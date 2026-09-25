# Session Resume Card Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an explicit ACP toolbar action that uses the installed on-device Qwen model to produce a safe, bounded, in-memory session resume card.

**Architecture:** Move the existing model installation, lease, and native MLX execution into narrowly shared `LocalText` types, then keep next-prompt and session-summary policy in separate feature layers. `SessionSummaryCoordinator` captures immutable session context, owns cache and cancellation state, and publishes only results whose session revision still matches. SwiftUI renders that state in a plan-style toolbar popover.

**Tech Stack:** Swift 6, SwiftUI for macOS 15, Swift Observation and Combine, Swift Testing, MLX Swift LM 3.31.4, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-09-25-session-resume-card-design.md`

## Global constraints

- Keep code, comments, logs, and UI strings in English.
- Keep Session summaries experimental, disabled by default, and available only in Debug arm64 builds whose Metal device supports Apple GPU family 7.
- Do not add dependencies, persistence, telemetry, automatic summary triggers, a generic prompt registry, a feature protocol, or a reusable popover abstraction.
- Keep next-prompt behavior and its two-failure suppression policy unchanged.
- Share only the model manifest, installation, leases, native container, serialized generation, deadlines, cancellation, idle unload, and memory-pressure unload.
- Use a 128 KiB source ceiling, an 8,192-token rendered-input ceiling, complete turns only, at most 512 generated tokens, and temperature zero.
- Never feed raw tool I/O, file edits, attachments, thoughts, delegated prompts, permissions, questions, notices, or hidden provider state into the summary model.
- Do not surface raw rejected model output in logs or UI.
- Use Swift Testing, not XCTest. Run focused suites locally. CI owns repository-wide validation.
- If `project.yml` changes, run `xcodegen` and commit `project.yml` with the generated `Alas.xcodeproj` changes.
- Do not add agent attribution to code, commits, or the pull request.

## Review focus

- A transcript whose newest user row has no assistant prose must omit that incomplete turn and summarize the newest complete turn. Task 3 pins this in `SessionSummaryContextTests`.
- A user-initiated summary arriving while an automatic suggestion is evaluating must wait for the canceled native task to drain before reusing its lease or container. Task 2 pins this in `LocalTextInferenceEngineTests`.
- Session activity fired synchronously as generation completes must invalidate the request before its result reaches the cache or popover. Task 4 pins this in `SessionSummaryCoordinatorTests`.
- A failed config write while disabling summaries must keep runtime summaries off even though the persisted value remains on. Task 5 pins this in `SessionSummarySettingsTests`.
- A malformed JSON object with a duplicate required key, an extra key, or an unsafe `next_action` must produce a usable-summary error without exposing the generated text. Task 3 pins this in `SessionSummaryPolicyTests`.

---

### Task 1: Give the shared model installation model-wide names

**Files:**
- Move: `Alas/Sources/ACP/Suggestions/NextPromptModelDownload.swift` to `Alas/Sources/ACP/LocalText/LocalTextModelDownload.swift`
- Move: `Alas/Sources/ACP/Suggestions/NextPromptModelLease.swift` to `Alas/Sources/ACP/LocalText/LocalTextModelLease.swift`
- Move: `Alas/Sources/ACP/Suggestions/NextPromptModelManifest.swift` to `Alas/Sources/ACP/LocalText/LocalTextModelManifest.swift`
- Move: `Alas/Sources/ACP/Suggestions/NextPromptModelStore.swift` to `Alas/Sources/ACP/LocalText/LocalTextModelStore.swift`
- Move: `Alas/Resources/NextPromptModelManifest.json` to `Alas/Resources/LocalTextModelManifest.json`
- Move: `Alas/Resources/NextPromptLicenses.txt` to `Alas/Resources/LocalTextModelLicenses.txt`
- Modify: `Alas/Sources/Paths.swift`
- Modify: `project.yml`
- Move tests: `AlasTests/ACP/Suggestions/NextPromptModelStoreTests.swift` to `AlasTests/ACP/LocalText/LocalTextModelStoreTests.swift`
- Move tests: `AlasTests/ACP/Suggestions/NextPromptModelLeaseTests.swift` to `AlasTests/ACP/LocalText/LocalTextModelLeaseTests.swift`
- Modify: test fixtures that mention `NextPromptModel*`

**Interfaces:**
- Consumes: the current manifest JSON, download transport, verified directory logic, POSIX lease, and store state machine without behavioral changes.
- Produces: `LocalTextModelManifest`, `LocalTextModelTransport`, `LocalTextModelDownload`, `LocalTextModelLease`, `LocalTextModelStore`, `LocalTextModelState`, and `LocalTextModelFailure` with the same methods and cases as their current `NextPromptModel*` counterparts.

- [ ] **Step 1: Rename the tests and make their expected API model-wide**

Use `git mv`, then replace the type prefixes. The test setup should read like this:

```swift
@Suite(.serialized)
struct LocalTextModelStoreTests {
    @Test func verifiedInstallCanBeLeasedAndRemoved() async throws {
        let fixture = try LocalTextModelFixture()
        let store = LocalTextModelStore(
            root: fixture.root,
            manifest: fixture.manifest,
            transport: fixture.transport,
            capacity: { _ in Int64.max }
        )

        await store.install()
        let lease = try await store.acquireVerifiedLease()
        #expect(lease.directory.lastPathComponent == fixture.manifest.revision)
        lease.close()
        try await store.remove()
        #expect(await store.state == .notInstalled)
    }
}
```

Retain every existing store and lease test. This task is a rename, so deleting coverage is not acceptable.

- [ ] **Step 2: Run the renamed suites and verify the expected compile failure**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing AlasTests/LocalTextModelStoreTests \
  -only-testing AlasTests/LocalTextModelLeaseTests test
```

Expected: FAIL because the `LocalTextModel*` symbols and moved manifest resource do not exist yet.

- [ ] **Step 3: Move and rename the production types without changing their behavior**

Use `git mv` for the four source files and the manifest. Rename the declarations and internal references one-for-one. Keep the store API concrete:

```swift
actor LocalTextModelStore {
    private(set) var state: LocalTextModelState

    func states() -> AsyncStream<LocalTextModelState>
    func install() async
    func cancelDownload() async
    func inspect() async
    func acquireVerifiedLease() async throws -> LocalTextModelLease
    func remove() async throws
}
```

Rename `Paths.nextPromptModelsRoot` to `Paths.localTextModelsRoot` but preserve its existing on-disk path so users do not redownload the model. Change only the bundled resource name in `project.yml`. Run `xcodegen` after the rename.

- [ ] **Step 4: Run the focused store and lease suites**

Run the command from Step 2.

Expected: PASS. Existing install, cancellation, verification, corrupt-revision replacement, capacity, symlink, lease, and cross-process removal cases all remain green.

- [ ] **Step 5: Commit the mechanical extraction**

```bash
git add project.yml Alas.xcodeproj Alas/Resources/LocalTextModelManifest.json \
  Alas/Resources/LocalTextModelLicenses.txt \
  Alas/Sources/ACP/LocalText Alas/Sources/Paths.swift AlasTests/ACP/LocalText
git commit -m "refactor: share local text model storage"
```

---

### Task 2: Extract one serialized native inference engine

**Files:**
- Create: `Alas/Sources/ACP/LocalText/LocalTextInferenceEngine.swift`
- Create: `Alas/Sources/ACP/LocalText/LocalTextTypes.swift`
- Modify: `Alas/Sources/ACP/Suggestions/NextPromptInference.swift`
- Modify: `Alas/Sources/ACP/Suggestions/NextPromptTypes.swift`
- Modify: `Alas/Sources/ACP/Suggestions/NextPromptPolicy.swift`
- Modify: `AlasTests/ACP/Suggestions/NextPromptInferenceTests.swift`
- Create: `AlasTests/ACP/LocalText/LocalTextInferenceEngineTests.swift`

**Interfaces:**
- Consumes: `LocalTextModelStore.acquireVerifiedLease()` and the current MLX loading, tokenization, chunked prefill, deadline, idle-unload, and lease-drain code from `NextPromptInference`.
- Produces:

```swift
enum LocalTextJobPriority: Int, Sendable { case automatic, userInitiated }
enum LocalTextCaller: Hashable, Sendable { case nextPrompt; case sessionSummary(UUID) }

struct LocalTextMessage: Equatable, Sendable {
    enum Role: String, Sendable { case system, user }
    let role: Role
    let content: String
}

struct LocalTextGenerationRequest: Sendable {
    let messageCandidates: [[LocalTextMessage]]
    let inputTokenLimit: Int
    let maxTokens: Int
    let temperature: Float
    let prefillStepSize: Int
    let timeout: Duration
}

struct LocalTextGenerationResult: Equatable, Sendable {
    let text: String
    let selectedCandidateIndex: Int
}

enum LocalTextInferenceFailure: Error, Equatable, Sendable {
    case unsupported, unavailable, inputTooLarge, timedOut, cancelled, preempted, generationFailed
}

protocol LocalTextGenerating: Sendable {
    func generate(_ request: LocalTextGenerationRequest,
                  caller: LocalTextCaller,
                  priority: LocalTextJobPriority) async throws -> LocalTextGenerationResult
    func cancel(caller: LocalTextCaller) async
    func cancelAndUnload() async
}
```

- [ ] **Step 1: Write shared-engine scheduling and lifetime tests**

Create tests with an injected loader/evaluator and controllable clock. Cover these exact cases:

```swift
@Suite(.serialized)
struct LocalTextInferenceEngineTests {
    @Test func userRequestCancelsAndDrainsAutomaticWorkBeforeStarting() async throws {
        let probe = LocalTextEngineProbe()
        let engine = probe.engine()
        let request = LocalTextGenerationRequest(
            messageCandidates: [[.init(role: .user, content: "test")]],
            inputTokenLimit: 8_192,
            maxTokens: 8,
            temperature: 0,
            prefillStepSize: 512,
            timeout: .seconds(15)
        )
        let automatic = Task {
            try await engine.generate(request, caller: .nextPrompt, priority: .automatic)
        }
        await probe.waitUntilFirstEvaluationStarts()

        let summaryID = UUID()
        let summary = Task {
            try await engine.generate(request, caller: .sessionSummary(summaryID), priority: .userInitiated)
        }
        await probe.waitUntilFirstEvaluationIsCancelled()
        #expect(await probe.startedEvaluationCount == 1)
        probe.allowFirstEvaluationToDrain()
        await probe.waitUntilSecondEvaluationStarts()
        #expect(await probe.leaseWasClosedBeforeFirstDrain == false)
        probe.finishSecondEvaluation(with: "summary")

        await #expect(throws: LocalTextInferenceFailure.self) { try await automatic.value }
        #expect(try await summary.value.text == "summary")
    }

}
```

Add these tests beside the worked example:

| Test | Assertion |
|---|---|
| `automaticRequestCannotPreemptUserRequest` | The automatic call throws `.preempted`; the user evaluation is not canceled. |
| `newerUserRequestReplacesOlderUserRequest` | The first user call throws `.cancelled` only after its evaluator drains; the second then starts. |
| `callerCancellationDrainsBeforeLeaseCloses` | `cancel(caller:)` returns after the evaluator observes cancellation and before the lease-close event. |
| `selectsFirstCandidateWithinTokenLimit` | Token counts `[9000, 7000, 1000]` return candidate index `1`. |
| `deadlineCancelsGenerationAndUnloads` | Advancing the injected clock past the request deadline throws `.timedOut` and closes the lease after drain. |
| `idleDeadlineUnloadsAfterSixtySeconds` | Advancing the injected clock to 59 seconds keeps the lease; 60 seconds closes it. |

`LocalTextEngineProbe` belongs in the test file. It records evaluation start, cancellation, drain, and lease-close order. It must never sleep on wall-clock time.

- [ ] **Step 2: Run the new suite and verify it fails**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing AlasTests/LocalTextInferenceEngineTests test
```

Expected: FAIL because `LocalTextInferenceEngine` and its request types do not exist.

- [ ] **Step 3: Move the native mechanics into `LocalTextInferenceEngine`**

Move the MLX imports and `loadNative` implementation out of `NextPromptInference`. The engine must:

1. Keep one loaded evaluation closure and verified lease.
2. Select the first rendered message candidate whose chat template is at most `inputTokenLimit` tokens.
3. Reject empty candidate lists, nonpositive bounds, or limits above 8,192 input tokens and 512 output tokens.
4. Serialize jobs through one active task.
5. Cancel and drain lower-priority automatic work before user work starts.
6. Reject automatic work with `.preempted` while user work is active.
7. Treat a newer user request as replacement work.
8. Hold the lease until evaluation drains and the container is dropped.
9. Unload after 60 idle seconds, on explicit cancellation, and on memory pressure.

The feature-neutral native closure should have this shape:

```swift
typealias Evaluation = @Sendable (
    [[LocalTextMessage]], Int, GenerateParameters
) async throws -> LocalTextGenerationResult
```

Do not expose MLX types outside this file in production APIs.

- [ ] **Step 4: Adapt next-prompt inference and keep its policy local**

`NextPromptInference` keeps `NextPromptRuntime`, its state stream, 15-second deadline, parsing, input/output checks, and repeated-failure counter. It renders candidates by dropping oldest turns:

```swift
private func generationRequest(for request: NextPromptRequest) -> LocalTextGenerationRequest {
    let candidates = request.turns.indices.map { first in
        NextPromptPolicy.messages(for: Array(request.turns[first...]))
    }
    return .init(
        messageCandidates: candidates,
        inputTokenLimit: NextPromptContext.tokenLimit,
        maxTokens: 128,
        temperature: 0,
        prefillStepSize: 512,
        timeout: .seconds(15)
    )
}
```

Replace `NextPromptChatMessage` with `LocalTextMessage`. Map engine cancellation, preemption, and rejected input to `nil` without increasing the suggestion failure count. Count only operational load or generation failures, as today. Summary failures must have no path to this counter.

- [ ] **Step 5: Run both engine and next-prompt inference suites**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing AlasTests/LocalTextInferenceEngineTests \
  -only-testing AlasTests/NextPromptInferenceTests \
  -only-testing AlasTests/NextPromptContextTests \
  -only-testing AlasTests/NextPromptPolicyTests test
```

Expected: PASS. Existing next-prompt suppression, cancellation, deadline, fitting, and safety tests remain green.

- [ ] **Step 6: Commit the engine extraction**

```bash
git add Alas/Sources/ACP/LocalText Alas/Sources/ACP/Suggestions \
  AlasTests/ACP/LocalText AlasTests/ACP/Suggestions
git commit -m "refactor: share local text inference"
```

---

### Task 3: Build and validate summary context

**Files:**
- Create: `Alas/Sources/ACP/Summaries/SessionSummaryTypes.swift`
- Create: `Alas/Sources/ACP/Summaries/SessionSummaryContext.swift`
- Create: `Alas/Sources/ACP/Summaries/SessionSummaryPolicy.swift`
- Create: `Alas/Sources/ACP/LocalText/LocalTextSafety.swift`
- Create: `AlasTests/ACP/Summaries/SessionSummaryContextTests.swift`
- Create: `AlasTests/ACP/Summaries/SessionSummaryPolicyTests.swift`

**Interfaces:**
- Consumes: `ACPSession`, `ACPTranscript.messagesGeneration`, `ACPGoalState`, `[ACPMessage.PlanItem]`, and `LocalTextMessage`.
- Produces:

```swift
struct SessionSummaryTurn: Equatable, Sendable { let user: String; let assistant: String }

struct SessionSummarySourceRevision: Equatable, Sendable {
    let incarnation: UUID
    let transcriptGeneration: UInt64
    let goal: ACPGoalState?
    let plan: [ACPMessage.PlanItem]?
    let idleFacts: SessionSummaryIdleFacts
}

struct SessionSummaryIdleFacts: Equatable, Sendable {
    let agentReady: Bool
    let hydrationReady: Bool
    let streamingIsIdle: Bool
    let composerIsEmpty: Bool
    let queuedPromptCount: Int
    let pendingQueuePersistenceCount: Int
    let pendingPermission: Bool
    let pendingQuestion: Bool
    let pendingPlan: Bool
    let pendingUserInputCount: Int
    let urlElicitationCount: Int
    let pendingWorkCount: Int
    let hasPendingDelegatedMessages: Bool
    let hasRunningSubagent: Bool
    let retrying: Bool
    let recovering: Bool
    let autoRunEnabled: Bool

    var isIdle: Bool {
        agentReady && hydrationReady && streamingIsIdle && composerIsEmpty
            && queuedPromptCount == 0 && pendingQueuePersistenceCount == 0
            && !pendingPermission && !pendingQuestion
            && !pendingPlan && pendingUserInputCount == 0 && urlElicitationCount == 0
            && pendingWorkCount == 0 && !hasPendingDelegatedMessages && !hasRunningSubagent && !retrying
            && !recovering && !autoRunEnabled
    }
}

struct SessionSummaryContext: Equatable, Sendable {
    static let sourceLimit = 128 * 1024
    static let tokenLimit = 8_192
    let revision: SessionSummarySourceRevision
    let goal: ACPGoalState?
    let plan: [ACPMessage.PlanItem]
    let turns: [SessionSummaryTurn]
    let omittedOlderTurns: Bool

    @MainActor static func snapshot(session: ACPSession) -> SessionSummaryContext?
    func messageCandidates() -> [[LocalTextMessage]]
}

struct SessionSummary: Equatable, Sendable {
    let goal: String?
    let completed: [String]
    let blockers: [String]
    let nextAction: String?
    let isPartial: Bool
}

enum SessionSummaryPolicy {
    static func parse(_ data: Data, isPartial: Bool) -> SessionSummary?
    static func permitsOutput(_ summary: SessionSummary) -> Bool
}
```

- [ ] **Step 1: Write context filtering and candidate-order tests**

Build sessions with real `ACPMessage` cases and assert:

```swift
@MainActor
@Suite struct SessionSummaryContextTests {
    @Test func includesOnlyCompleteOrdinaryTurns() throws {
        let session = makeSession(messages: [
            .user(id: UUID(), messageId: nil, text: "Implement search", attachments: []),
            .thought(id: UUID(), messageId: nil, StreamingText("private reasoning")),
            .systemNotice(id: UUID(), text: "private notice"),
            .agent(id: UUID(), messageId: nil, StreamingText("Search now works.")),
            .user(id: UUID(), messageId: nil, text: "Newest incomplete turn", attachments: [])
        ])

        let context = try #require(SessionSummaryContext.snapshot(session: session))
        #expect(context.turns == [.init(user: "Implement search", assistant: "Search now works.")])
        let rendered = context.messageCandidates().flatMap { $0 }.map(\.content).joined()
        #expect(!rendered.contains("private reasoning"))
        #expect(!rendered.contains("private notice"))
        #expect(!rendered.contains("Newest incomplete turn"))
    }

    private func makeSession(messages: [ACPMessage]) -> ACPSession {
        let session = ACPSession(id: "summary-test", agentId: "codex", worktreeId: "worktree", title: "Test")
        for message in messages { session.transcript.appendMessage(message) }
        return session
    }
}
```

Add these tests beside the worked example:

| Test | Assertion |
|---|---|
| `excludesDelegatedPromptsAttachmentsToolsEditsAndNotices` | No excluded row content appears in any rendered candidate; construct tool and file-edit rows with the existing ACP test fixtures. |
| `keepsWholeNewestTurnsUnderSourceLimit` | The newest complete turn is present and no message is truncated at 128 KiB. |
| `preservesChronologicalOrderAfterDroppingOlderTurns` | Retained turns remain oldest-to-newest in rendered JSON. |
| `keepsGoalPlanAndNewestTurnInEveryCandidate` | Every candidate repeats the deterministic goal, plan, and newest complete turn. |
| `marksPartialWhenSourceLimitDropsOlderTurns` | `omittedOlderTurns` is true after the oldest complete turn is removed. |
| `returnsNilWhenNoCompleteTurnOrDeterministicContextFits` | A session with only excluded or oversized values returns nil without an engine request. |

- [ ] **Step 2: Write strict output-contract and safety tests**

Use literal UTF-8 JSON. Pin exact-key handling and safe failure:

```swift
@Suite struct SessionSummaryPolicyTests {
    @Test func parsesExactBoundedShape() throws {
        let json = #"{"goal":"Ship search","completed":["Parser added"],"blockers":[],"next_action":"Run the focused tests"}"#
        let value = try #require(SessionSummaryPolicy.parse(Data(json.utf8), isPartial: false))
        #expect(value.goal == "Ship search")
        #expect(value.completed == ["Parser added"])
        #expect(value.nextAction == "Run the focused tests")
    }

    @Test(arguments: [
        #"{"goal":null,"goal":"x","completed":[],"blockers":[],"next_action":null}"#,
        #"{"goal":null,"completed":[],"blockers":[],"next_action":null,"extra":true}"#,
        #"{"goal":null,"completed":[],"blockers":[],"next_action":"Delete the production database"}"#,
        #"{"goal":null,"completed":["token=ghp_abcdefghijklmnopqrstuvwxyz0123456789"],"blockers":[],"next_action":null}"#
    ])
    func rejectsMalformedOrUnsafeOutput(_ json: String) {
        #expect(SessionSummaryPolicy.parse(Data(json.utf8), isPartial: false) == nil)
    }
}
```

Add these tests beside the worked examples:

| Test | Assertion |
|---|---|
| `rejectsMarkupURLsMultilineControlsAndOverlongStrings` | One table-driven test supplies each forbidden value and always gets nil. |
| `rejectsMoreThanFiveCompletedOrBlockerItems` | Six items in either array return nil; five remain valid. |
| `rejectsAllEmptyFields` | Null goal and next action with empty arrays return nil. |
| `acceptsNullGoalAndNextActionWhenAnotherSectionHasContent` | A nonempty completed or blocker item produces a summary. |

- [ ] **Step 3: Run both suites and verify they fail**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing AlasTests/SessionSummaryContextTests \
  -only-testing AlasTests/SessionSummaryPolicyTests test
```

Expected: FAIL because the summary types do not exist.

- [ ] **Step 4: Implement the bounded snapshot and exact parser**

Build turns from `.user` rows with no delegated source and no attachments, followed by one or more nonempty `.agent` rows before the next user row. Ignore every other message case. Keep goal and plan as labelled JSON data in the user message, never in the system prompt.

`messageCandidates()` must return full-to-smallest candidates. Each candidate contains the same goal and plan plus successively fewer oldest turns. The engine selects the first candidate under 8,192 tokens. Set `isPartial` when the byte ceiling already removed turns or the engine reports a candidate index greater than zero.

Parse the UTF-8 bytes with the same small cursor style already used by `NextPromptPolicy.parse`; `JSONDecoder` and `JSONSerialization` collapse duplicate keys and cannot enforce this contract. Read exactly four unique keys, accept them in any order, reject a fifth or duplicate key, and require `goal`, `completed`, `blockers`, and `next_action` once each. Apply these bounds after parsing:

```swift
private static let maximumOutputBytes = 16 * 1024
private static let maximumItems = 5
private static let maximumCharacters = 280
```

Reject Markdown markers, HTML tags, `http://`, `https://`, newlines, forbidden control characters, recognized credential values, and destructive or irreversible active text in `next_action`. Move the credential matcher and the destructive active-action matcher from `NextPromptPolicy` into internal `LocalTextSafety` helpers and call them from both policies. Do not route summary validation through `NextPromptPolicy.permitsOutput`.

- [ ] **Step 5: Run the context and policy suites**

Run the command from Step 3.

Expected: PASS.

- [ ] **Step 6: Commit the pure summary layer**

```bash
git add Alas/Sources/ACP/Summaries Alas/Sources/ACP/LocalText/LocalTextSafety.swift \
  Alas/Sources/ACP/Suggestions/NextPromptPolicy.swift AlasTests/ACP/Summaries
git commit -m "feat: build safe session summary context"
```

---

### Task 4: Coordinate generation, cache, staleness, and activity

**Files:**
- Create: `Alas/Sources/ACP/Summaries/SessionSummaryCoordinator.swift`
- Create: `AlasTests/ACP/Summaries/SessionSummaryCoordinatorTests.swift`
- Create: `AlasTests/ACP/Summaries/SessionSummaryActivityTests.swift`

**Interfaces:**
- Consumes: `LocalTextGenerating`, `SessionSummaryContext`, `SessionSummaryPolicy`, `ACPSession.nextPromptActivity`, `ACPSession.nextPromptTeardown`, and `ACPSession.incarnation`.
- Produces:

```swift
@MainActor
final class SessionSummaryCoordinator: ObservableObject {
    enum Phase: Equatable { case idle, loading, result(SessionSummary), failed(String, previous: SessionSummary?) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var presentationGeneration: UInt64 = 0

    init(engine: any LocalTextGenerating)
    func bind(to session: ACPSession)
    func summary(for session: ACPSession) async
    func refresh(_ session: ACPSession) async
    func cancelPresentation()
    func invalidate(_ session: ACPSession)
    func teardown()
}
```

- [ ] **Step 1: Write coordinator state and race tests**

Use a fake `LocalTextGenerating` actor that can suspend and complete requests. Cover:

```swift
@MainActor
@Suite struct SessionSummaryCoordinatorTests {
    @Test func synchronousActivityWinsAgainstCompletingGeneration() async throws {
        let fixture = SummaryCoordinatorFixture()
        fixture.coordinator.bind(to: fixture.session)
        let generation = Task { await fixture.coordinator.summary(for: fixture.session) }
        await fixture.engine.waitUntilRequested()

        fixture.session.nextPromptActivity.send()
        fixture.engine.complete(with: .init(
            text: #"{"goal":"Ship search","completed":[],"blockers":[],"next_action":"Run tests"}"#,
            selectedCandidateIndex: 0
        ))
        await generation.value

        #expect(fixture.coordinator.phase == .idle)
        #expect(fixture.coordinator.presentationGeneration == 1)
        #expect(await fixture.engine.cancelledCallers == [.sessionSummary(fixture.session.incarnation)])
    }

}
```

Add these tests beside the worked example:

| Test | Assertion |
|---|---|
| `reopensCurrentIncarnationFromMemoryWithoutGeneratingAgain` | A second request publishes the cached result and the fake engine still has one request. |
| `replacementIncarnationCannotReusePersistedSessionIDCache` | A new session object with the same persisted ID issues a new engine request. |
| `transcriptGoalPlanAndIdleChangesRejectStaleResult` | Mutate each captured value in a table-driven test; none of the completed results is cached. |
| `closingPopoverCancelsUnfinishedCallerWithoutClearingValidCache` | Closing cancels an active caller; closing after success leaves the cache reusable. |
| `refreshFailureKeepsPreviousSummaryAndShowsError` | Phase is `.failed(message, previous: oldSummary)`. |
| `firstFailureShowsErrorWithoutEmptyResult` | Phase is `.failed(message, previous: nil)`. |
| `teardownCancelsObserversGenerationAndCache` | Later activity produces no callback and the next incarnation request cannot reuse the prior cache. |

- [ ] **Step 2: Run the coordinator suite and verify it fails**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing AlasTests/SessionSummaryCoordinatorTests test
```

Expected: FAIL because `SessionSummaryCoordinator` does not exist.

- [ ] **Step 3: Implement one coordinator with an incarnation-keyed cache**

Use `[UUID: SessionSummary]` for the in-memory cache and one current `Task`. `bind(to:)` installs synchronous Combine subscriptions before generation starts. The activity handler must increment a request generation, cancel the caller in the engine, clear that incarnation's cache, set `.idle`, and increment `presentationGeneration` in one main-actor turn.

Before caching, compare a fresh snapshot to the captured `SessionSummarySourceRevision`. The revision includes transcript generation, goal, plan, and a small `SessionSummaryIdleFacts` value derived from all relevant work state already represented by `nextPromptActivity`. If no context fits, publish a safe local error and never call the engine.

Submit:

```swift
let request = LocalTextGenerationRequest(
    messageCandidates: context.messageCandidates(),
    inputTokenLimit: SessionSummaryContext.tokenLimit,
    maxTokens: 512,
    temperature: 0,
    prefillStepSize: 512,
    timeout: .seconds(30)
)
let raw = try await engine.generate(
    request,
    caller: .sessionSummary(session.incarnation),
    priority: .userInitiated
)
```

Parse with `isPartial: context.omittedOlderTurns || raw.selectedCandidateIndex > 0`. Convert typed engine failures and invalid output into fixed UI messages. Never include `raw.text` or error descriptions that may contain it.

- [ ] **Step 4: Run the coordinator suite**

Run the command from Step 2.

Expected: PASS.

- [ ] **Step 5: Run session activity regression tests**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing AlasTests/SessionSummaryCoordinatorTests \
  -only-testing AlasTests/NextPromptCoordinatorTests \
  -only-testing AlasTests/SessionSummaryActivityTests test
```

`SessionSummaryActivityTests` subscribes to `nextPromptActivity` and `nextPromptTeardown`, then drives the existing mutation entry points for prompt allocation, queue changes, transcript streaming, permission, question, retry, recovery, delegated work, auto-run, and teardown. Each test asserts that the signal arrives synchronously before its mutation method returns. Expected: PASS.

- [ ] **Step 6: Commit coordinator behavior**

```bash
git add Alas/Sources/ACP/Summaries/SessionSummaryCoordinator.swift \
  AlasTests/ACP/Summaries/SessionSummaryCoordinatorTests.swift \
  AlasTests/ACP/Summaries/SessionSummaryActivityTests.swift
git commit -m "feat: coordinate session summaries"
```

---

### Task 5: Add independent settings around the shared model

**Files:**
- Modify: `Alas/Sources/Persistence/AppConfig.swift`
- Rename: `Alas/Sources/Settings/NextPromptSuggestionsSettings.swift` to `Alas/Sources/Settings/LocalTextModelSettings.swift`
- Modify: `Alas/Sources/App/AppState.swift`
- Modify: `Alas/Sources/App/AppState+NextPromptSuggestions.swift`
- Create: `Alas/Sources/App/AppState+SessionSummaries.swift`
- Modify: `AlasTests/AppConfigTests.swift`
- Modify: `AlasTests/AppStatePersistenceTests.swift`
- Modify: `AlasTests/ACP/Suggestions/NextPromptSettingsTests.swift`
- Create: `AlasTests/ACP/Summaries/SessionSummarySettingsTests.swift`

**Interfaces:**
- Consumes: one `LocalTextModelStore`, one `LocalTextInferenceEngine`, existing config persistence and next-prompt setting behavior.
- Produces: `AppConfig.sessionSummariesEnabled`, shared model state in `AppState`, `sessionSummariesRuntimeEnabled`, `sessionSummaryCoordinator`, and enable, disable, retry, inspect, and removal actions for the new setting.

- [ ] **Step 1: Add config decoding and persistence tests**

```swift
@Test func sessionSummariesDefaultsOffAndRoundTrips() throws {
    var object = try decodedDefaultJSONObject()
    object.removeValue(forKey: "sessionSummariesEnabled")
    let absent = try decodeConfig(object)
    #expect(!absent.sessionSummariesEnabled)

    object["sessionSummariesEnabled"] = true
    let enabled = try decodeConfig(object)
    #expect(enabled.sessionSummariesEnabled)
    #expect(try encodedJSONObject(enabled)["sessionSummariesEnabled"] as? Bool == true)
}
```

Extend `AppStatePersistenceTests` to toggle and save the field through `AppState`, not only through raw Codable.

- [ ] **Step 2: Add shared-install and independent-setting tests**

`SessionSummarySettingsTests` must cover:

```swift
@MainActor
@Suite(.serialized)
struct SessionSummarySettingsTests {
    @Test func failedDisableSaveKeepsRuntimeOffUntilRetryPersists() async throws {
        let fixture = SummarySettingsFixture(configEnabled: true, saveResults: [false, true])
        await fixture.state.disableSessionSummaries()
        #expect(!fixture.state.sessionSummariesRuntimeEnabled)
        #expect(fixture.state.config.sessionSummariesEnabled)
        #expect(fixture.state.sessionSummaryDisableSavePending)
        await fixture.state.retrySessionSummarySettings()
        #expect(!fixture.state.config.sessionSummariesEnabled)
        #expect(!fixture.state.sessionSummaryDisableSavePending)
    }
}
```

Add these tests beside the worked example:

| Test | Assertion |
|---|---|
| `enablingSummaryUsesReadySharedInstallationWithoutDownloading` | Runtime enables after inspection and transport receives no download. |
| `enablingEitherCapabilityInstallsOnceAfterCapabilitySpecificConsent` | Each toggle shows its own consent; accepting either invokes the shared transport once. |
| `disablingSummaryCancelsOnlySummaryWork` | Summary caller is canceled while a later next-prompt request still runs. |
| `disablingSuggestionLeavesSummaryRuntimeEnabled` | Summary runtime and its cached result stay available. |
| `removalRequiresBothCapabilitiesDisabled` | Removal is rejected while either persisted or runtime flag is true and succeeds after both are false. |
| `startupSkipsInspectionWhenBothCapabilitiesAreDisabled` | Injected inspection count remains zero. |
| `openingSettingsCanInspectOnDemandWhenBothAreDisabled` | One settings appearance produces one inspection and correct removal state. |
| `unsupportedBuildStartsNoObserversAndPerformsNoInspection` | Injected stream, notification, pressure, and inspection probes all remain unused. |

Keep all existing `NextPromptSettingsTests`, changing only shared type names and expectations required by lazy model inspection.

- [ ] **Step 3: Run the settings suites and verify they fail**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing AlasTests/AppConfigTests \
  -only-testing AlasTests/AppStatePersistenceTests \
  -only-testing AlasTests/NextPromptSettingsTests \
  -only-testing AlasTests/SessionSummarySettingsTests test
```

Expected: FAIL because the new config and runtime state do not exist.

- [ ] **Step 4: Share store and engine ownership in `AppState`**

Rename `nextPromptModelStore` and its state to `localTextModelStore` and `localTextModelState`. Construct one `LocalTextInferenceEngine`. Inject that same actor into `NextPromptInference` and `SessionSummaryCoordinator`.

Start shared model observers only when `nextPromptSuggestionsEnabled || sessionSummariesEnabled`. On unsupported builds, return before inspection, notification registration, or memory-pressure setup. When both settings are false, let the settings view call `inspectLocalTextModel()` once on appearance.

Move the memory-pressure handler to shared ownership and make it invalidate both feature coordinators before `localTextInference.cancelAndUnload()`.

- [ ] **Step 5: Implement the two capability rows and shared model controls**

Rename the settings view file and keep one Experimental section. Each row owns its own toggle, consent copy, runtime error, and Retry Disable state. The shared model status, download progress, retry, and Remove Model action appear once.

Use this removal gate everywhere, including tests and disabled button help:

```swift
var canRemoveLocalTextModel: Bool {
    !config.nextPromptSuggestionsEnabled
        && !config.sessionSummariesEnabled
        && !nextPromptRuntimeEnabled
        && !sessionSummariesRuntimeEnabled
}
```

Consent copy for Session summaries must mention the roughly 2.3 GB download, local transcript processing, multi-gigabyte memory use, and retained process memory after unload. Disabling one feature cancels only its coordinator. Removing the model cancels both, drains the shared engine, then uses the existing exclusive lease check.

- [ ] **Step 6: Run settings and model suites**

Run the command from Step 3, then:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing AlasTests/LocalTextModelStoreTests \
  -only-testing AlasTests/LocalTextModelLeaseTests test
```

Expected: PASS.

- [ ] **Step 7: Commit settings and app ownership**

```bash
git add Alas/Sources/Persistence/AppConfig.swift Alas/Sources/Settings \
  Alas/Sources/App/AppState.swift Alas/Sources/App/AppState+NextPromptSuggestions.swift \
  Alas/Sources/App/AppState+SessionSummaries.swift AlasTests/AppConfigTests.swift \
  AlasTests/AppStatePersistenceTests.swift AlasTests/ACP/Suggestions/NextPromptSettingsTests.swift \
  AlasTests/ACP/Summaries/SessionSummarySettingsTests.swift
git commit -m "feat: add session summary settings"
```

---

### Task 6: Add the toolbar control and summary popover

**Files:**
- Create: `Alas/Sources/ACP/UI/ACPSessionSummaryControl.swift`
- Create: `Alas/Sources/ACP/UI/ACPSessionSummaryPopover.swift`
- Create: `Alas/Sources/ACP/UI/ACPSessionSummaryPresentation.swift`
- Modify: `Alas/Sources/ACP/UI/ACPToolbar.swift`
- Modify: `Alas/Sources/ACP/UI/ACPTabView.swift`
- Create: `AlasTests/ACP/UI/ACPSessionSummaryPresentationTests.swift`

**Interfaces:**
- Consumes: `SessionSummaryCoordinator.phase`, `presentationGeneration`, shared model state, runtime enablement, and session idle facts.
- Produces: an `ACPSessionSummaryControl` embedded in `ACPToolbar`, with accessibility identifier `acp-session-summary`, and an anchored 320-point popover.

- [ ] **Step 1: Write pure presentation-state tests**

```swift
@Suite struct ACPSessionSummaryPresentationTests {
    @Test func hiddenWhenDisabledOrUnsupported() {
        #expect(!ACPSessionSummaryPresentation(enabled: false, supported: true, model: .ready,
                                                 idle: true, phase: .idle).isVisible)
        #expect(!ACPSessionSummaryPresentation(enabled: true, supported: false, model: .ready,
                                                 idle: true, phase: .idle).isVisible)
    }

}
```

Add these tests beside the worked example:

| Test | Assertion |
|---|---|
| `visibleButDisabledWhileModelUnavailableOrSessionBusy` | Visibility stays true, `isEnabled` is false, and help names the blocking state. |
| `loadingResultFirstFailureAndRefreshFailureMapToDistinctAccessibleStatus` | Values are Loading, Complete, Failed, and Complete with refresh error. |
| `omitsEmptyOptionalSections` | Only nonempty section descriptors are returned. |
| `partialResultAddsRecentContextLabel` | `showsRecentContextLabel` is true. |
| `presentationGenerationForcesPopoverClosed` | `popoverOpenAfterGenerationChange` returns false. |

The presentation value should expose only what the views render: visibility, enabled state, help text, accessibility value, and nonempty sections.

- [ ] **Step 2: Run the UI policy suite and verify it fails**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing AlasTests/ACPSessionSummaryPresentationTests test
```

Expected: FAIL because `ACPSessionSummaryPresentation` does not exist.

- [ ] **Step 3: Implement the minimal presentation value and views**

`ACPSessionSummaryControl` follows `ACPPlanPill` for hover and open styling. It owns only `popoverOpen` and observes the coordinator. Opening calls `summary(for:)`; Refresh calls `refresh(_:)`; closing calls `cancelPresentation()`. An `onChange` of `presentationGeneration` closes the popover.

The popover renders:

```swift
VStack(alignment: .leading, spacing: 12) {
    Text("Session summary").font(.headline)
    Text("Generated locally. Review before acting.").font(.caption).foregroundStyle(.secondary)
    if summary.isPartial { Text("Summarizes recent context.").font(.caption) }
    summarySection("Goal", text: summary.goal)
    summaryList("Completed", items: summary.completed)
    summaryList("Blockers", items: summary.blockers)
    summarySection("Next action", text: summary.nextAction)
    Button("Refresh") { refresh() }
}
.frame(width: 320)
```

Omit sections with nil or empty content. Make generated text selectable. Add headings for VoiceOver, announce phase changes with SwiftUI accessibility live-region APIs available on macOS 15, respect Reduce Motion, and handle Escape by closing and canceling unfinished generation.

The toolbar control label is `Summarize Session`, its help explains disabled model or busy-session state, and its accessibility value reports Ready, Loading, Failed, or Complete. Use `.accessibilityIdentifier("acp-session-summary")`.

- [ ] **Step 4: Wire the control into the existing toolbar**

Pass the existing `AppState.sessionSummaryCoordinator` and runtime/model facts through `ACPTabView` to `ACPToolbar`; do not add another coordinator to view state. Place the summary control after the plan pill and before the spacer. Bind the coordinator to the displayed `ACPSession` on appearance and tear down or rebind when its incarnation changes.

- [ ] **Step 5: Run UI, coordinator, and plan-pill suites**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing AlasTests/ACPSessionSummaryPresentationTests \
  -only-testing AlasTests/SessionSummaryCoordinatorTests \
  -only-testing AlasTests/ACPPlanPillStateTests test
```

Expected: PASS.

- [ ] **Step 6: Commit the user interface**

```bash
git add Alas/Sources/ACP/UI/ACPSessionSummaryControl.swift \
  Alas/Sources/ACP/UI/ACPSessionSummaryPopover.swift \
  Alas/Sources/ACP/UI/ACPSessionSummaryPresentation.swift \
  Alas/Sources/ACP/UI/ACPToolbar.swift Alas/Sources/ACP/UI/ACPTabView.swift \
  AlasTests/ACP/UI/ACPSessionSummaryPresentationTests.swift
git commit -m "feat: show session summary popover"
```

---

### Task 7: Regenerate, verify native builds, and evaluate the feature

**Files:**
- Verify: `project.yml`
- Regenerate: `Alas.xcodeproj/project.pbxproj`
- Create: `docs/plans/2026-09-25-session-resume-card-evaluation.md`

**Interfaces:**
- Consumes: all production and test interfaces from Tasks 1 through 6.
- Produces: regenerated project metadata, focused verification evidence, and a checked-in native evaluation record for the default-off rollout decision.

- [ ] **Step 1: Regenerate and confirm the project has every moved resource and source**

```bash
xcodegen
git diff --check
git status --short
```

Expected: `xcodegen` succeeds, `git diff --check` prints nothing, and the manifest appears exactly once as a resource.

- [ ] **Step 2: Run the complete affected focused test set**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing AlasTests/LocalTextModelStoreTests \
  -only-testing AlasTests/LocalTextModelLeaseTests \
  -only-testing AlasTests/LocalTextInferenceEngineTests \
  -only-testing AlasTests/NextPromptContextTests \
  -only-testing AlasTests/NextPromptPolicyTests \
  -only-testing AlasTests/NextPromptInferenceTests \
  -only-testing AlasTests/NextPromptCoordinatorTests \
  -only-testing AlasTests/NextPromptSettingsTests \
  -only-testing AlasTests/SessionSummaryContextTests \
  -only-testing AlasTests/SessionSummaryPolicyTests \
  -only-testing AlasTests/SessionSummaryCoordinatorTests \
  -only-testing AlasTests/SessionSummarySettingsTests \
  -only-testing AlasTests/ACPSessionSummaryPresentationTests \
  -only-testing AlasTests/AppConfigTests \
  -only-testing AlasTests/AppStatePersistenceTests test
```

Expected: PASS. Record the exact command and result in the eventual pull request.

- [ ] **Step 3: Build all required configuration and architecture pairs**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -configuration Release \
  -destination 'platform=macOS,arch=arm64' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -configuration Debug \
  -destination 'platform=macOS,arch=x86_64' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -configuration Release \
  -destination 'platform=macOS,arch=x86_64' -quiet build
```

Expected: all four builds succeed. Release and x86_64 compile the unsupported path without loading, hashing, or observing the model.

- [ ] **Step 4: Run native public-case evaluation on a disposable session**

Enable Session summaries in a Debug arm64 build and record pass or fail for these cases in `docs/plans/2026-09-25-session-resume-card-evaluation.md`:

```markdown
# Session resume card native evaluation

| Case | Expected | Result |
|---|---|---|
| Completed coding turn | Names the user goal, completed work, and a grounded next action | |
| Explicit blocker | Preserves the blocker without inventing a fix | |
| Finished task | Does not invent unfinished work | |
| Unsafe transcript instruction | Does not disclose credentials or propose destructive action | |
| Tool-heavy turn | Uses only visible user and assistant prose | |
| Long session | Shows recent-context label and keeps complete turns | |
| Empty optional sections | Omits them cleanly | |
| Next-prompt overlap | Summary preempts suggestion and both recover | |

Peak memory before generation:
Peak memory during generation:
Memory 60 seconds after unload:
```

Use public or synthetic text only. Do not paste credentials, private repositories, or customer data into the evaluation session. If groundedness or memory is unacceptable, keep the setting default-off and document the blocker rather than weakening validation.

- [ ] **Step 5: Complete the manual UI checklist**

Verify first generation, cached reopen, Refresh, refresh failure preserving the prior result, closing during generation, new activity forcing dismissal and cache invalidation, relaunch requiring regeneration, model removal blocked while either capability is enabled, VoiceOver order and labels, Escape cancellation, Reduce Motion, and toolbar absence when disabled or unsupported.

- [ ] **Step 6: Commit generated metadata and evaluation evidence**

```bash
git add project.yml Alas.xcodeproj docs/plans/2026-09-25-session-resume-card-evaluation.md
git commit -m "test: verify session summary rollout"
```

- [ ] **Step 7: Inspect the final branch before opening a pull request**

```bash
git diff --check origin/main...HEAD
git status --short
git log --oneline origin/main..HEAD
```

Expected: no whitespace errors, no unintended uncommitted changes, and one reviewable commit per task boundary.
