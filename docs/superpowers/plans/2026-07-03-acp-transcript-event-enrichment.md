# ACP Transcript Event Enrichment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve richer ACP session/tool metadata and render Codex-style enriched transcript events through generic ACP presentation paths.

**Architecture:** Decode enriched protocol fields first, then make `ACPSession.apply(_:)` the only place that maps them into runtime state and transcript rows. Keep UI polish in focused presentation/rendering helpers so `ACPToolCallCard` consumes classified display data instead of growing provider-specific branches.

**Tech Stack:** Swift 5.9+, SwiftUI, Combine, Swift Testing, existing ACP JSON-RPC protocol models, existing `ACPTerminalHost`/`ACPTerminalTailView` transcript UI.

---

## File Structure

- Modify `Alas/Sources/ACP/Protocol/ACPSessionUpdate.swift`
  - Decode `session_info_update`.
  - Preserve `_meta` on tool-call create/update payloads.
  - Decode update-time `title`, `locations`, `rawInput`, and `rawOutput`.
- Modify `Alas/Sources/ACP/Protocol/ACPMessages.swift`
  - Keep `AnyCodable` as the metadata transport used by enriched session and tool-call updates.
  - Preserve image/resource block data already decoded by `ACPContentBlock`.
- Modify `Alas/Sources/ACP/Session/ACPMessage.swift`
  - Extend `ACPMessage.ToolCall` with `rawOutput`, `metadata`, and preserved content assets.
  - Keep decoding backward-compatible for persisted rows.
- Modify `Alas/Sources/ACP/Session/ACPSession.swift`
  - Add `ACPGoalState`.
  - Apply session info updates to title/goal.
  - Apply enriched tool-call update fields.
  - Route terminal metadata into retained terminal buffers.
- Modify `Alas/Sources/ACP/Terminal/ACPTerminal.swift`
  - Add a lightweight initializer for metadata-backed terminal rows.
  - Add methods to append metadata output and publish terminal exit without a spawned process.
- Modify `Alas/Sources/ACP/Terminal/ACPTerminalHost.swift`
  - Add APIs for metadata-created terminal buffers.
- Create `Alas/Sources/ACP/UI/ACPToolCallPresentation.swift`
  - Classify generic ACP tool-call rows for display.
- Modify `Alas/Sources/ACP/UI/ACPToolCallCard.swift`
  - Use `ACPToolCallPresentation`.
  - Render image/resource assets in expanded cards.
- Create `Alas/Sources/ACP/UI/ACPGoalPill.swift`
  - Compact goal indicator for toolbar/header.
- Modify `Alas/Sources/ACP/UI/ACPToolbar.swift`
  - Render `ACPGoalPill` when `session.currentGoal` exists.
- Add/modify tests:
  - `AlasTests/ACP/Protocol/ACPSessionUpdateTests.swift`
  - `AlasTests/ACP/Session/ACPSessionTests.swift`
  - `AlasTests/ACP/Session/ACPMessageTests.swift`
  - `AlasTests/ACP/Terminal/ACPTerminalHostTests.swift`
  - Create `AlasTests/ACP/UI/ACPToolCallPresentationTests.swift`
  - Create fixtures under `AlasTests/ACP/Fixtures/`

---

### Task 1: Decode enriched ACP session updates

**Files:**
- Modify: `Alas/Sources/ACP/Protocol/ACPSessionUpdate.swift`
- Modify: `AlasTests/ACP/Protocol/ACPSessionUpdateTests.swift`
- Create: `AlasTests/ACP/Fixtures/session-update-session-info-goal.json`
- Create: `AlasTests/ACP/Fixtures/session-update-tool-call-meta.json`
- Create: `AlasTests/ACP/Fixtures/session-update-tool-call-update-meta.json`

- [ ] **Step 1: Add failing protocol fixtures**

Create `AlasTests/ACP/Fixtures/session-update-session-info-goal.json`:

```json
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": {
    "sessionId": "s",
    "update": {
      "sessionUpdate": "session_info_update",
      "title": "Investigate ACP events",
      "_meta": {
        "codex": {
          "goal": {
            "objective": "Surface richer ACP events",
            "status": "in_progress",
            "tokenBudget": 12000
          }
        }
      }
    }
  }
}
```

Create `AlasTests/ACP/Fixtures/session-update-tool-call-meta.json`:

```json
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": {
    "sessionId": "s",
    "update": {
      "sessionUpdate": "tool_call",
      "toolCallId": "cmd-1",
      "title": "swift test",
      "kind": "execute",
      "status": "in_progress",
      "content": [{ "type": "terminal", "terminalId": "cmd-1" }],
      "rawInput": { "command": "swift test", "cwd": "/repo" },
      "_meta": {
        "terminal_info": {
          "terminal_id": "cmd-1",
          "cwd": "/repo"
        }
      }
    }
  }
}
```

Create `AlasTests/ACP/Fixtures/session-update-tool-call-update-meta.json`:

```json
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": {
    "sessionId": "s",
    "update": {
      "sessionUpdate": "tool_call_update",
      "toolCallId": "cmd-1",
      "title": "swift test --filter ACP",
      "status": "completed",
      "locations": [{ "path": "AlasTests/ACP/Session/ACPSessionTests.swift", "line": 12 }],
      "rawInput": { "command": "swift test --filter ACP" },
      "rawOutput": { "exit_code": 0 },
      "_meta": {
        "terminal_output_delta": {
          "terminal_id": "cmd-1",
          "data": "ok\n"
        },
        "terminal_exit": {
          "terminal_id": "cmd-1",
          "exit_code": 0,
          "signal": null
        }
      }
    }
  }
}
```

- [ ] **Step 2: Add failing decode tests**

Append tests to `AlasTests/ACP/Protocol/ACPSessionUpdateTests.swift`:

```swift
@Test("decodes session_info_update with metadata")
func sessionInfoUpdate() throws {
    let env = try decode("session-update-session-info-goal")
    guard case .sessionInfoUpdate(let info) = env.params!.update else {
        Issue.record("expected sessionInfoUpdate")
        return
    }
    #expect(info.title == "Investigate ACP events")
    let meta = try #require(info.metadata?.value as? [String: AnyCodable])
    let codex = try #require(meta["codex"]?.value as? [String: AnyCodable])
    let goal = try #require(codex["goal"]?.value as? [String: AnyCodable])
    #expect(goal["objective"]?.value as? String == "Surface richer ACP events")
    #expect(goal["status"]?.value as? String == "in_progress")
    #expect(goal["tokenBudget"]?.value as? Int == 12000)
}

@Test("decodes tool call metadata")
func toolCallMetadata() throws {
    let env = try decode("session-update-tool-call-meta")
    guard case .toolCall(let tc) = env.params!.update else {
        Issue.record("expected toolCall")
        return
    }
    #expect(tc.toolCallId == "cmd-1")
    #expect(tc.metadata != nil)
    let meta = try #require(tc.metadata?.value as? [String: AnyCodable])
    let terminalInfo = try #require(meta["terminal_info"]?.value as? [String: AnyCodable])
    #expect(terminalInfo["terminal_id"]?.value as? String == "cmd-1")
    #expect(terminalInfo["cwd"]?.value as? String == "/repo")
}

@Test("decodes tool call update metadata and mutable fields")
func toolCallUpdateMetadata() throws {
    let env = try decode("session-update-tool-call-update-meta")
    guard case .toolCallUpdate(let update) = env.params!.update else {
        Issue.record("expected toolCallUpdate")
        return
    }
    #expect(update.toolCallId == "cmd-1")
    #expect(update.title == "swift test --filter ACP")
    #expect(update.locations?.first?.path == "AlasTests/ACP/Session/ACPSessionTests.swift")
    #expect(update.rawInput != nil)
    #expect(update.rawOutput != nil)
    #expect(update.metadata != nil)
}
```

- [ ] **Step 3: Run tests to verify failure**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPSessionUpdateTests test
```

Expected: FAIL because `ACPSessionUpdate.sessionInfoUpdate`, `metadata`, and update-time fields do not exist.

- [ ] **Step 4: Implement protocol decoding**

Update `Alas/Sources/ACP/Protocol/ACPSessionUpdate.swift`:

```swift
enum ACPSessionUpdate: Codable, Equatable {
    case userMessageChunk(ACPContentBlock)
    case agentMessageChunk(ACPContentBlock)
    case agentThoughtChunk(ACPContentBlock)
    case toolCall(ACPToolCallPayload)
    case toolCallUpdate(ACPToolCallUpdate)
    case plan([ACPPlanEntry])
    case availableModelsUpdate([ACPModelInfo])
    case currentModeUpdate(modeId: String)
    case currentModelUpdate(modelId: String)
    case sessionConfigOptionsUpdate([ACPConfigOption])
    case availableCommandsUpdate([ACPPromptSuggestion])
    case usageUpdate(ACPUsageInfo)
    case sessionInfoUpdate(ACPSessionInfoUpdate)
    case unknown(String)

    private enum Keys: String, CodingKey {
        case sessionUpdate, content, availableModels, modeId, modelId,
             entries, availableCommands, configOptions
    }
}
```

Add the decode case:

```swift
case "session_info_update":
    self = .sessionInfoUpdate(try ACPSessionInfoUpdate(from: decoder))
```

Add encode fallthrough:

```swift
case .sessionInfoUpdate:
    break
```

Add new protocol type:

```swift
struct ACPSessionInfoUpdate: Codable, Equatable {
    let title: String?
    let metadata: AnyCodable?

    private enum CodingKeys: String, CodingKey {
        case title
        case metadata = "_meta"
    }
}
```

Update tool-call payloads:

```swift
struct ACPToolCallPayload: Codable, Equatable {
    let toolCallId: String
    let title: String
    let kind: String?
    let status: String
    let content: [ACPToolCallContent]?
    let locations: [ACPToolLocation]?
    let rawInput: AnyCodable?
    let rawOutput: AnyCodable?
    let metadata: AnyCodable?

    private enum CodingKeys: String, CodingKey {
        case toolCallId, title, kind, status, content, locations, rawInput, rawOutput
        case metadata = "_meta"
    }
}

struct ACPToolCallUpdate: Codable, Equatable {
    let toolCallId: String
    let title: String?
    let status: String?
    let content: [ACPToolCallContent]?
    let locations: [ACPToolLocation]?
    let rawInput: AnyCodable?
    let rawOutput: AnyCodable?
    let metadata: AnyCodable?

    private enum CodingKeys: String, CodingKey {
        case toolCallId, title, status, content, locations, rawInput, rawOutput
        case metadata = "_meta"
    }
}
```

- [ ] **Step 5: Run tests to verify pass**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPSessionUpdateTests test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
rtk git add Alas/Sources/ACP/Protocol/ACPSessionUpdate.swift AlasTests/ACP/Protocol/ACPSessionUpdateTests.swift AlasTests/ACP/Fixtures/session-update-session-info-goal.json AlasTests/ACP/Fixtures/session-update-tool-call-meta.json AlasTests/ACP/Fixtures/session-update-tool-call-update-meta.json
rtk git commit -m "feat(acp): decode enriched session updates"
```

---

### Task 2: Persist enriched tool-call fields

**Files:**
- Modify: `Alas/Sources/ACP/Session/ACPMessage.swift`
- Modify: `AlasTests/ACP/Session/ACPMessageTests.swift`
- Modify: `AlasTests/ACP/Session/ACPMessageWireTests.swift`

- [ ] **Step 1: Add failing round-trip tests**

Add to `AlasTests/ACP/Session/ACPMessageTests.swift`:

```swift
@Test("tool call round-trips enriched fields")
func toolCallEnrichedRoundtrip() throws {
    let metadata = AnyCodable([
        "is_mcp_tool_call": AnyCodable(true),
        "terminal_info": AnyCodable([
            "terminal_id": AnyCodable("term-1"),
            "cwd": AnyCodable("/repo")
        ])
    ])
    let rawOutput = #"{"exit_code":0}"#
    let assets = [
        ACPMessage.ToolCallAsset.image(data: "abc123", uri: "/tmp/out.png", mimeType: "image/png", name: "out.png"),
        ACPMessage.ToolCallAsset.resource(uri: "/tmp/out.png", name: "out.png", mimeType: "image/png")
    ]
    let original = ACPMessage.toolCall(.init(
        toolCallId: "tc-enriched",
        title: "Image generation",
        kind: "other",
        status: "completed",
        content: "Revised prompt: a small icon",
        preview: "Revised prompt",
        contentLanguage: nil,
        rawInput: #"{"prompt":"icon"}"#,
        rawOutput: rawOutput,
        metadata: metadata,
        locations: ["/tmp/out.png"],
        terminalIds: ["term-1"],
        assets: assets
    ))

    let payload = try ACPMessageCodec.encode(original)
    let decoded = try ACPMessageCodec.decode(kind: original.kind, payload: payload)
    #expect(decoded == original)
}
```

Add to `AlasTests/ACP/Session/ACPMessageWireTests.swift`:

```swift
@Test("tool call missing enriched fields decodes with defaults")
func toolCallMissingEnrichedFieldsDecodeAsDefaults() throws {
    let payload = """
    {
      "toolCallId": "tc1",
      "title": "read",
      "kind": "fs.read",
      "status": "completed",
      "content": "abc",
      "preview": "abc",
      "locations": ["/a"],
      "terminalIds": []
    }
    """.data(using: .utf8)!
    let wire = try ACPMessageWire.decode(kind: "tool_call", payload: payload)
    guard case let .toolCall(decoded) = wire else {
        Issue.record("expected .toolCall")
        return
    }
    #expect(decoded.rawOutput == nil)
    #expect(decoded.metadata == nil)
    #expect(decoded.assets.isEmpty)
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPMessageTests -only-testing:AlasTests/ACPMessageWireTests test
```

Expected: FAIL because `rawOutput`, `metadata`, and `ToolCallAsset` do not exist.

- [ ] **Step 3: Extend `ACPMessage.ToolCall`**

In `Alas/Sources/ACP/Session/ACPMessage.swift`, add nested asset type:

```swift
struct ToolCallAsset: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Equatable, Hashable, Sendable {
        case image
        case resource
    }

    let kind: Kind
    let data: String?
    let uri: String?
    let mimeType: String?
    let name: String?

    static func image(data: String?, uri: String?, mimeType: String?, name: String?) -> Self {
        Self(kind: .image, data: data, uri: uri, mimeType: mimeType, name: name)
    }

    static func resource(uri: String, name: String?, mimeType: String?) -> Self {
        Self(kind: .resource, data: nil, uri: uri, mimeType: mimeType, name: name)
    }
}
```

Extend `ToolCall` stored properties and initializer:

```swift
var rawOutput: String?
var metadata: AnyCodable?
var assets: [ToolCallAsset]

init(toolCallId: String, title: String, kind: String? = nil,
     status: String, content: String = "", preview: String? = nil,
     contentLanguage: String? = nil, rawInput: String? = nil,
     rawOutput: String? = nil, metadata: AnyCodable? = nil,
     locations: [String] = [], terminalIds: [String] = [],
     assets: [ToolCallAsset] = [])
{
    self.toolCallId = toolCallId
    self.title = title
    self.kind = kind
    self.status = status
    self.content = content
    self.preview = preview
    self.contentLanguage = contentLanguage
    self.rawInput = rawInput
    self.rawOutput = rawOutput
    self.metadata = metadata
    self.locations = locations
    self.terminalIds = terminalIds
    self.assets = assets
}
```

Update `CodingKeys`:

```swift
case toolCallId, title, kind, status, content, preview,
     contentSummary, contentLanguage, rawInput, rawOutput,
     metadata, locations, terminalIds, assets
```

Update decode:

```swift
rawOutput = try? c.decode(String.self, forKey: .rawOutput)
metadata = try? c.decode(AnyCodable.self, forKey: .metadata)
assets = (try? c.decode([ToolCallAsset].self, forKey: .assets)) ?? []
```

Update encode:

```swift
try c.encodeIfPresent(rawOutput, forKey: .rawOutput)
try c.encodeIfPresent(metadata, forKey: .metadata)
try c.encode(assets, forKey: .assets)
```

Update equality and hash to include `rawOutput`, `metadata`, `assets`, and `terminalIds`.

- [ ] **Step 4: Run tests to verify pass**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPMessageTests -only-testing:AlasTests/ACPMessageWireTests test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
rtk git add Alas/Sources/ACP/Session/ACPMessage.swift AlasTests/ACP/Session/ACPMessageTests.swift AlasTests/ACP/Session/ACPMessageWireTests.swift
rtk git commit -m "feat(acp): persist enriched tool calls"
```

---

### Task 3: Apply session info, goal, and enriched tool-call updates

**Files:**
- Modify: `Alas/Sources/ACP/Session/ACPSession.swift`
- Modify: `AlasTests/ACP/Session/ACPSessionTests.swift`

- [ ] **Step 1: Add failing session-apply tests**

Add to `AlasTests/ACP/Session/ACPSessionTests.swift`:

```swift
@Test("session info update applies title and goal")
func sessionInfoAppliesTitleAndGoal() async {
    let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "Old")
    let metadata = AnyCodable([
        "codex": AnyCodable([
            "goal": AnyCodable([
                "objective": AnyCodable("Ship ACP enrichment"),
                "status": AnyCodable("in_progress"),
                "tokenBudget": AnyCodable(8000)
            ])
        ])
    ])

    let dirty = session.apply(.sessionInfoUpdate(.init(title: "New title", metadata: metadata)))

    #expect(dirty.isEmpty)
    #expect(session.title == "New title")
    #expect(session.currentGoal?.objective == "Ship ACP enrichment")
    #expect(session.currentGoal?.status == "in_progress")
    #expect(session.currentGoal?.tokenBudget == 8000)
}

@Test("session info update clears goal when metadata goal is null")
func sessionInfoClearsGoal() async {
    let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "Title")
    session.currentGoal = .init(objective: "Old goal", status: "in_progress", tokenBudget: nil)
    let metadata = AnyCodable([
        "codex": AnyCodable([
            "goal": AnyCodable(NSNull())
        ])
    ])

    _ = session.apply(.sessionInfoUpdate(.init(title: nil, metadata: metadata)))

    #expect(session.currentGoal == nil)
}

@Test("tool call update mutates enriched fields")
func toolCallUpdateMutatesEnrichedFields() async {
    let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
    session.apply(.toolCall(.init(
        toolCallId: "tc",
        title: "old",
        kind: "execute",
        status: "in_progress",
        content: nil,
        locations: nil,
        rawInput: nil,
        rawOutput: nil,
        metadata: nil
    )))

    let touched = session.apply(.toolCallUpdate(.init(
        toolCallId: "tc",
        title: "new title",
        status: "completed",
        content: [.content(.text("done"))],
        locations: [.init(path: "Sources/App.swift", line: 4)],
        rawInput: AnyCodable(["command": AnyCodable("swift test")]),
        rawOutput: AnyCodable(["exit_code": AnyCodable(0)]),
        metadata: AnyCodable(["is_mcp_tool_call": AnyCodable(true)])
    )))

    #expect(touched == [0])
    guard case .toolCall(let tc) = session.transcript.messages[0] else {
        Issue.record("expected tool call")
        return
    }
    #expect(tc.title == "new title")
    #expect(tc.status == "completed")
    #expect(tc.content == "done")
    #expect(tc.locations == ["Sources/App.swift"])
    #expect(tc.rawInput?.contains("swift test") == true)
    #expect(tc.rawOutput?.contains(#""exit_code":0"#) == true)
    #expect(tc.metadata != nil)
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPSessionTests test
```

Expected: FAIL because `ACPGoalState`, `currentGoal`, and enriched apply behavior do not exist.

- [ ] **Step 3: Implement goal state and apply behavior**

In `Alas/Sources/ACP/Session/ACPSession.swift`, add near session published state:

```swift
@Published var currentGoal: ACPGoalState?
```

Add near `ACPSession` nested types or file scope:

```swift
struct ACPGoalState: Equatable, Hashable {
    let objective: String
    let status: String
    let tokenBudget: Int?
}
```

Add `apply` case:

```swift
case .sessionInfoUpdate(let info):
    if let title = info.title?.trimmingCharacters(in: .whitespacesAndNewlines),
       !title.isEmpty,
       titleSource != .manual {
        self.title = title
        self.titleSource = .generated
    }
    applyGoalMetadata(info.metadata)
    return []
```

Update `.toolCall` creation:

```swift
rawInput: Self.metadataString(payload.rawInput),
rawOutput: Self.metadataString(payload.rawOutput),
metadata: payload.metadata,
locations: payload.locations?.map(\.path) ?? [],
terminalIds: Self.extractTerminalIds(items),
assets: Self.extractAssets(items)
```

Update `.toolCallUpdate` mutation:

```swift
if let title = u.title { tc.title = title }
if let s = u.status { tc.status = s }
if let locations = u.locations { tc.locations = locations.map(\.path) }
if let rawInput = u.rawInput { tc.rawInput = Self.metadataString(rawInput) }
if let rawOutput = u.rawOutput { tc.rawOutput = Self.metadataString(rawOutput) }
if let metadata = u.metadata { tc.metadata = metadata }
if let c = u.content {
    let raw = Self.flatten(c)
    let full = Self.stripWrappingFence(raw, isFinal: Self.isFinalStatus(tc.status))
    tc.content = full
    tc.preview = Self.previewLine(full)
    tc.contentLanguage = Self.wrappingFenceLanguage(raw)
    tc.terminalIds = Self.extractTerminalIds(c)
    tc.assets = Self.extractAssets(c)
}
```

Add helpers:

```swift
private func applyGoalMetadata(_ metadata: AnyCodable?) {
    guard let dict = metadata?.value as? [String: AnyCodable] else { return }
    if let directGoal = dict["goal"] {
        currentGoal = Self.goalState(from: directGoal)
        return
    }
    if let codex = dict["codex"]?.value as? [String: AnyCodable],
       let goal = codex["goal"] {
        currentGoal = Self.goalState(from: goal)
    }
}

private static func goalState(from value: AnyCodable) -> ACPGoalState? {
    if value.value is NSNull { return nil }
    guard let dict = value.value as? [String: AnyCodable],
          let objective = dict["objective"]?.value as? String,
          let status = dict["status"]?.value as? String
    else { return nil }
    let trimmed = objective.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return ACPGoalState(
        objective: trimmed,
        status: status,
        tokenBudget: dict["tokenBudget"]?.value as? Int
    )
}

private static func extractAssets(_ items: [ACPToolCallContent]) -> [ACPMessage.ToolCallAsset] {
    items.compactMap { item in
        switch item {
        case .content(.image(let data, let uri, let mimeType)):
            return .image(data: data, uri: uri, mimeType: mimeType, name: uri.map { URL(fileURLWithPath: $0).lastPathComponent })
        case .content(.resourceLink(let uri, let name)):
            return .resource(uri: uri, name: name, mimeType: nil)
        case .content(.resource(let uri, let mimeType, _)):
            return .resource(uri: uri, name: URL(fileURLWithPath: uri).lastPathComponent, mimeType: mimeType)
        default:
            return nil
        }
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPSessionTests test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
rtk git add Alas/Sources/ACP/Session/ACPSession.swift AlasTests/ACP/Session/ACPSessionTests.swift
rtk git commit -m "feat(acp): apply enriched session metadata"
```

---

### Task 4: Route terminal output metadata into retained terminal buffers

**Files:**
- Modify: `Alas/Sources/ACP/Terminal/ACPTerminal.swift`
- Modify: `Alas/Sources/ACP/Terminal/ACPTerminalHost.swift`
- Modify: `Alas/Sources/ACP/Session/ACPSession.swift`
- Modify: `AlasTests/ACP/Terminal/ACPTerminalHostTests.swift`
- Modify: `AlasTests/ACP/Session/ACPSessionTests.swift`

- [ ] **Step 1: Add failing terminal host tests**

Add to `AlasTests/ACP/Terminal/ACPTerminalHostTests.swift`:

```swift
@MainActor
@Test("metadata terminal buffers append output and publish exit")
func metadataTerminalBuffers() async throws {
    let host = ACPTerminalHost(sessionCwd: "/repo", sessionEnv: [:])

    host.recordMetadataTerminalInfo(terminalId: "term-1", cwd: "/repo/sub")
    host.appendMetadataOutput(terminalId: "term-1", data: Data("hello".utf8), replace: false)
    host.appendMetadataOutput(terminalId: "term-1", data: Data(" world".utf8), replace: false)
    host.recordMetadataExit(terminalId: "term-1", exitStatus: .init(exitCode: 0, signal: nil))

    let term = try #require(host.terminal(id: "term-1"))
    #expect(String(data: term.buffer, encoding: .utf8) == "hello world")
    #expect(term.exitStatus == .init(exitCode: 0, signal: nil))
    #expect(term.outputByteLimit == ACPTerminal.internalBufferCap)
}

@MainActor
@Test("metadata terminal replacement overwrites output")
func metadataTerminalReplacementOverwritesOutput() async throws {
    let host = ACPTerminalHost(sessionCwd: "/repo", sessionEnv: [:])

    host.appendMetadataOutput(terminalId: "term-1", data: Data("old".utf8), replace: false)
    host.appendMetadataOutput(terminalId: "term-1", data: Data("new".utf8), replace: true)

    let term = try #require(host.terminal(id: "term-1"))
    #expect(String(data: term.buffer, encoding: .utf8) == "new")
}
```

- [ ] **Step 2: Add failing session metadata routing test**

Add to `AlasTests/ACP/Session/ACPSessionTests.swift`:

```swift
@Test("tool call metadata routes terminal output and exit")
func toolCallMetadataRoutesTerminalOutput() async throws {
    let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
    session.apply(.toolCall(.init(
        toolCallId: "cmd-1",
        title: "swift test",
        kind: "execute",
        status: "in_progress",
        content: [.terminal(terminalId: "cmd-1")],
        locations: nil,
        rawInput: nil,
        rawOutput: nil,
        metadata: AnyCodable([
            "terminal_info": AnyCodable([
                "terminal_id": AnyCodable("cmd-1"),
                "cwd": AnyCodable("/repo")
            ])
        ])
    )))
    session.apply(.toolCallUpdate(.init(
        toolCallId: "cmd-1",
        title: nil,
        status: "completed",
        content: nil,
        locations: nil,
        rawInput: nil,
        rawOutput: nil,
        metadata: AnyCodable([
            "terminal_output_delta": AnyCodable([
                "terminal_id": AnyCodable("cmd-1"),
                "data": AnyCodable("ok\n")
            ]),
            "terminal_exit": AnyCodable([
                "terminal_id": AnyCodable("cmd-1"),
                "exit_code": AnyCodable(0),
                "signal": AnyCodable(NSNull())
            ])
        ])
    )))

    let term = try #require(session.terminalHost.terminal(id: "cmd-1"))
    #expect(String(data: term.buffer, encoding: .utf8) == "ok\n")
    #expect(term.exitStatus == .init(exitCode: 0, signal: nil))
}
```

- [ ] **Step 3: Run tests to verify failure**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPTerminalHostTests -only-testing:AlasTests/ACPSessionTests/toolCallMetadataRoutesTerminalOutput test
```

Expected: FAIL because metadata-backed terminal APIs do not exist.

- [ ] **Step 4: Add metadata terminal support**

In `Alas/Sources/ACP/Terminal/ACPTerminal.swift`, add a metadata initializer and mutation methods. Because existing process-backed stored properties are non-optional, make `process` and `pipe` optional and guard process-only operations.

Change properties:

```swift
private let process: Process?
private let pipe: Pipe?
```

Set them in the existing initializer:

```swift
self.process = Process()
self.pipe = Pipe()
guard let process, let pipe else { fatalError("process terminal requires process and pipe") }
```

Add metadata initializer:

```swift
init(metadataId id: String, cwd: String?, outputByteLimit: Int = ACPTerminal.internalBufferCap) {
    self.id = id
    self.createdAt = Date()
    self.outputByteLimit = max(1, min(outputByteLimit, Self.internalBufferCap))
    self.process = nil
    self.pipe = nil
}
```

Add methods:

```swift
func appendMetadataOutput(_ data: Data, replace: Bool) {
    if replace {
        buffer.removeAll(keepingCapacity: true)
        truncated = false
    }
    appendChunk(data)
}

func finishMetadata(exitStatus status: ACPTerminalExitStatus) {
    guard exitStatus == nil else { return }
    exitStatus = status
    for waiter in exitWaiters {
        waiter.resume(returning: status)
    }
    exitWaiters.removeAll()
    onExit?()
}
```

Update `kill()` to no-op for metadata terminals:

```swift
guard let process else { return }
```

- [ ] **Step 5: Add host APIs**

In `Alas/Sources/ACP/Terminal/ACPTerminalHost.swift`, add:

```swift
func recordMetadataTerminalInfo(terminalId: String, cwd: String?) {
    _ = metadataTerminal(id: terminalId, cwd: cwd)
}

func appendMetadataOutput(terminalId: String, data: Data, replace: Bool) {
    let term = metadataTerminal(id: terminalId, cwd: nil)
    term.appendMetadataOutput(data, replace: replace)
}

func recordMetadataExit(terminalId: String, exitStatus: ACPTerminalExitStatus) {
    let term = metadataTerminal(id: terminalId, cwd: nil)
    term.finishMetadata(exitStatus: exitStatus)
    pruneFinishedTerminals()
}

private func metadataTerminal(id: String, cwd: String?) -> ACPTerminal {
    if let existing = terminals[id] { return existing }
    let term = ACPTerminal(metadataId: id, cwd: cwd)
    term.onExit = { [weak self] in self?.pruneFinishedTerminals() }
    terminals[id] = term
    return term
}
```

- [ ] **Step 6: Route metadata in session apply**

In `Alas/Sources/ACP/Session/ACPSession.swift`, call after creating/updating tool calls:

```swift
applyToolCallMetadata(payload.metadata)
```

and:

```swift
if let metadata = u.metadata {
    tc.metadata = metadata
    applyToolCallMetadata(metadata)
}
```

Add helper:

```swift
private func applyToolCallMetadata(_ metadata: AnyCodable?) {
    guard let dict = metadata?.value as? [String: AnyCodable] else { return }
    if let info = dict["terminal_info"]?.value as? [String: AnyCodable],
       let id = info["terminal_id"]?.value as? String {
        terminalHost.recordMetadataTerminalInfo(
            terminalId: id,
            cwd: info["cwd"]?.value as? String
        )
    }
    if let output = dict["terminal_output"]?.value as? [String: AnyCodable],
       let id = output["terminal_id"]?.value as? String,
       let data = output["data"]?.value as? String {
        terminalHost.appendMetadataOutput(terminalId: id, data: Data(data.utf8), replace: true)
    }
    if let output = dict["terminal_output_delta"]?.value as? [String: AnyCodable],
       let id = output["terminal_id"]?.value as? String,
       let data = output["data"]?.value as? String {
        terminalHost.appendMetadataOutput(terminalId: id, data: Data(data.utf8), replace: false)
    }
    if let exit = dict["terminal_exit"]?.value as? [String: AnyCodable],
       let id = exit["terminal_id"]?.value as? String {
        let status = ACPTerminalExitStatus(
            exitCode: exit["exit_code"]?.value as? Int,
            signal: exit["signal"]?.value as? String
        )
        terminalHost.recordMetadataExit(terminalId: id, exitStatus: status)
    }
}
```

- [ ] **Step 7: Run tests to verify pass**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPTerminalHostTests -only-testing:AlasTests/ACPSessionTests test
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
rtk git add Alas/Sources/ACP/Terminal/ACPTerminal.swift Alas/Sources/ACP/Terminal/ACPTerminalHost.swift Alas/Sources/ACP/Session/ACPSession.swift AlasTests/ACP/Terminal/ACPTerminalHostTests.swift AlasTests/ACP/Session/ACPSessionTests.swift
rtk git commit -m "feat(acp): render terminal metadata output"
```

---

### Task 5: Add bridge-neutral tool-call presentation resolver

**Files:**
- Create: `Alas/Sources/ACP/UI/ACPToolCallPresentation.swift`
- Modify: `Alas/Sources/ACP/UI/ACPToolCallCard.swift`
- Create: `AlasTests/ACP/UI/ACPToolCallPresentationTests.swift`

- [ ] **Step 1: Add failing presentation tests**

Create `AlasTests/ACP/UI/ACPToolCallPresentationTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

@Suite("ACPToolCallPresentation")
struct ACPToolCallPresentationTests {
    @Test("classifies web search")
    func webSearch() {
        let tc = ACPMessage.ToolCall(toolCallId: "web", title: "Web search: swift testing", kind: "search", status: "completed")
        let presentation = ACPToolCallPresentation.resolve(tc)
        #expect(presentation.label == "Web Search")
        #expect(presentation.iconSystemName == "globe")
        #expect(presentation.style == .webSearch)
    }

    @Test("classifies open page")
    func openPage() {
        let tc = ACPMessage.ToolCall(toolCallId: "open", title: "Open page: https://example.com", kind: "search", status: "completed")
        let presentation = ACPToolCallPresentation.resolve(tc)
        #expect(presentation.label == "Opened Page")
        #expect(presentation.iconSystemName == "safari")
        #expect(presentation.style == .webSearch)
    }

    @Test("classifies image generation")
    func imageGeneration() {
        let tc = ACPMessage.ToolCall(
            toolCallId: "img",
            title: "Image generation",
            kind: "other",
            status: "completed",
            assets: [.image(data: "abc", uri: "/tmp/out.png", mimeType: "image/png", name: "out.png")]
        )
        let presentation = ACPToolCallPresentation.resolve(tc)
        #expect(presentation.label == "Image")
        #expect(presentation.iconSystemName == "photo")
        #expect(presentation.style == .image)
    }

    @Test("classifies image view")
    func imageView() {
        let tc = ACPMessage.ToolCall(
            toolCallId: "view",
            title: "View Image /tmp/out.png",
            kind: "read",
            status: "completed",
            assets: [.resource(uri: "/tmp/out.png", name: "out.png", mimeType: "image/png")]
        )
        let presentation = ACPToolCallPresentation.resolve(tc)
        #expect(presentation.label == "Viewed Image")
        #expect(presentation.style == .image)
    }

    @Test("classifies MCP calls")
    func mcpCall() {
        let tc = ACPMessage.ToolCall(
            toolCallId: "mcp",
            title: "mcp.github.fetch_issue",
            kind: "execute",
            status: "completed",
            metadata: AnyCodable(["is_mcp_tool_call": AnyCodable(true)])
        )
        let presentation = ACPToolCallPresentation.resolve(tc)
        #expect(presentation.label == "MCP")
        #expect(presentation.iconSystemName == "point.3.connected.trianglepath.dotted")
        #expect(presentation.style == .mcp)
    }

    @Test("classifies review thinking")
    func guardianReview() {
        let tc = ACPMessage.ToolCall(toolCallId: "review", title: "Guardian Review", kind: "think", status: "completed")
        let presentation = ACPToolCallPresentation.resolve(tc)
        #expect(presentation.label == "Review")
        #expect(presentation.iconSystemName == "checkmark.shield")
        #expect(presentation.style == .review)
    }

    @Test("keeps existing execute fallback")
    func executeFallback() {
        let tc = ACPMessage.ToolCall(toolCallId: "run", title: "swift test", kind: "execute", status: "completed")
        let presentation = ACPToolCallPresentation.resolve(tc)
        #expect(presentation.label == "Ran")
        #expect(presentation.iconSystemName == "terminal")
        #expect(presentation.style == .generic)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPToolCallPresentationTests test
```

Expected: FAIL because `ACPToolCallPresentation` does not exist.

- [ ] **Step 3: Implement resolver**

Create `Alas/Sources/ACP/UI/ACPToolCallPresentation.swift`:

```swift
import Foundation

struct ACPToolCallPresentation: Equatable {
    enum Style: Equatable {
        case generic
        case webSearch
        case image
        case mcp
        case review
    }

    let label: String
    let iconSystemName: String
    let style: Style

    static func resolve(_ toolCall: ACPMessage.ToolCall) -> Self {
        let title = toolCall.title
        let lowerTitle = title.lowercased()
        let lowerKind = toolCall.kind?.lowercased()

        if lowerKind == "search", lowerTitle.hasPrefix("web search") {
            return .init(label: "Web Search", iconSystemName: "globe", style: .webSearch)
        }
        if lowerKind == "search", lowerTitle.hasPrefix("open page") {
            return .init(label: "Opened Page", iconSystemName: "safari", style: .webSearch)
        }
        if lowerKind == "search", lowerTitle.hasPrefix("find in page") {
            return .init(label: "Find", iconSystemName: "text.magnifyingglass", style: .webSearch)
        }
        if lowerTitle == "image generation", toolCall.assets.contains(where: { $0.kind == .image }) || toolCall.rawOutput?.contains("result") == true {
            return .init(label: "Image", iconSystemName: "photo", style: .image)
        }
        if lowerKind == "read", toolCall.assets.contains(where: { asset in
            asset.kind == .image || asset.mimeType?.hasPrefix("image/") == true || asset.uri.map(isImagePath) == true
        }) {
            return .init(label: "Viewed Image", iconSystemName: "photo.on.rectangle", style: .image)
        }
        if isMCP(toolCall) {
            return .init(label: "MCP", iconSystemName: "point.3.connected.trianglepath.dotted", style: .mcp)
        }
        if lowerKind == "think" || lowerTitle == "guardian review" {
            return .init(label: "Review", iconSystemName: "checkmark.shield", style: .review)
        }

        switch lowerKind {
        case "read":
            return .init(label: "Read", iconSystemName: "doc.text", style: .generic)
        case "search":
            return .init(label: "Searched", iconSystemName: "magnifyingglass", style: .generic)
        case "execute", "run":
            return .init(label: "Ran", iconSystemName: "terminal", style: .generic)
        case "edit":
            return .init(label: "Edit", iconSystemName: "pencil", style: .generic)
        default:
            return .init(label: toolCall.kind?.capitalized ?? "Tool", iconSystemName: "gearshape", style: .generic)
        }
    }

    private static func isMCP(_ toolCall: ACPMessage.ToolCall) -> Bool {
        if toolCall.title.hasPrefix("mcp.") || toolCall.title.hasPrefix("mcp__") {
            return true
        }
        guard let metadata = toolCall.metadata?.value as? [String: AnyCodable] else { return false }
        return metadata["is_mcp_tool_call"]?.value as? Bool == true
    }

    private static func isImagePath(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext)
    }
}
```

- [ ] **Step 4: Update `ACPToolCallCard` to use resolver**

In `Alas/Sources/ACP/UI/ACPToolCallCard.swift`, add:

```swift
private var presentation: ACPToolCallPresentation {
    ACPToolCallPresentation.resolve(toolCall)
}
```

Change label text:

```swift
Text(presentation.label)
```

Change `iconSystemName` to:

```swift
private var iconSystemName: String {
    presentation.iconSystemName
}
```

Remove or stop using the old `verb` switch. When checking whether to render the title chip, compare against `presentation.label`:

```swift
if !toolCall.title.isEmpty && toolCall.title.lowercased() != presentation.label.lowercased() {
    FileChip(path: toolCall.title, lines: nil, iconSystemName: nil)
}
```

- [ ] **Step 5: Run tests to verify pass**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPToolCallPresentationTests test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
rtk git add Alas/Sources/ACP/UI/ACPToolCallPresentation.swift Alas/Sources/ACP/UI/ACPToolCallCard.swift AlasTests/ACP/UI/ACPToolCallPresentationTests.swift
rtk git commit -m "feat(acp): classify tool call presentation"
```

---

### Task 6: Render image assets in tool-call cards

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPToolCallCard.swift`
- Modify: `AlasTests/ACP/Session/ACPSessionTests.swift`

- [ ] **Step 1: Add failing image preservation test**

Add to `AlasTests/ACP/Session/ACPSessionTests.swift`:

```swift
@Test("tool call image content is preserved as an asset")
func toolCallImageContentPreserved() async {
    let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")

    session.apply(.toolCall(.init(
        toolCallId: "img",
        title: "Image generation",
        kind: "other",
        status: "completed",
        content: [.content(.image(data: "base64-image", uri: "/tmp/out.png", mimeType: "image/png"))],
        locations: nil,
        rawInput: nil,
        rawOutput: nil,
        metadata: nil
    )))

    guard case .toolCall(let tc) = session.transcript.messages[0] else {
        Issue.record("expected tool call")
        return
    }
    #expect(tc.assets == [.image(data: "base64-image", uri: "/tmp/out.png", mimeType: "image/png", name: "out.png")])
    #expect(tc.preview == nil)
}
```

- [ ] **Step 2: Run test to verify current behavior**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPSessionTests/toolCallImageContentPreserved test
```

Expected: PASS if Task 3 already extracts assets; FAIL if the image asset extraction still needs adjustment. If it fails because the generated `name` is wrong for absolute paths, update `extractAssets(_:)` to use `URL(fileURLWithPath: uri).lastPathComponent`.

- [ ] **Step 3: Add image rendering helpers**

In `Alas/Sources/ACP/UI/ACPToolCallCard.swift`, add to `expandedBody` after text content and before terminal tails:

```swift
if !toolCall.assets.isEmpty {
    ToolCallAssetsView(assets: toolCall.assets)
}
```

Add local views at the bottom of the file:

```swift
private struct ToolCallAssetsView: View {
    let assets: [ACPMessage.ToolCallAsset]
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(assets.enumerated()), id: \.offset) { _, asset in
                switch asset.kind {
                case .image:
                    ToolCallImageAssetView(asset: asset)
                case .resource:
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
                        Text(asset.name ?? asset.uri ?? "Resource")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("fg-muted"))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.color("bg-0").opacity(0.55))
    }
}

private struct ToolCallImageAssetView: View {
    let asset: ACPMessage.ToolCallAsset
    @Environment(\.theme) private var theme

    var body: some View {
        if let image = image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 360, maxHeight: 260, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.5))
        } else {
            HStack(spacing: 6) {
                Image(systemName: "photo")
                Text(asset.name ?? asset.uri ?? "Image unavailable")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.color("fg-faint"))
        }
    }

    private var image: NSImage? {
        if let data = asset.data,
           let decoded = Data(base64Encoded: data),
           let nsImage = NSImage(data: decoded) {
            return nsImage
        }
        if let uri = asset.uri {
            let url = URL(fileURLWithPath: uri)
            return NSImage(contentsOf: url)
        }
        return nil
    }
}
```

- [ ] **Step 4: Build targeted UI code**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
rtk git add Alas/Sources/ACP/UI/ACPToolCallCard.swift AlasTests/ACP/Session/ACPSessionTests.swift
rtk git commit -m "feat(acp): render tool call image assets"
```

---

### Task 7: Surface current goal in the ACP toolbar

**Files:**
- Create: `Alas/Sources/ACP/UI/ACPGoalPill.swift`
- Modify: `Alas/Sources/ACP/UI/ACPToolbar.swift`
- Create: `AlasTests/ACP/UI/ACPGoalPillTests.swift`

- [ ] **Step 1: Add failing copy tests**

Create `AlasTests/ACP/UI/ACPGoalPillTests.swift`:

```swift
import Testing
@testable import Alas

@Suite("ACPGoalPill")
struct ACPGoalPillTests {
    @Test("summarizes goal with status and budget")
    func summaryWithStatusAndBudget() {
        let goal = ACPGoalState(objective: "Surface richer events", status: "in_progress", tokenBudget: 12000)
        #expect(ACPGoalPill.summary(goal) == "Goal: Surface richer events · in progress · 12k")
    }

    @Test("truncates long objective")
    func summaryTruncatesLongObjective() {
        let goal = ACPGoalState(objective: String(repeating: "x", count: 90), status: "completed", tokenBudget: nil)
        #expect(ACPGoalPill.summary(goal).hasPrefix("Goal: \(String(repeating: "x", count: 60))…"))
        #expect(ACPGoalPill.summary(goal).hasSuffix("completed"))
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPGoalPillTests test
```

Expected: FAIL because `ACPGoalPill` does not exist.

- [ ] **Step 3: Implement goal pill**

Create `Alas/Sources/ACP/UI/ACPGoalPill.swift`:

```swift
import SwiftUI

struct ACPGoalPill: View {
    let goal: ACPGoalState
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "target")
                .font(.system(size: 10, weight: .semibold))
            Text(Self.summary(goal))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(theme.color("fg-muted"))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.color("bg-1").opacity(0.7))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(theme.color("line"), lineWidth: 0.5))
    }

    static func summary(_ goal: ACPGoalState) -> String {
        let objective = goal.objective.count > 60
            ? String(goal.objective.prefix(60)) + "…"
            : goal.objective
        var parts = ["Goal: \(objective)", statusLabel(goal.status)]
        if let tokenBudget = goal.tokenBudget {
            parts.append(tokenBudgetLabel(tokenBudget))
        }
        return parts.joined(separator: " · ")
    }

    private static func statusLabel(_ status: String) -> String {
        switch status {
        case "in_progress": return "in progress"
        default: return status.replacingOccurrences(of: "_", with: " ")
        }
    }

    private static func tokenBudgetLabel(_ value: Int) -> String {
        if value >= 1000, value % 1000 == 0 {
            return "\(value / 1000)k"
        }
        if value >= 1000 {
            return String(format: "%.1fk", Double(value) / 1000.0)
        }
        return "\(value)"
    }
}
```

- [ ] **Step 4: Render in toolbar**

In `Alas/Sources/ACP/UI/ACPToolbar.swift`, add after `ACPRecoveryPill(session:)`:

```swift
if let goal = session.currentGoal {
    ACPGoalPill(goal: goal)
        .layoutPriority(1)
}
```

- [ ] **Step 5: Run tests and build**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPGoalPillTests test
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: both PASS.

- [ ] **Step 6: Commit**

```bash
rtk git add Alas/Sources/ACP/UI/ACPGoalPill.swift Alas/Sources/ACP/UI/ACPToolbar.swift AlasTests/ACP/UI/ACPGoalPillTests.swift
rtk git commit -m "feat(acp): surface current goal"
```

---

### Task 8: Final verification and cleanup

**Files:**
- Inspect all files changed by Tasks 1-7.

- [ ] **Step 1: Run full project generation**

Run:

```bash
rtk xcodegen
```

Expected: completes successfully. If `project.yml` was not edited, `Alas.xcodeproj` should either be unchanged or have no meaningful diff.

- [ ] **Step 2: Run lightweight local build smoke only if the machine can handle it**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: build succeeds when local resources allow it. If the laptop is under memory pressure or the build stalls, stop the local build and rely on GitHub Actions for the full authoritative build/test gate.

- [ ] **Step 3: Push a PR and use CI as the full verification gate**

Run:

```bash
rtk git fetch origin
rtk git rebase origin/main
rtk git push -u origin HEAD
```

Open a pull request for the current branch. Then monitor GitHub Actions and treat CI as the required full build/test verification. Do not run the full local test suite on a resource-constrained laptop unless CI is unavailable.

- [ ] **Step 4: Loop on CI and PR review feedback**

Use GitHub Actions logs for any failed checks. Fix the cause, commit the fix, push, and repeat until CI is green.

If the PR receives an automated Codex review, inspect the review comments. Address actionable feedback, commit fixes, push, and repeat until the review is approving or has no requested changes.

- [ ] **Step 5: Inspect diff for accidental scope creep**

Run:

```bash
rtk git diff --stat HEAD
rtk git diff HEAD -- Alas/Sources/ACP AlasTests/ACP docs/superpowers/plans/2026-07-03-acp-transcript-event-enrichment.md
```

Expected: changes are limited to ACP protocol/session/terminal/UI and ACP tests. No filesystem boundary expansion, provider-specific Codex UI branch, or attribution footer is present.

- [ ] **Step 6: Commit any final cleanup**

If Step 5 required cleanup, commit it:

```bash
rtk git add Alas/Sources/ACP AlasTests/ACP Alas.xcodeproj docs/superpowers/plans/2026-07-03-acp-transcript-event-enrichment.md
rtk git commit -m "test(acp): verify transcript event enrichment"
```

If there is no cleanup diff, do not create an empty commit.
