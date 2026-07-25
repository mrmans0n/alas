# ACP Session Fork Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-message ACP chat forking that uses native same-agent `session/fork` at the remote head and durable conversation transfer for earlier checkpoints or different providers.

**Architecture:** A pure fork-domain layer resolves a stable message boundary against the fully persisted source transcript and chooses a native candidate or transcript transfer. `ACPSessionStore` atomically creates the local target plus copied conversation rows and fork metadata; `ACPSessionManager.attach` then either performs native fork on the target's own connection or creates a normal remote session whose first real prompt privately carries the inherited context. The existing message `…` menu supplies the target agent, while a persisted fork divider presents lineage and links back to the source chat.

**Tech Stack:** Swift 5.9+, SwiftUI and AppKit on macOS, ACP JSON-RPC, SQLite persistence, Swift Testing, XcodeGen.

**Design:** `docs/superpowers/specs/2026-07-24-acp-session-fork-design.md`

## Global Constraints

- Keep code, comments, logs, and UI strings in English.
- Tests use Swift Testing (`import Testing`), not XCTest.
- Prefix every shell command with `rtk`.
- Do not add agent attribution to commits, PR bodies, docs, comments, or code.
- A fork is a conversation branch in the source worktree's current filesystem state; it does not create or rewind a Git worktree.
- Eligible boundaries are completed user messages and completed agent responses only.
- Copy only user and agent text; omit attachments, thoughts, tool calls, tool output, file edits, plans, system notices, permissions, questions, queued prompts, and drafts.
- Use native ACP fork only for the same agent at the exact persisted remote head with a remote source ID and advertised fork capability.
- Use transcript transfer for earlier checkpoints, cross-provider targets, known-missing capabilities, and non-auth native-fork errors. When runtime capability state is not yet known, persist a native candidate and decide after target initialization.
- Open the local target tab after the atomic local snapshot commit; do not generate an agent response until the user sends a real prompt.
- Keep transcript-transfer context private and pending until the first real prompt succeeds.
- The source transcript and persisted source rows must remain unchanged.
- Run `xcodegen`, `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build`, and `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test` before completion.

---

## File Structure

- Create `Alas/Sources/ACP/Session/ACPSessionFork.swift`
  - Own fork boundary, target, phase, mechanism, persisted metadata, policy, snapshot resolution, and copied-message encoding.
- Create `Alas/Sources/ACP/UI/ACPSessionForkDivider.swift`
  - Render persisted lineage, transcript-transfer limitations, and source navigation.
- Create `AlasTests/ACP/Session/ACPSessionForkPolicyTests.swift`
  - Cover mechanism selection, boundary resolution, filtering, payload rewriting, and mismatch failure.
- Create `AlasTests/ACP/Session/ACPSessionForkPersistenceTests.swift`
  - Cover schema migration, atomic target creation, finalization, pending-context clearing, and hydration.
- Create `AlasTests/ACP/Session/ACPSessionForkManagerTests.swift`
  - Cover full-backfill boundary creation, source immutability, in-memory materialization, and restart state.
- Create `AlasTests/ACP/Session/ACPSessionForkRunnerTests.swift`
  - Cover one-time private context injection and retry behavior.
- Create `AlasTests/ACP/Session/ACPSessionForkAttachTests.swift`
  - Cover native fork success, broker operation keys, graceful fallback, and relaunch reconciliation.
- Create `AlasTests/ACP/UI/ACPSessionForkPresentationTests.swift`
  - Cover target ordering, menu eligibility, divider copy, and source-link policy.
- Modify `Alas/Sources/ACP/Protocol/ACPMessages.swift`
  - Add the stable `session/close` parameter used for best-effort orphan cleanup.
- Modify `Alas/Sources/ACP/Protocol/ACPConnection.swift`
  - Make fork responses durable, accept a broker operation key, and add best-effort session close.
- Modify `Alas/Sources/ACP/Session/ACPSessionStore.swift`
  - Add schema v15 and transactional fork CRUD.
- Modify `Alas/Sources/ACP/Session/ACPSessionPersistence.swift`
  - Expose actor-isolated fork operations.
- Modify `Alas/Sources/ACP/Session/ACPSessionHydrator.swift`
  - Include fork metadata in hydration and mirror snapshots.
- Modify `Alas/Sources/ACP/Session/ACPSession.swift`
  - Retain runtime session capabilities, hydrated fork metadata, and message eligibility.
- Modify `Alas/Sources/ACP/Session/ACPTranscriptMarkdown.swift`
  - Serialize the inherited prefix into the exact private background-context prompt.
- Modify `Alas/Sources/ACP/Session/ACPSessionRunner.swift`
  - Prepend pending fork context to the first real wire prompt and clear it after success.
- Modify `Alas/Sources/ACP/Session/ACPSessionManager.swift`
  - Create local forks, resolve durable boundaries, negotiate native fork inside attach, and finalize fallback.
- Modify `Alas/Sources/ACP/UI/ACPMessageGutter.swift`
  - Add the native target-agent submenu.
- Modify `Alas/Sources/ACP/UI/ACPMessageList.swift`
  - Pass stable fork boundaries into row actions and insert the persisted divider.
- Modify `Alas/Sources/ACP/UI/ACPTabView.swift`
  - Supply targets/callbacks and route source navigation.
- Modify `Alas/Sources/App/AppState.swift`
  - Order enabled ACP targets, create/focus fork tabs, schedule attach, and present creation errors.

---

### Task 1: Fork Domain, Mechanism Policy, and Durable Snapshot

**Files:**
- Create: `Alas/Sources/ACP/Session/ACPSessionFork.swift`
- Create: `AlasTests/ACP/Session/ACPSessionForkPolicyTests.swift`

**Interfaces:**
- Consumes: `ACPMessage`, `ACPMessageWire.decode(kind:payload:)`, `ACPStoredMessage`, and `ACPInitializeResult.ACPAgentSessionCapabilities`.
- Produces: `ACPForkMessageBoundary`, `ACPSessionForkTarget`, `ACPSessionForkCreationPhase`, `ACPSessionForkMechanism`, `ACPSessionForkRecord`, `ACPSessionForkCandidatePolicy.candidate(...)`, `ACPSessionForkSnapshotResolver.resolve(...)`, and `ACPSessionForkSnapshot.copiedMessages(targetSessionID:createdAt:)`.

- [ ] **Step 1: Write failing policy and snapshot tests**

Create `AlasTests/ACP/Session/ACPSessionForkPolicyTests.swift` with:

```swift
import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP session fork policy")
struct ACPSessionForkPolicyTests {
    @Test("native candidate requires same agent, remote head, id, and non-negative capability knowledge")
    func nativeCandidateRequirements() {
        #expect(ACPSessionForkCandidatePolicy.candidate(
            sourceAgentID: "claude",
            targetAgentID: "claude",
            boundaryIsRemoteHead: true,
            sourceRemoteSessionID: "remote-1",
            forkCapability: true
        ) == .native)
        #expect(ACPSessionForkCandidatePolicy.candidate(
            sourceAgentID: "claude",
            targetAgentID: "codex",
            boundaryIsRemoteHead: true,
            sourceRemoteSessionID: "remote-1",
            forkCapability: true
        ) == .transcript)
        #expect(ACPSessionForkCandidatePolicy.candidate(
            sourceAgentID: "claude",
            targetAgentID: "claude",
            boundaryIsRemoteHead: false,
            sourceRemoteSessionID: "remote-1",
            forkCapability: true
        ) == .transcript)
        #expect(ACPSessionForkCandidatePolicy.candidate(
            sourceAgentID: "claude",
            targetAgentID: "claude",
            boundaryIsRemoteHead: true,
            sourceRemoteSessionID: nil,
            forkCapability: true
        ) == .transcript)
        #expect(ACPSessionForkCandidatePolicy.candidate(
            sourceAgentID: "claude",
            targetAgentID: "claude",
            boundaryIsRemoteHead: true,
            sourceRemoteSessionID: "remote-1",
            forkCapability: nil
        ) == .native)
    }

    @Test("snapshot is inclusive and conversation-only")
    func conversationOnlySnapshot() throws {
        let user: ACPMessage = .user(
            id: UUID(), messageId: "u1", text: "Question",
            attachments: [.init(uri: "file:///tmp/image.png", name: "image.png", mimeType: "image/png")]
        )
        let tool: ACPMessage = .toolCall(.init(
            toolCallId: "tc1", title: "Read", status: "completed",
            content: "secret tool output", locations: []
        ))
        let agent: ACPMessage = .agent(
            id: UUID(), messageId: "a1", StreamingText("Answer")
        )
        let stored = try [user, tool, agent].enumerated().map { index, message in
            ACPStoredMessage(
                id: "source-\(index)",
                sessionId: "source",
                kind: message.kind,
                seq: Int64(index),
                payload: try ACPMessageCodec.encode(message),
                createdAt: Int64(index)
            )
        }

        let snapshot = try ACPSessionForkSnapshotResolver.resolve(
            boundary: .init(stableID: agent.stableId, kind: .agent),
            liveMessages: [user, tool, agent],
            storedMessages: stored
        )

        #expect(snapshot.sourceBoundarySequence == 2)
        #expect(snapshot.messages == [
            .init(role: .user, text: "Question"),
            .init(role: .agent, text: "Answer")
        ])
        let copied = try snapshot.copiedMessages(targetSessionID: "target", createdAt: 10)
        #expect(copied.map(\.kind) == ["user", "agent"])
        #expect(copied.map(\.seq) == [0, 1])
        let copiedUser = try ACPMessageWire.decode(kind: copied[0].kind, payload: copied[0].payload)
        guard case .user(_, _, let attachments, let delegatedSource) = copiedUser else {
            Issue.record("Expected copied user message")
            return
        }
        #expect(attachments.isEmpty)
        #expect(delegatedSource == nil)
    }

    @Test("snapshot rejects a stale or mismatched boundary")
    func staleBoundaryFails() throws {
        let message: ACPMessage = .user(id: UUID(), text: "live", attachments: [])
        let storedMessage: ACPMessage = .user(id: UUID(), text: "different", attachments: [])
        let stored = ACPStoredMessage(
            id: "m0", sessionId: "source", kind: "user", seq: 0,
            payload: try ACPMessageCodec.encode(storedMessage), createdAt: 0
        )

        #expect(throws: ACPSessionForkSnapshotError.self) {
            _ = try ACPSessionForkSnapshotResolver.resolve(
                boundary: .init(stableID: message.stableId, kind: .user),
                liveMessages: [message],
                storedMessages: [stored]
            )
        }
    }
}
```

- [ ] **Step 2: Run the focused tests and verify the missing-type failure**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPSessionForkPolicyTests test
```

Expected: FAIL at compile time because the fork-domain types do not exist.

- [ ] **Step 3: Implement the fork domain and snapshot resolver**

Create `Alas/Sources/ACP/Session/ACPSessionFork.swift` with these public-to-module declarations and implementations:

```swift
import Foundation

struct ACPForkMessageBoundary: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable { case user, agent }
    let stableID: String
    let kind: Kind
}

struct ACPSessionForkTarget: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let isSameAgent: Bool
}

enum ACPSessionForkCreationPhase: String, Codable, Equatable, Sendable {
    case negotiatingNative
    case ready
}

enum ACPSessionForkMechanism: String, Codable, Equatable, Sendable {
    case nativeACP
    case transcriptTransfer
}

struct ACPSessionForkRecord: Equatable, Sendable {
    let targetSessionID: String
    let sourceSessionID: String
    let sourceAgentID: String
    let sourceBoundarySequence: Int64
    let inheritedMessageCount: Int
    var phase: ACPSessionForkCreationPhase
    var mechanism: ACPSessionForkMechanism?
    var contextDeliveryPending: Bool
}

enum ACPSessionForkCandidate: Equatable { case native, transcript }

enum ACPSessionForkCandidatePolicy {
    static func candidate(
        sourceAgentID: String,
        targetAgentID: String,
        boundaryIsRemoteHead: Bool,
        sourceRemoteSessionID: String?,
        forkCapability: Bool?
    ) -> ACPSessionForkCandidate {
        guard sourceAgentID == targetAgentID,
              boundaryIsRemoteHead,
              sourceRemoteSessionID?.isEmpty == false,
              forkCapability != false
        else { return .transcript }
        return .native
    }
}

struct ACPSessionForkConversationMessage: Equatable, Sendable {
    enum Role: String, Equatable, Sendable { case user, agent }
    let role: Role
    let text: String
}

struct ACPSessionForkSnapshot: Equatable, Sendable {
    let sourceBoundarySequence: Int64
    let messages: [ACPSessionForkConversationMessage]

    func copiedMessages(targetSessionID: String, createdAt: Int64) throws -> [ACPStoredMessage] {
        try messages.enumerated().map { index, message in
            let payload: Data
            let kind: String
            switch message.role {
            case .user:
                kind = "user"
                payload = try JSONEncoder().encode(CopiedUserPayload(
                    messageId: nil, text: message.text, attachments: [], delegatedSource: nil
                ))
            case .agent:
                kind = "agent"
                payload = try JSONEncoder().encode(CopiedTextPayload(messageId: nil, text: message.text))
            }
            return ACPStoredMessage(
                id: "msg-\(targetSessionID)-\(index)",
                sessionId: targetSessionID,
                kind: kind,
                seq: Int64(index),
                payload: payload,
                createdAt: createdAt
            )
        }
    }
}

enum ACPSessionForkSnapshotError: Error, Equatable {
    case boundaryNotFound
    case transcriptMismatch
}

enum ACPSessionForkSnapshotResolver {
    @MainActor
    static func resolve(
        boundary: ACPForkMessageBoundary,
        liveMessages: [ACPMessage],
        storedMessages: [ACPStoredMessage]
    ) throws -> ACPSessionForkSnapshot {
        guard let boundaryIndex = liveMessages.firstIndex(where: { $0.stableId == boundary.stableID }),
              storedMessages.count == liveMessages.count
        else { throw ACPSessionForkSnapshotError.boundaryNotFound }

        let decoded = try storedMessages.map {
            try ACPMessageWire.decode(kind: $0.kind, payload: $0.payload)
        }
        for index in 0...boundaryIndex {
            guard matches(liveMessages[index], decoded[index]) else {
                throw ACPSessionForkSnapshotError.transcriptMismatch
            }
        }

        let conversation = decoded[0...boundaryIndex].compactMap { wire -> ACPSessionForkConversationMessage? in
            switch wire {
            case .user(_, let text, _, _):
                return text.isEmpty ? nil : .init(role: .user, text: text)
            case .agent(_, let text):
                return text.isEmpty ? nil : .init(role: .agent, text: text)
            default:
                return nil
            }
        }
        return .init(
            sourceBoundarySequence: storedMessages[boundaryIndex].seq,
            messages: conversation
        )
    }

    @MainActor
    private static func matches(_ live: ACPMessage, _ stored: ACPMessageWire) -> Bool {
        switch (live, stored) {
        case let (.user(_, liveID, liveText, _, _), .user(storedID, storedText, _, _)):
            return liveID == storedID && liveText == storedText
        case let (.agent(_, liveID, liveText), .agent(storedID, storedText)):
            return liveID == storedID && liveText.value == storedText
        case let (.thought(_, liveID, liveText), .thought(storedID, storedText)):
            return liveID == storedID && liveText.value == storedText
        case let (.toolCall(liveCall), .toolCall(storedCall)):
            return liveCall.toolCallId == storedCall.toolCallId
        case (.fileEdit, .fileEdit), (.plan, .plan), (.systemNotice, .systemNotice):
            return true
        default:
            return false
        }
    }
}

private struct CopiedTextPayload: Codable {
    let messageId: String?
    let text: String
}

private struct CopiedUserPayload: Codable {
    let messageId: String?
    let text: String
    let attachments: [ACPMessage.Attachment]
    let delegatedSource: ACPDelegatedPromptSource?
}
```

- [ ] **Step 4: Run the focused tests**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPSessionForkPolicyTests test
```

Expected: PASS.

- [ ] **Step 5: Commit the domain layer**

```bash
rtk git add Alas/Sources/ACP/Session/ACPSessionFork.swift AlasTests/ACP/Session/ACPSessionForkPolicyTests.swift
rtk git commit -m "feat(acp): define session fork snapshots"
```

---

### Task 2: Fork Persistence and Hydration

**Files:**
- Modify: `Alas/Sources/ACP/Session/ACPSessionStore.swift:4-225`
- Modify: `Alas/Sources/ACP/Session/ACPSessionStore.swift:240-830`
- Modify: `Alas/Sources/ACP/Session/ACPSessionPersistence.swift:20-560`
- Modify: `Alas/Sources/ACP/Session/ACPSessionHydrator.swift:40-145`
- Create: `AlasTests/ACP/Session/ACPSessionForkPersistenceTests.swift`

**Interfaces:**
- Consumes: Task 1's `ACPSessionForkRecord`, `ACPSessionForkMechanism`, `ACPSessionForkCreationPhase`, and copied `[ACPStoredMessage]`.
- Produces: `ACPSessionStore.createFork(session:messages:record:)`, `loadFork(targetSessionID:)`, `finalizeFork(targetSessionID:mechanism:remoteSessionID:)`, `clearForkContextDeliveryPending(targetSessionID:)`, matching actor methods on `ACPSessionPersistence`, and `HydrationResult.forkRecord`.

- [ ] **Step 1: Write failing atomicity and hydration tests**

Create `AlasTests/ACP/Session/ACPSessionForkPersistenceTests.swift` with a suite that:

```swift
import Foundation
import Testing
@testable import Alas

@Suite("ACP session fork persistence")
struct ACPSessionForkPersistenceTests {
    @Test("fork row, copied messages, and metadata commit together")
    func atomicCreateAndLoad() throws {
        let store = try ACPSessionStore(path: temporaryPath())
        let row = targetRow(id: "target")
        let messages = [
            ACPStoredMessage(
                id: "msg-target-0", sessionId: "target", kind: "user", seq: 0,
                payload: Data(#"{"messageId":null,"text":"hello","attachments":[],"delegatedSource":null}"#.utf8),
                createdAt: 1
            )
        ]
        let record = forkRecord(target: "target", phase: .ready, mechanism: .transcriptTransfer)

        try store.createFork(session: row, messages: messages, record: record)

        #expect(try store.loadSession(id: "target") == row)
        #expect(try store.loadMessages(sessionId: "target") == messages)
        #expect(try store.loadFork(targetSessionID: "target") == record)
    }

    @Test("fork create rolls back when a copied message conflicts")
    func atomicRollback() throws {
        let store = try ACPSessionStore(path: temporaryPath())
        try store.upsertSession(targetRow(id: "existing"))
        try store.appendMessage(
            sessionId: "existing", id: "collision", kind: "system", seq: 0,
            payload: Data(#"{"messageId":null,"text":"existing"}"#.utf8), createdAt: 0
        )
        let conflicting = ACPStoredMessage(
            id: "collision", sessionId: "target", kind: "user", seq: 0,
            payload: Data(#"{"messageId":null,"text":"fork","attachments":[],"delegatedSource":null}"#.utf8),
            createdAt: 1
        )

        var didThrow = false
        do {
            try store.createFork(
                session: targetRow(id: "target"),
                messages: [conflicting],
                record: forkRecord(target: "target", phase: .ready, mechanism: .transcriptTransfer)
            )
        } catch {
            didThrow = true
        }
        #expect(didThrow)
        #expect(try store.loadSession(id: "target") == nil)
        #expect(try store.loadFork(targetSessionID: "target") == nil)
    }

    @Test("finalize and clear pending context survive hydration")
    func finalizeAndHydrate() async throws {
        let path = temporaryPath()
        let persistence = ACPSessionPersistence(path: path)
        let initial = forkRecord(target: "target", phase: .negotiatingNative, mechanism: nil)
        try await persistence.createFork(
            session: targetRow(id: "target"),
            messages: [],
            record: initial
        )
        try await persistence.finalizeFork(
            targetSessionID: "target",
            mechanism: .transcriptTransfer,
            remoteSessionID: nil
        )

        let hydrated = try await persistence.hydrate(sessionId: "target")
        #expect(hydrated.forkRecord?.phase == .ready)
        #expect(hydrated.forkRecord?.mechanism == .transcriptTransfer)
        #expect(hydrated.forkRecord?.contextDeliveryPending == true)

        try await persistence.clearForkContextDeliveryPending(targetSessionID: "target")
        #expect(try await persistence.loadFork(targetSessionID: "target")?.contextDeliveryPending == false)
    }

    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-fork-\(UUID()).sqlite").path
    }

    private func targetRow(id: String) -> ACPSessionRow {
        .init(
            id: id, agentId: "codex", title: "Source (fork)",
            titleSource: .generated, currentModel: nil, currentMode: nil,
            autoRun: false, createdAt: 1, updatedAt: 1, lastOpenedAt: 1,
            archived: false
        )
    }

    private func forkRecord(
        target: String,
        phase: ACPSessionForkCreationPhase,
        mechanism: ACPSessionForkMechanism?
    ) -> ACPSessionForkRecord {
        .init(
            targetSessionID: target,
            sourceSessionID: "source",
            sourceAgentID: "claude",
            sourceBoundarySequence: 2,
            inheritedMessageCount: 1,
            phase: phase,
            mechanism: mechanism,
            contextDeliveryPending: mechanism == .transcriptTransfer
        )
    }
}
```

- [ ] **Step 2: Run the focused persistence suite**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPSessionForkPersistenceTests test
```

Expected: FAIL because schema v15 and fork persistence APIs do not exist.

- [ ] **Step 3: Add schema v15 and store CRUD**

In `ACPSessionStore`:

```swift
static let targetSchemaVersion = 15
```

Call `migrate_to_v15()` from `migrate()` and implement:

```swift
private func migrate_to_v15() throws {
    try db.exec("""
    CREATE TABLE IF NOT EXISTS session_forks (
      target_session_id          TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
      source_session_id          TEXT NOT NULL,
      source_agent_id            TEXT NOT NULL,
      source_boundary_seq        INTEGER NOT NULL,
      inherited_message_count    INTEGER NOT NULL,
      phase                      TEXT NOT NULL,
      mechanism                  TEXT,
      context_delivery_pending   INTEGER NOT NULL DEFAULT 0
    )
    """)
}
```

Add store methods whose transaction bodies are:

```swift
func createFork(
    session: ACPSessionRow,
    messages: [ACPStoredMessage],
    record: ACPSessionForkRecord
) throws {
    try db.transaction {
        try upsertSession(session)
        for message in messages {
            try appendMessage(
                sessionId: message.sessionId,
                id: message.id,
                kind: message.kind,
                seq: message.seq,
                payload: message.payload,
                createdAt: message.createdAt
            )
        }
        try upsertFork(record)
    }
}

func finalizeFork(
    targetSessionID: String,
    mechanism: ACPSessionForkMechanism,
    remoteSessionID: String?
) throws {
    try db.transaction {
        try db.exec("""
        UPDATE session_forks
        SET phase = ?, mechanism = ?, context_delivery_pending = ?
        WHERE target_session_id = ?
        """, bindings: [
            ACPSessionForkCreationPhase.ready.rawValue,
            mechanism.rawValue,
            mechanism == .transcriptTransfer ? 1 : 0,
            targetSessionID
        ])
        if let remoteSessionID {
            try db.exec(
                "UPDATE sessions SET remote_session_id = ?, origin = ? WHERE id = ?",
                bindings: [remoteSessionID, ACPSessionOrigin.agentForked.rawValue, targetSessionID]
            )
        }
    }
}

func clearForkContextDeliveryPending(targetSessionID: String) throws {
    try db.exec("""
    UPDATE session_forks
    SET context_delivery_pending = 0
    WHERE target_session_id = ?
    """, bindings: [targetSessionID])
}
```

Implement `upsertFork(_:)` and `loadFork(targetSessionID:)` by binding every
`ACPSessionForkRecord` field exactly to the v15 columns. `source_session_id`
must not be a foreign key, so deleting a source never deletes the target.

- [ ] **Step 4: Expose actor APIs and hydrate metadata**

Add one-line forwarding methods to `ACPSessionPersistence`:

```swift
func createFork(session: ACPSessionRow, messages: [ACPStoredMessage], record: ACPSessionForkRecord) throws
func loadFork(targetSessionID: String) throws -> ACPSessionForkRecord?
func finalizeFork(targetSessionID: String, mechanism: ACPSessionForkMechanism, remoteSessionID: String?) throws
func clearForkContextDeliveryPending(targetSessionID: String) throws
```

Add `let forkRecord: ACPSessionForkRecord?` to `HydrationResult`, load it in
`ACPSessionHydrator.loadSnapshot`, and preserve it in
`replacingRowLastOpenedAt` and `replacingRecent`.

- [ ] **Step 5: Run persistence and hydration tests**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPSessionForkPersistenceTests -only-testing:AlasTests/ACPSessionHydratorTests test
```

Expected: PASS.

- [ ] **Step 6: Commit persistence**

```bash
rtk git add Alas/Sources/ACP/Session/ACPSessionStore.swift Alas/Sources/ACP/Session/ACPSessionPersistence.swift Alas/Sources/ACP/Session/ACPSessionHydrator.swift AlasTests/ACP/Session/ACPSessionForkPersistenceTests.swift
rtk git commit -m "feat(acp): persist session fork lineage"
```

---

### Task 3: Manager-Owned Local Fork Creation

**Files:**
- Modify: `Alas/Sources/ACP/Session/ACPSession.swift:25-310`
- Modify: `Alas/Sources/ACP/Session/ACPSession.swift:1180-1220`
- Modify: `Alas/Sources/ACP/Session/ACPSessionManager.swift:450-740`
- Create: `AlasTests/ACP/Session/ACPSessionForkManagerTests.swift`

**Interfaces:**
- Consumes: Tasks 1-2's snapshot resolver and persistence APIs plus `ACPSessionManager.awaitBackfill(id:)` and `flushAllPersistence()`.
- Produces: `ACPSession.sessionCapabilities`, `ACPSession.forkRecord`, `ACPSession.canForkMessage(at:)`, and `ACPSessionManager.createFork(sourceSessionID:boundary:targetAgentID:autoRunDefault:) async throws -> ACPSession`.

- [ ] **Step 1: Write failing manager tests**

Create `AlasTests/ACP/Session/ACPSessionForkManagerTests.swift` with tests that:

```swift
@MainActor
@Suite("ACP session fork manager")
struct ACPSessionForkManagerTests {
    @Test("createFork copies through selected boundary and leaves source unchanged")
    func createsLocalFork() async throws {
        let path = temporaryPath()
        let store = try ACPSessionStore(path: path)
        let manager = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let source = manager.createSession(agentId: "claude")
        let user: ACPMessage = .user(id: UUID(), text: "one", attachments: [])
        let agent: ACPMessage = .agent(id: UUID(), StreamingText("two"))
        let later: ACPMessage = .user(id: UUID(), text: "three", attachments: [])
        for message in [user, agent, later] {
            let index = source.transcript.messages.count
            source.transcript.appendMessage(message)
            try store.appendMessage(
                sessionId: source.id,
                id: "msg-\(source.id)-\(index)",
                kind: message.kind,
                seq: Int64(index),
                payload: try ACPMessageCodec.encode(message),
                createdAt: Int64(index)
            )
        }
        let sourceBefore = try store.loadMessages(sessionId: source.id)

        let target = try await manager.createFork(
            sourceSessionID: source.id,
            boundary: .init(stableID: agent.stableId, kind: .agent),
            targetAgentID: "codex",
            autoRunDefault: false
        )

        #expect(target.agentId == "codex")
        #expect(target.title == "New session (fork)")
        #expect(target.transcript.messages.count == 2)
        #expect(target.forkRecord?.mechanism == .transcriptTransfer)
        #expect(try store.loadMessages(sessionId: source.id) == sourceBefore)
    }

    @Test("streaming agent is ineligible while earlier messages remain eligible")
    func messageEligibility() {
        let session = ACPSession(
            id: "s", agentId: "claude", worktreeId: "wt",
            title: "Session", hydrationState: .ready
        )
        session.transcript.appendMessage(.user(id: UUID(), text: "old", attachments: []))
        session.transcript.appendMessage(.agent(id: UUID(), StreamingText("old answer")))
        session.transcript.appendMessage(.user(id: UUID(), text: "new", attachments: []))
        session.transcript.appendMessage(.agent(id: UUID(), StreamingText("partial")))
        session.transcript.streamingState = .streaming

        #expect(session.canForkMessage(at: 0))
        #expect(session.canForkMessage(at: 1))
        #expect(session.canForkMessage(at: 2))
        #expect(!session.canForkMessage(at: 3))
    }
}
```

Include the same `temporaryPath()` helper pattern used by
`ACPSessionManagerTests`.

- [ ] **Step 2: Run the manager suite and verify failure**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPSessionForkManagerTests test
```

Expected: FAIL because fork state and manager creation APIs are missing.

- [ ] **Step 3: Add runtime fork state and eligibility**

In `ACPSession` add:

```swift
@Published var sessionCapabilities: ACPInitializeResult.ACPAgentSessionCapabilities?
@Published var forkRecord: ACPSessionForkRecord?

func canForkMessage(at index: Int) -> Bool {
    guard transcript.messages.indices.contains(index) else { return false }
    switch transcript.messages[index] {
    case .user:
        return true
    case .agent:
        guard transcript.streamingState != .idle else { return true }
        return lastAgent() != index
    default:
        return false
    }
}
```

In `ACPSessionManager.applyHydration`, assign `result.forkRecord` to
`session.forkRecord`. In the attach initialize path, assign
`initialized.sessionCapabilities` to `session.sessionCapabilities`.

- [ ] **Step 4: Implement atomic local fork creation**

Add this manager entry point:

```swift
func createFork(
    sourceSessionID: ACPSession.ID,
    boundary: ACPForkMessageBoundary,
    targetAgentID: String,
    autoRunDefault: Bool
) async throws -> ACPSession
```

Its body must:

1. Require a live, hydrated source and call
   `acquireWriterLease(sessionId: sourceSessionID)` when this manager does not
   already own its writer lease. Throw `ACPSessionForkCreationError.sourceReadOnly`
   when the lease cannot be acquired.
2. Call `awaitBackfill(id:)`, `flushAllPersistence()`, then
   `persistence.loadMessages(sessionId:)`.
3. Call `ACPSessionForkSnapshotResolver.resolve`.
4. Set `boundaryIsRemoteHead` by comparing
   `snapshot.sourceBoundarySequence == storedMessages.last?.seq`.
5. Select a candidate with `source.sessionCapabilities?.supportsFork`. A nil
   runtime value intentionally creates a native candidate when the other
   preconditions hold; target initialization makes the final capability
   decision.
6. Build a target row whose title is
   `source.title == "New session" ? "New session (fork)" : "\(source.title) (fork)"`.
7. Set the initial record to `.negotiatingNative` with nil mechanism and
   pending false for a native candidate; otherwise `.ready`,
   `.transcriptTransfer`, and pending true.
8. Call the single atomic `persistence.createFork`.
9. Materialize a ready in-memory target from the copied rows, assign its
   `forkRecord`, insert it into `sessions`, `persistedRows`, and `recent`, and
   return it.

Do not use `createSession` followed by message writes; that would violate the
atomic target contract.

- [ ] **Step 5: Run manager, persistence, and hydration suites**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPSessionForkManagerTests -only-testing:AlasTests/ACPSessionForkPersistenceTests -only-testing:AlasTests/ACPSessionManagerHydrationTests test
```

Expected: PASS.

- [ ] **Step 6: Commit local fork creation**

```bash
rtk git add Alas/Sources/ACP/Session/ACPSession.swift Alas/Sources/ACP/Session/ACPSessionManager.swift AlasTests/ACP/Session/ACPSessionForkManagerTests.swift
rtk git commit -m "feat(acp): create durable local chat forks"
```

---

### Task 4: One-Time Private Transcript Context

**Files:**
- Modify: `Alas/Sources/ACP/Session/ACPTranscriptMarkdown.swift:1-85`
- Modify: `Alas/Sources/ACP/Session/ACPSessionPersistence.swift`
- Modify: `Alas/Sources/ACP/Session/ACPSessionRunner.swift:1280-1320`
- Modify: `Alas/Sources/ACP/Session/ACPSessionRunner.swift:1470-1630`
- Modify: `Alas/Sources/ACP/Session/ACPSessionManager.swift:2690-2920`
- Create: `AlasTests/ACP/Session/ACPSessionForkRunnerTests.swift`

**Interfaces:**
- Consumes: `ACPSession.forkRecord`, inherited prefix count, existing `ACPTranscriptMarkdown.document`, and runner prompt-block injection.
- Produces: `ACPTranscriptMarkdown.forkContext(sourceAgentID:messages:) -> String?`, `ACPSessionRunner` one-time injection, and durable pending-context clearing.

- [ ] **Step 1: Write failing serializer and runner tests**

Add tests proving:

```swift
let context = ACPTranscriptMarkdown.forkContext(
    sourceAgentID: "claude",
    messages: [
        .user(id: UUID(), text: "Question", attachments: []),
        .agent(id: UUID(), StreamingText("Answer"))
    ]
)
#expect(context?.contains("The conversation below was imported from claude.") == true)
#expect(context?.contains("## You\n\nQuestion") == true)
#expect(context?.contains("## claude\n\nAnswer") == true)
```

In `ACPSessionForkRunnerTests`, construct an `ACPMockClient`, a target session
with a `.transcriptTransfer` fork record and `inheritedMessageCount == 2`, then
call `sendNow(blocks:[.text("Continue")], queuedItemId:nil)`. Script
`session/prompt`, wait for the request, and assert:

```swift
#expect(promptBlocks == [
    .text(try #require(ACPTranscriptMarkdown.forkContext(
        sourceAgentID: "claude",
        messages: Array(session.transcript.messages.prefix(2))
    ))),
    .text("Continue")
])
#expect(session.transcript.messages.count == 3)
#expect(try await persistence.loadFork(targetSessionID: session.id)?.contextDeliveryPending == false)
```

Add a separate test with a fresh pending target whose scripted prompt throws
`ACPClientError.notRunning`; assert pending remains true, the private inherited
context is absent from visible messages, and retry does not append a duplicate
visible user prompt.

- [ ] **Step 2: Run the focused runner suite**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPSessionForkRunnerTests test
```

Expected: FAIL because fork context serialization and runner injection are absent.

- [ ] **Step 3: Add the exact context serializer**

Add to `ACPTranscriptMarkdown`:

```swift
@MainActor
static func forkContext(sourceAgentID: String, messages: [ACPMessage]) -> String? {
    let markdown = document(
        title: "Imported conversation",
        agentName: sourceAgentID,
        messages: messages
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !markdown.isEmpty else { return nil }
    return """
    The conversation below was imported from \(sourceAgentID). Use it as background context for this branch. Provider-specific tool state, hidden context, and attachments were not transferred. Do not summarize or repeat the imported conversation unless I ask.

    \(markdown)
    """
}
```

- [ ] **Step 4: Inject and clear pending fork context**

In `sendNow`, capture the pending context before hydration:

```swift
let pendingForkContext: String? = {
    guard let fork = self.session.forkRecord,
          fork.phase == .ready,
          fork.mechanism == .transcriptTransfer,
          fork.contextDeliveryPending
    else { return nil }
    return ACPTranscriptMarkdown.forkContext(
        sourceAgentID: fork.sourceAgentID,
        messages: Array(self.session.transcript.messages.prefix(fork.inheritedMessageCount))
    )
}()
```

Insert `pendingForkContext` after MCP preamble and before the user's hydrated
blocks, preserving this wire order:

```swift
var privateBlocks: [ACPContentBlock] = []
if let pendingMCPPreamble { privateBlocks.append(.text(pendingMCPPreamble)) }
if let pendingForkContext { privateBlocks.append(.text(pendingForkContext)) }
wireBlocks.insert(contentsOf: privateBlocks, at: 0)
```

After successful `connection.prompt`, clear the in-memory flag and enqueue:

```swift
if pendingForkContext != nil,
   var fork = self.session.forkRecord,
   fork.contextDeliveryPending {
    fork.contextDeliveryPending = false
    self.session.forkRecord = fork
    self.persistForkContextDelivered()
}
```

Implement `persistForkContextDelivered()` like `persistMCPPreambleSent()`, using
the lease fence. Add this exact overload to `ACPSessionPersistence`:

```swift
@discardableResult
func clearForkContextDeliveryPending(
    targetSessionID: String,
    fence: ACPSessionLeaseFence?
) throws -> Bool {
    let store = try openedStore()
    let operation = {
        try store.clearForkContextDeliveryPending(targetSessionID: targetSessionID)
    }
    if let fence {
        return try store.withLeaseFence(fence, operation) != nil
    }
    try operation()
    return true
}
```

The runner enqueues this fenced overload with its current
`leaseFenceProvider()` value and updates the in-memory flag only after
`connection.prompt` succeeds.

In manager attach recovery, exclude sessions with pending fork context from
the generic `contextRecoveryPending` / `sendTranscriptAsContext` path. Their
inherited context must wait for the first real prompt.

- [ ] **Step 5: Run runner and existing recovery tests**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPSessionForkRunnerTests -only-testing:AlasTests/ACPSessionRunnerTests -only-testing:AlasTests/ACPSessionManagerAttachRestoreTests test
```

Expected: PASS.

- [ ] **Step 6: Commit private context delivery**

```bash
rtk git add Alas/Sources/ACP/Session/ACPTranscriptMarkdown.swift Alas/Sources/ACP/Session/ACPSessionPersistence.swift Alas/Sources/ACP/Session/ACPSessionRunner.swift Alas/Sources/ACP/Session/ACPSessionManager.swift AlasTests/ACP/Session/ACPSessionForkRunnerTests.swift
rtk git commit -m "feat(acp): deliver fork context on first prompt"
```

---

### Task 5: Native ACP Fork Negotiation and Graceful Fallback

**Files:**
- Modify: `Alas/Sources/ACP/Protocol/ACPMessages.swift:720-790`
- Modify: `Alas/Sources/ACP/Protocol/ACPConnection.swift:90-125`
- Modify: `Alas/Sources/ACP/Session/ACPSessionManager.swift:1630-1665`
- Modify: `Alas/Sources/ACP/Session/ACPSessionManager.swift:2690-2925`
- Modify: `AlasTests/ACP/Protocol/ACPConnectionTests.swift`
- Create: `AlasTests/ACP/Session/ACPSessionForkAttachTests.swift`

**Interfaces:**
- Consumes: persisted `.negotiatingNative` record from Task 3 and normal manager attach setup/MCP planning.
- Produces: `ACPConnection.forkSession(cwd:sessionId:mcpServers:brokerOperationKey:)`, `ACPConnection.closeSession(sessionId:)`, stable startup operation keys, and attach-time native/fallback finalization.

- [ ] **Step 1: Add failing protocol tests**

Extend `ACPConnectionTests` with:

```swift
@Test("forkSession carries broker key and defers durable acknowledgement")
func forkSessionDurableRPC() async throws {
    let mock = ACPMockClient()
    let acknowledgement = DurableAcknowledgementRecorder()
    mock.scriptResponse(method: "session/fork") { _ in
        ACPResponse(
            body: try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "forked", availableModels: [], availableModes: [],
                currentModel: nil, currentMode: nil, promptSuggestions: []
            )),
            durableConsumptionAcknowledgement: { acknowledgement.record() }
        )
    }
    let connection = ACPConnection(client: mock)

    let result = try await connection.forkSession(
        cwd: "/tmp/wt",
        sessionId: "source-remote",
        mcpServers: [],
        brokerOperationKey: "startup:target:session/fork:source-remote"
    )

    #expect(result.sessionId == "forked")
    #expect(mock.sent.last?.brokerOperationKey == "startup:target:session/fork:source-remote")
    #expect(acknowledgement.count == 0)
    connection.acknowledgeDurableSessionResponses()
    #expect(acknowledgement.count == 1)
}
```

Add this file-private helper to `ACPConnectionTests.swift`:

```swift
private final class DurableAcknowledgementRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}
```

- [ ] **Step 2: Run protocol tests and verify failure**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPConnectionTests test
```

Expected: FAIL because fork does not accept a broker key or defer acknowledgement.

- [ ] **Step 3: Make fork durable and add best-effort close**

Add:

```swift
struct ACPSessionCloseParams: Codable, Equatable {
    let sessionId: String
}
```

Change `forkSession` to:

```swift
func forkSession(
    cwd: String,
    sessionId: String,
    mcpServers: [ACPMCPServer],
    brokerOperationKey: String? = nil
) async throws -> ACPSessionNewResult {
    let req = ACPRequest(
        method: "session/fork",
        params: ACPSessionForkParams(cwd: cwd, sessionId: sessionId, mcpServers: mcpServers),
        brokerOperationKey: brokerOperationKey
    )
    let resp = try await client.send(req)
    let result = try JSONDecoder().decode(ACPSessionNewResult.self, from: resp.body)
    deferDurableSessionResponse(resp)
    return result
}

func closeSession(sessionId: String) async throws {
    let response = try await client.send(ACPRequest(
        method: "session/close",
        params: ACPSessionCloseParams(sessionId: sessionId)
    ))
    response.acknowledgeDurableConsumption()
}
```

- [ ] **Step 4: Write failing attach negotiation tests**

In `ACPSessionForkAttachTests`, use the connection factory pattern from
`ACPSessionManagerAttachRestoreTests` to cover:

- `.negotiatingNative` + advertised fork sends `initialize`, `session/fork`,
  persists `.nativeACP` plus returned remote ID, and registers the returned
  connection as the target runner.
- Missing fork capability finalizes `.transcriptTransfer`, then sends
  `session/new`.
- `session/fork` throwing `ACPClientError.jsonrpc` finalizes transcript and
  sends `session/new` on the same connection.
- Auth failure finalizes transcript but preserves the existing needs-auth
  surface.
- Reattaching the same target uses the same
  `startup:<target>:session/fork:<sourceRemote>` broker key.
- A source session absent from `manager.sessions` still resolves its remote ID
  through `persistence.loadSession(id:)`.

- [ ] **Step 5: Add the attach startup branch**

Immediately before the current `if freshlyCreated` startup selection in
`ACPSessionManager.attach`, add a branch for
`session.forkRecord?.phase == .negotiatingNative`. Resolve the source remote ID
from `try await persistence.loadSession(id: fork.sourceSessionID)` rather than
requiring the source to remain materialized in `sessions`.

The branch must:

```swift
if var fork = session.forkRecord, fork.phase == .negotiatingNative {
    if initialized.sessionCapabilities.supportsFork,
       let source = try await persistence.loadSession(id: fork.sourceSessionID),
       let sourceRemoteID = source.remoteSessionId,
       !sourceRemoteID.isEmpty {
        do {
            result = try await connection.forkSession(
                cwd: worktreePath,
                sessionId: sourceRemoteID,
                mcpServers: wireMCPServers,
                brokerOperationKey: Self.brokerStartupOperationKey(
                    sessionId: sessionId,
                    method: "session/fork",
                    remoteSessionId: sourceRemoteID
                )
            )
            try await persistence.finalizeFork(
                targetSessionID: sessionId,
                mechanism: .nativeACP,
                remoteSessionID: result.sessionId
            )
            fork.phase = .ready
            fork.mechanism = .nativeACP
            fork.contextDeliveryPending = false
            session.forkRecord = fork
        } catch {
            try await persistence.finalizeFork(
                targetSessionID: sessionId,
                mechanism: .transcriptTransfer,
                remoteSessionID: nil
            )
            fork.phase = .ready
            fork.mechanism = .transcriptTransfer
            fork.contextDeliveryPending = true
            session.forkRecord = fork
            if ACPAuthFailure.message(from: error) != nil { throw error }
            result = try await connection.newSession(
                cwd: worktreePath,
                mcpServers: wireMCPServers,
                brokerOperationKey: Self.brokerStartupOperationKey(
                    sessionId: sessionId,
                    method: "session/new"
                )
            )
            createdFreshRemoteSession = true
        }
    } else {
        try await persistence.finalizeFork(
            targetSessionID: sessionId,
            mechanism: .transcriptTransfer,
            remoteSessionID: nil
        )
        fork.phase = .ready
        fork.mechanism = .transcriptTransfer
        fork.contextDeliveryPending = true
        session.forkRecord = fork
        result = try await connection.newSession(
            cwd: worktreePath,
            mcpServers: wireMCPServers,
            brokerOperationKey: Self.brokerStartupOperationKey(
                sessionId: sessionId,
                method: "session/new"
            )
        )
        createdFreshRemoteSession = true
    }
}
```

Implement the branch as a private
`startForkTarget(session:fork:initialized:connection:wireMCPServers:)` helper
returning `(result: ACPSessionNewResult, createdFreshRemoteSession: Bool)`.
The attach selection assigns both tuple members before joining the existing
runner-registration path.

Add `downgradeNegotiatingForkToTranscript(session:) async` and call it before
every existing attach return caused by setup, launch, authentication, or
connection failure while the record is `.negotiatingNative`. It persists
`.ready` + `.transcriptTransfer` + pending context and mirrors those values
into `session.forkRecord` before the normal failure UI is set. A retry then
uses the normal fresh `session/new` path.

If native remote creation succeeds but local finalization fails, call
`try? await connection.closeSession(sessionId: result.sessionId)`, then
`try? await persistence.finalizeFork(targetSessionID: sessionId,
mechanism: .transcriptTransfer, remoteSessionID: nil)`, mirror the transcript
state in memory, and shut down the connection.

In `makeBrokerConnection`, pre-register the stable fork operation key alongside
restored queue keys whenever the hydrated record is `.negotiatingNative` and
the persisted source row has a remote ID. This protects a replayed completion
until `forkSession` consumes it. Reusing the same key delegates idempotence to
the broker; a broker transport failure with no durable completion follows the
transcript fallback and must never issue an unkeyed `session/fork`.

Call `connection.acknowledgeDurableSessionResponses()` only after the final
fork mechanism and remote ID are durable.

- [ ] **Step 6: Run protocol and attach suites**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPConnectionTests -only-testing:AlasTests/ACPSessionForkAttachTests -only-testing:AlasTests/ACPSessionManagerAttachRestoreTests test
```

Expected: PASS.

- [ ] **Step 7: Commit native negotiation**

```bash
rtk git add Alas/Sources/ACP/Protocol/ACPMessages.swift Alas/Sources/ACP/Protocol/ACPConnection.swift Alas/Sources/ACP/Session/ACPSessionManager.swift AlasTests/ACP/Protocol/ACPConnectionTests.swift AlasTests/ACP/Session/ACPSessionForkAttachTests.swift
rtk git commit -m "feat(acp): negotiate native session forks"
```

---

### Task 6: Native Message Menu and Target Ordering

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPMessageGutter.swift:1-190`
- Modify: `Alas/Sources/ACP/UI/ACPMessageList.swift:1-40`
- Modify: `Alas/Sources/ACP/UI/ACPMessageList.swift:1450-1630`
- Modify: `Alas/Sources/ACP/UI/ACPTabView.swift:310-410`
- Modify: `Alas/Sources/App/AppState.swift:5180-5275`
- Create: `AlasTests/ACP/UI/ACPSessionForkPresentationTests.swift`

**Interfaces:**
- Consumes: Task 1's `ACPSessionForkTarget` and `ACPForkMessageBoundary`, Task 3's `canForkMessage(at:)`, `AgentRegistry.enabled()`, and `ACPLaunchCatalog.specs`.
- Produces: `AppState.acpForkTargets(sourceAgentID:)`, row-level `onFork`, and the AppKit submenu.

- [ ] **Step 1: Write failing ordering and eligibility tests**

Create `ACPSessionForkPresentationTests` with:

```swift
@MainActor
@Suite("ACP session fork presentation")
struct ACPSessionForkPresentationTests {
    @Test("current target is first and remaining targets preserve ACP catalog order")
    func targetOrdering() {
        let targets = ACPForkTargetPolicy.targets(
            sourceAgentID: "codex",
            enabledAgents: [
                .init(id: "claude", displayName: "Claude"),
                .init(id: "gemini", displayName: "Gemini"),
            ],
            sourceAgent: .init(id: "codex", displayName: "Codex"),
            catalogAgentIDs: ["claude", "gemini", "codex"]
        )
        #expect(targets.map(\.id) == ["codex", "claude", "gemini"])
        #expect(targets.first?.isSameAgent == true)
    }

    @Test("message menu only offers fork for eligible rows")
    func menuEligibility() {
        #expect(ACPMessageForkMenuPolicy.showsForkAction(
            messageKind: "user", isEligible: true, targetCount: 2
        ))
        #expect(!ACPMessageForkMenuPolicy.showsForkAction(
            messageKind: "agent", isEligible: false, targetCount: 2
        ))
        #expect(!ACPMessageForkMenuPolicy.showsForkAction(
            messageKind: "tool_call", isEligible: true, targetCount: 2
        ))
    }
}
```

Define a small test input type inside the test or production policy instead of
constructing full `AgentDefinition` values.

- [ ] **Step 2: Run the presentation suite and verify failure**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPSessionForkPresentationTests test
```

Expected: FAIL because target and menu policies are missing.

- [ ] **Step 3: Add pure target/menu policies**

In `ACPSessionFork.swift`, add:

```swift
struct ACPForkAgentOption: Equatable {
    let id: String
    let displayName: String
}

enum ACPForkTargetPolicy {
    static func targets(
        sourceAgentID: String,
        enabledAgents: [ACPForkAgentOption],
        sourceAgent: ACPForkAgentOption?,
        catalogAgentIDs: [String]
    ) -> [ACPSessionForkTarget] {
        var byID = Dictionary(uniqueKeysWithValues: enabledAgents.map { ($0.id, $0) })
        if let sourceAgent {
            byID[sourceAgent.id] = sourceAgent
        }
        let ordered = catalogAgentIDs.compactMap { byID[$0] }
        let current = ordered.filter { $0.id == sourceAgentID }
        let others = ordered.filter { $0.id != sourceAgentID }
        return (current + others).map {
            .init(id: $0.id, displayName: $0.displayName, isSameAgent: $0.id == sourceAgentID)
        }
    }
}

enum ACPMessageForkMenuPolicy {
    static func showsForkAction(messageKind: String, isEligible: Bool, targetCount: Int) -> Bool {
        (messageKind == "user" || messageKind == "agent") && isEligible && targetCount > 0
    }
}
```

- [ ] **Step 4: Extend the AppKit message menu**

Add to `ACPMessageGutter`:

```swift
let forkBoundary: ACPForkMessageBoundary?
let forkTargets: [ACPSessionForkTarget]
let onFork: (ACPForkMessageBoundary, String) -> Void
```

Pass these through `ACPMessageActionsButton` and update its coordinator on
every `updateNSView`. In `Coordinator.showMenu`, after `Copy message`, add a
separator and a parent `NSMenuItem(title:"Fork from here", ...)` only when the
boundary exists and targets are non-empty. Build its submenu:

```swift
let submenu = NSMenu()
for target in forkTargets {
    let title = target.isSameAgent
        ? "\(target.displayName)\tSame agent"
        : target.displayName
    let item = NSMenuItem(
        title: title,
        action: #selector(forkFromHere(_:)),
        keyEquivalent: ""
    )
    item.target = self
    item.representedObject = target.id
    submenu.addItem(item)
}
forkItem.submenu = submenu
menu.addItem(forkItem)
```

Implement `forkFromHere(_:)` by requiring the current boundary and represented
target ID, then calling `onFork(boundary, targetID)`.

- [ ] **Step 5: Wire row boundaries and targets**

Add `forkTargets` and `onFork` to `ACPMessageList`, then to
`ACPTranscriptRowContent`. For user/agent cases, create the boundary only when
`session.canForkMessage(at: rowIndex)` is true. Add `messageIndex: Int` to
`ACPTranscriptRowContent` so it can make:

```swift
let boundary = ACPForkMessageBoundary(
    stableID: stableId,
    kind: message.kind == "user" ? .user : .agent
)
```

Include fork eligibility and targets in `ACPTranscriptRowContent.EqualityKey`
so enabling/disabling the action cannot be hidden by `.equatable()`.

In `AppState`, implement `acpForkTargets(sourceAgentID:)` using
`agentRegistry.enabled()` for alternative targets,
`agentRegistry.agents.first(where: { $0.id == sourceAgentID })` for the current
target, and `ACPLaunchCatalog.specs.map(\.agentID)` for the ACP-only ordering.

- [ ] **Step 6: Run UI policy and message-row tests**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPSessionForkPresentationTests -only-testing:AlasTests/ACPMessageStableIdTests -only-testing:AlasTests/ACPTranscriptRowContentTests test
```

The existing equality suite is declared as
`ACPTranscriptRowContentTests` in
`AlasTests/ACP/UI/ACPTranscriptRowContentTests.swift`; keep the new equality
assertions in that suite and use
`-only-testing:AlasTests/ACPTranscriptRowContentTests`.

Expected: PASS.

- [ ] **Step 7: Commit the menu**

```bash
rtk git add Alas/Sources/ACP/Session/ACPSessionFork.swift Alas/Sources/ACP/UI/ACPMessageGutter.swift Alas/Sources/ACP/UI/ACPMessageList.swift Alas/Sources/ACP/UI/ACPTabView.swift Alas/Sources/App/AppState.swift AlasTests/ACP/UI/ACPSessionForkPresentationTests.swift
rtk git commit -m "feat(acp): add per-message fork menu"
```

---

### Task 7: Fork Tab Creation, Divider, and Source Navigation

**Files:**
- Create: `Alas/Sources/ACP/UI/ACPSessionForkDivider.swift`
- Modify: `Alas/Sources/ACP/UI/ACPMessageList.swift:155-250`
- Modify: `Alas/Sources/ACP/UI/ACPMessageList.swift:1450-1520`
- Modify: `Alas/Sources/ACP/UI/ACPTabView.swift:310-410`
- Modify: `Alas/Sources/App/AppState.swift:5180-5310`
- Modify: `AlasTests/ACP/UI/ACPSessionForkPresentationTests.swift`

**Interfaces:**
- Consumes: `ACPSessionManager.createFork`, `ACPSession.forkRecord`, Task 6's row callback and target list, `openExistingACPSession`.
- Produces: `AppState.forkACPSession(...)`, `ACPSessionForkPresentation`, `ACPSessionForkDivider`, and source-session navigation.

- [ ] **Step 1: Add failing divider-copy tests**

Extend `ACPSessionForkPresentationTests`:

```swift
@Test("native and transcript forks use honest divider copy")
func dividerCopy() {
    #expect(ACPSessionForkPresentation(
        sourceAgentName: "Claude", mechanism: .nativeACP
    ).title == "Forked from Claude")
    let imported = ACPSessionForkPresentation(
        sourceAgentName: "Claude", mechanism: .transcriptTransfer
    )
    #expect(imported.title == "Conversation imported from Claude")
    #expect(imported.notice ==
        "Provider-specific tool state, hidden context, and attachments were not transferred. This chat shares the source chat’s current worktree.")
}
```

- [ ] **Step 2: Run the presentation suite**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPSessionForkPresentationTests test
```

Expected: FAIL because the divider presentation type is missing.

- [ ] **Step 3: Implement divider presentation and view**

Create `ACPSessionForkDivider.swift`:

```swift
import SwiftUI

struct ACPSessionForkPresentation: Equatable {
    let title: String
    let notice: String?

    init(sourceAgentName: String, mechanism: ACPSessionForkMechanism) {
        switch mechanism {
        case .nativeACP:
            title = "Forked from \(sourceAgentName)"
            notice = nil
        case .transcriptTransfer:
            title = "Conversation imported from \(sourceAgentName)"
            notice = "Provider-specific tool state, hidden context, and attachments were not transferred. This chat shares the source chat’s current worktree."
        }
    }
}

struct ACPSessionForkDivider: View {
    let presentation: ACPSessionForkPresentation
    let onOpenSource: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Rectangle().fill(theme.color("line")).frame(height: 1)
                Button(presentation.title, action: onOpenSource)
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.color("accent"))
                    .help("Open source chat")
                Rectangle().fill(theme.color("line")).frame(height: 1)
            }
            if let notice = presentation.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("fg-muted"))
                    .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
```

- [ ] **Step 4: Insert the divider after the inherited prefix**

Add `onOpenForkSource: (String) -> Void` and
`agentDisplayName: (String) -> String` to `ACPMessageList`. Immediately after
each `visibleRow(row)`, render the divider when:

```swift
if let fork = session.forkRecord,
   fork.phase == .ready,
   row.index == fork.inheritedMessageCount - 1,
   let mechanism = fork.mechanism {
    ACPSessionForkDivider(
        presentation: .init(
            sourceAgentName: agentDisplayName(fork.sourceAgentID),
            mechanism: mechanism
        ),
        onOpenSource: { onOpenForkSource(fork.sourceSessionID) }
    )
    .id("__fork_divider__")
}
```

- [ ] **Step 5: Implement AppState creation and source navigation**

Add:

```swift
func forkACPSession(
    worktree: Worktree,
    sourceSessionID: ACPSession.ID,
    boundary: ACPForkMessageBoundary,
    targetAgentID: String
) {
    guard let manager = acpManager(for: worktree) else { return }
    Task { @MainActor in
        do {
            let target = try await manager.createFork(
                sourceSessionID: sourceSessionID,
                boundary: boundary,
                targetAgentID: targetAgentID,
                autoRunDefault: config.harness.acpAutoRunByDefault
            )
            let tabState = ACPSessionTabState(sessionId: target.id, title: target.title)
            let tab = tabs.append(acpSession: tabState, to: worktree.id)
            tabs.activate(worktreeId: worktree.id, tabId: tab.id)
            await manager.attach(
                to: target.id,
                freshlyCreated: true
            )
        } catch {
            manager.liveSession(for: sourceSessionID)?.lastError =
                "Could not create fork: \(error.localizedDescription)"
        }
    }
}
```

Pass this callback from `ACPTabView` through `ACPMessageList`. Route
`onOpenForkSource` to `await state.openExistingACPSession(sessionId:)` in the
same worktree manager; existing tab-focus behavior handles an already-open or
archived source.

Treat a negotiating native target as a startup operation inside attach rather
than a restored remote session: Task 5's fork branch must precede the existing
`if freshlyCreated` branch. Immediate transcript forks and native fallbacks use
the same `freshlyCreated: true` call and therefore create `session/new`;
negotiating targets are intercepted by the fork branch.

- [ ] **Step 6: Run presentation, manager, and AppState-adjacent tests**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPSessionForkPresentationTests -only-testing:AlasTests/ACPSessionForkManagerTests -only-testing:AlasTests/ACPSessionManagerTests test
```

Expected: PASS.

- [ ] **Step 7: Commit the complete interaction**

```bash
rtk git add Alas/Sources/ACP/UI/ACPSessionForkDivider.swift Alas/Sources/ACP/UI/ACPMessageList.swift Alas/Sources/ACP/UI/ACPTabView.swift Alas/Sources/App/AppState.swift Alas/Sources/ACP/Session/ACPSessionManager.swift AlasTests/ACP/UI/ACPSessionForkPresentationTests.swift
rtk git commit -m "feat(acp): open and present forked chats"
```

---

### Task 8: Relaunch Recovery and Full Verification

**Files:**
- Modify: `AlasTests/ACP/Session/ACPSessionForkAttachTests.swift`
- Modify: `AlasTests/ACP/Session/ACPSessionForkRunnerTests.swift`
- Modify: `AlasTests/ACP/Session/ACPSessionForkManagerTests.swift`
- Regenerate: `Alas.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: the complete fork creation, attach, persistence, and prompt paths from Tasks 1-7.
- Produces: regression coverage for app relaunch and the final verified build.

- [ ] **Step 1: Add a relaunch regression for transcript forks**

Add a test that creates a transcript fork with manager A, discards manager A,
constructs manager B on the same database, hydrates the target, attaches a mock
fresh remote session, sends the first real prompt, and asserts:

```swift
#expect(restored.forkRecord?.mechanism == .transcriptTransfer)
#expect(restored.forkRecord?.contextDeliveryPending == true)
#expect(restored.transcript.messages.count == inheritedCount)
// After successful first prompt:
#expect(try store.loadFork(targetSessionID: restored.id)?.contextDeliveryPending == false)
#expect(restored.transcript.messages.count == inheritedCount + 1)
```

- [ ] **Step 2: Add a relaunch regression for negotiating native forks**

Seed a `.negotiatingNative` fork and a mock broker-backed connection that
returns the same durable response for the stable startup operation key. Hydrate
with a new manager and assert:

```swift
#expect(restored.forkRecord?.phase == .ready)
#expect(restored.forkRecord?.mechanism == .nativeACP)
#expect(restored.remoteSessionId == "forked-remote")
#expect(mock.sent.filter { $0.method == "session/fork" }.count == 1)
```

Add the unavailable-response case and assert it becomes
`.transcriptTransfer` with pending context instead of issuing an unkeyed fork.

- [ ] **Step 3: Run every focused fork suite**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/ACPSessionForkPolicyTests \
  -only-testing:AlasTests/ACPSessionForkPersistenceTests \
  -only-testing:AlasTests/ACPSessionForkManagerTests \
  -only-testing:AlasTests/ACPSessionForkRunnerTests \
  -only-testing:AlasTests/ACPSessionForkAttachTests \
  -only-testing:AlasTests/ACPSessionForkPresentationTests \
  test
```

Expected: PASS.

- [ ] **Step 4: Regenerate the Xcode project**

Run:

```bash
rtk xcodegen
```

Expected: `Alas.xcodeproj/project.pbxproj` includes every new source and test
file and exits successfully.

- [ ] **Step 5: Run the required quiet build**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: exit status 0 with no compiler errors.

- [ ] **Step 6: Run the complete required test suite**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: all Alas tests pass.

- [ ] **Step 7: Check formatting and commit final recovery coverage**

Run:

```bash
rtk git diff --check
rtk git status --short
```

Expected: no whitespace errors; only the intended fork implementation, tests,
plan/spec, and regenerated project changes are present.

Commit:

```bash
rtk git add AlasTests/ACP/Session/ACPSessionForkAttachTests.swift AlasTests/ACP/Session/ACPSessionForkRunnerTests.swift AlasTests/ACP/Session/ACPSessionForkManagerTests.swift Alas.xcodeproj/project.pbxproj
rtk git commit -m "test(acp): cover session fork recovery"
```
