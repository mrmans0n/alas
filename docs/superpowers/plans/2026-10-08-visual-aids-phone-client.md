# Visual Aids in the Phone Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render ACP visual aids in the phone web client, let the user answer or dismiss their question there, and stop sending the raw `visual_show` HTML to the phone as text.

**Architecture:** The gateway projects `.visualAid` as a visible `visualAid` row (title as fallback text, a DTO in `json`) and scrubs the HTML-bearing fields of the `visual_show` tool-call row. A new `visualAidResponse` client message is validated by the gateway and routed through `RemoteSessionsProvider` and `AppState` to `ACPSessionManager.answerVisualAid`. The phone renders each visual in a `sandbox="allow-scripts"` `srcdoc` iframe built by a pure `visual-aid.js` module (CSP injected first, lockdown and height bridge scripts), with phone-native answer controls under an inert frame for question visuals.

**Tech Stack:** Swift 5.9+ (Swift Testing, WebKit in tests), plain JavaScript (classic scripts, Node `assert` tests), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-08-visual-aids-phone-client-design.md`

## Global Constraints

- Keep code, comments, logs and UI strings in English. Conventional Commits. No agent attribution anywhere.
- Tests use Swift Testing (`import Testing`). Extend the named existing suites (`RemoteSessionGatewayTests`, `RemoteProtocolTests`, `RemoteWebAssetTests`). New Node runner only for the pure module.
- Before EVERY commit run `swiftformat Alas AlasTests --lint` and require `0/NNNN files require formatting` (CI runs it first and a failure skips everything after it). No semicolons: never `a; b` on one line.
- Every `xcodebuild`: `-derivedDataPath /tmp/dd-verify -skipPackagePluginValidation -skipMacroValidation`. If the default DerivedData is used, package resolution can hang for an hour. If the persistent bash tool wedges, use the eval tool with subprocess.
- Only ONE `xcodebuild` may run at a time (shared DerivedData). Task 3 is Node-only and may run beside a Swift task.
- After adding any Swift file run `xcodegen` and commit `project.yml` and `Alas.xcodeproj` if they changed. This plan adds no Swift files.
- Wire contract, verbatim: row `kind` is `"visualAid"`; client message `{"type":"visualAidResponse","sessionId":S,"visualId":V,"action":"answer"|"dismiss","selectedOptionIds":[...],"note":"..."?}`; server message `{"type":"visualAidRejected","sessionId":S,"visualId":V,"reason":R}` with `R` one of `notWriter`, `notFound`, `alreadyAnswered`, `invalid`, `failed`. `RemoteProtocolVersion.current` stays 1.
- CSP, verbatim and identical to `VisualAidWebPolicy.contentSecurityPolicy`: `default-src 'none'; script-src 'unsafe-inline' https:; style-src 'unsafe-inline' https:; img-src data: blob: https:; font-src data: https:; connect-src 'none'; frame-src 'none'; worker-src 'none'; form-action 'none'; base-uri 'none'`
- Iframe sandbox is exactly `allow-scripts`. `allow-same-origin` must not appear anywhere under `Alas/Resources/RemoteWeb/` (the page's bearer token is in `localStorage` and `/ws` is same-origin).
- Limits: frame height clamped 120 to 720 px; note at most 2000 characters (`ACPVisualAidQuestionForm.noteMaxLength`); at most 3 live iframes.
- Error strings, verbatim: `Couldn't send your answer. Try again.`; `Take over to answer`; `Visual paused to save memory`; `Show visual`.
- Focused Swift test command (replace suites):

  ```bash
  xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
    -derivedDataPath /tmp/dd-verify -skipPackagePluginValidation -skipMacroValidation \
    -only-testing AlasTests/<Suite> test
  ```

  Check the `Test run with N tests in M suites` line; a misspelled suite runs nothing and still passes.
- Node runner: `bash scripts/tests/remote-web-visual-aid/run.sh`.

## Review Focus

1. A full HTML document whose attribute or script text contains `<head>` (`<html data-note="<head>">`) must come out of `buildDocument` unmangled with the CSP `<meta>` as the first child of the real `<head>`. Pinned in Task 4 with a real WebKit `DOMParser`.
2. A visual's script that posts a height with another card's id, or from a different window, must not change any card's height (`event.source` and id both checked). Pinned in Task 3.
3. An answer with a duplicate option id, an unknown id, no choice, two choices without `allowMultiple`, or a 2001-character note is rejected with `invalid` and the manager is never called. Pinned in Task 2.
4. A delta that only changes `answer` must not recreate the iframe (it would reload and lose the page). Pinned in Task 4.
5. A question visual's iframe is `inert` and `sandbox` never contains `allow-same-origin`. Pinned in Task 4.

---

### Task 1: Project visual aids on the wire and scrub the tool-call HTML

**Files:**
- Modify: `Alas/Sources/Remote/Protocol/RemoteMessageWireJSON.swift` (new `RemoteVisualAid` DTO; update the `kind` comment at line 8)
- Modify: `Alas/Sources/Remote/Gateway/RemoteSessionGateway.swift` (`toWire` `.visualAid` case ~1331; `remoteToolCall` ~1338; the `cachedFullToolCallContent` call site in `wireMessage` ~828-848)
- Modify: `Alas/Sources/ACP/UI/ACPToolCallPresentation.swift` (extract the `visual_show` match)
- Test: `AlasTests/Remote/RemoteSessionGatewayTests.swift`

**Interfaces:**
- Produces: `struct RemoteVisualAid: Codable, Equatable, Sendable` with `init(_ visual: ACPVisualAid)`; `static func ACPToolCallPresentation.isVisualShow(_ toolCall: ACPMessage.ToolCall) -> Bool`. Row shape: `kind: "visualAid"`, `text: title`, `json: encodeJSON(RemoteVisualAid)`, not hidden.
- DTO JSON: `{"id","title","html","question"?:{"prompt","options":[{"id","label"}],"allowMultiple"},"answer"?:{"kind":"answered"|"dismissed","selectedOptionIds"?:[...],"note"?:...}}`. The timestamp is not sent.

- [ ] **Step 1: Write the failing tests**

Add to `RemoteSessionGatewayTests` (use the existing `FakeSessionsProvider`, `makeManager()` and the `sent` closure pattern):

```swift
    private func makeVisual(answer: ACPVisualAid.Answer? = nil) -> ACPVisualAid {
        ACPVisualAid(
            id: UUID(uuidString: "6F0C2D4E-8B1A-4C3D-9E5F-1A2B3C4D5E6F")!,
            title: "Layouts", html: "<h2>Pick</h2>",
            question: .init(prompt: "Which?", options: [.init(id: "a", label: "One"), .init(id: "b", label: "Two")], allowMultiple: false),
            answer: answer, createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test func visualAidRowIsVisibleWithTitleAndStructuredJSON() throws {
        let visual = makeVisual()
        let wire = RemoteSessionGateway.toWire(.visualAid(visual), index: 3)
        #expect(wire.kind == "visualAid")
        #expect(wire.text == "Layouts")
        #expect(wire.isHidden != true)
        #expect(wire.stableId == "m3")
        let dto = try JSONDecoder().decode(RemoteVisualAid.self, from: Data(try #require(wire.json).utf8))
        #expect(dto.id == visual.id.uuidString)
        #expect(dto.html == "<h2>Pick</h2>")
        #expect(dto.question?.options.map(\.id) == ["a", "b"])
        #expect(dto.answer == nil)
    }

    @Test func visualAidAnswerDTOOmitsTheTimestamp() throws {
        let answered = RemoteVisualAid(makeVisual(answer: .answered(selectedOptionIds: ["b"], note: "ok", at: Date(timeIntervalSince1970: 9))))
        #expect(answered.answer == .init(kind: "answered", selectedOptionIds: ["b"], note: "ok"))
        let dismissed = RemoteVisualAid(makeVisual(answer: .dismissed(at: Date())))
        #expect(dismissed.answer == .init(kind: "dismissed", selectedOptionIds: nil, note: nil))
    }

    @Test(arguments: ["mcp__alas__visual_show", "visual_show"])
    func visualShowToolCallIsScrubbedOnTheWire(name: String) throws {
        let call = ACPMessage.ToolCall(
            toolCallId: "t1", title: "Show visual", status: "completed",
            content: "<h2>secret</h2>", rawInput: #"{"html":"<h2>secret</h2>"}"#, preview: "<h2>secret</h2>", name: name)
        let wire = RemoteSessionGateway.toWire(.toolCall(call), index: 0)
        let json = try #require(wire.json)
        #expect(!json.contains("secret"))
        let decoded = try JSONDecoder().decode(ACPMessage.ToolCall.self, from: Data(json.utf8))
        #expect(decoded.title == "Show visual")
        #expect(decoded.status == "completed")
    }

    @Test func ordinaryToolCallKeepsItsContent() throws {
        let call = ACPMessage.ToolCall(toolCallId: "t1", title: "Run", status: "completed", content: "output", name: "Bash")
        let wire = RemoteSessionGateway.toWire(.toolCall(call), index: 0)
        #expect(try #require(wire.json).contains("output"))
    }
```

Add a snapshot-and-delta test with the continuation pattern the file already uses (see the `path == "delta"` test near line 934):

```swift
    @Test func answeringAVisualUpdatesTheSameRowThroughADelta() async throws {
        let provider = FakeSessionsProvider()
        let s = try makeSessionWithAgentText("hi")
        let visual = makeVisual()
        s.transcript.appendMessage(.visualAid(visual))
        provider.sessions["s1"] = s
        var sent: [RemoteServerMessage] = []
        var nextDelta: CheckedContinuation<RemoteServerMessage, Never>?
        let gw = RemoteSessionGateway(provider: provider) { frame in
            sent.append(frame)
            if case .transcriptDelta = frame, let waiter = nextDelta {
                nextDelta = nil
                waiter.resume(returning: frame)
            }
        }
        await gw.handle(.subscribe(sessionId: "s1"))
        let snapshot = sent.compactMap { msg -> [RemoteWireMessage]? in
            if case .transcriptSnapshot(_, _, _, let m, _, _, _, _, _) = msg { return m }
            return nil
        }.first
        #expect(snapshot?.last?.kind == "visualAid")
        let index = try #require(snapshot?.last?.index)

        var answered = visual
        answered.answer = .dismissed(at: Date())
        let frame = await withCheckedContinuation { nextDelta = $0
            s.transcript.replaceMessage(at: index, with: .visualAid(answered)) }
        guard case .transcriptDelta(_, _, _, let upserts, _, _, _) = frame else { Issue.record("expected delta"); return }
        #expect(upserts.count == 1)
        #expect(upserts[0].index == index)
        #expect(upserts[0].kind == "visualAid")
        let dto = try JSONDecoder().decode(RemoteVisualAid.self, from: Data(try #require(upserts[0].json).utf8))
        #expect(dto.answer?.kind == "dismissed")
    }

    @Test func oversizedVisualBecomesTheTooLargeNoticeAtItsPosition() throws {
        var visual = makeVisual()
        visual = ACPVisualAid(id: visual.id, title: visual.title, html: String(repeating: "x", count: 5 * 1024 * 1024),
                              question: nil, answer: nil, createdAt: Date())
        let wire = RemoteSessionGateway.toWire(.visualAid(visual), index: 7)
        let bounded = wire.boundedForTransport(maximumBytes: RemoteTranscriptSync.maxMessageBytes).message
        #expect(bounded.kind == "systemNotice")
        #expect(bounded.index == 7)
        #expect(bounded.stableId == "m7")
    }
```

If `toWire` is not accessible from the test target as `RemoteSessionGateway.toWire(_:index:)`, use the existing way other tests reach it (`@testable import Alas` is already in this file). Adapt the `ToolCall` initializer labels to the real memberwise init (`rawInput`, `preview`, `name` exist on `ACPMessage.ToolCall`; check `ACPMessage.swift` ~lines 210-290).

- [ ] **Step 2: Run to verify failure**

Run the focused command with `-only-testing AlasTests/RemoteSessionGatewayTests`.
Expected: compile errors (`RemoteVisualAid` not defined), then failures once it exists.

- [ ] **Step 3: Add the DTO**

In `RemoteMessageWireJSON.swift`, extend the `kind` comment to include `"visualAid"` and add:

```swift
/// A visual aid as the phone receives it in `RemoteWireMessage.json`. The
/// answer timestamp stays on the Mac; the phone needs only what it shows.
struct RemoteVisualAid: Codable, Equatable, Sendable {
    struct Option: Codable, Equatable, Sendable {
        let id: String
        let label: String
    }

    struct Question: Codable, Equatable, Sendable {
        let prompt: String
        let options: [Option]
        let allowMultiple: Bool
    }

    struct Answer: Codable, Equatable, Sendable {
        let kind: String
        let selectedOptionIds: [String]?
        let note: String?
    }

    let id: String
    let title: String
    let html: String
    let question: Question?
    let answer: Answer?

    init(_ visual: ACPVisualAid) {
        id = visual.id.uuidString
        title = visual.title
        html = visual.html
        question = visual.question.map { question in
            Question(
                prompt: question.prompt,
                options: question.options.map { Option(id: $0.id, label: $0.label) },
                allowMultiple: question.allowMultiple)
        }
        switch visual.answer {
        case .answered(let ids, let note, _):
            answer = Answer(kind: "answered", selectedOptionIds: ids, note: note)
        case .dismissed:
            answer = Answer(kind: "dismissed", selectedOptionIds: nil, note: nil)
        case nil:
            answer = nil
        }
    }
}
```

- [ ] **Step 4: Project the row**

In `toWire` replace the hidden `.visualAid` case:

```swift
        case .visualAid(let visual):
            // Without json the phone falls back to a plain-text row with the title.
            return .init(
                stableId: sid, kind: "visualAid", text: visual.title,
                json: Self.encodeJSON(RemoteVisualAid(visual)), index: index)
```

- [ ] **Step 5: Scrub the tool call**

In `ACPToolCallPresentation`, extract the rule `resolve` already uses (keep its exact asymmetry: `name` is case-sensitive, `title` is lowercased) and call it from `resolve`:

```swift
    /// A `visual_show` call: the rule `resolve` labels "Visual aid". The call's
    /// content and raw input carry the visual's HTML.
    static func isVisualShow(_ toolCall: ACPMessage.ToolCall) -> Bool {
        let lowerTitle = toolCall.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return toolCall.nonEmptyName?.contains("visual_show") == true || lowerTitle.contains("visual_show")
    }
```

In `remoteToolCall`, after the existing scrubbing, blank every HTML-bearing field for these calls:

```swift
        if ACPToolCallPresentation.isVisualShow(remote) {
            remote.content = ""
            remote.rawInput = nil
            remote.preview = nil
        }
```

(adapt types: `preview` and `rawInput` are optional strings on `ToolCall`; if `preview` is non-optional use `""`). In `wireMessage`, skip `cachedFullToolCallContent` for a `visual_show` call so a truncated off-window body is not reloaded from SQLite only to be discarded.

- [ ] **Step 6: Run the tests**

Run the focused command with `-only-testing AlasTests/RemoteSessionGatewayTests -only-testing AlasTests/ACPToolCallPresentationTests`. Expected: PASS. Run `swiftformat Alas AlasTests --lint`.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources AlasTests
git commit -m "feat(remote): send visual aids to the phone and scrub the visual_show tool call"
```

---

### Task 2: `visualAidResponse` end to end on the Mac

**Files:**
- Modify: `Alas/Sources/Remote/Protocol/RemoteProtocol.swift` (client case ~55-117 and its `CodingKeys` ~120, decode ~184, encode ~329; server case ~479-551, `CodingKeys` ~555, decode ~666, encode ~887)
- Modify: `Alas/Sources/Remote/Gateway/RemoteSessionGateway.swift` (`handle` switch ~66-405; new private handler)
- Modify: `Alas/Sources/Remote/Gateway/RemoteSessionsProvider.swift` (protocol requirement)
- Modify: `Alas/Sources/App/AppState.swift` (`extension AppState: RemoteSessionsProvider` ~14934, near `sendPrompt` ~15549)
- Modify (compiler-driven): every other exhaustive switch over `RemoteClientMessage` or `RemoteServerMessage` (federation routing, native peer pump); grep `case .questionAnswer` and `case .promptRejected` across `Alas/Sources` for the sites
- Test: `AlasTests/Remote/RemoteProtocolTests.swift`, `AlasTests/Remote/RemoteSessionGatewayTests.swift` (the shared `FakeSessionsProvider` at the top of that file gets the new method)

**Interfaces:**
- Consumes: `RemoteVisualAid` rows (Task 1), `ACPSessionManager.answerVisualAid(id:answer:in:) async -> Bool`, `ACPTranscript.visualAid(id:)`, `ACPVisualAidQuestionForm.noteMaxLength`.
- Produces: `RemoteClientMessage.visualAidResponse(sessionId: String, visualId: String, action: String, selectedOptionIds: [String], note: String?)`; `RemoteServerMessage.visualAidRejected(sessionId: String, visualId: String, reason: String)`; `RemoteSessionsProvider.answerVisualAid(for id: String, visualId: UUID, answer: ACPVisualAid.Answer) async -> Bool`.

- [ ] **Step 1: Write the failing protocol tests**

In `RemoteProtocolTests` (it has the `roundTrip` helper):

```swift
    @Test func visualAidResponseRoundTrips() throws {
        let answer = RemoteClientMessage.visualAidResponse(
            sessionId: "s1", visualId: "V", action: "answer", selectedOptionIds: ["a", "b"], note: "hi")
        #expect(try roundTrip(answer) == answer)
        let dismiss = RemoteClientMessage.visualAidResponse(
            sessionId: "s1", visualId: "V", action: "dismiss", selectedOptionIds: [], note: nil)
        #expect(try roundTrip(dismiss) == dismiss)
    }

    @Test func visualAidResponseDecodesWithOptionalFieldsAbsent() throws {
        let json = #"{"type":"visualAidResponse","sessionId":"s1","visualId":"V","action":"dismiss"}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(RemoteClientMessage.self, from: json)
        #expect(msg == .visualAidResponse(sessionId: "s1", visualId: "V", action: "dismiss", selectedOptionIds: [], note: nil))
    }

    @Test func visualAidRejectedRoundTrips() throws {
        let rejected = RemoteServerMessage.visualAidRejected(sessionId: "s1", visualId: "V", reason: "notWriter")
        #expect(try roundTrip(rejected) == rejected)
    }
```

- [ ] **Step 2: Write the failing gateway tests**

Extend `FakeSessionsProvider` (top of `RemoteSessionGatewayTests.swift`) with:

```swift
    var answeredVisuals: [(id: String, visualId: UUID, answer: ACPVisualAid.Answer)] = []
    var answerVisualAidResult = true
    func answerVisualAid(for id: String, visualId: UUID, answer: ACPVisualAid.Answer) async -> Bool {
        answeredVisuals.append((id, visualId, answer))
        return answerVisualAidResult
    }
```

Add tests (a `makeVisualSession(question:)` helper builds a session holding `makeVisual()` from Task 1 with the given `allowMultiple`; mark `provider.writers.insert("s1")` for the writer cases):

```swift
    private func visualRejection(_ sent: [RemoteServerMessage]) -> String? {
        for case .visualAidRejected(_, _, let reason) in sent { return reason }
        return nil
    }

    @Test func visualAnswerRoutesToTheProviderInQuestionOrder() async throws {
        let provider = FakeSessionsProvider()
        let (s, visual) = try makeVisualSession(allowMultiple: true)
        provider.sessions["s1"] = s; provider.writers.insert("s1")
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.visualAidResponse(sessionId: "s1", visualId: visual.id.uuidString, action: "answer",
                                           selectedOptionIds: ["b", "a"], note: "  keep it  "))
        let call = try #require(provider.answeredVisuals.first)
        #expect(call.visualId == visual.id)
        guard case .answered(let ids, let note, _) = call.answer else { Issue.record("expected answered"); return }
        #expect(ids == ["a", "b"])
        #expect(note == "keep it")
        #expect(visualRejection(sent) == nil)
    }

    @Test func visualDismissRoutesWithoutChoices() async throws {
        let provider = FakeSessionsProvider()
        let (s, visual) = try makeVisualSession(allowMultiple: false)
        provider.sessions["s1"] = s; provider.writers.insert("s1")
        let gw = RemoteSessionGateway(provider: provider) { _ in }
        await gw.handle(.visualAidResponse(sessionId: "s1", visualId: visual.id.uuidString, action: "dismiss",
                                           selectedOptionIds: [], note: nil))
        guard case .dismissed = try #require(provider.answeredVisuals.first).answer else { Issue.record("expected dismissed"); return }
    }

    @Test(arguments: [
        ("notWriter", false, "answer", ["a"], Optional<String>.none),
        ("invalid", true, "answer", [String](), nil),
        ("invalid", true, "answer", ["zzz"], nil),
        ("invalid", true, "answer", ["a", "a"], nil),
        ("invalid", true, "answer", ["a", "b"], nil),
        ("invalid", true, "answer", ["a"], String(repeating: "x", count: 2001)),
        ("invalid", true, "wave", ["a"], nil),
    ])
    func invalidVisualResponsesAreRejectedWithoutCallingTheManager(
        reason: String, isWriter: Bool, action: String, ids: [String], note: String?
    ) async throws {
        let provider = FakeSessionsProvider()
        let (s, visual) = try makeVisualSession(allowMultiple: false)
        provider.sessions["s1"] = s
        if isWriter { provider.writers.insert("s1") }
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.visualAidResponse(sessionId: "s1", visualId: visual.id.uuidString, action: action,
                                           selectedOptionIds: ids, note: note))
        #expect(visualRejection(sent) == reason)
        #expect(provider.answeredVisuals.isEmpty)
    }

    @Test func unknownAndAlreadyAnsweredVisualsAreRejected() async throws {
        let provider = FakeSessionsProvider()
        let (s, visual) = try makeVisualSession(allowMultiple: false)
        provider.sessions["s1"] = s; provider.writers.insert("s1")
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.visualAidResponse(sessionId: "s1", visualId: UUID().uuidString, action: "dismiss", selectedOptionIds: [], note: nil))
        #expect(visualRejection(sent) == "notFound")
        sent.removeAll()
        var answered = visual
        answered.answer = .dismissed(at: Date())
        s.transcript.replaceMessage(at: s.transcript.messages.count - 1, with: .visualAid(answered))
        await gw.handle(.visualAidResponse(sessionId: "s1", visualId: visual.id.uuidString, action: "dismiss", selectedOptionIds: [], note: nil))
        #expect(visualRejection(sent) == "alreadyAnswered")
        #expect(provider.answeredVisuals.isEmpty)
    }

    @Test func aManagerFailureIsReportedAsFailed() async throws {
        let provider = FakeSessionsProvider()
        provider.answerVisualAidResult = false
        let (s, visual) = try makeVisualSession(allowMultiple: false)
        provider.sessions["s1"] = s; provider.writers.insert("s1")
        var sent: [RemoteServerMessage] = []
        let gw = RemoteSessionGateway(provider: provider) { sent.append($0) }
        await gw.handle(.visualAidResponse(sessionId: "s1", visualId: visual.id.uuidString, action: "answer",
                                           selectedOptionIds: ["a"], note: nil))
        #expect(visualRejection(sent) == "failed")
    }
```

- [ ] **Step 3: Run to verify failure**

Run `-only-testing AlasTests/RemoteProtocolTests -only-testing AlasTests/RemoteSessionGatewayTests`. Expected: compile errors for the missing cases.

- [ ] **Step 4: Protocol messages**

Follow the existing hand-written Codable style (a `type` discriminator, one keyed container). Client:

```swift
    case visualAidResponse(sessionId: String, visualId: String, action: String, selectedOptionIds: [String], note: String?)
```

Add `visualId, selectedOptionIds, note` to the client `CodingKeys`, then:

```swift
        case "visualAidResponse":
            self = .visualAidResponse(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                visualId: try c.decode(String.self, forKey: .visualId),
                action: try c.decode(String.self, forKey: .action),
                selectedOptionIds: try c.decodeIfPresent([String].self, forKey: .selectedOptionIds) ?? [],
                note: try c.decodeIfPresent(String.self, forKey: .note))
```

```swift
        case .visualAidResponse(let s, let v, let a, let ids, let n):
            try c.encode("visualAidResponse", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(v, forKey: .visualId)
            try c.encode(a, forKey: .action)
            try c.encode(ids, forKey: .selectedOptionIds)
            try c.encodeIfPresent(n, forKey: .note)
```

Server (add `visualId` to its `CodingKeys`; `reason` and `sessionId` already exist):

```swift
    /// The server refused a `visualAidResponse` (reason: notWriter, notFound,
    /// alreadyAnswered, invalid or failed), so the phone re-enables the card.
    case visualAidRejected(sessionId: String, visualId: String, reason: String)
```

```swift
        case "visualAidRejected":
            self = .visualAidRejected(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                visualId: try c.decode(String.self, forKey: .visualId),
                reason: try c.decode(String.self, forKey: .reason))
```

```swift
        case .visualAidRejected(let s, let v, let r):
            try c.encode("visualAidRejected", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(v, forKey: .visualId)
            try c.encode(r, forKey: .reason)
```

Update the doc comment of `RemoteClientMessage`/`RemoteServerMessage` if it lists cases. Fix every other exhaustive switch the compiler reports. FEDERATION: `RemoteSessionGateway.handle` routes federated session messages first. Find how `sendPrompt`/`questionAnswer` are forwarded to a peer Mac for a federated session and how server messages from a peer are forwarded back (`FederatedDownstream`), and make `visualAidResponse` and `visualAidRejected` follow the same routing, so a visual on a peer's session is answerable. Report what you found and added.

- [ ] **Step 5: Provider and AppState**

`RemoteSessionsProvider`:

```swift
    /// Stores `answer` on the visual and starts sending it to the agent. False
    /// when no live session owns `id` or the manager could not store it.
    func answerVisualAid(for id: String, visualId: UUID, answer: ACPVisualAid.Answer) async -> Bool
```

`AppState` (next to `sendPrompt`):

```swift
    func answerVisualAid(for id: String, visualId: UUID, answer: ACPVisualAid.Answer) async -> Bool {
        guard let manager = acpManager(forSession: id) else { return false }
        return await manager.answerVisualAid(id: visualId, answer: answer, in: id)
    }
```

- [ ] **Step 6: Gateway handler**

In `handle`, add a case that calls a private method (the existing handlers reply with the injected synchronous `send` closure):

```swift
        case .visualAidResponse(let sessionId, let visualId, let action, let selectedOptionIds, let note):
            await handleVisualAidResponse(
                sessionId: sessionId, visualId: visualId, action: action,
                selectedOptionIds: selectedOptionIds, note: note)
```

```swift
    private func handleVisualAidResponse(
        sessionId: String, visualId: String, action: String, selectedOptionIds: [String], note: String?
    ) async {
        func reject(_ reason: String) {
            send(.visualAidRejected(sessionId: sessionId, visualId: visualId, reason: reason))
        }
        guard provider.isWriter(for: sessionId) else { return reject("notWriter") }
        guard let id = UUID(uuidString: visualId),
              let session = provider.session(for: sessionId),
              let visual = session.transcript.visualAid(id: id)
        else { return reject("notFound") }
        guard let question = visual.question, visual.answer == nil else { return reject("alreadyAnswered") }

        let answer: ACPVisualAid.Answer
        switch action {
        case "dismiss":
            answer = .dismissed(at: Date())
        case "answer":
            let known = Set(question.options.map(\.id))
            let picked = Set(selectedOptionIds)
            guard picked.count == selectedOptionIds.count, !picked.isEmpty, picked.isSubset(of: known),
                  question.allowMultiple || picked.count == 1
            else { return reject("invalid") }
            let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, trimmed.count > ACPVisualAidQuestionForm.noteMaxLength { return reject("invalid") }
            // Question order, like a native answer.
            let ordered = question.options.map(\.id).filter(picked.contains)
            answer = .answered(
                selectedOptionIds: ordered,
                note: (trimmed?.isEmpty ?? true) ? nil : trimmed,
                at: Date())
        default:
            return reject("invalid")
        }
        guard await provider.answerVisualAid(for: sessionId, visualId: id, answer: answer) else { return reject("failed") }
    }
```

- [ ] **Step 7: Run the tests**

Run `-only-testing AlasTests/RemoteProtocolTests -only-testing AlasTests/RemoteSessionGatewayTests -only-testing AlasTests/RemotePeerConnectionTests -only-testing AlasTests/RemoteServerIntegrationTests` (the last two use `FakeSessionsProvider`). Expected: PASS. Run `swiftformat Alas AlasTests --lint`.

- [ ] **Step 8: Commit**

```bash
git add Alas/Sources AlasTests
git commit -m "feat(remote): answer a visual aid question from the phone"
```

---

### Task 3: The pure `visual-aid.js` module

**Files:**
- Create: `Alas/Resources/RemoteWeb/visual-aid.js`
- Create: `scripts/tests/remote-web-visual-aid/run.sh`
- Create: `scripts/tests/remote-web-visual-aid/test-visual-aid.js`
- Modify: `.github/workflows/build.yml` (`remote-web-tests` job, after the `remote web hub` step)

**Interfaces:**
- Produces: `globalThis.RemoteVisualAid` with: `CSP`, `SANDBOX` (`"allow-scripts"`), `HEIGHT_MIN` 120, `HEIGHT_MAX` 720, `NOTE_MAX` 2000, `MAX_LIVE_FRAMES` 3, `FRAME_CSS`, `isFullDocument(html)`, `buildDocument(html, id, parse)`, `parseVisual(json)`, `clampHeight(value)`, `heightFromMessage(data, expectedId, source, expectedSource)`, `toggleSelection(question, selected, optionId)`, `canSubmit(question, selected, note)`, `buildResponse(sessionId, visual, action, selected, note)`, `answerView(visual, state)`, `rejectionText(reason)`, `admitFrame(order, id, limit)`, `touchFrame(order, id)`, `releaseFrame(order, id)`.

`buildDocument(html, id, parse)`: `parse` is `(source) => Document` (in the browser `(s) => new DOMParser().parseFromString(s, "text/html")`). It returns the `srcdoc` string. `id` must match `/^[0-9a-fA-F-]{36}$/` or the function throws (it is placed inside a script).

- [ ] **Step 1: Write the failing Node tests**

`scripts/tests/remote-web-visual-aid/run.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
node "$(dirname "$0")/test-visual-aid.js"
```

`test-visual-aid.js` (the module follows the repo convention: it assigns `globalThis.RemoteVisualAid` and `require` evaluates it):

```js
const assert = require("node:assert/strict");

require("../../../Alas/Resources/RemoteWeb/visual-aid.js");
const V = globalThis.RemoteVisualAid;

const ID = "6f0c2d4e-8b1a-4c3d-9e5f-1a2b3c4d5e6f";
const question = (allowMultiple = false) => ({
  prompt: "Which?",
  options: [{ id: "a", label: "One" }, { id: "b", label: "Two" }, { id: "c", label: "Three" }],
  allowMultiple,
});
const visual = (extra = {}) => ({ id: ID, title: "Layouts", html: "<p>x</p>", question: question(), ...extra });

// Constants that are part of the security contract.
assert.equal(V.SANDBOX, "allow-scripts");
assert.ok(!/allow-same-origin/.test(V.SANDBOX));
assert.equal(
  V.CSP,
  "default-src 'none'; script-src 'unsafe-inline' https:; style-src 'unsafe-inline' https:; " +
    "img-src data: blob: https:; font-src data: https:; connect-src 'none'; frame-src 'none'; " +
    "worker-src 'none'; form-action 'none'; base-uri 'none'");

// isFullDocument matches the desktop rule (VisualAidWebPolicyTests.fullDocumentDetection).
for (const [html, expected] of [
  ["<!DOCTYPE html><html></html>", true],
  ["  \n<!doctype html>", true],
  ["<!-- note --> <HTML lang=\"en\">", true],
  ["<!-- unterminated <html>", false],
  ["<div>hi</div>", false],
  ["<h2>html</h2>", false],
  ["<html-preview>x</html-preview>", false],
  ["<!doctype-widget>", false],
  ["<html>", true],
  ["<html/>", true],
  ["<!DOCTYPE\nhtml>", true],
]) {
  assert.equal(V.isFullDocument(html), expected, JSON.stringify(html));
}

// Height handling.
assert.equal(V.clampHeight(10), 120);
assert.equal(V.clampHeight(300.4), 301);
assert.equal(V.clampHeight(99999), 720);
assert.equal(V.clampHeight("nope"), null);
assert.equal(V.clampHeight(NaN), null);
const win = {};
const other = {};
assert.equal(V.heightFromMessage({ alasVisual: true, id: ID, height: 300 }, ID, win, win), 300);
assert.equal(V.heightFromMessage({ alasVisual: true, id: ID, height: 300 }, ID, other, win), null, "wrong source");
assert.equal(V.heightFromMessage({ alasVisual: true, id: "other", height: 300 }, ID, win, win), null, "wrong id");
assert.equal(V.heightFromMessage({ id: ID, height: 300 }, ID, win, win), null, "missing marker");
assert.equal(V.heightFromMessage(null, ID, win, win), null);

// Selection and submit rules.
assert.deepEqual(V.toggleSelection(question(false), ["a"], "b"), ["b"]);
assert.deepEqual(V.toggleSelection(question(false), ["a"], "a"), ["a"]);
assert.deepEqual(V.toggleSelection(question(true), ["a"], "b"), ["a", "b"]);
assert.deepEqual(V.toggleSelection(question(true), ["a", "b"], "a"), ["b"]);
assert.deepEqual(V.toggleSelection(question(true), ["a"], "zzz"), ["a"], "unknown id ignored");
assert.equal(V.canSubmit(question(false), [], ""), false);
assert.equal(V.canSubmit(question(false), ["a"], ""), true);
assert.equal(V.canSubmit(question(false), ["a", "b"], ""), false);
assert.equal(V.canSubmit(question(true), ["a", "b"], ""), true);
assert.equal(V.canSubmit(question(false), ["a"], "x".repeat(2000)), true);
assert.equal(V.canSubmit(question(false), ["a"], "x".repeat(2001)), false);

// Response builder: question order, trimmed note, dismissal carries nothing.
assert.deepEqual(V.buildResponse("s1", visual({ question: question(true) }), "answer", ["c", "a"], "  hi  "), {
  type: "visualAidResponse", sessionId: "s1", visualId: ID, action: "answer", selectedOptionIds: ["a", "c"], note: "hi",
});
assert.deepEqual(V.buildResponse("s1", visual(), "answer", ["a"], "   "), {
  type: "visualAidResponse", sessionId: "s1", visualId: ID, action: "answer", selectedOptionIds: ["a"],
});
assert.deepEqual(V.buildResponse("s1", visual(), "dismiss", ["a"], "ignored"), {
  type: "visualAidResponse", sessionId: "s1", visualId: ID, action: "dismiss", selectedOptionIds: [],
});
assert.equal(V.buildResponse("s1", visual(), "answer", [], ""), null, "an invalid answer builds nothing");
assert.equal(V.buildResponse("s1", visual({ question: null }), "dismiss", [], ""), null, "no question");

// Answer view states.
const open = (state) => V.answerView(visual(), { canDrive: true, pending: false, error: "", selected: [], note: "", ...state });
assert.equal(V.answerView(visual({ question: null }), {}).kind, "none");
assert.equal(open({}).kind, "open");
assert.equal(open({}).editable, true);
assert.equal(open({}).canSubmit, false);
assert.equal(open({ selected: ["a"] }).canSubmit, true);
assert.equal(open({ canDrive: false }).editable, false);
assert.equal(open({ canDrive: false }).hint, "Take over to answer");
assert.equal(open({ pending: true, selected: ["a"] }).editable, false);
assert.equal(open({ error: "boom" }).error, "boom");
assert.deepEqual(open({ selected: ["b"] }).options.map((o) => o.checked), [false, true, false]);
assert.equal(open({}).multiple, false);
const answered = V.answerView(visual({ answer: { kind: "answered", selectedOptionIds: ["b", "a"], note: "ok" } }), {});
assert.equal(answered.kind, "answered");
assert.deepEqual(answered.labels, ["One", "Two"], "labels follow question order");
assert.equal(answered.note, "ok");
assert.equal(V.answerView(visual({ answer: { kind: "dismissed" } }), {}).kind, "dismissed");

// Visual parsing.
assert.equal(V.parseVisual("not json"), null);
assert.equal(V.parseVisual(JSON.stringify({ id: ID, title: "t" })), null, "html is required");
assert.equal(V.parseVisual(JSON.stringify({ id: "bad id", title: "t", html: "x" })), null, "id must be a UUID");
assert.equal(V.parseVisual(JSON.stringify({ id: ID, title: "t", html: "x", question: { prompt: "p", options: [{ id: 1 }] } })), null);
assert.equal(V.parseVisual(JSON.stringify(visual())).id, ID);
assert.equal(V.parseVisual(JSON.stringify({ id: ID, title: "t", html: "x" })).question, undefined);

// Rejections.
assert.equal(V.rejectionText("failed"), "Couldn't send your answer. Try again.");
assert.equal(V.rejectionText("notWriter"), "Take over this session to answer.");
assert.equal(V.rejectionText("whatever"), "Couldn't send your answer. Try again.");

// Live frame budget: least recently shown goes first, re-admit refreshes.
let r = V.admitFrame([], "a", 3);
assert.deepEqual(r, { order: ["a"], evicted: [] });
r = V.admitFrame(r.order, "b", 3); r = V.admitFrame(r.order, "c", 3);
assert.deepEqual(V.touchFrame(r.order, "a"), ["b", "c", "a"]);
r = V.admitFrame(V.touchFrame(r.order, "a"), "d", 3);
assert.deepEqual(r, { order: ["c", "a", "d"], evicted: ["b"] });
assert.deepEqual(V.releaseFrame(r.order, "a"), ["c", "d"]);

// buildDocument: a stub parser records what the module inserts. The real DOMParser behavior is
// covered in RemoteWebAssetTests with WebKit.
const inserted = [];
const stubDoc = (hasHead) => {
  const head = { prepend(...nodes) { inserted.push(...nodes); } };
  const node = (tag) => ({ tag, textContent: "", httpEquiv: "", content: "" });
  return {
    doctype: { name: "html" },
    head: hasHead ? head : null,
    documentElement: {
      outerHTML: "<html>…</html>",
      firstChild: null,
      insertBefore(h) { this.createdHead = h; return head; },
    },
    createElement: (tag) => (tag === "head" ? head : node(tag)),
  };
};
const out = V.buildDocument("<p>x</p>", ID, () => stubDoc(true));
assert.ok(out.startsWith("<!DOCTYPE html>"));
assert.equal(inserted[0].httpEquiv, "Content-Security-Policy");
assert.equal(inserted[0].content, V.CSP);
assert.match(inserted[1].textContent, /RTC/, "the lockdown script comes second");
assert.ok(inserted[2].textContent.includes(JSON.stringify(ID)), "the bridge script carries the id");
assert.throws(() => V.buildDocument("<p>x</p>", "</script><script>", () => stubDoc(true)));

console.log("visual-aid tests passed");
```

- [ ] **Step 2: Run to verify failure**

Run `bash scripts/tests/remote-web-visual-aid/run.sh`. Expected: FAIL, the module does not exist.

- [ ] **Step 3: Implement the module**

`Alas/Resources/RemoteWeb/visual-aid.js` (classic script, no `module.exports`, one global like the other pure modules):

```js
// Pure logic for visual aids in the phone client: the sandboxed document an agent's HTML runs in, the answer
// state machine, and the live-frame budget. app.js owns every DOM and socket effect.
(function () {
  const CSP =
    "default-src 'none'; script-src 'unsafe-inline' https:; style-src 'unsafe-inline' https:; " +
    "img-src data: blob: https:; font-src data: https:; connect-src 'none'; frame-src 'none'; " +
    "worker-src 'none'; form-action 'none'; base-uri 'none'";
  // Never add allow-same-origin: the page keeps its bearer token in localStorage and /ws is same-origin.
  const SANDBOX = "allow-scripts";
  const HEIGHT_MIN = 120, HEIGHT_MAX = 720, NOTE_MAX = 2000, MAX_LIVE_FRAMES = 3;
  const FAILED_TEXT = "Couldn't send your answer. Try again.";
  const UUID = /^[0-9a-fA-F-]{36}$/;

  // Mirrors Alas/Resources/VisualAid/frame.html; RemoteWebAssetTests checks every class selector is present.
  const FRAME_CSS = `
  :root { color-scheme: dark; font: 14px -apple-system, system-ui, sans-serif;
    --alas-text: oklch(0.94 0.012 220); --alas-dim: oklch(0.64 0.014 220); --alas-accent: oklch(0.74 0.11 195);
    --alas-background: oklch(0.215 0.013 245); --alas-line: oklch(1 0 0 / 0.14);
    --alas-tone-success: oklch(0.78 0.14 155); --alas-tone-danger: oklch(0.72 0.16 25); }
  html, body { margin: 0; }
  body { padding: 14px; color: var(--alas-text); background: var(--alas-background); line-height: 1.45; }
  h2 { font-size: 17px; margin: 0 0 4px; }
  h3 { font-size: 14px; margin: 0 0 4px; }
  .subtitle { color: var(--alas-dim); margin: 0 0 14px; }
  .section { margin-bottom: 16px; }
  .label { font-size: 10.5px; font-weight: 600; letter-spacing: .06em; text-transform: uppercase; color: var(--alas-dim); }
  .options, .cards { display: grid; gap: 10px; }
  .options { grid-template-columns: 1fr; }
  .cards { grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); }
  .option, .card { border: 1px solid var(--alas-line); border-radius: 8px; }
  .option { display: flex; gap: 12px; align-items: flex-start; padding: 12px; }
  .option .letter { flex: none; width: 24px; height: 24px; border-radius: 6px; display: grid; place-items: center; font-weight: 700; background: var(--alas-line); }
  .option.selected, .card.selected { border-color: var(--alas-accent); box-shadow: 0 0 0 1px var(--alas-accent); }
  .option.selected .letter { background: var(--alas-accent); color: var(--alas-background); }
  .card-image { min-height: 120px; padding: 12px; border-bottom: 1px solid var(--alas-line); }
  .card-body { padding: 10px 12px; }
  .mockup { border: 1px solid var(--alas-line); border-radius: 8px; overflow: hidden; }
  .mockup-header { padding: 6px 10px; font-size: 11px; color: var(--alas-dim); border-bottom: 1px solid var(--alas-line); }
  .mockup-body { padding: 12px; }
  .split { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  .pros-cons { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  .pros h4 { color: var(--alas-tone-success); }
  .cons h4 { color: var(--alas-tone-danger); }
  .mock-nav { padding: 8px 12px; border: 1px solid var(--alas-line); border-radius: 6px; margin-bottom: 8px; }
  .mock-sidebar { width: 160px; padding: 10px; border: 1px dashed var(--alas-line); border-radius: 6px; margin-right: 8px; }
  .mock-content { flex: 1; padding: 10px; border: 1px dashed var(--alas-line); border-radius: 6px; }
  .mock-button { font: inherit; padding: 6px 12px; border-radius: 6px; border: 1px solid var(--alas-accent); background: var(--alas-accent); color: var(--alas-background); }
  .mock-input { font: inherit; padding: 6px 8px; border-radius: 6px; border: 1px solid var(--alas-line); background: transparent; color: inherit; }
  .placeholder { display: grid; place-items: center; min-height: 80px; border: 1px dashed var(--alas-line); border-radius: 6px; color: var(--alas-dim); }`;

  // CSP does not cover WebRTC. Best effort in a browser: a no-src child frame is a clean realm.
  const LOCKDOWN_SCRIPT =
    "(() => { for (const name of Object.getOwnPropertyNames(window)) {" +
    " if (/^(webkit)?RTC/.test(name)) { try { delete window[name]; } catch (e) {} } } })();";

  function bridgeScript(id) {
    return `(() => {
      const id = ${JSON.stringify(id)};
      const post = () => parent.postMessage({ alasVisual: true, id, height: Math.ceil(document.documentElement.getBoundingClientRect().height) }, "*");
      const observer = new ResizeObserver(post);
      observer.observe(document.documentElement);
      addEventListener("DOMContentLoaded", () => { if (document.body) observer.observe(document.body); post(); });
      addEventListener("load", post);
      // Links do nothing in a phone visual; same-document anchors keep scrolling.
      document.addEventListener("click", (event) => {
        const link = event.target instanceof Element && event.target.closest("a[href]");
        if (link && !(link.getAttribute("href") || "").startsWith("#")) event.preventDefault();
      }, true);
    })();`;
  }

  // The desktop rule: after whitespace and comments, a doctype or <html followed by whitespace, ">" or "/".
  function isFullDocument(html) {
    let rest = String(html);
    for (;;) {
      rest = rest.replace(/^\s+/, "");
      if (!rest.startsWith("<!--")) break;
      const end = rest.indexOf("-->");
      if (end < 0) return false;
      rest = rest.slice(end + 3);
    }
    const opening = rest.slice(0, 10).toLowerCase();
    return ["<!doctype", "<html"].some((token) => {
      if (!opening.startsWith(token)) return false;
      const next = opening.charAt(token.length);
      return next === "" || /\s/.test(next) || next === ">" || next === "/";
    });
  }

  function buildDocument(html, id, parse) {
    if (!UUID.test(id)) throw new Error("invalid visual id");
    const source = isFullDocument(html)
      ? html
      : `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><style>${FRAME_CSS}</style></head><body>${html}</body></html>`;
    const doc = parse(source);
    let head = doc.head;
    if (!head) {
      head = doc.createElement("head");
      doc.documentElement.insertBefore(head, doc.documentElement.firstChild);
    }
    const csp = doc.createElement("meta");
    csp.httpEquiv = "Content-Security-Policy";
    csp.content = CSP;
    const lockdown = doc.createElement("script");
    lockdown.textContent = LOCKDOWN_SCRIPT;
    const bridge = doc.createElement("script");
    bridge.textContent = bridgeScript(id);
    // First in <head>, so they run before anything the agent wrote.
    head.prepend(csp, lockdown, bridge);
    const doctype = doc.doctype ? `<!DOCTYPE ${doc.doctype.name}>` : "";
    return doctype + doc.documentElement.outerHTML;
  }

  function parseVisual(json) {
    let v;
    try { v = JSON.parse(json); } catch (_) { return null; }
    if (!v || typeof v.id !== "string" || !UUID.test(v.id) || typeof v.title !== "string" || typeof v.html !== "string") return null;
    if (v.question != null) {
      const q = v.question;
      if (typeof q.prompt !== "string" || !Array.isArray(q.options) || q.options.length === 0) return null;
      if (!q.options.every((o) => o && typeof o.id === "string" && typeof o.label === "string")) return null;
    }
    return v;
  }

  function clampHeight(value) {
    if (typeof value !== "number" || !Number.isFinite(value)) return null;
    return Math.min(Math.max(Math.ceil(value), HEIGHT_MIN), HEIGHT_MAX);
  }

  // Only the card's own window may size it, and only for its own id.
  function heightFromMessage(data, expectedId, source, expectedSource) {
    if (!data || data.alasVisual !== true || data.id !== expectedId || source !== expectedSource) return null;
    return clampHeight(data.height);
  }

  function toggleSelection(question, selected, optionId) {
    if (!question.options.some((o) => o.id === optionId)) return selected.slice();
    if (!question.allowMultiple) return [optionId];
    return selected.includes(optionId) ? selected.filter((id) => id !== optionId) : selected.concat(optionId);
  }

  function canSubmit(question, selected, note) {
    if (selected.length === 0 || (!question.allowMultiple && selected.length !== 1)) return false;
    return String(note || "").trim().length <= NOTE_MAX;
  }

  function buildResponse(sessionId, visual, action, selected, note) {
    const q = visual.question;
    if (!q) return null;
    const base = { type: "visualAidResponse", sessionId, visualId: visual.id, action };
    if (action === "dismiss") return { ...base, selectedOptionIds: [] };
    if (!canSubmit(q, selected, note)) return null;
    const ordered = q.options.map((o) => o.id).filter((id) => selected.includes(id));
    const trimmed = String(note || "").trim();
    return trimmed ? { ...base, selectedOptionIds: ordered, note: trimmed } : { ...base, selectedOptionIds: ordered };
  }

  function answerView(visual, state) {
    const q = visual.question;
    if (!q) return { kind: "none" };
    if (visual.answer) {
      if (visual.answer.kind === "dismissed") return { kind: "dismissed" };
      const ids = visual.answer.selectedOptionIds || [];
      const labels = q.options.filter((o) => ids.includes(o.id)).map((o) => o.label);
      return { kind: "answered", labels, note: visual.answer.note || "" };
    }
    const s = state || {};
    const selected = s.selected || [];
    const editable = s.canDrive === true && s.pending !== true;
    return {
      kind: "open",
      prompt: q.prompt,
      multiple: q.allowMultiple === true,
      options: q.options.map((o) => ({ id: o.id, label: o.label, checked: selected.includes(o.id) })),
      note: s.note || "",
      noteMax: NOTE_MAX,
      editable,
      canSubmit: editable && canSubmit(q, selected, s.note),
      hint: s.canDrive === true ? "" : "Take over to answer",
      error: s.error || "",
      pending: s.pending === true,
    };
  }

  function rejectionText(reason) {
    switch (reason) {
      case "notWriter": return "Take over this session to answer.";
      case "notFound": return "This visual is no longer available.";
      case "alreadyAnswered": return "This question was already answered.";
      case "invalid": return "That answer wasn't accepted. Check your choice and try again.";
      default: return FAILED_TEXT;
    }
  }

  // Least recently shown first. Admitting past the limit evicts from the front.
  function admitFrame(order, id, limit) {
    const next = order.filter((x) => x !== id).concat(id);
    const overflow = Math.max(0, next.length - limit);
    return { order: next.slice(overflow), evicted: next.slice(0, overflow) };
  }
  function touchFrame(order, id) { return order.includes(id) ? order.filter((x) => x !== id).concat(id) : order.slice(); }
  function releaseFrame(order, id) { return order.filter((x) => x !== id); }

  globalThis.RemoteVisualAid = {
    CSP, SANDBOX, HEIGHT_MIN, HEIGHT_MAX, NOTE_MAX, MAX_LIVE_FRAMES, FAILED_TEXT, FRAME_CSS,
    isFullDocument, buildDocument, parseVisual, clampHeight, heightFromMessage, toggleSelection, canSubmit,
    buildResponse, answerView, rejectionText, admitFrame, touchFrame, releaseFrame,
  };
})();
```

- [ ] **Step 4: Run the tests**

Run `bash scripts/tests/remote-web-visual-aid/run.sh`. Expected: `visual-aid tests passed`. Fix the module, not the expectations, unless an expectation contradicts the spec.

- [ ] **Step 5: Add the CI step**

In `.github/workflows/build.yml`, in the `remote-web-tests` job after the `Test remote web hub` step:

```yaml
      - name: Test remote web visual aid
        if: ${{ !cancelled() }}
        run: bash scripts/tests/remote-web-visual-aid/run.sh
```

- [ ] **Step 6: Commit**

```bash
git add Alas/Resources/RemoteWeb/visual-aid.js scripts/tests/remote-web-visual-aid .github/workflows/build.yml
git commit -m "feat(remote-web): add the visual aid module for the phone client"
```

---

### Task 4: Render visual cards in the phone client

**Files:**
- Modify: `Alas/Resources/RemoteWeb/app.js` (`renderMessage` ~3054; `insertMessage`/`upsertMessage` ~2130-2160; `handle` ~354 and the `promptRejected` case ~423; `applySnapshot` ~1945; `openSession` ~858; `renderDriveBar` ~3665; the Take Over wiring ~3932)
- Modify: `Alas/Resources/RemoteWeb/style.css` (visual card styles; bump `?v=54`)
- Modify: `Alas/Resources/RemoteWeb/index.html` (load `/visual-aid.js` before `/app.js`; bump `app.js` and `style.css` versions)
- Modify: `Alas/Resources/RemoteWeb/sw.js` (`SHELL_ASSETS` and `CACHE_NAME` to `v78`)
- Test: `AlasTests/Remote/RemoteWebAssetTests.swift`

**Interfaces:**
- Consumes: `globalThis.RemoteVisualAid` (Task 3); wire row `kind: "visualAid"` and the `visualAidRejected` server message (Tasks 1 and 2).
- Produces (inside `app.js`): `renderVisualAid(m)`, `updateVisualAid(node, m)`, `mountVisualFrame(card)`, `renderVisualAnswer(card)`, `submitVisual(card, action)`, `rejectVisual(visualId, reason)`, `takeOver()`, `refreshVisualCards()`, `resetVisualCards()`.

- [ ] **Step 1: Write the failing asset tests**

Add to `RemoteWebAssetTests` (add `import WebKit` and `@testable import Alas` at the top):

```swift
    @Test func visualAidScriptLoadsBeforeAppAndIsPrecached() throws {
        let html = try asset("index.html")
        let sw = try asset("sw.js")
        try expectLoadsBeforeApp("/visual-aid.js", in: html)
        try expectReferencedAndPrecached("/visual-aid.js", html: html, sw: sw)
    }

    @Test func visualAidIframeNeverAllowsSameOrigin() throws {
        let module = try asset("visual-aid.js")
        let app = try asset("app.js")
        #expect(module.contains(#"const SANDBOX = "allow-scripts";"#))
        #expect(app.contains(#"setAttribute("sandbox", RemoteVisualAid.SANDBOX)"#))
        // The token lives in localStorage and /ws is same-origin: a frame with allow-same-origin could read both.
        for name in ["app.js", "index.html", "hub-links.js"] {
            let text = try asset(name)
            #expect(!text.contains("allow-same-origin"), "\(name) must not mention allow-same-origin")
        }
        #expect(module.components(separatedBy: "allow-same-origin").count == 2, "only the explanatory comment mentions it")
    }

    @Test func visualAidQuestionFramesAreInert() throws {
        let app = try asset("app.js")
        #expect(app.contains(#"frame.setAttribute("inert", "")"#))
        #expect(app.contains("card.visual.question"))
    }

    @Test func visualAidCSPMatchesTheDesktopPolicy() throws {
        let module = try asset("visual-aid.js")
        let lines = VisualAidWebPolicy.contentSecurityPolicy
        // The phone module builds the same string from fragments, so compare by evaluating it.
        let context = try #require(JSContext())
        context.evaluateScript(module)
        #expect(context.exception == nil)
        let csp = context.evaluateScript("globalThis.RemoteVisualAid.CSP")?.toString()
        #expect(csp == lines)
    }

    @Test func visualAidFrameCopyHasEveryDesktopClass() throws {
        let desktop = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Alas/Resources/VisualAid/frame.html"),
            encoding: .utf8)
        let phone = try asset("visual-aid.js")
        let classes = Set(desktop.matches(of: #/\.([a-zA-Z][a-zA-Z0-9-]*)\s*[{,]/#).map { String($0.1) })
        #expect(!classes.isEmpty)
        for name in classes {
            #expect(phone.contains(".\(name)"), "the phone frame is missing .\(name)")
        }
    }

    @Test func visualAidAnswerOnlyChangesTheCardWithoutReplacingItsFrame() throws {
        let source = try asset("app.js")
        let start = try #require(source.range(of: "function upsertMessage("))
        let end = try #require(source.range(of: "\n}", range: start.upperBound..<source.endIndex))
        let context = try #require(JSContext())
        context.evaluateScript("""
        var replaced = 0, updated = 0;
        var messages = new Map(), transcriptMeta = null;
        var node = { dataset: { kind: "visualAid", sid: "m1", index: "1" }, classList: { contains() { return false; } },
                     replaceWith() { replaced += 1; }, remove() {} };
        var messageNodes = new Map([["m1", node]]);
        function updateVisualAid(n, m) { updated += 1; return true; }
        function renderMessage() { return node; }
        function insertMessage() {}
        \(source[start.lowerBound..<end.upperBound])
        upsertMessage({ stableId: "m1", index: 1, kind: "visualAid", json: "{}" });
        """)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("replaced")?.toInt32() == 0)
        #expect(context.evaluateScript("updated")?.toInt32() == 1)
    }

    @MainActor
    @Test func visualAidDocumentBuilderRunsOnARealDOMParser() async throws {
        let module = try asset("visual-aid.js")
        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString("<html></html>", baseURL: nil)
        await awaitCondition { !webView.isLoading }
        _ = try await webView.evaluateJavaScript(module)
        let id = "6f0c2d4e-8b1a-4c3d-9e5f-1a2b3c4d5e6f"
        let script = """
        const parse = (s) => new DOMParser().parseFromString(s, "text/html");
        const build = (html) => {
          const doc = parse(RemoteVisualAid.buildDocument(html, "\(id)", parse));
          return { first: doc.head.firstElementChild && doc.head.firstElementChild.outerHTML,
                   scripts: doc.head.querySelectorAll("script").length,
                   body: doc.body.innerHTML, doctype: !!doc.doctype, htmlAttr: doc.documentElement.getAttribute("data-note") };
        };
        return JSON.stringify({
          fragment: build("<p>hi</p>"),
          full: build("<!DOCTYPE html><html><head><title>t</title></head><body><b>x</b></body></html>"),
          noHead: build("<html><body>y</body></html>"),
          tricky: build('<!DOCTYPE html><html data-note="<head>"><body><script>var s = "<head>";</script>z</body></html>')
        });
        """
        let raw = try await webView.callAsyncJavaScript(script, contentWorld: .page) as? String
        let result = try #require(raw.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: [String: Any]] })
        for key in ["fragment", "full", "noHead", "tricky"] {
            let entry = try #require(result[key])
            let first = try #require(entry["first"] as? String)
            #expect(first.contains("Content-Security-Policy"), "\(key): the CSP meta must be first in <head>")
            #expect((entry["scripts"] as? Int) ?? 0 >= 2, "\(key): lockdown and bridge scripts")
        }
        #expect((result["full"]?["doctype"] as? Bool) == true)
        #expect((result["tricky"]?["htmlAttr"] as? String) == "<head>", "an attribute containing <head> is untouched")
        #expect((result["tricky"]?["body"] as? String)?.contains(#"var s = "<head>";"#) == true)
    }
```

`awaitCondition(within:)` is the shared helper in `AlasTests` (a `@MainActor` global in `ACPLocalTitleGeneratorTests.swift`); use its real signature. If `callAsyncJavaScript(_:contentWorld:)` needs `arguments:`/`in:` labels, adapt. The CSP test evaluates the module in a plain `JSContext`, which has no `DOM`; `buildDocument` is not called there.

- [ ] **Step 2: Run to verify failure**

Run `-only-testing AlasTests/RemoteWebAssetTests`. Expected: FAIL (`/visual-aid.js` not referenced, `renderVisualAid` missing).

- [ ] **Step 3: Wire the page**

`index.html`: add `<script src="/visual-aid.js?v=1"></script>` after `hub-links.js` and before `app.js`; bump `/app.js?v=94` to `95` and `/style.css?v=54` to `55`. `sw.js`: add `"/visual-aid.js?v=1"`, bump the same two entries, and `CACHE_NAME` to `alas-remote-shell-v78`. The two files must agree on every versioned asset.

- [ ] **Step 4: Card rendering in `app.js`**

Add this block near the other card builders (the module's functions are used for every decision; this block only does DOM and socket effects):

```js
// ---- Visual aids ---------------------------------------------------------
const visualCards = new Map();   // visualId -> card state
let visualFrameOrder = [];       // live frame ids, least recently shown first
let visualObserver = null;

function takeOver() {
  if (currentSession) send({ type: "takeOver", sessionId: currentSession });
}

function resetVisualCards() {
  if (visualObserver) visualObserver.disconnect();
  visualObserver = null;
  visualCards.clear();
  visualFrameOrder = [];
}

function forgetVisualCard(visualId) {
  visualFrameOrder = RemoteVisualAid.releaseFrame(visualFrameOrder, visualId);
  const card = visualCards.get(visualId);
  if (card && visualObserver) visualObserver.unobserve(card.node);
  visualCards.delete(visualId);
}

function renderVisualAid(m) {
  const visual = RemoteVisualAid.parseVisual(m.json);
  if (!visual) return el("div", "msg m-agent", m.text || "");   // an old or malformed row shows its title
  const node = el("div", "msg m-visual");
  node.dataset.kind = "visualAid";
  node.dataset.visualId = visual.id;
  const host = el("div", "visual-host");
  const answer = el("div", "visual-answer");
  node.append(el("div", "visual-title", visual.title), host, answer);
  const card = { id: visual.id, node, host, answer, visual, frame: null, height: RemoteVisualAid.HEIGHT_MIN,
                 selected: [], note: "", pending: false, error: "", signature: "" };
  visualCards.set(visual.id, card);
  showVisualPlaceholder(card, "Visual not loaded");
  observeVisualCard(card);
  renderVisualAnswer(card);
  return node;
}

// An upsert that only changes the answer must not rebuild the frame: that would reload the page.
function updateVisualAid(node, m) {
  const visual = RemoteVisualAid.parseVisual(m.json);
  const card = visual && visualCards.get(visual.id);
  if (!card || card.node !== node) return false;
  const previous = card.visual;
  card.visual = visual;
  if (visual.answer) { card.pending = false; card.error = ""; }
  else if (previous.answer) card.error = RemoteVisualAid.FAILED_TEXT;   // a failed send reopened the question
  renderVisualAnswer(card);
  return true;
}

function showVisualPlaceholder(card, text) {
  card.frame = null;
  const label = el("div", "visual-placeholder-text", text);
  const button = el("button", "visual-show", "Show visual");
  button.type = "button";
  button.onclick = () => mountVisualFrame(card);
  card.host.replaceChildren(label, button);
}

function mountVisualFrame(card) {
  if (card.frame) return;
  const admitted = RemoteVisualAid.admitFrame(visualFrameOrder, card.id, RemoteVisualAid.MAX_LIVE_FRAMES);
  visualFrameOrder = admitted.order;
  admitted.evicted.forEach((id) => {
    const other = visualCards.get(id);
    if (other) showVisualPlaceholder(other, "Visual paused to save memory");
  });
  const frame = document.createElement("iframe");
  frame.setAttribute("sandbox", RemoteVisualAid.SANDBOX);
  frame.setAttribute("referrerpolicy", "no-referrer");
  frame.setAttribute("title", card.visual.title);
  frame.className = "visual-frame";
  if (card.visual.question) {   // display-only: no click, key or assistive input reaches the page
    frame.setAttribute("inert", "");
    frame.tabIndex = -1;
    frame.classList.add("is-inert");
  }
  frame.style.height = card.height + "px";
  frame.srcdoc = RemoteVisualAid.buildDocument(card.visual.html, card.id,
    (source) => new DOMParser().parseFromString(source, "text/html"));
  card.frame = frame;
  card.host.replaceChildren(frame);
}

function observeVisualCard(card) {
  if (!("IntersectionObserver" in window)) { mountVisualFrame(card); return; }
  if (!visualObserver) {
    visualObserver = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        const card = visualCards.get(entry.target.dataset.visualId);
        if (!card) return;
        if (card.frame) visualFrameOrder = RemoteVisualAid.touchFrame(visualFrameOrder, card.id);
        else mountVisualFrame(card);
      });
    }, { root: $("messages"), rootMargin: "100% 0px" });
  }
  visualObserver.observe(card.node);
}

window.addEventListener("message", (event) => {
  const data = event.data;
  if (!data || typeof data.id !== "string") return;
  const card = visualCards.get(data.id);
  if (!card || !card.frame) return;
  const height = RemoteVisualAid.heightFromMessage(data, card.id, event.source, card.frame.contentWindow);
  if (height === null) return;
  card.height = height;
  card.frame.style.height = height + "px";
});

function renderVisualAnswer(card) {
  const view = RemoteVisualAid.answerView(card.visual, {
    canDrive: canDriveKnown && canDrive, pending: card.pending, error: card.error, selected: card.selected, note: card.note });
  // Skip a redraw that would change nothing, so a typing user keeps focus when unrelated state ticks.
  const signature = JSON.stringify({ ...view, note: undefined });
  if (signature === card.signature) return;
  card.signature = signature;
  const box = card.answer;
  box.replaceChildren();
  if (view.kind === "none") return;
  if (view.kind === "dismissed") { box.append(el("div", "visual-summary", "Dismissed")); return; }
  if (view.kind === "answered") {
    box.append(el("div", "visual-summary", "Answered: " + view.labels.join(", ")));
    if (view.note) box.append(el("div", "visual-note-summary", view.note));
    return;
  }
  box.append(el("div", "visual-prompt", view.prompt));
  view.options.forEach((option) => {
    const row = el("label", "visual-option");
    const input = document.createElement("input");
    input.type = view.multiple ? "checkbox" : "radio";
    input.name = "visual-" + card.id;
    input.checked = option.checked;
    input.disabled = !view.editable;
    input.onchange = () => {
      card.selected = RemoteVisualAid.toggleSelection(card.visual.question, card.selected, option.id);
      renderVisualAnswer(card);
    };
    row.append(input, el("span", "visual-option-label", option.label));
    box.append(row);
  });
  const note = document.createElement("textarea");
  note.className = "visual-note";
  note.placeholder = "Add a note (optional)";
  note.maxLength = view.noteMax;
  note.value = card.note;
  note.disabled = !view.editable;
  const submit = el("button", "visual-submit", view.pending ? "Sending…" : "Submit");
  submit.type = "button";
  submit.disabled = !view.canSubmit;
  note.oninput = () => {
    card.note = note.value;
    submit.disabled = !RemoteVisualAid.answerView(card.visual, {
      canDrive: canDriveKnown && canDrive, pending: card.pending, selected: card.selected, note: card.note }).canSubmit;
  };
  submit.onclick = () => submitVisual(card, "answer");
  const dismiss = el("button", "visual-dismiss", "Dismiss");
  dismiss.type = "button";
  dismiss.disabled = !view.editable;
  dismiss.onclick = () => submitVisual(card, "dismiss");
  const actions = el("div", "visual-actions");
  actions.append(submit, dismiss);
  box.append(note, actions);
  if (view.hint) {
    const hint = el("button", "visual-takeover", view.hint);
    hint.type = "button";
    hint.onclick = takeOver;
    box.append(hint);
  }
  if (view.error) box.append(el("div", "visual-error", view.error));
}

function submitVisual(card, action) {
  if (!currentSession || card.pending) return;
  const msg = RemoteVisualAid.buildResponse(currentSession, card.visual, action, card.selected, card.note);
  if (!msg) return;
  card.pending = true;
  card.error = "";
  renderVisualAnswer(card);
  send(msg);
}

function rejectVisual(visualId, reason) {
  const card = visualCards.get(visualId);
  if (!card) return;
  card.pending = false;
  card.error = RemoteVisualAid.rejectionText(reason);
  renderVisualAnswer(card);
}

function refreshVisualCards() { visualCards.forEach(renderVisualAnswer); }
```

Then integrate (each is a small edit to existing code):

- `renderMessage`: add `else if (m.kind === "visualAid") { node = renderVisualAid(m); }` before the final fallback.
- `insertMessage`/`upsertMessage` hidden branches: before `messageNodes.get(m.stableId)?.remove()` capture `const gone = messageNodes.get(m.stableId); if (gone?.dataset.visualId) forgetVisualCard(gone.dataset.visualId);`.
- `upsertMessage`, in the `existing` branch, before the whole-node replacement:

  ```js
  if (existing.dataset.kind === "visualAid" && m.kind === "visualAid" && updateVisualAid(existing, m)) {
    existing.dataset.index = m.index;
    messages.set(m.stableId, m);
    return;
  }
  ```

- `applySnapshot` and `openSession`: call `resetVisualCards()` where `box.innerHTML = ""` / `$("messages").innerHTML = ""` run.
- `renderDriveBar`: call `refreshVisualCards()` after `canDrive` is applied (it already runs on every snapshot and delta).
- `handle`: `case "visualAidRejected": if (msg.sessionId === currentSession) rejectVisual(msg.visualId, msg.reason); break;`
- Replace the inline Take Over handler with `$("takeover").onclick = takeOver;`.

- [ ] **Step 5: Styles**

Append to `style.css` (reuse the existing tokens; no new colors):

```css
.m-visual { align-self: stretch; padding: 0; background: var(--bg-2); border-radius: 12px; box-shadow: inset 0 0 0 0.5px var(--ring); overflow: hidden; white-space: normal; }
.visual-title { padding: 10px 12px; font-size: 13px; font-weight: 600; color: var(--fg); border-bottom: 0.5px solid var(--line); }
.visual-host { min-height: 120px; display: flex; flex-direction: column; align-items: stretch; justify-content: center; }
.visual-frame { display: block; width: 100%; border: 0; background: transparent; }
.visual-frame.is-inert { pointer-events: none; }
.visual-placeholder-text { padding: 14px 12px 6px; text-align: center; color: var(--fg-dim); font-size: 13px; }
.visual-show, .visual-takeover { align-self: center; margin: 4px 0 14px; padding: 8px 14px; border: 0; border-radius: 10px; background: var(--fill-strong); color: var(--fg); font: inherit; }
.visual-answer { padding: 0 12px 12px; }
.visual-answer:not(:empty) { border-top: 0.5px solid var(--line); padding-top: 12px; }
.visual-prompt { margin-bottom: 8px; font-weight: 600; }
.visual-option { display: flex; align-items: center; gap: 10px; min-height: 44px; }
.visual-note { width: 100%; box-sizing: border-box; min-height: 64px; margin: 8px 0; padding: 8px 10px; border-radius: 10px; border: 0.5px solid var(--line-strong); background: var(--well); color: var(--fg); font: inherit; resize: vertical; }
.visual-actions { display: flex; gap: 8px; }
.visual-submit { padding: 10px 16px; border: 0; border-radius: 10px; background: var(--accent); color: var(--on-accent); font: inherit; font-weight: 600; }
.visual-dismiss { padding: 10px 16px; border: 0; border-radius: 10px; background: var(--fill-strong); color: var(--fg); font: inherit; }
.visual-submit:disabled, .visual-dismiss:disabled { opacity: 0.5; }
.visual-summary { color: var(--fg-muted); }
.visual-note-summary { margin-top: 4px; color: var(--fg-dim); font-size: 13px; }
.visual-error { margin-top: 8px; color: var(--del); font-size: 13px; }
```

- [ ] **Step 6: Run the tests**

Run `bash scripts/tests/remote-web-visual-aid/run.sh`, then `-only-testing AlasTests/RemoteWebAssetTests` (and the other `remote-web-*` runners the existing job uses, to confirm nothing regressed: `bash scripts/tests/remote-web-hub/run.sh`). Expected: PASS. Run `swiftformat Alas AlasTests --lint`.

- [ ] **Step 7: Commit**

```bash
git add Alas/Resources/RemoteWeb AlasTests
git commit -m "feat(remote-web): render visual aids and their questions on the phone"
```

---

### Task 5: Docs, smoke run, and wrap-up

**Files:**
- Modify: `docs/web-previews.md` (replace "The phone client does not show visuals yet." near line 146 and describe phone behavior)
- Modify: `CHANGELOG.md` (a Features line under `[Unreleased]`)
- Modify: protocol comments in `RemoteMessageWireJSON.swift` and `RemoteProtocol.swift` only if Task 1 or 2 left them stale

- [ ] **Step 1: Docs**

In `docs/web-previews.md`, replace the sentence that says the phone does not show visuals with a short section: the phone renders visuals in a sandboxed frame without script access to the app, the same https loads as desktop and no `fetch`, XHR or WebSockets; a visual with a question is display-only on the phone and is answered from phone controls under it (so `data-choice` clicks do nothing there); links inside a visual do nothing on the phone; the question is read-only until the phone drives the session (Take over); at most three frames stay live and older ones show "Show visual". Add one `CHANGELOG.md` line under `[Unreleased]` Features: `Show visual aids in the phone web client and let their questions be answered there.` Run `swiftformat Alas AlasTests --lint`.

- [ ] **Step 2: Whole-suite check of what changed**

Run, once: `-only-testing AlasTests/RemoteSessionGatewayTests -only-testing AlasTests/RemoteProtocolTests -only-testing AlasTests/RemoteWebAssetTests -only-testing AlasTests/RemotePeerConnectionTests -only-testing AlasTests/RemoteServerIntegrationTests -only-testing AlasTests/ACPToolCallPresentationTests`, and every `bash scripts/tests/remote-web-*/run.sh`. Report the `Test run with N tests in M suites` line.

- [ ] **Step 3: Commit**

```bash
git add docs/web-previews.md CHANGELOG.md
git commit -m "docs: document visual aids in the phone web client"
```

- [ ] **Step 4: Browser smoke (controller)**

The controller runs a throwaway mock server (not committed) that serves `Alas/Resources/RemoteWeb/` and speaks the `/ws` protocol enough to send `hello`, a `sessionList`, and a `transcriptSnapshot` containing: a fragment visual, a full-document visual with `<html data-note="<head>">`, a question visual (single and multiple), and a `visual_show` tool-call row. Open it at a phone width in the Alas preview and check: the cards render and size, the question visual's frame is inert and its answer controls enable only when `canDrive` is true, submitting sends a well-formed `visualAidResponse`, a `visualAidRejected` shows its message, an answered delta updates the card without reloading the frame, a fourth visual evicts the oldest, and the `visual_show` tool card shows no HTML.

- [ ] **Step 5: PR**

Push `nacho/visual-aid-phone` (set no upstream to `main`), open the PR against `main`, and shepherd it with the lassie flow.
