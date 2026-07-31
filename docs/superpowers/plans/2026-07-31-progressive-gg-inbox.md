# Progressive gg Inbox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stream `gg inbox --jsonl` results into the Alas Inbox tab as each candidate completes, with a hard gg 0.9.12 minimum and an inline Homebrew upgrade path.

**Architecture:** `GGInboxModels` owns the versioned JSONL event contract, `GGService` turns the process line stream into a validated typed stream, and `GGInboxStore` reduces one isolated refresh generation into observable partial state before reconciling the final summary. `GGInboxTabView` remains a state renderer and gates refreshes through the existing session-cached gg version probe.

**Tech Stack:** Swift 5.9+, SwiftUI/Observation, `AsyncThrowingStream`, Foundation `Process`, Swift Testing, XcodeGen.

## Global Constraints

- Inbox requires gg 0.9.12 or newer; there is no `gg inbox --json` fallback.
- The minimum applies only to Inbox; do not change other gg capability gates.
- Keep `gg Inbox` discoverable for otherwise-qualified projects with an older installed gg.
- Preserve project-scoped caching, refresh deduplication, invalidation generations, and stale-snapshot rollback.
- Do not mix entries from different refresh generations.
- Treat only the final `summary` as complete and timestampable.
- Keep all code, comments, logs, and UI copy in English.
- Use Swift Testing (`import Testing`), not XCTest.
- Do not add a new source file; keep the event contract in `GGInboxModels.swift`, so Xcode project membership does not change.
- Prefix repository commands with `rtk`.

---

## File Map

- `Alas/Sources/Integrations/GG/GGInboxModels.swift`: atomic snapshot additions, JSONL event types/decoder, bucket mutation helpers, optional URL normalization.
- `Alas/Sources/Integrations/GG/GGService.swift`: validated `inboxStream(repoPath:)` orchestration over the existing incremental runner.
- `Alas/Sources/Integrations/GG/GGInboxStore.swift`: generation-scoped progressive reducer, progress state, rollback, and final-summary publication.
- `Alas/Sources/Integrations/GG/GGInstallController.swift`: Homebrew upgrade operation while preserving the Settings install API.
- `Alas/Sources/Integrations/GG/GGInboxTabView.swift`: version gate, upgrade screen, progress label, Refresh failed rows, and optional PR link.
- `AlasTests/Integrations/GGInboxModelsTests.swift`: snapshot and event-decoder contract tests.
- `AlasTests/Integrations/GGServiceInboxTests.swift`: stream sequencing, invocation, and failure tests.
- `AlasTests/Integrations/GGInboxStoreTests.swift`: progressive-generation and rollback tests.
- `AlasTests/Integrations/GGInstallControllerTests.swift`: upgrade execution/reprobe tests.
- `AlasTests/Integrations/GGInboxHelpersTests.swift`: minimum-version and presentation-helper tests.

---

### Task 1: Model the gg 0.9.12 snapshot and JSONL event contract

**Files:**
- Modify: `Alas/Sources/Integrations/GG/GGInboxModels.swift:3-99`
- Test: `AlasTests/Integrations/GGInboxModelsTests.swift:5-64`

**Interfaces:**
- Consumes: `GGServiceError.malformedOutput`, gg JSONL schema version 1.
- Produces: `GGInboxEvent.decode(line:) throws -> GGInboxEvent`, `GGInboxSnapshot`, `GGInboxBuckets`, `GGInboxEntry`, `GGInboxBucket`, and `GGInboxSupport.isSupported(version:)` for Tasks 2-5.

- [ ] **Step 1: Write failing snapshot-addition tests**

Update `fullSample` to include an empty `refresh_failed` array. Add a refresh-failed fixture that proves the additive fields and empty URL normalization:

```swift
@Test func decodesRefreshFailedEntryAndNormalizesEmptyURL() throws {
    let json = #"{"version":1,"total_items":1,"buckets":{"refresh_failed":[{"stack_name":"auth","position":1,"sha":"abc123","title":"Add login","pr_number":42,"pr_url":"","ci_status":null,"behind_base":2,"refresh_error":"provider unavailable"}],"ready_to_land":[],"changes_requested":[],"blocked_on_ci":[],"awaiting_review":[],"behind_base":[],"draft":[]},"stack_errors":[]}"#

    let snapshot = try GGInboxSnapshot.decode(fromJSON: Data(json.utf8))
    let entry = try #require(snapshot.buckets.refreshFailed.first)
    #expect(entry.prUrl == nil)
    #expect(entry.refreshError == "provider unavailable")
    #expect(GGInboxBucket.allCases.first == .refreshFailed)
}
```

- [ ] **Step 2: Write failing JSONL event tests**

Add one test per event shape, using the exact 0.9.12 field names. The core assertions are:

```swift
@Test func decodesInboxJSONLEvents() throws {
    #expect(try GGInboxEvent.decode(line: #"{"event":"start","total_candidates":2,"total_stack_errors":1,"version":1,"command":"inbox"}"#)
        == .start(totalCandidates: 2, totalStackErrors: 1))

    #expect(try GGInboxEvent.decode(line: #"{"event":"stack_error","stack_name":"stale","error":"missing base","version":1,"command":"inbox"}"#)
        == .stackError(GGInboxStackError(stackName: "stale", error: "missing base")))

    let entry = try GGInboxEvent.decode(line: #"{"event":"entry","completed":1,"total_candidates":2,"included":true,"bucket":"ready_to_land","remote_state":"open","entry":{"stack_name":"auth","position":1,"sha":"abc123","title":"Add login","pr_number":42,"pr_url":"https://example.test/42","ci_status":"success","behind_base":null},"version":1,"command":"inbox"}"#)
    guard case .entry(let payload) = entry else {
        Issue.record("Expected entry event")
        return
    }
    #expect(payload.completed == 1)
    #expect(payload.bucket == .readyToLand)
    #expect(payload.entry.prUrl == "https://example.test/42")

    let failed = try GGInboxEvent.decode(line: #"{"event":"entry_error","completed":2,"total_candidates":2,"included":true,"bucket":"refresh_failed","entry":{"stack_name":"perf","position":2,"sha":"def456","title":"Cache layer","pr_number":43,"behind_base":3},"error":"provider unavailable","version":1,"command":"inbox"}"#)
    guard case .entryError(let payload) = failed else {
        Issue.record("Expected entry_error event")
        return
    }
    #expect(payload.failedEntry.refreshError == "provider unavailable")
    #expect(payload.failedEntry.prUrl == nil)

    let summary = try GGInboxEvent.decode(line: #"{"event":"summary","total_items":0,"buckets":{"refresh_failed":[],"ready_to_land":[],"changes_requested":[],"blocked_on_ci":[],"awaiting_review":[],"behind_base":[],"draft":[]},"stack_errors":[],"version":1,"command":"inbox"}"#)
    guard case .summary(let snapshot) = summary else {
        Issue.record("Expected summary event")
        return
    }
    #expect(snapshot.totalItems == 0)

    #expect(try GGInboxEvent.decode(line: #"{"version":1,"command":"inbox","status":"error","event":"error","message":"Not in a git repository"}"#)
        == .error(message: "Not in a git repository"))
}
```

Add rejection cases:

```swift
@Test(arguments: [
    #"{"event":"start","total_candidates":0,"total_stack_errors":0,"version":2,"command":"inbox"}"#,
    #"{"event":"start","total_candidates":0,"total_stack_errors":0,"version":1,"command":"sync"}"#,
    #"{"event":"future_event","version":1,"command":"inbox"}"#,
    "not json",
])
func rejectsInvalidInboxJSONLEnvelopes(_ line: String) {
    #expect(throws: GGServiceError.self) {
        _ = try GGInboxEvent.decode(line: line)
    }
}
```

- [ ] **Step 3: Run the model tests and confirm they fail**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GGInboxModelsTests test
```

Expected: compilation failures for missing `refreshFailed`, `refreshError`, `GGInboxEvent`, and `GGInboxSupport` APIs.

- [ ] **Step 4: Implement the additive snapshot model**

Make bucket properties mutable for progressive insertion, add explicit initializers, and decode `refresh_failed` as required in the 0.9.12 schema:

```swift
struct GGInboxSnapshot: Equatable, Decodable {
    let version: Int
    let totalItems: Int
    let buckets: GGInboxBuckets
    let stackErrors: [GGInboxStackError]

    init(version: Int = 1, totalItems: Int, buckets: GGInboxBuckets, stackErrors: [GGInboxStackError]) {
        self.version = version
        self.totalItems = totalItems
        self.buckets = buckets
        self.stackErrors = stackErrors
    }
}

struct GGInboxBuckets: Equatable, Decodable {
    var refreshFailed: [GGInboxEntry]
    var readyToLand: [GGInboxEntry]
    var changesRequested: [GGInboxEntry]
    var blockedOnCi: [GGInboxEntry]
    var awaitingReview: [GGInboxEntry]
    var behindBase: [GGInboxEntry]
    var draft: [GGInboxEntry]
    var merged: [GGInboxEntry]

    init(
        refreshFailed: [GGInboxEntry] = [],
        readyToLand: [GGInboxEntry] = [],
        changesRequested: [GGInboxEntry] = [],
        blockedOnCi: [GGInboxEntry] = [],
        awaitingReview: [GGInboxEntry] = [],
        behindBase: [GGInboxEntry] = [],
        draft: [GGInboxEntry] = [],
        merged: [GGInboxEntry] = []
    ) {
        self.refreshFailed = refreshFailed
        self.readyToLand = readyToLand
        self.changesRequested = changesRequested
        self.blockedOnCi = blockedOnCi
        self.awaitingReview = awaitingReview
        self.behindBase = behindBase
        self.draft = draft
        self.merged = merged
    }
}
```

Give `GGInboxEntry` an explicit memberwise initializer and custom decoder. Decode `pr_url` as `String?`, normalize `""` to `nil`, and decode `refresh_error` with `decodeIfPresent`:

```swift
struct GGInboxEntry: Equatable, Decodable {
    let stackName: String
    let position: Int
    let sha: String
    let title: String
    let prNumber: Int
    let prUrl: String?
    let ciStatus: String?
    let behindBase: Int?
    let refreshError: String?
}
```

Make `GGInboxBucket` raw-string backed and put `.refreshFailed` first. Add `mutating func insert(_ entry: GGInboxEntry, into bucket: GGInboxBucket)` on `GGInboxBuckets`; upsert by `(stackName, position, prNumber)` and sort by `stackName`, then `position`, then `sha`.

- [ ] **Step 5: Implement the typed event decoder and version helper**

Add exact payload types and decode through a shallow envelope before switching on `event`:

```swift
struct GGInboxEntryEvent: Equatable {
    let completed: Int
    let totalCandidates: Int
    let included: Bool
    let bucket: GGInboxBucket?
    let remoteState: String
    let entry: GGInboxEntry
}

struct GGInboxEntryErrorEvent: Equatable {
    let completed: Int
    let totalCandidates: Int
    let included: Bool
    let bucket: GGInboxBucket
    let failedEntry: GGInboxEntry
}

enum GGInboxEvent: Equatable {
    case start(totalCandidates: Int, totalStackErrors: Int)
    case stackError(GGInboxStackError)
    case entry(GGInboxEntryEvent)
    case entryError(GGInboxEntryErrorEvent)
    case summary(GGInboxSnapshot)
    case error(message: String)

    static func decode(line: String) throws -> GGInboxEvent {
        let data = Data(line.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            let envelope = try decoder.decode(GGInboxEventEnvelope.self, from: data)
            guard envelope.version == 1 else {
                throw GGServiceError.unsupportedSchema(envelope.version)
            }
            guard envelope.command == "inbox" else {
                throw GGServiceError.malformedOutput("Expected gg inbox event, got \(envelope.command).")
            }
            switch envelope.event {
            case "start": return try decoder.decode(GGInboxStartPayload.self, from: data).event
            case "stack_error": return try decoder.decode(GGInboxStackErrorPayload.self, from: data).event
            case "entry": return try decoder.decode(GGInboxEntryPayload.self, from: data).event
            case "entry_error": return try decoder.decode(GGInboxEntryErrorPayload.self, from: data).event
            case "summary": return .summary(try decoder.decode(GGInboxSnapshot.self, from: data))
            case "error": return .error(message: try decoder.decode(GGInboxFatalPayload.self, from: data).message)
            default: throw GGServiceError.malformedOutput("Unknown gg inbox event: \(envelope.event)")
            }
        } catch let error as GGServiceError {
            throw error
        } catch {
            throw GGServiceError.malformedOutput(String(describing: error))
        }
    }
}

enum GGInboxSupport {
    static let minimumVersion = SemanticVersion(major: 0, minor: 9, patch: 12)

    static func isSupported(version: String?) -> Bool {
        guard let version, let parsed = SemanticVersion(parsing: version) else { return false }
        return parsed >= minimumVersion
    }
}
```

The private payload structs must decode all fields named in the event tests. `GGInboxEntryErrorPayload.event` constructs `failedEntry` with `prUrl: nil`, `ciStatus: nil`, and `refreshError: error`.

- [ ] **Step 6: Run model tests and commit**

Run the focused command from Step 3. Expected: all `GGInboxModelsTests` pass.

```bash
rtk git add Alas/Sources/Integrations/GG/GGInboxModels.swift AlasTests/Integrations/GGInboxModelsTests.swift
rtk git commit -m "feat(gg): model streaming inbox events"
```

---

### Task 2: Stream and validate the Inbox protocol in GGService

**Files:**
- Modify: `Alas/Sources/Integrations/GG/GGService.swift:338-345`
- Modify: `AlasTests/Integrations/GGServiceInboxTests.swift:5-47`

**Interfaces:**
- Consumes: `GGInboxEvent.decode(line:)` from Task 1 and `GGCommandRunning.runStreaming(args:cwd:)`.
- Produces: `GGService.inboxStream(repoPath:) -> AsyncThrowingStream<GGInboxEvent, Error>` for Task 3.

- [ ] **Step 1: Replace atomic service tests with failing stream tests**

Keep `InboxRecordingGGRunner`, but assert the default buffered `runStreaming` path now calls JSONL and yields typed events:

```swift
@Test func inboxStreamsAtRepoPathAndDecodes() async throws {
    let ndjson = [
        #"{"event":"start","total_candidates":0,"total_stack_errors":0,"version":1,"command":"inbox"}"#,
        #"{"event":"summary","total_items":0,"buckets":{"refresh_failed":[],"ready_to_land":[],"changes_requested":[],"blocked_on_ci":[],"awaiting_review":[],"behind_base":[],"draft":[]},"stack_errors":[],"version":1,"command":"inbox"}"#,
    ].joined(separator: "\n")
    let runner = InboxRecordingGGRunner(result: ProcessResult(exitCode: 0, stdout: ndjson, stderr: ""))

    var events: [GGInboxEvent] = []
    for try await event in GGService(runner: runner).inboxStream(repoPath: "/repo/root") {
        events.append(event)
    }

    #expect(runner.lastArgs == ["inbox", "--jsonl"])
    #expect(runner.lastCwd?.path == "/repo/root")
    #expect(events.count == 2)
}
```

Add table-driven sequence failures for: summary without start, duplicate start,
duplicate summary, an entry after summary, clean EOF after start without summary,
malformed line, and an event whose `total_candidates` differs from start. Assert
each stream iteration throws `GGServiceError`.

Add the fatal exception test:

```swift
@Test func inboxAcceptsSoleFatalEventAndSurfacesItsMessage() async {
    let line = #"{"version":1,"command":"inbox","status":"error","event":"error","message":"Not in a git repository"}"#
    let runner = InboxRecordingGGRunner(result: ProcessResult(exitCode: 1, stdout: line, stderr: "fallback stderr"))

    await #expect(throws: GGServiceError.commandFailed(stderr: "Not in a git repository")) {
        for try await _ in GGService(runner: runner).inboxStream(repoPath: "/repo/root") {}
    }
}
```

- [ ] **Step 2: Run service tests and confirm they fail**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GGServiceInboxTests test
```

Expected: compilation failure because `inboxStream(repoPath:)` does not exist and the old method still invokes `--json`.

- [ ] **Step 3: Implement stream sequencing and fatal-message precedence**

Replace the atomic Inbox method with a typed stream. Keep the raw process stream alive until EOF, even after receiving a fatal event:

```swift
func inboxStream(repoPath: String) -> AsyncThrowingStream<GGInboxEvent, Error> {
    AsyncThrowingStream { continuation in
        Task {
            var sawStart = false
            var sawSummary = false
            var fatalMessage: String?
            var totalCandidates: Int?
            var lastCompleted = 0

            do {
                do {
                    for try await line in runner.runStreaming(
                        args: ["inbox", "--jsonl"],
                        cwd: URL(fileURLWithPath: repoPath)
                    ) {
                        guard !sawSummary, fatalMessage == nil else {
                            throw GGServiceError.malformedOutput("gg inbox emitted data after a terminal event.")
                        }
                        let event = try GGInboxEvent.decode(line: line)
                        switch event {
                        case .error(let message):
                            fatalMessage = message
                        case .start(let count, _):
                            guard !sawStart else {
                                throw GGServiceError.malformedOutput("gg inbox emitted duplicate start events.")
                            }
                            sawStart = true
                            totalCandidates = count
                            continuation.yield(event)
                        case .entry(let payload):
                            try Self.validateInboxProgress(
                                started: sawStart,
                                expectedTotal: totalCandidates,
                                completed: payload.completed,
                                eventTotal: payload.totalCandidates,
                                lastCompleted: &lastCompleted
                            )
                            continuation.yield(event)
                        case .entryError(let payload):
                            try Self.validateInboxProgress(
                                started: sawStart,
                                expectedTotal: totalCandidates,
                                completed: payload.completed,
                                eventTotal: payload.totalCandidates,
                                lastCompleted: &lastCompleted
                            )
                            continuation.yield(event)
                        case .stackError:
                            guard sawStart else {
                                throw GGServiceError.malformedOutput("gg inbox emitted stack_error before start.")
                            }
                            continuation.yield(event)
                        case .summary:
                            guard sawStart else {
                                throw GGServiceError.malformedOutput("gg inbox emitted summary before start.")
                            }
                            sawSummary = true
                            continuation.yield(event)
                        }
                    }
                } catch {
                    if let fatalMessage {
                        throw GGServiceError.commandFailed(stderr: fatalMessage)
                    }
                    throw error
                }

                if let fatalMessage {
                    throw GGServiceError.commandFailed(stderr: fatalMessage)
                }
                guard sawStart, sawSummary else {
                    throw GGServiceError.malformedOutput("gg inbox ended without a summary event.")
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
```

Implement `validateInboxProgress` as a private static helper. It must require a
start event, require `eventTotal == expectedTotal`, require
`lastCompleted < completed && completed <= eventTotal`, then assign
`lastCompleted = completed`. The 0.9.12 contract increments once per candidate,
so repeated or decreasing values are malformed output.

- [ ] **Step 4: Run service and low-level streaming tests**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GGServiceInboxTests -only-testing:AlasTests/GGCommandRunningStreamingTests test
```

Expected: all selected tests pass, including existing proof that
`ProcessGGCommandRunner.streamProcess` yields before process completion.

- [ ] **Step 5: Commit the service boundary**

```bash
rtk git add Alas/Sources/Integrations/GG/GGService.swift AlasTests/Integrations/GGServiceInboxTests.swift
rtk git commit -m "feat(gg): stream inbox jsonl events"
```

---

### Task 3: Reduce progressive events in one isolated store generation

**Files:**
- Modify: `Alas/Sources/Integrations/GG/GGInboxStore.swift:4-78`
- Modify: `AlasTests/Integrations/GGInboxStoreTests.swift:5-176`

**Interfaces:**
- Consumes: `GGService.inboxStream(repoPath:)` and the Task 1 event/snapshot types.
- Produces: `GGInboxStore.State.refreshProgress: GGInboxRefreshProgress?` and progressively updated `State.snapshot` for Task 5.

- [ ] **Step 1: Add a controllable streaming runner to store tests**

Replace atomic-only suspended fixtures with a runner that exposes its
continuation and records invocation:

```swift
private final class ControlledInboxRunner: GGCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private(set) var lastArgs: [String] = []

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }

    func runStreaming(args: [String], cwd: URL?) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        lastArgs = args
        lock.unlock()
        return AsyncThrowingStream { continuation in
            self.lock.lock()
            self.continuation = continuation
            self.lock.unlock()
        }
    }

    func yield(_ line: String) {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        continuation?.yield(line)
    }

    func finish(throwing error: Error? = nil) {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
    }
}
```

Retain `waitUntil` and use it after every yielded event so assertions observe
the MainActor write before sending the next line. Replace `emptyJSON` with an
`emptyJSONL` fixture containing a `start` line followed by an empty `summary`,
and update every pre-existing success runner to return that fixture. Update the
invalidation replacement fixture by changing `summary.total_items` instead of
the removed atomic document.

- [ ] **Step 2: Write failing progressive-generation tests**

Add a test that seeds a complete snapshot, starts a two-candidate stream, and
asserts the exact state transitions:

```swift
@Test func refreshKeepsOldSnapshotUntilFirstCompletionThenPublishesPartialState() async throws {
    let store = GGInboxStore()
    let old = GGInboxSnapshot(totalItems: 9, buckets: GGInboxBuckets(), stackErrors: [])
    store.states["p1"] = .init(snapshot: old, fetchedAt: Date(timeIntervalSince1970: 100))
    let runner = ControlledInboxRunner()
    let task = Task { @MainActor in
        await store.refresh(projectId: "p1", repoPath: "/repo", service: GGService(runner: runner), now: { Date(timeIntervalSince1970: 200) })
    }
    try await waitUntil { runner.lastArgs == ["inbox", "--jsonl"] }

    runner.yield(#"{"event":"start","total_candidates":2,"total_stack_errors":0,"version":1,"command":"inbox"}"#)
    try await waitUntil { store.states["p1"]?.refreshProgress?.total == 2 }
    #expect(store.states["p1"]?.snapshot == old)

    runner.yield(Self.readyEntryEvent(completed: 1, total: 2))
    try await waitUntil { store.states["p1"]?.refreshProgress?.completed == 1 }
    #expect(store.states["p1"]?.snapshot?.totalItems == 1)
    #expect(store.states["p1"]?.snapshot != old)

    runner.yield(Self.emptySummary)
    runner.finish()
    await task.value
    #expect(store.states["p1"]?.snapshot?.totalItems == 0)
    #expect(store.states["p1"]?.fetchedAt == Date(timeIntervalSince1970: 200))
    #expect(store.states["p1"]?.refreshProgress == nil)
}
```

Add focused tests with concrete two-event fixtures for:

- `entry_error` immediately populating `refreshFailed` with no PR URL.
- an excluded `entry` switching generations and advancing progress without adding a row.
- fast `perf #2` then slow `auth #1` ending in stable `auth`, `perf` order.
- `stack_error` accumulating before the first completion and appearing when partial state publishes.
- fatal EOF before summary restoring the old snapshot and preserving its old `fetchedAt`.
- invalidation after first partial publication restoring the old snapshot, setting `fetchedAt` to `nil`, and ignoring the later summary.
- a second refresh call returning while `isRefreshing` is true.

- [ ] **Step 3: Run store tests and confirm failures**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GGInboxStoreTests test
```

Expected: compilation failures for `refreshProgress` and failures from the old atomic reducer.

- [ ] **Step 4: Add progress state and implement the event reducer**

Add the state value:

```swift
struct GGInboxRefreshProgress: Equatable {
    let completed: Int
    let total: Int
}

struct State: Equatable {
    var snapshot: GGInboxSnapshot? = nil
    var fetchedAt: Date? = nil
    var isRefreshing: Bool = false
    var refreshProgress: GGInboxRefreshProgress? = nil
    var lastError: String? = nil
}
```

In `refresh`, capture `rollbackSnapshot` and `rollbackFetchedAt`, create empty
`partialBuckets`/`partialStackErrors`, and drain `service.inboxStream`. Before
every write, compare the captured invalidation generation. Continue draining
after invalidation but skip publication.

Use this reduction shape:

```swift
switch event {
case .start(let total, _):
    state.refreshProgress = .init(completed: 0, total: total)
case .stackError(let error):
    partialStackErrors.append(error)
case .entry(let payload):
    state.refreshProgress = .init(completed: payload.completed, total: payload.totalCandidates)
    if payload.included, let bucket = payload.bucket {
        partialBuckets.insert(payload.entry, into: bucket)
    }
    publishPartial = true
case .entryError(let payload):
    state.refreshProgress = .init(completed: payload.completed, total: payload.totalCandidates)
    partialBuckets.insert(payload.failedEntry, into: .refreshFailed)
    publishPartial = true
case .summary(let snapshot):
    state.snapshot = snapshot
    state.fetchedAt = now()
    state.refreshProgress = nil
    state.lastError = nil
    sawSummary = true
case .error:
    preconditionFailure("GGService intercepts fatal inbox events")
}

if publishPartial {
    state.snapshot = GGInboxSnapshot(
        totalItems: GGInboxBucket.allCases.reduce(0) { $0 + $1.entries(in: partialBuckets).count },
        buckets: partialBuckets,
        stackErrors: partialStackErrors
    )
}
```

On a command-level catch, restore both rollback values, clear progress, and set
`lastError`. On invalidation, restore `rollbackSnapshot`, force `fetchedAt = nil`,
clear refresh/progress, and do not publish any later event. On normal summary,
clear `isRefreshing` only after stream completion.

- [ ] **Step 5: Run store and model tests**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GGInboxStoreTests -only-testing:AlasTests/GGInboxModelsTests test
```

Expected: all selected tests pass.

- [ ] **Step 6: Commit progressive store state**

```bash
rtk git add Alas/Sources/Integrations/GG/GGInboxStore.swift AlasTests/Integrations/GGInboxStoreTests.swift
rtk git commit -m "feat(gg): publish progressive inbox state"
```

---

### Task 4: Add the Homebrew upgrade operation and minimum-version helpers

**Files:**
- Modify: `Alas/Sources/Integrations/GG/GGInstallController.swift:4-58`
- Modify: `AlasTests/Integrations/GGInstallControllerTests.swift:5-37`
- Modify: `AlasTests/Integrations/GGInboxHelpersTests.swift:74-110`

**Interfaces:**
- Consumes: `GGInboxSupport.isSupported(version:)` from Task 1 and `GGAvailability.probe(force:)` through the existing injected reprobe closure.
- Produces: `GGInstallController.upgrade()` / `upgradeAndWait()` and tested version/progress helpers for Task 5.

- [ ] **Step 1: Write failing controller upgrade tests**

Add an injected `runUpgrade` closure and verify execution, reprobe, errors, and
the running-phase dedupe:

```swift
@Test func successfulUpgradeReachesSucceededAndReprobes() async {
    var upgraded = false
    var probed = false
    let controller = GGInstallController(
        runInstall: { ProcessResult(exitCode: 0, stdout: "", stderr: "") },
        runUpgrade: {
            upgraded = true
            return ProcessResult(exitCode: 0, stdout: "upgraded", stderr: "")
        },
        reprobe: {
            probed = true
            return true
        }
    )

    await controller.upgradeAndWait()
    #expect(controller.phase == .succeeded)
    #expect(upgraded)
    #expect(probed)
}

@Test func upgradeFailureSurfacesStderrWithoutReprobe() async {
    var probed = false
    let controller = GGInstallController(
        runInstall: { ProcessResult(exitCode: 0, stdout: "", stderr: "") },
        runUpgrade: { ProcessResult(exitCode: 1, stdout: "", stderr: "formula unavailable") },
        reprobe: {
            probed = true
            return true
        }
    )

    await controller.upgradeAndWait()
    #expect(controller.phase == .failed("formula unavailable"))
    #expect(!probed)
}
```

Retain all install tests unchanged to prove Settings compatibility.

- [ ] **Step 2: Write failing version and presentation-helper tests**

Add:

```swift
@Test(arguments: ["0.9.12", "0.9.13", "0.10.0", "1.0.0"])
func supportedInboxVersions(_ version: String) {
    #expect(GGInboxSupport.isSupported(version: version))
}

@Test(arguments: [nil, "", "abc", "0.9.11", "0.8.99"] as [String?])
func unsupportedInboxVersions(_ version: String?) {
    #expect(!GGInboxSupport.isSupported(version: version))
}

@Test func refreshProgressLabel() {
    #expect(GGInboxTabView.refreshLabel(nil) == nil)
    #expect(GGInboxTabView.refreshLabel(.init(completed: 2, total: 5)) == "Refreshing 2/5")
}

@Test func validPRURLRequiresHTTPOrHTTPS() {
    #expect(GGInboxTabView.validPRURL("https://example.test/42") != nil)
    #expect(GGInboxTabView.validPRURL("") == nil)
    #expect(GGInboxTabView.validPRURL(nil) == nil)
    #expect(GGInboxTabView.validPRURL("file:///tmp/secret") == nil)
}
```

- [ ] **Step 3: Run focused tests and confirm failures**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GGInstallControllerTests -only-testing:AlasTests/GGInboxHelpersTests test
```

Expected: compilation failures for the upgrade API and the two view helpers.

- [ ] **Step 4: Implement the upgrade operation without changing install callers**

Add a second injected command with the exact Homebrew invocation:

```swift
private let runUpgrade: @Sendable () async throws -> ProcessResult

init(
    runInstall: @escaping @Sendable () async throws -> ProcessResult = {
        try await Process.run(
            "/usr/bin/env",
            args: ["brew", "install", "mrmans0n/tap/gg-stack"],
            env: Process.gitEnv(),
            timeout: 600
        )
    },
    runUpgrade: @escaping @Sendable () async throws -> ProcessResult = {
        try await Process.run(
            "/usr/bin/env",
            args: ["brew", "upgrade", "mrmans0n/tap/gg-stack"],
            env: Process.gitEnv(),
            timeout: 600
        )
    },
    reprobe: @escaping @MainActor () async -> Bool = {
        await GGAvailability.shared.probe(force: true)
        return GGAvailability.shared.isInstalled
    }
) {
    self.runInstall = runInstall
    self.runUpgrade = runUpgrade
    self.reprobe = reprobe
}

func upgrade() {
    Task { await upgradeAndWait() }
}

func upgradeAndWait() async {
    await perform(runUpgrade, missingMessage: "gg is still not on PATH after upgrade.")
}
```

Extract the existing phase/exit/stderr/reprobe flow into
`perform(_:missingMessage:)`. Keep `install()` and `installAndWait()` source
compatible and pass the existing install-specific missing message.

- [ ] **Step 5: Add the pure view helpers**

In `GGInboxTabView`, add:

```swift
static func refreshLabel(_ progress: GGInboxRefreshProgress?) -> String? {
    guard let progress else { return nil }
    return "Refreshing \(progress.completed)/\(progress.total)"
}

static func validPRURL(_ rawValue: String?) -> URL? {
    guard let rawValue, let url = URL(string: rawValue),
          url.scheme == "https" || url.scheme == "http" else { return nil }
    return url
}
```

- [ ] **Step 6: Run focused tests and commit**

Run the command from Step 3. Expected: all selected tests pass.

```bash
rtk git add Alas/Sources/Integrations/GG/GGInstallController.swift Alas/Sources/Integrations/GG/GGInboxTabView.swift AlasTests/Integrations/GGInstallControllerTests.swift AlasTests/Integrations/GGInboxHelpersTests.swift
rtk git commit -m "feat(gg): add inbox upgrade gate support"
```

---

### Task 5: Render progressive Inbox state and the upgrade-required screen

**Files:**
- Modify: `Alas/Sources/Integrations/GG/GGInboxTabView.swift:60-310`
- Modify: `AlasTests/Integrations/GGInboxHelpersTests.swift:74-110`
- Modify: `AlasTests/Integrations/GGInboxModelsTests.swift:52-63`

**Interfaces:**
- Consumes: `GGInboxSupport`, `GGInboxStore.State.refreshProgress`, `GGInstallController.upgrade()`, optional `GGInboxEntry.prUrl`, and `.refreshFailed`.
- Produces: the complete user-facing progressive Inbox behavior.

- [ ] **Step 1: Extend failing presentation metadata assertions**

Make the bucket-order test assert the complete new order and styling:

```swift
#expect(GGInboxBucket.allCases == [
    .refreshFailed, .readyToLand, .changesRequested, .blockedOnCi,
    .awaitingReview, .behindBase, .draft,
])
#expect(GGInboxBucket.refreshFailed.title == "Refresh failed")
#expect(GGInboxBucket.refreshFailed.themeToken == "warn")
```

Add a pure empty-state helper and test so partial zero-item state cannot claim
success:

```swift
@Test func clearInboxRequiresCompletedNonErrorState() {
    let empty = GGInboxSnapshot(totalItems: 0, buckets: GGInboxBuckets(), stackErrors: [])
    #expect(GGInboxTabView.shouldShowClearInbox(snapshot: empty, isRefreshing: false, lastError: nil))
    #expect(!GGInboxTabView.shouldShowClearInbox(snapshot: empty, isRefreshing: true, lastError: nil))
    #expect(!GGInboxTabView.shouldShowClearInbox(snapshot: empty, isRefreshing: false, lastError: "failed"))
}
```

- [ ] **Step 2: Run model/helper tests and confirm failure**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GGInboxModelsTests -only-testing:AlasTests/GGInboxHelpersTests test
```

Expected: failure until the new bucket metadata and clear-state helper exist.

- [ ] **Step 3: Add the version-gated content state and upgrade controller**

Add observable upgrade state:

```swift
@State private var ggUpgrade = GGInstallController()

private var supportsStreamingInbox: Bool {
    GGInboxSupport.isSupported(version: GGAvailability.shared.version)
}
```

At the top of `content`, render `upgradeRequiredState` when unsupported. The
state must show `gg <detected>` when a raw version exists, the exact requirement
copy `gg Inbox requires gg 0.9.12 or newer.`, the controller's running/error
phase, and an `AlasButton(title: "Upgrade gg…", style: .normal)` that calls
`ggUpgrade.upgrade()`.

Observe `ggUpgrade.phase`. When it becomes `.succeeded`, force no second probe
(the controller already did it); if `supportsStreamingInbox` is true, call
`refresh()`. If it remains unsupported, leave the upgrade-required state visible
with the newly probed raw version.

- [ ] **Step 4: Render progress and partial/failure rows**

In the header, when `isRefreshing` is true, show
`refreshLabel(inboxState.refreshProgress)` beside the spinner. Keep the previous
updated timestamp hidden during refresh and restore it afterward.

Use the tested helper for empty-state selection:

```swift
static func shouldShowClearInbox(
    snapshot: GGInboxSnapshot,
    isRefreshing: Bool,
    lastError: String?
) -> Bool {
    snapshot.totalItems == 0 && snapshot.stackErrors.isEmpty
        && !isRefreshing && lastError == nil
}
```

In `row`, replace unconditional URL creation with:

```swift
if let url = Self.validPRURL(entry.prUrl) {
    Button { NSWorkspace.shared.open(url) } label: { prNumberLabel(entry.prNumber) }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("Open PR in browser")
} else {
    prNumberLabel(entry.prNumber)
}
```

Extract the existing styled number text into the helper used above:

```swift
private func prNumberLabel(_ number: Int) -> some View {
    Text("#\(number)")
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundColor(theme.color("accent"))
}
```

For `entry.refreshError`, add a trailing warning-colored, two-line-limited error
label before the PR number. Preserve the existing row navigation behavior.

- [ ] **Step 5: Prevent unsupported refresh launches**

Make both automatic and manual refresh paths require
`supportsStreamingInbox`. `refreshIfStale()` returns without changing store
state when unsupported; `refresh()` keeps the existing project and
`ggInboxAvailable` guards and adds the version guard.

- [ ] **Step 6: Run all focused Inbox and installer tests**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/GGInboxModelsTests \
  -only-testing:AlasTests/GGServiceInboxTests \
  -only-testing:AlasTests/GGInboxStoreTests \
  -only-testing:AlasTests/GGInboxHelpersTests \
  -only-testing:AlasTests/GGInstallControllerTests test
```

Expected: all selected tests pass.

- [ ] **Step 7: Format, lint, inspect, and commit the UI integration**

Run SwiftFormat in lint mode on the changed source and test files, matching CI's
formatter configuration. Inspect the diff and tracked file set:

```bash
rtk swiftformat Alas/Sources/Integrations/GG/GGInboxModels.swift Alas/Sources/Integrations/GG/GGService.swift Alas/Sources/Integrations/GG/GGInboxStore.swift Alas/Sources/Integrations/GG/GGInstallController.swift Alas/Sources/Integrations/GG/GGInboxTabView.swift AlasTests/Integrations/GGInboxModelsTests.swift AlasTests/Integrations/GGServiceInboxTests.swift AlasTests/Integrations/GGInboxStoreTests.swift AlasTests/Integrations/GGInstallControllerTests.swift AlasTests/Integrations/GGInboxHelpersTests.swift --lint
rtk git diff --check
rtk git status --short
rtk git diff -- Alas/Sources/Integrations/GG AlasTests/Integrations
rtk git ls-files Alas/Sources/Integrations/GG AlasTests/Integrations
```

Commit only the Task 5 files:

```bash
rtk git add Alas/Sources/Integrations/GG/GGInboxTabView.swift AlasTests/Integrations/GGInboxHelpersTests.swift AlasTests/Integrations/GGInboxModelsTests.swift
rtk git commit -m "feat(gg): render progressive inbox refresh"
```

---

## Final Verification

- [ ] Run XcodeGen even though no source-membership change is expected, and inspect whether it changes the project:

```bash
rtk xcodegen
rtk git status --short
```

If `Alas.xcodeproj/project.pbxproj` changes, verify the change is solely the
result of the repository generator, commit `project.yml` only if intentionally
edited, and commit both generator inputs/outputs together. Otherwise leave the
project file untouched.

- [ ] Run the required build:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: exit 0 with no compiler errors.

- [ ] Run the required full test suite:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: exit 0 with all tests passing. A stalled run without an `xctest`
process is incomplete, not passing; capture the last output and report that
boundary truthfully.

- [ ] Verify final scope and history:

```bash
rtk git diff origin/main...HEAD --check
rtk git status --short --branch
rtk git log --oneline origin/main..HEAD
rtk git ls-files docs/superpowers/specs/2026-07-31-progressive-gg-inbox-design.md docs/superpowers/plans/2026-07-31-progressive-gg-inbox.md
```

Expected: clean worktree, only the intended spec/plan and implementation commits,
and both ignored design artifacts explicitly tracked.
