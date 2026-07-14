# ACP Remote Web Incremental Transcript & Fast Stop — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the remote web's full-transcript-replay wire protocol with windowed snapshots + true incremental deltas, and make Stop land in under a second by fast-laning it past the serial queue and the writer-lease round-trips.

**Architecture:** A change log on `ACPTranscript` records which message indices mutated (array-diff in `messages.didSet` + explicit hooks at the streaming-buffer tick sites). Each gateway consumes the log per connection: snapshots carry only a ~90-message tail window; deltas carry only dirty messages; older history is served by a new `fetchOlder` page request. Index-shifting mutations (prepend/removal/wholesale replace) bump an epoch and force a tail re-snapshot — the correctness fallback is always "resync the tail", never "diff harder". Stop becomes a control-class message that skips the per-connection serial chain and the lease confirmation.

**Tech Stack:** Swift 5.9 / SwiftUI macOS app, Network.framework WebSocket server, vanilla-JS web client (`Alas/Resources/RemoteWeb/`), Swift Testing (`import Testing`).

**Spec:** `docs/superpowers/specs/2026-07-14-acp-remote-web-perf-design.md`

## Global Constraints

- All code, comments, logs, UI strings in English.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`) — never XCTest.
- New source files require regenerating the Xcode project: run `xcodegen` and commit `Alas.xcodeproj` alongside the new files.
- No agent attributions anywhere: no `Co-Authored-By`, no "Generated with" footers, no 🤖 markers in commits/PRs/code.
- Build: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build`
- Test (scoped): `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/<SuiteName>`
- Full test suite must pass before finishing: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test`
- Web assets: any change to `app.js`/`style.css` must bump the matching `?v=` in `Alas/Resources/RemoteWeb/index.html` **and** in `sw.js` `SHELL_ASSETS`, and bump `CACHE_NAME` in `sw.js` (currently `alas-remote-shell-v35`, `app.js?v=57`, `style.css?v=36`).
- Both wire endpoints (Swift server + bundled JS client) ship together; no wire backward compatibility is required.

## Design invariants (read before any task)

1. **Message indices are stable under append and in-place mutation.** The only operations that shift indices — prepend during hydration backfill, removals, wholesale array replacement (mirror refresh) — are detected as *structural* changes, bump the `epoch`, clear the log, and force subscribers to re-snapshot. Therefore positional wire ids (`"m<index>"`) remain valid client map keys, and indices recorded in the change log never go stale.
2. **Streaming chunk appends do not fire `messages.didSet`.** `StreamingText` is a reference type with identity equality (`ACPStreamingText.swift:36`), so appends mutate the buffer in place and only bump `transcript.streamingTick`. Every `streamingTick &+= 1` site in `ACPSession.swift` has the mutated index `i` in hand — those sites are the explicit dirty hooks.
3. **The change log is per-transcript; consumption state is per-connection.** Multiple browsers each hold their own `sentVersion`/`revision`; the log is append-only with pruning, and a consumer that falls behind the pruned window gets `.resync`.
4. **Two deliberate refinements vs. the spec:** (a) deltas carry no `removals` field — every removal shifts indices, so it is structural and resolves as a tail re-snapshot (the fallback the spec explicitly allows); (b) the `stopPending` ack goes to the connection that pressed Stop — other subscribers learn via the normal state delta when the cancel lands.

---

### Task 1: `ACPTranscriptChangeLog`

**Files:**
- Create: `Alas/Sources/ACP/Session/ACPTranscriptChangeLog.swift`
- Test: `AlasTests/ACP/ACPTranscriptChangeLogTests.swift`

**Interfaces:**
- Consumes: nothing (pure model).
- Produces: `@MainActor final class ACPTranscriptChangeLog` with:
  - `enum Changes: Equatable { case none, resync, dirty([Int]) }`
  - `private(set) var epoch: Int`, `private(set) var latestVersion: Int`
  - `var isTracking: Bool`, `func retainTracking()`, `func releaseTracking()`
  - `func record(index: Int)`, `func recordStructural()`
  - `func changes(since: Int) -> Changes`

- [ ] **Step 1: Write the failing tests**

Create `AlasTests/ACP/ACPTranscriptChangeLogTests.swift`:

```swift
import Testing
import Foundation
@testable import Alas

@MainActor
struct ACPTranscriptChangeLogTests {
    @Test func recordsNothingWhileNotTracking() {
        let log = ACPTranscriptChangeLog()
        log.record(index: 3)
        #expect(log.latestVersion == 0)
        #expect(log.changes(since: 0) == .none)
    }

    @Test func recordsDirtyIndicesWhileTracking() {
        let log = ACPTranscriptChangeLog()
        log.retainTracking()
        log.record(index: 3)
        log.record(index: 5)
        #expect(log.changes(since: 0) == .dirty([3, 5]))
        #expect(log.changes(since: log.latestVersion) == .none)
    }

    @Test func consecutiveSameIndexCoalescesIntoOneEntry() {
        let log = ACPTranscriptChangeLog()
        log.retainTracking()
        let consumed = log.latestVersion
        for _ in 0..<100 { log.record(index: 7) }   // streaming burst
        #expect(log.changes(since: consumed) == .dirty([7]))
        // A consumer that read mid-burst still sees the entry (version was bumped in place).
        let mid = log.latestVersion - 10
        #expect(log.changes(since: mid) == .dirty([7]))
    }

    @Test func structuralChangeBumpsEpochAndForcesResync() {
        let log = ACPTranscriptChangeLog()
        log.retainTracking()
        log.record(index: 1)
        let consumed = log.latestVersion
        let epochBefore = log.epoch
        log.recordStructural()
        #expect(log.epoch == epochBefore + 1)
        #expect(log.changes(since: consumed) == .resync)
        #expect(log.changes(since: log.latestVersion) == .none)
    }

    @Test func prunedHistoryForcesResync() {
        let log = ACPTranscriptChangeLog()
        log.retainTracking()
        log.record(index: 0)
        let consumed = log.latestVersion
        // Overflow the ring: alternate indices so entries don't coalesce.
        for i in 0..<(ACPTranscriptChangeLog.maxEntries + 10) {
            log.record(index: 1 + (i % 2))
        }
        #expect(log.changes(since: consumed) == .resync)
    }

    @Test func releasingLastTrackerClearsEntries() {
        let log = ACPTranscriptChangeLog()
        log.retainTracking()
        log.retainTracking()
        log.record(index: 2)
        let consumed = 0
        log.releaseTracking()
        #expect(log.changes(since: consumed) == .dirty([2]))   // still one tracker
        log.releaseTracking()
        #expect(log.isTracking == false)
        let versionBefore = log.latestVersion
        log.record(index: 9)                                    // ignored while untracked
        #expect(log.latestVersion == versionBefore)
        // A stale consumer from before the release must resync, not read a gap.
        #expect(log.changes(since: consumed) == .resync)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/ACPTranscriptChangeLogTests 2>&1 | tail -20`
Expected: BUILD FAILURE — `cannot find 'ACPTranscriptChangeLog' in scope`. (You must run `xcodegen` first for the new test file to be seen; it will then fail to compile, which is the expected "red".)

- [ ] **Step 3: Implement the change log**

Create `Alas/Sources/ACP/Session/ACPTranscriptChangeLog.swift`:

```swift
import Foundation

/// Records which transcript message indices mutated so remote-web gateways
/// can send incremental deltas instead of full re-snapshots.
///
/// Indices recorded here never go stale: every index-shifting operation
/// (prepend, removal, wholesale replacement) is recorded as *structural*,
/// which bumps `epoch`, clears the log, and forces consumers to take a
/// fresh tail snapshot. Recording is refcount-gated so the transcript pays
/// zero diff cost when no remote client is subscribed.
@MainActor
final class ACPTranscriptChangeLog {
    enum Changes: Equatable {
        case none
        case resync
        case dirty([Int])   // distinct dirty message indices, ascending
    }

    /// Transcript generation. Bumped on any structural change; a consumer
    /// holding a stale epoch must re-snapshot.
    private(set) var epoch: Int = 0
    /// Monotonic mutation counter. Consumers read "changes since version".
    private(set) var latestVersion: Int = 0
    /// Ring of (version, index) entries; consecutive records of the same
    /// index coalesce by bumping the tail entry's version in place, so a
    /// streaming burst occupies one slot.
    private var entries: [(version: Int, index: Int)] = []
    /// Highest version dropped from `entries`; a consumer behind this
    /// cannot be served incrementally.
    private var prunedThrough: Int = 0
    private var trackingRefCount = 0

    static let maxEntries = 1024

    var isTracking: Bool { trackingRefCount > 0 }

    func retainTracking() { trackingRefCount += 1 }

    func releaseTracking() {
        trackingRefCount = max(0, trackingRefCount - 1)
        if trackingRefCount == 0 {
            entries.removeAll()
            prunedThrough = latestVersion
        }
    }

    func record(index: Int) {
        guard isTracking else { return }
        latestVersion += 1
        if let last = entries.last, last.index == index {
            entries[entries.count - 1].version = latestVersion
        } else {
            entries.append((latestVersion, index))
            if entries.count > Self.maxEntries {
                prunedThrough = entries.removeFirst().version
            }
        }
    }

    func recordStructural() {
        guard isTracking else { return }
        epoch += 1
        latestVersion += 1
        entries.removeAll()
        prunedThrough = latestVersion
    }

    func changes(since: Int) -> Changes {
        if since >= latestVersion { return .none }
        if since < prunedThrough { return .resync }
        let dirty = Set(entries.filter { $0.version > since }.map(\.index))
        // Defensive: a consumer inside the retained window should always
        // find entries; an empty result means bookkeeping drifted — resync.
        return dirty.isEmpty ? .resync : .dirty(dirty.sorted())
    }
}
```

- [ ] **Step 4: Regenerate project, run tests to verify they pass**

Run: `xcodegen && xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/ACPTranscriptChangeLogTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **` with 6 tests passing.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/ACP/Session/ACPTranscriptChangeLog.swift AlasTests/ACP/ACPTranscriptChangeLogTests.swift Alas.xcodeproj
git commit -m "feat(acp): add transcript change log for incremental remote sync"
```

---

### Task 2: Transcript dirty-tracking hooks

**Files:**
- Modify: `Alas/Sources/ACP/Session/ACPTranscript.swift` (add change log + didSet diff + `noteStreamingChange`)
- Modify: `Alas/Sources/ACP/Session/ACPSession.swift` (replace the five `transcript.streamingTick &+= 1` sites)
- Test: `AlasTests/ACP/ACPTranscriptChangeLogTests.swift` (extend)

**Interfaces:**
- Consumes: `ACPTranscriptChangeLog` from Task 1.
- Produces: `ACPTranscript.changeLog: ACPTranscriptChangeLog` (a `let` property) and `ACPTranscript.noteStreamingChange(at index: Int)`. Gateways call `transcript.changeLog.retainTracking()` / `.releaseTracking()` / `.changes(since:)`.

- [ ] **Step 1: Write the failing tests**

Append to the suite in `AlasTests/ACP/ACPTranscriptChangeLogTests.swift`:

```swift
    // MARK: - ACPTranscript hooks

    private func makeTrackedTranscript(messageCount: Int) -> ACPTranscript {
        let t = ACPTranscript()
        t.messages = (0..<messageCount).map { i in
            .user(id: UUID(), messageId: "u\(i)", text: "m\(i)", attachments: [])
        }
        t.changeLog.retainTracking()
        return t
    }

    @Test func appendIsRecordedAsDirtyIndex() {
        let t = makeTrackedTranscript(messageCount: 3)
        let consumed = t.changeLog.latestVersion
        t.messages.append(.systemNotice(id: UUID(), text: "notice"))
        #expect(t.changeLog.changes(since: consumed) == .dirty([3]))
    }

    @Test func inPlaceMutationKeepingIdentityIsRecordedAsDirty() {
        let t = ACPTranscript()
        var tc = ACPMessage.ToolCall(toolCallId: "tc1", title: "read", status: "in_progress", content: "", preview: "")
        t.messages = [.toolCall(tc)]
        t.changeLog.retainTracking()
        let consumed = t.changeLog.latestVersion
        tc.status = "completed"
        t.messages[0] = .toolCall(tc)
        #expect(t.changeLog.changes(since: consumed) == .dirty([0]))
        #expect(t.changeLog.epoch == 0)
    }

    @Test func removalIsStructural() {
        let t = makeTrackedTranscript(messageCount: 3)
        let epochBefore = t.changeLog.epoch
        t.messages.removeLast()
        #expect(t.changeLog.epoch == epochBefore + 1)
    }

    @Test func identityChangeAtExistingIndexIsStructural() {
        let t = makeTrackedTranscript(messageCount: 3)
        let epochBefore = t.changeLog.epoch
        // Prepending shifts every identity; the diff sees index 0's stableId change.
        t.messages.insert(.systemNotice(id: UUID(), text: "older"), at: 0)
        #expect(t.changeLog.epoch == epochBefore + 1)
    }

    @Test func streamingChangeIsRecordedWithoutArrayMutation() {
        let t = ACPTranscript()
        let buf = StreamingText("hel")
        t.messages = [.agent(id: UUID(), messageId: "a1", buf)]
        t.changeLog.retainTracking()
        let consumed = t.changeLog.latestVersion
        let tickBefore = t.streamingTick
        buf.append("lo")                    // no didSet fires (identity equality)
        t.noteStreamingChange(at: 0)
        #expect(t.streamingTick == tickBefore &+ 1)
        #expect(t.changeLog.changes(since: consumed) == .dirty([0]))
    }

    @Test func untrackedTranscriptPaysNoDiffAndRecordsNothing() {
        let t = ACPTranscript()
        t.messages = [.systemNotice(id: UUID(), text: "x")]
        t.messages.append(.systemNotice(id: UUID(), text: "y"))
        #expect(t.changeLog.latestVersion == 0)
    }
```

Note: check `ACPMessage.ToolCall`'s real initializer before using the stub above — mirror the parameters used in `RemoteSessionGatewayTests.swift` (`snapshotRestoresFullTruncatedToolCallContent` builds one with `toolCallId/title/status/content/preview`).

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/ACPTranscriptChangeLogTests 2>&1 | tail -20`
Expected: compile error — `value of type 'ACPTranscript' has no member 'changeLog'`.

- [ ] **Step 3: Implement the transcript hooks**

In `Alas/Sources/ACP/Session/ACPTranscript.swift`:

1. Add the property (near the top, after the `@Published` block):

```swift
    /// Mutation log consumed by remote-web gateways for incremental deltas.
    /// Recording is enabled only while at least one gateway is subscribed.
    let changeLog = ACPTranscriptChangeLog()
```

2. Extend the existing `messages` `didSet`:

```swift
    @Published var messages: [ACPMessage] = [] {
        didSet {
            refreshPlanCaches()
            recordMessagesDiff(old: oldValue)
        }
    }
```

3. Add the diff + streaming hook (new section near the render-window helpers):

```swift
    // MARK: - Remote change tracking

    /// Classify an array mutation for the change log. Index-shifting
    /// operations (shrink, or an identity change at a surviving index —
    /// i.e. a prepend, mid-removal, or wholesale replacement) are
    /// structural; everything else records per-index dirty entries.
    /// Cost is O(count) enum compares, but unchanged elements share
    /// storage (COW) and `StreamingText` compares by identity, so the
    /// scan is cheap — and it only runs while a remote client is
    /// subscribed.
    private func recordMessagesDiff(old: [ACPMessage]) {
        guard changeLog.isTracking else { return }
        guard messages.count >= old.count else {
            changeLog.recordStructural()
            return
        }
        for i in old.indices where old[i] != messages[i] {
            guard old[i].stableIdentityKey == messages[i].stableIdentityKey else {
                changeLog.recordStructural()
                return
            }
            changeLog.record(index: i)
        }
        for i in old.count..<messages.count {
            changeLog.record(index: i)
        }
    }

    /// Streaming chunk appends mutate a `StreamingText` buffer in place —
    /// the array element compares equal (identity equality), so
    /// `messages.didSet` cannot see them. Callers pass the mutated index.
    /// Replaces direct `streamingTick &+= 1` writes.
    func noteStreamingChange(at index: Int) {
        streamingTick &+= 1
        if changeLog.isTracking, messages.indices.contains(index) {
            changeLog.record(index: index)
        }
    }
```

4. In `Alas/Sources/ACP/Session/ACPSession.swift`, replace every `transcript.streamingTick &+= 1` with `transcript.noteStreamingChange(at: i)`. Find them with `grep -n 'streamingTick &+= 1' Alas/Sources/ACP/Session/ACPSession.swift` (five sites, currently near lines 1558, 1572, 1593, 1750, 1803). Each site already has the mutated index in a local named `i` — verify the local's name at each site before substituting. Do NOT touch the `streamingTick` declaration in `ACPTranscript.swift`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/ACPTranscriptChangeLogTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Run the ACP test directory to catch regressions in streaming behavior**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests 2>&1 | tail -30`

(If the full AlasTests run is prohibitively slow here, run at minimum every suite whose name contains `Session`, `Transcript`, or `Streaming`.)
Expected: no new failures.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/ACP/Session/ACPTranscript.swift Alas/Sources/ACP/Session/ACPSession.swift AlasTests/ACP/ACPTranscriptChangeLogTests.swift
git commit -m "feat(acp): record transcript mutations for incremental remote sync"
```

---

### Task 3: Wire protocol — windowed snapshots, true deltas, pages, stopPending

**Files:**
- Modify: `Alas/Sources/Remote/Protocol/RemoteProtocol.swift`
- Modify: `Alas/Sources/Remote/Protocol/RemoteMessageWireJSON.swift` (`RemoteWireMessage` gains `index`)
- Test: `AlasTests/Remote/RemoteProtocolTests.swift` (extend)

**Interfaces:**
- Consumes: nothing new.
- Produces (exact shapes later tasks rely on):
  - `RemoteClientMessage.fetchOlder(sessionId: String, beforeIndex: Int, limit: Int)` — wire type `"fetchOlder"`.
  - `RemoteServerMessage.transcriptSnapshot(sessionId: String, streamingState: String, canDrive: Bool, messages: [RemoteWireMessage], firstIndex: Int, totalCount: Int, epoch: Int, revision: Int)`
  - `RemoteServerMessage.transcriptDelta(sessionId: String, streamingState: String, canDrive: Bool, upserts: [RemoteWireMessage], epoch: Int, revision: Int)`
  - `RemoteServerMessage.transcriptPage(sessionId: String, epoch: Int, firstIndex: Int, messages: [RemoteWireMessage])` — wire type `"transcriptPage"`.
  - `RemoteServerMessage.stopPending(sessionId: String)` — wire type `"stopPending"`.
  - `RemoteWireMessage.index: Int` (required, synthesized Codable).
  - `RemoteClientMessage.isControl: Bool` — true only for `.stop` (used by Task 5; define it here so the protocol file owns classification).

- [ ] **Step 1: Write the failing round-trip tests**

Add to `AlasTests/Remote/RemoteProtocolTests.swift`, following the file's existing encode→decode round-trip idiom (read a couple of existing tests first and match them):

```swift
    @Test func fetchOlderRoundTrips() throws {
        let msg = RemoteClientMessage.fetchOlder(sessionId: "s1", beforeIndex: 120, limit: 90)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(RemoteClientMessage.self, from: data)
        #expect(decoded == msg)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""type":"fetchOlder""#))
    }

    @Test func windowedSnapshotRoundTrips() throws {
        let wire = [RemoteWireMessage(stableId: "m110", kind: "agent", text: "hi", json: nil, index: 110)]
        let msg = RemoteServerMessage.transcriptSnapshot(
            sessionId: "s1", streamingState: "idle", canDrive: true,
            messages: wire, firstIndex: 110, totalCount: 200, epoch: 3, revision: 0)
        let decoded = try JSONDecoder().decode(RemoteServerMessage.self, from: JSONEncoder().encode(msg))
        #expect(decoded == msg)
    }

    @Test func deltaCarriesEpochAndRevision() throws {
        let msg = RemoteServerMessage.transcriptDelta(
            sessionId: "s1", streamingState: "streaming", canDrive: false,
            upserts: [], epoch: 3, revision: 7)
        let decoded = try JSONDecoder().decode(RemoteServerMessage.self, from: JSONEncoder().encode(msg))
        #expect(decoded == msg)
    }

    @Test func transcriptPageRoundTrips() throws {
        let wire = [RemoteWireMessage(stableId: "m20", kind: "user", text: "old", json: nil, index: 20)]
        let msg = RemoteServerMessage.transcriptPage(sessionId: "s1", epoch: 3, firstIndex: 20, messages: wire)
        let decoded = try JSONDecoder().decode(RemoteServerMessage.self, from: JSONEncoder().encode(msg))
        #expect(decoded == msg)
    }

    @Test func stopPendingRoundTrips() throws {
        let msg = RemoteServerMessage.stopPending(sessionId: "s1")
        let decoded = try JSONDecoder().decode(RemoteServerMessage.self, from: JSONEncoder().encode(msg))
        #expect(decoded == msg)
    }

    @Test func onlyStopIsControl() {
        #expect(RemoteClientMessage.stop(sessionId: "s").isControl)
        #expect(!RemoteClientMessage.subscribe(sessionId: "s").isControl)
        #expect(!RemoteClientMessage.takeOver(sessionId: "s").isControl)
        #expect(!RemoteClientMessage.fetchOlder(sessionId: "s", beforeIndex: 0, limit: 1).isControl)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/RemoteProtocolTests 2>&1 | tail -20`
Expected: compile errors (`fetchOlder` not a member, extra arguments to `transcriptSnapshot`, missing `index:`).

- [ ] **Step 3: Implement the protocol changes**

In `RemoteMessageWireJSON.swift`, add the field:

```swift
struct RemoteWireMessage: Codable, Equatable, Sendable {
    let stableId: String
    let kind: String          // "user" | "agent" | "thought" | "toolCall" | "fileEdit" | "plan" | "systemNotice"
    let text: String?
    let json: String?         // JSON string for structured kinds; nil otherwise
    let index: Int            // transcript position; the client orders and windows by this
}
```

In `RemoteProtocol.swift`:

1. `RemoteClientMessage`: add case `fetchOlder(sessionId: String, beforeIndex: Int, limit: Int)`; add `beforeIndex`, `limit` to `CodingKeys`; wire both `init(from:)` (`case "fetchOlder"`) and `encode(to:)`. Add:

```swift
extension RemoteClientMessage {
    /// Control messages bypass the per-connection serial processing chain
    /// (RemoteConnection.dispatchMessage): they are idempotent and must not
    /// queue behind transcript work. Everything else stays strictly ordered
    /// (e.g. takeOver-before-sendPrompt).
    var isControl: Bool {
        if case .stop = self { return true }
        return false
    }
}
```

2. `RemoteServerMessage`: extend `transcriptSnapshot`/`transcriptDelta` with the new associated values, add `transcriptPage` and `stopPending` cases, add `firstIndex`, `totalCount`, `epoch`, `revision` to `CodingKeys`, and wire codable paths for all four. Follow the file's existing hand-rolled Codable style exactly.

3. Fix every non-test construction/pattern-match of the changed cases so the target compiles — they are all in `RemoteSessionGateway.swift` (`sendSnapshot`/`sendDelta`/`toWire`). For this task only, thread placeholder values so behavior is unchanged: snapshot sends the full array with `firstIndex: 0, totalCount: wire.count, epoch: 0, revision: 0`; delta keeps full upserts with `epoch: 0, revision: 0`; `toWire` passes its existing `index` parameter into `RemoteWireMessage(index:)`. Task 4 replaces these placeholders with real logic.

- [ ] **Step 4: Fix existing test pattern-matches and run**

Existing tests pattern-match the old arities (e.g. `case .transcriptSnapshot(let id, _, _, let msgs)` in `RemoteSessionGatewayTests`, `RemoteServerIntegrationTests`, `RemoteProtocolTests`). Update every match/construction mechanically (`grep -rn "transcriptSnapshot\|transcriptDelta" AlasTests/`).

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/RemoteProtocolTests -only-testing:AlasTests/RemoteSessionGatewayTests -only-testing:AlasTests/RemoteServerIntegrationTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Remote/Protocol/ AlasTests/Remote/
git commit -m "feat(remote): wire protocol for windowed snapshots, deltas, pages, stopPending"
```

---

### Task 4: Gateway — tail-window snapshots, incremental deltas, fetchOlder, tool-content cache

**Files:**
- Create: `Alas/Sources/Remote/Gateway/RemoteTranscriptSync.swift`
- Modify: `Alas/Sources/Remote/Gateway/RemoteSessionGateway.swift`
- Test: `AlasTests/Remote/RemoteSessionGatewayTests.swift` (extend + update stale expectations)

**Interfaces:**
- Consumes: `ACPTranscriptChangeLog` (Task 2), protocol shapes (Task 3), `RemoteSessionsProvider.fullToolCallContent(sessionId:toolCallId:)` (existing).
- Produces: per-session, per-connection sync state:

```swift
@MainActor
final class RemoteTranscriptSync {
    static let tailWindow = ACPTranscript.maxVisibleRows        // 90
    static let pageLimitRange = 1...200
    /// Above this many dirty messages, a tail re-snapshot is cheaper than a delta.
    static let dirtyResnapshotThreshold = 200
    static let toolContentCacheLimit = 128

    var sentVersion = 0     // change-log version covered by the last send
    var epoch = 0           // transcript epoch the client knows
    var revision = 0        // per-connection outgoing delta counter
    private var toolContent: [String: String] = [:]            // toolCallId → full content
    private var toolContentOrder: [String] = []                 // FIFO eviction

    func cachedToolContent(_ id: String) -> String? { toolContent[id] }
    func storeToolContent(_ id: String, _ content: String) {
        if toolContent[id] == nil {
            toolContentOrder.append(id)
            if toolContentOrder.count > Self.toolContentCacheLimit {
                toolContent[toolContentOrder.removeFirst()] = nil
            }
        }
        toolContent[id] = content
    }
    func invalidateToolContent(_ id: String) { toolContent[id] = nil }
}
```

- [ ] **Step 1: Write the failing tests**

Add to `AlasTests/Remote/RemoteSessionGatewayTests.swift`. Extend `FakeSessionsProvider` first with a call counter:

```swift
    var fullToolCallContentCallCount = 0
    // in fullToolCallContent(sessionId:toolCallId:): fullToolCallContentCallCount += 1
```

Then the tests (the 250ms sleeps mirror the file's existing `> coalesce window` idiom):

```swift
    private func makeSessionWithUserMessages(_ count: Int) throws -> ACPSession {
        let mgr = try makeManager()
        let s = mgr.createSession(agentId: "claude")
        s.transcript.messages = (0..<count).map {
            .user(id: UUID(), messageId: "u\($0)", text: "msg \($0)", attachments: [])
        }
        return s
    }

    @Test func snapshotOfLongTranscriptIsTailWindowed() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithUserMessages(200)
        provider.sessions["s1"] = s
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        guard case .transcriptSnapshot(_, _, _, let msgs, let first, let total, _, let revision)? = sent.first else {
            Issue.record("expected snapshot, got \(sent)"); return
        }
        #expect(total == 200)
        #expect(first == 200 - RemoteTranscriptSync.tailWindow)
        #expect(msgs.count == RemoteTranscriptSync.tailWindow)
        #expect(msgs.first?.stableId == "m\(first)")
        #expect(msgs.first?.index == first)
        #expect(revision == 0)
    }

    @Test func deltaCarriesOnlyDirtyMessages() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithUserMessages(50)
        provider.sessions["s1"] = s
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        sent.removeAll()
        s.transcript.messages.append(.systemNotice(id: UUID(), text: "done"))
        try await Task.sleep(nanoseconds: 250_000_000)   // > coalesce window
        let delta = sent.compactMap { msg -> [RemoteWireMessage]? in
            if case .transcriptDelta(_, _, _, let u, _, _) = msg { return u }
            return nil
        }.last
        #expect(delta?.count == 1)
        #expect(delta?.first?.index == 50)
        #expect(delta?.first?.kind == "systemNotice")
    }

    @Test func structuralChangeTriggersResyncSnapshotWithBumpedEpoch() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithUserMessages(10)
        provider.sessions["s1"] = s
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        guard case .transcriptSnapshot(_, _, _, _, _, _, let epoch0, _)? = sent.first else {
            Issue.record("expected snapshot"); return
        }
        sent.removeAll()
        s.transcript.messages.removeLast()               // structural
        try await Task.sleep(nanoseconds: 250_000_000)
        let resync = sent.last { if case .transcriptSnapshot = $0 { return true }; return false }
        guard case .transcriptSnapshot(_, _, _, let msgs, _, let total, let epoch1, _)? = resync else {
            Issue.record("expected resync snapshot, got \(sent)"); return
        }
        #expect(epoch1 == epoch0 + 1)
        #expect(total == 9)
        #expect(msgs.count == 9)
    }

    @Test func fetchOlderReturnsClampedPage() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithUserMessages(200)
        provider.sessions["s1"] = s
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        sent.removeAll()
        await gw.handle(.fetchOlder(sessionId: "s1", beforeIndex: 110, limit: 90))
        guard case .transcriptPage(_, _, let first, let msgs)? = sent.last else {
            Issue.record("expected page, got \(sent)"); return
        }
        #expect(first == 20)
        #expect(msgs.count == 90)
        #expect(msgs.first?.index == 20)
        #expect(msgs.last?.index == 109)

        sent.removeAll()
        await gw.handle(.fetchOlder(sessionId: "s1", beforeIndex: 10, limit: 500))   // clamp both ends
        guard case .transcriptPage(_, _, let first2, let msgs2)? = sent.last else {
            Issue.record("expected page, got \(sent)"); return
        }
        #expect(first2 == 0)
        #expect(msgs2.count == 10)
    }

    @Test func fetchOlderBeforeSubscribeIsIgnored() async throws {
        let provider = FakeSessionsProvider()
        provider.sessions["s1"] = try makeSessionWithUserMessages(5)
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.fetchOlder(sessionId: "s1", beforeIndex: 5, limit: 5))
        #expect(sent.isEmpty)
    }

    @Test func truncatedToolContentIsFetchedOnceAcrossSnapshotAndDeltas() async throws {
        let provider = FakeSessionsProvider()
        let fullContent = String(repeating: "abcdef0123456789", count: 400)
        var toolCall = ACPMessage.ToolCall(
            toolCallId: "old", title: "read", status: "completed",
            content: fullContent, preview: "abcdef")
        toolCall.truncateForOffWindow()
        let session = try makeSessionWithAgentText("tail")
        session.transcript.messages = [.toolCall(toolCall), .agent(id: UUID(), StreamingText("tail"))]
        provider.sessions["s1"] = session
        provider.fullToolCallContents["s1|old"] = fullContent
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.subscribe(sessionId: "s1"))
        #expect(provider.fullToolCallContentCallCount == 1)
        // A dirty tick on the OTHER message must not re-fetch tool content.
        session.transcript.messages.append(.systemNotice(id: UUID(), text: "x"))
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(provider.fullToolCallContentCallCount == 1)
    }

    @Test func unsubscribeReleasesChangeTracking() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithUserMessages(3)
        provider.sessions["s1"] = s
        let gw = RemoteSessionGateway(provider: provider) { _ in }
        await gw.handle(.subscribe(sessionId: "s1"))
        #expect(s.transcript.changeLog.isTracking)
        await gw.handle(.unsubscribe(sessionId: "s1"))
        #expect(!s.transcript.changeLog.isTracking)
    }

    @Test func resubscribeDoesNotLeakTrackingRetains() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithUserMessages(3)
        provider.sessions["s1"] = s
        let gw = RemoteSessionGateway(provider: provider) { _ in }
        await gw.handle(.subscribe(sessionId: "s1"))
        await gw.handle(.subscribe(sessionId: "s1"))   // client resync
        await gw.handle(.unsubscribe(sessionId: "s1"))
        #expect(!s.transcript.changeLog.isTracking)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/RemoteSessionGatewayTests 2>&1 | tail -20`
Expected: compile error (`RemoteTranscriptSync` unknown) or assertion failures on the placeholder full-window snapshot.

- [ ] **Step 3: Implement**

Create `Alas/Sources/Remote/Gateway/RemoteTranscriptSync.swift` with the class from the Interfaces block (add a short doc comment: per-connection, per-session sync bookkeeping for incremental transcript delivery).

In `RemoteSessionGateway.swift`:

1. Add state: `private var syncStates: [String: RemoteTranscriptSync] = [:]` and `private var trackedSessions: Set<String> = []`.

2. Tracking lifecycle. In `.subscribe`, BEFORE calling `sendSnapshot`: `beginTracking(id: id, session: session)`. Add helpers:

```swift
    private func beginTracking(id: String, session: ACPSession) {
        guard !trackedSessions.contains(id) else { return }
        trackedSessions.insert(id)
        session.transcript.changeLog.retainTracking()
    }

    private func endTracking(id: String) {
        guard trackedSessions.remove(id) != nil else { return }
        provider.session(for: id)?.transcript.changeLog.releaseTracking()
    }
```

In `.unsubscribe`, call `endTracking(id: id)` and `syncStates[id] = nil` alongside the existing cleanup. In `close()`, iterate `trackedSessions` calling `endTracking`, then clear `syncStates`.

3. Rewrite `sendSnapshot` to a tail window:

```swift
    private func sendSnapshot(id: String, session: ACPSession) async {
        let state = syncState(for: id)
        let log = session.transcript.changeLog
        let count = session.transcript.messages.count
        let first = max(0, count - RemoteTranscriptSync.tailWindow)
        // Capture version/epoch BEFORE the async serialize: anything that
        // mutates during the awaits lands at a higher version and is
        // picked up by the next delta.
        state.epoch = log.epoch
        state.sentVersion = log.latestVersion
        state.revision = 0
        let wire = await wireMessages(id: id, session: session, indices: Array(first..<count))
        send(.transcriptSnapshot(sessionId: id,
                                 streamingState: Self.stateString(session.transcript.streamingState),
                                 canDrive: provider.isWriter(for: id),
                                 messages: wire,
                                 firstIndex: first,
                                 totalCount: count,
                                 epoch: state.epoch,
                                 revision: 0))
        emitPendingPermissionIfAny(id: id, session: session)
        emitPendingQuestionIfAny(id: id, session: session)
        emitPendingElicitationIfAny(id: id, session: session)
    }

    private func syncState(for id: String) -> RemoteTranscriptSync {
        if let s = syncStates[id] { return s }
        let s = RemoteTranscriptSync()
        syncStates[id] = s
        return s
    }
```

4. Rewrite `sendDelta` (replace the "v1 full re-snapshot" comment and body):

```swift
    /// Emits an incremental delta: only messages the change log marked
    /// dirty since the last send. Structural transcript changes (prepend,
    /// removal, wholesale replacement) resync via a fresh tail snapshot.
    private func sendDelta(id: String, session: ACPSession) async {
        guard let state = syncStates[id] else { return }
        let log = session.transcript.changeLog
        switch log.changes(since: state.sentVersion) {
        case .resync:
            await sendSnapshot(id: id, session: session)
            return
        case .none:
            // No transcript content changed — this tick was a state flip
            // (streamingState / pending prompt). Send a content-free delta
            // so the client still tracks state.
            state.revision += 1
            send(.transcriptDelta(sessionId: id,
                                  streamingState: Self.stateString(session.transcript.streamingState),
                                  canDrive: provider.isWriter(for: id),
                                  upserts: [],
                                  epoch: state.epoch,
                                  revision: state.revision))
        case .dirty(let indices):
            guard indices.count <= RemoteTranscriptSync.dirtyResnapshotThreshold else {
                await sendSnapshot(id: id, session: session)
                return
            }
            state.sentVersion = log.latestVersion
            // A dirty tool call's persisted content may have grown past the
            // cached copy — drop it so serialization re-fetches.
            for index in indices where session.transcript.messages.indices.contains(index) {
                if case .toolCall(let tc) = session.transcript.messages[index] {
                    state.invalidateToolContent(tc.toolCallId)
                }
            }
            let wire = await wireMessages(id: id, session: session, indices: indices)
            state.revision += 1
            send(.transcriptDelta(sessionId: id,
                                  streamingState: Self.stateString(session.transcript.streamingState),
                                  canDrive: provider.isWriter(for: id),
                                  upserts: wire,
                                  epoch: state.epoch,
                                  revision: state.revision))
        }
        emitPendingPermissionIfAny(id: id, session: session)
        emitPendingQuestionIfAny(id: id, session: session)
        emitPendingElicitationIfAny(id: id, session: session)
    }
```

5. Generalize `wireMessages` to serialize arbitrary indices with the cache:

```swift
    private func wireMessages(id: String, session: ACPSession, indices: [Int]) async -> [RemoteWireMessage] {
        var wire: [RemoteWireMessage] = []
        wire.reserveCapacity(indices.count)
        for index in indices {
            // Re-check across awaits: a structural mutation mid-serialize can
            // shrink the array; the epoch bump will resync the client.
            guard session.transcript.messages.indices.contains(index) else { continue }
            let message = session.transcript.messages[index]
            wire.append(Self.toWire(
                message,
                index: index,
                fullToolCallContent: await cachedFullToolCallContent(sessionId: id, message: message)))
        }
        return wire
    }

    private func cachedFullToolCallContent(sessionId: String, message: ACPMessage) async -> String? {
        guard case .toolCall(let toolCall) = message, toolCall.isContentTruncated else { return nil }
        let state = syncState(for: sessionId)
        if let cached = state.cachedToolContent(toolCall.toolCallId) { return cached }
        guard let full = await provider.fullToolCallContent(sessionId: sessionId, toolCallId: toolCall.toolCallId)
        else { return nil }
        state.storeToolContent(toolCall.toolCallId, full)
        return full
    }
```

Delete the old `fullToolCallContentIfNeeded`.

6. Add the `fetchOlder` handler in `handle(_:)`:

```swift
        case .fetchOlder(let id, let beforeIndex, let limit):
            // Ignore pages requested before a snapshot established sync state.
            guard let session = provider.session(for: id), syncStates[id] != nil else { return }
            let clamped = min(max(limit, RemoteTranscriptSync.pageLimitRange.lowerBound),
                              RemoteTranscriptSync.pageLimitRange.upperBound)
            let count = session.transcript.messages.count
            let hi = min(max(beforeIndex, 0), count)
            let lo = max(0, hi - clamped)
            let wire = await wireMessages(id: id, session: session, indices: Array(lo..<hi))
            // Stamp with the CURRENT epoch: if it moved past the client's,
            // the client drops the page and the pending resync wins.
            send(.transcriptPage(sessionId: id,
                                 epoch: session.transcript.changeLog.epoch,
                                 firstIndex: lo,
                                 messages: wire))
```

7. Update `toWire`'s doc comment: positional ids stay (`"m\(index)"`) — note they remain valid because every index-shifting mutation is structural and forces a tail re-snapshot under a new epoch. Set `index: index` in every `RemoteWireMessage` init inside `toWire`.

8. Update the class doc comment (lines 4–11): it no longer "re-snapshots on change"; describe change-log consumption + tail-window snapshots.

- [ ] **Step 4: Run gateway tests; update stale expectations**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/RemoteSessionGatewayTests 2>&1 | tail -40`

Some pre-existing tests assert full-transcript deltas or snapshot shapes; update them to the new semantics (they should still pass conceptually — short transcripts fit entirely inside the tail window, so most assertions hold). Iterate until green.

- [ ] **Step 5: Run the remote suites**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/RemoteSessionGatewayTests -only-testing:AlasTests/RemoteServerIntegrationTests -only-testing:AlasTests/RemoteAppStateAccessTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Remote/Gateway/ AlasTests/Remote/RemoteSessionGatewayTests.swift Alas.xcodeproj
git commit -m "feat(remote): incremental transcript deltas with windowed snapshots and paging"
```

---

### Task 5: Fast-lane stop — dispatch bypass, lease bypass, stopPending ack

**Files:**
- Modify: `Alas/Sources/Remote/Server/RemoteConnection.swift` (control-class dispatch)
- Modify: `Alas/Sources/Remote/Gateway/RemoteSessionGateway.swift` (`.stop` case)
- Modify: `Alas/Sources/ACP/Session/ACPSessionManager.swift` (add `interruptBypassingLease`)
- Modify: `Alas/Sources/ACP/Session/ACPSessionRunner.swift` (`userCancel(confirmingLease:)`)
- Modify: `Alas/Sources/App/AppState.swift` (`stop(for:)` routes to the bypass)
- Test: `AlasTests/Remote/RemoteSessionGatewayTests.swift`, `AlasTests/Remote/RemoteServerIntegrationTests.swift`

**Interfaces:**
- Consumes: `RemoteClientMessage.isControl` (Task 3), `RemoteServerMessage.stopPending` (Task 3).
- Produces:
  - `ACPSessionManager.interruptBypassingLease(for id: ACPSession.ID) async`
  - `ACPSessionRunner.userCancel(confirmingLease: Bool = true) async` (existing callers unchanged)

- [ ] **Step 1: Write the failing tests**

Gateway-level (in `RemoteSessionGatewayTests.swift`):

```swift
    @Test func stopWorksWithoutWriterLeaseAndAcksImmediately() async throws {
        let provider = FakeSessionsProvider()
        provider.sessions["s1"] = try makeSessionWithAgentText("hi")
        // NOTE: provider.writers is intentionally empty — not the writer.
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.stop(sessionId: "s1"))
        #expect(provider.stopped == ["s1"])
        #expect(sent.first == .stopPending(sessionId: "s1"))
    }
```

Integration-level (in `RemoteServerIntegrationTests.swift`, using the existing `startServer(pairing:provider:)` + pair + WS helpers — copy the connection boilerplate from `pairThenWebSocketSubscribeReceivesSnapshot`):

```swift
    @Test func stopBypassesBlockedOrderedQueue() async throws {
        let provider = FakeSessionsProvider()
        let mgr = try makeManager()
        let s = mgr.createSession(agentId: "claude")
        provider.sessions[s.id] = s
        provider.pauseSessionSummaries = true            // blocks the ordered chain
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let (server, port) = try await startServer(pairing: pairing, provider: provider)
        defer { server.stop() }
        // ... pair + open WS exactly as pairThenWebSocketSubscribeReceivesSnapshot ...
        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.listSessions)))   // parks the chain
        try await task.send(.data(JSONEncoder().encode(RemoteClientMessage.stop(sessionId: s.id))))
        // stop must land while listSessions is still parked on its continuation.
        for _ in 0..<100 where provider.stopped.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(provider.stopped == [s.id])
        provider.resumeSessionSummaries()
        task.cancel(with: .goingAway, reason: nil)
    }
```

(Adapt names/boilerplate to the file's existing helpers; the assertion that matters is `provider.stopped` becoming non-empty while `pauseSessionSummaries` is still holding the ordered chain.)

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/RemoteSessionGatewayTests -only-testing:AlasTests/RemoteServerIntegrationTests 2>&1 | tail -20`
Expected: `stopWorksWithoutWriterLease...` fails (`provider.stopped == []` — writer guard rejects), `stopBypassesBlockedOrderedQueue` times out.

- [ ] **Step 3: Implement**

1. `RemoteConnection.dispatchMessage` — control messages skip the chain:

```swift
    private func dispatchMessage(_ payload: Data) {
        guard let msg = try? JSONDecoder().decode(RemoteClientMessage.self, from: payload),
              let gateway else { return }
        // Control messages (stop) are idempotent and latency-critical: run
        // them immediately instead of queueing behind transcript work.
        // Everything else keeps strict arrival order (takeOver before
        // sendPrompt, etc.).
        if msg.isControl {
            Task { @MainActor in await gateway.handle(msg) }
            return
        }
        let previous = processingTail
        processingTail = Task { @MainActor in
            await previous?.value
            await gateway.handle(msg)
        }
    }
```

2. Gateway `.stop` — drop the writer guard, ack first:

```swift
        case .stop(let id):
            // Emergency brake: any authenticated subscriber may cancel the
            // running turn; no writer lease required. Ack immediately so the
            // client flips to "stopping" before the ACP round-trip completes.
            send(.stopPending(sessionId: id))
            await provider.stop(for: id)
```

3. `ACPSessionRunner.userCancel` — parameterize the lease confirmation. Change the signature to `func userCancel(confirmingLease: Bool = true) async` and wrap the existing guard:

```swift
        if confirmingLease {
            // A former writer that lost the lease must not send a cancel RPC
            // ... (keep existing comment)
            guard await hasConfirmedLeaseForSideEffect() else { return }
        }
```

4. `ACPSessionManager` — add next to `interrupt(for:)`:

```swift
    /// Remote-web emergency brake: cancel this instance's in-flight turn
    /// WITHOUT confirming the writer lease. `session/cancel` is idempotent
    /// and only reaches this instance's own adapter — if another instance
    /// took the lease and drives the session, our runner has no active
    /// prompt and the cancel is a harmless no-op there.
    func interruptBypassingLease(for id: ACPSession.ID) async {
        guard let runner = runners[id] else { return }
        await runner.userCancel(confirmingLease: false)
    }
```

5. `AppState.stop(for:)` (RemoteSessionsProvider extension, ~line 4766): call `mgr.interruptBypassingLease(for: id)` instead of `mgr.interrupt(for: id)`.

6. `app.js` stop handler loses `ensureWriter()` in Task 6 (client side) — do not touch JS here.

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/RemoteSessionGatewayTests -only-testing:AlasTests/RemoteServerIntegrationTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Remote/ Alas/Sources/ACP/Session/ACPSessionManager.swift Alas/Sources/ACP/Session/ACPSessionRunner.swift Alas/Sources/App/AppState.swift AlasTests/Remote/
git commit -m "feat(remote): fast-lane stop past the ordered queue and writer lease"
```

---

### Task 6: Move outbound JSON encoding off the MainActor

**Files:**
- Modify: `Alas/Sources/Remote/Server/RemoteConnection.swift` (`sendServerMessage`)

**Interfaces:**
- Consumes: `RemoteServerMessage: Sendable` (already true).
- Produces: no API change; encoding happens on the connection's serial `queue` instead of the caller's (MainActor) context.

- [ ] **Step 1: Implement (no new test — covered by every existing wire test)**

```swift
    private func sendServerMessage(_ msg: RemoteServerMessage) {
        // Encode on the connection's serial queue, not the caller's
        // MainActor context — outbound serialization must never compete
        // with ACP state mutation for main-thread time.
        onQueue { [weak self] in
            guard let self, let data = try? JSONEncoder().encode(msg) else { return }
            self.send(WebSocketFrame.encode(opcode: .text, payload: data)) {}
        }
    }
```

- [ ] **Step 2: Build and run the remote suites**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/RemoteServerIntegrationTests -only-testing:AlasTests/RemoteSessionGatewayTests 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Alas/Sources/Remote/Server/RemoteConnection.swift
git commit -m "perf(remote): encode outbound frames off the main actor"
```

---

### Task 7: Web client — keyed rendering, scroll backfill, leaseless stop

**Files:**
- Modify: `Alas/Resources/RemoteWeb/app.js`
- Modify: `Alas/Resources/RemoteWeb/index.html` (bump `app.js?v=57` → `?v=58`; `style.css?v=36` → `?v=37` if CSS changes)
- Modify: `Alas/Resources/RemoteWeb/style.css` (loading-row + stopping-state styles)
- Modify: `Alas/Resources/RemoteWeb/sw.js` (bump `CACHE_NAME` to `alas-remote-shell-v36`; sync `SHELL_ASSETS` versions)
- Test: `AlasTests/Remote/RemoteWebAssetTests.swift` (extend)

**Interfaces:**
- Consumes: wire messages from Task 3 (`transcriptSnapshot` with `firstIndex`/`totalCount`/`epoch`/`revision`, `transcriptDelta` with `upserts`/`epoch`/`revision`, `transcriptPage`, `stopPending`) and `fetchOlder` client message.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Write the failing asset tests**

Add to `AlasTests/Remote/RemoteWebAssetTests.swift` (follow the file's `asset(_:)` string-inspection idiom):

```swift
    @Test func remoteWebSpeaksIncrementalTranscriptProtocol() throws {
        let js = try asset("app.js")
        #expect(js.contains(#"case "transcriptPage""#))
        #expect(js.contains(#"case "stopPending""#))
        #expect(js.contains(#"type: "fetchOlder""#))
    }

    @Test func remoteWebStopDoesNotTakeOverFirst() throws {
        let js = try asset("app.js")
        let stopHandler = try #require(js.range(of: #"$("stop").onclick"#).map { js[$0.lowerBound...].prefix(220) })
        #expect(!stopHandler.contains("ensureWriter"))
    }

    @Test func incrementalTranscriptBustsServiceWorkerAssetCache() throws {
        let sw = try asset("sw.js")
        let html = try asset("index.html")
        #expect(sw.contains("alas-remote-shell-v36"))
        #expect(sw.contains("/app.js?v=58"))
        #expect(html.contains("app.js?v=58"))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/RemoteWebAssetTests 2>&1 | tail -10`
Expected: the three new tests FAIL.

- [ ] **Step 3: Implement app.js**

All changes in `Alas/Resources/RemoteWeb/app.js`:

1. **State** (top of file, replacing `messages = new Map()` usage semantics):

```js
let ws, currentSession = null, messages = new Map();   // stableId → wire message
let messageNodes = new Map();                          // stableId → DOM node
let transcriptMeta = null;   // {epoch, revision, firstIndex, totalCount} for the open session
let olderFetchInFlight = false;
let stopPending = false;
```

Reset all of these in `openSession` and `showSessions` (where `messages = new Map()` is reset today).

2. **handle() cases** — replace the two transcript cases and add two:

```js
    case "transcriptSnapshot": applySnapshot(msg); break;
    case "transcriptDelta": applyDelta(msg); break;
    case "transcriptPage": applyPage(msg); break;
    case "stopPending": if (msg.sessionId === currentSession) markStopping(true); break;
```

3. **Snapshot / delta / page application:**

```js
function applySnapshot(msg) {
  if (msg.sessionId !== currentSession) return;
  canDrive = msg.canDrive; canDriveKnown = true;
  transcriptMeta = { epoch: msg.epoch, revision: msg.revision, firstIndex: msg.firstIndex, totalCount: msg.totalCount };
  olderFetchInFlight = false;
  const box = $("messages");
  const open = new Set();
  box.querySelectorAll(".m-collapsible.is-open").forEach(d => { if (d.dataset.sid) open.add(d.dataset.sid); });
  box.innerHTML = "";
  messages = new Map(); messageNodes = new Map();
  msg.messages.forEach(m => insertMessage(m, open));
  requestAnimationFrame(() => { box.scrollTop = box.scrollHeight; });
  syncStreamingState(msg.streamingState);
}

function applyDelta(msg) {
  if (msg.sessionId !== currentSession || !transcriptMeta) return;
  // Epoch moved or a delta was missed → the server's view diverged; resync.
  if (msg.epoch !== transcriptMeta.epoch || msg.revision !== transcriptMeta.revision + 1) {
    resubscribe();
    return;
  }
  transcriptMeta.revision = msg.revision;
  canDrive = msg.canDrive; canDriveKnown = true;
  const box = $("messages");
  const atBottom = box.scrollTop + box.clientHeight >= box.scrollHeight - 120;
  msg.upserts.forEach(m => upsertMessage(m));
  if (atBottom) requestAnimationFrame(() => { box.scrollTop = box.scrollHeight; });
  syncStreamingState(msg.streamingState);
}

function applyPage(msg) {
  olderFetchInFlight = false;
  removeLoadingRow();
  if (msg.sessionId !== currentSession || !transcriptMeta) return;
  if (msg.epoch !== transcriptMeta.epoch) return;   // stale page; a resync snapshot is coming
  const box = $("messages");
  const prevHeight = box.scrollHeight;
  // Pages arrive oldest-first; insert in reverse so each lands at the front.
  [...msg.messages].reverse().forEach(m => { if (!messages.has(m.stableId)) insertMessage(m, null); });
  transcriptMeta.firstIndex = Math.min(transcriptMeta.firstIndex, msg.firstIndex);
  box.scrollTop += box.scrollHeight - prevHeight;   // keep the viewport anchored
}

function resubscribe() {
  if (currentSession) send({ type: "subscribe", sessionId: currentSession });
}
```

4. **Keyed insert/upsert** (replaces `renderMessages`; delete `renderMessages`):

```js
// Insert a message node at its index-ordered DOM position. Nodes carry
// dataset.index; the common case (append at the tail) is O(1).
function insertMessage(m, open) {
  const box = $("messages");
  const node = renderMessage(m, m.stableId, open);
  node.dataset.sid = m.stableId;
  node.dataset.index = m.index;
  messages.set(m.stableId, m);
  messageNodes.set(m.stableId, node);
  let anchor = box.lastElementChild;
  while (anchor && Number(anchor.dataset.index) > m.index) anchor = anchor.previousElementSibling;
  if (anchor) anchor.after(node); else box.prepend(node);
}

function upsertMessage(m) {
  const existing = messageNodes.get(m.stableId);
  if (existing) {
    const wasOpen = existing.classList.contains("is-open") ? new Set([m.stableId]) : null;
    const node = renderMessage(m, m.stableId, wasOpen);
    node.dataset.sid = m.stableId;
    node.dataset.index = m.index;
    existing.replaceWith(node);
    messages.set(m.stableId, m);
    messageNodes.set(m.stableId, node);
    return;
  }
  // A message older than the loaded window (rare late mutation): skip —
  // it will arrive if the user backfills that far.
  if (transcriptMeta && m.index < transcriptMeta.firstIndex) return;
  insertMessage(m, null);
}
```

Note `renderMessage` already sets `dataset.sid` only for collapsibles — setting it for every node here is fine and needed for the open-state scan in `applySnapshot`.

5. **Scroll backfill** (register once at startup, next to the other listeners):

```js
const LOAD_OLDER_THRESHOLD_PX = 600;
const OLDER_PAGE_SIZE = 90;

listen("messages", "scroll", () => {
  if (!currentSession || !transcriptMeta || olderFetchInFlight) return;
  if (transcriptMeta.firstIndex <= 0) return;
  if ($("messages").scrollTop > LOAD_OLDER_THRESHOLD_PX) return;
  olderFetchInFlight = true;
  showLoadingRow();
  send({ type: "fetchOlder", sessionId: currentSession, beforeIndex: transcriptMeta.firstIndex, limit: OLDER_PAGE_SIZE });
});

function showLoadingRow() {
  if ($("messages").querySelector(".load-older")) return;
  const row = el("div", "load-older", "Loading earlier messages…");
  row.dataset.index = "-1";
  $("messages").prepend(row);
}
function removeLoadingRow() {
  const row = $("messages").querySelector(".load-older");
  if (row) row.remove();
}
```

Add `.load-older` styling to `style.css` (small, centered, muted — match `.create-empty`'s look).

6. **Stop UX** — replace the stop handler and hook state resets:

```js
$("stop").onclick = () => {
  if (!currentSession) return;
  send({ type: "stop", sessionId: currentSession });   // no ensureWriter: stop is leaseless
  markStopping(true);
};

let stopFallbackTimer = null;
function markStopping(on) {
  stopPending = on;
  const btn = $("stop");
  btn.disabled = on;
  btn.classList.toggle("is-stopping", on);
  if (stopFallbackTimer) { clearTimeout(stopFallbackTimer); stopFallbackTimer = null; }
  // If the cancel RPC fails and the turn keeps streaming, re-enable Stop so
  // the user can retry instead of being stranded on a dead button.
  if (on) stopFallbackTimer = setTimeout(() => markStopping(false), 15000);
}

function syncStreamingState(streamingState) {
  if (streamingState === "idle" && stopPending) markStopping(false);
  renderDriveBar(streamingState);
}
```

Add `#stop.is-stopping { opacity: 0.5; }` (or similar) to `style.css`. Reset `markStopping(false)` in `openSession`/`showSessions`.

7. **Bump versions:** `index.html` `app.js?v=58` (+ `style.css?v=37`); `sw.js` `CACHE_NAME = "alas-remote-shell-v36"` and matching `SHELL_ASSETS` entries.

- [ ] **Step 4: Run asset tests**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/RemoteWebAssetTests 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Manual browser verification**

Launch Alas, enable Remote, open the web client on a long ACP session (or seed one). Verify: (1) the transcript paints the tail instantly; (2) scrolling to the top loads older pages and preserves scroll position; (3) streaming updates only mutate the tail; (4) pressing Stop during a turn dims the button immediately and the turn cancels promptly; (5) expanded tool cards stay expanded across streaming ticks.

- [ ] **Step 6: Commit**

```bash
git add Alas/Resources/RemoteWeb/ AlasTests/Remote/RemoteWebAssetTests.swift
git commit -m "feat(remote-web): keyed incremental rendering, scroll backfill, instant stop"
```

---

### Task 8: Full verification

- [ ] **Step 1: Regenerate + full build + full test suite**

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`. Fix any stragglers (most likely: remaining pattern-matches of the widened `transcriptSnapshot`/`transcriptDelta` cases somewhere outside the remote tests — `grep -rn "transcriptSnapshot(\|transcriptDelta(" Alas/ AlasTests/`).

- [ ] **Step 2: Commit any remaining fixes; confirm clean tree**

```bash
git status
```
