# iOS Transcript: Collapsed Activity and Images — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The iOS transcript folds thinking and tool calls into the Mac's activity and "Worked for" bundles, and shows transcript images (markdown, tool output, attachments) with a full-screen viewer.

**Architecture:** The fold rules move from `Alas/` into `AlasRemoteKit` and run over a small per-row fold item instead of `ACPMessage`. The Mac keeps its call sites through a thin adapter. The Mac classifies each tool call and sends that classification, plus agent phase and message times, as optional wire fields. The phone and the Mac's peer view fold wire rows with one shared function.

**Tech Stack:** Swift 6, SwiftUI/UIKit (iOS), SwiftUI/AppKit (macOS), SwiftPM package `Packages/AlasCore`, Swift Testing, xcodegen.

**Spec:** `docs/superpowers/specs/2026-11-16-ios-transcript-activity-and-images-design.md`

## Global Constraints

- `AlasRemoteKit` must build for iOS: Foundation, CryptoKit and Observation only; its one package dependency is swift-crypto. Everything moved into it is `public`.
- PR 1 is behaviour-neutral on the Mac. Do not change Mac grouping or scroller tests: they must pass unedited, except for an added `import`. That is the proof of neutrality.
- Every wire addition is optional. An older Mac omits it, and an older phone ignores it.
- `createdAt` is sent only when `ACPTranscript.createdAt(forMessageAt:)` returns a date. Never fall back to now.
- Tests use Swift Testing and follow AGENTS.md: extend existing suites, parameterize, no fixed sleeps. There is no iOS test target, so shared logic is tested in `Packages/AlasCore/Tests/AlasCoreTests`.
- New files under `Mobile/` need `cd Mobile && xcodegen`, and the regenerated project must be committed. Never commit `Mobile/AlasMobile.xcodeproj/xcshareddata/xcschemes/AlasMobile.xcscheme`.
- Conventional Commits. No agent attribution anywhere: no Co-Authored-By trailer, no 🤖 line, no "Generated with" footer.
- Ship one PR at a time: open it, shepherd it with `/lassie <n> --merge`, and start the next PR from fresh `origin/main` once it has merged.

## Review Focus

1. **An older Mac sends rows without `phase`, `createdAt` or `fold`.** The phone still folds: finished and running tool calls join, the verb comes from `ACPToolCall.kind`, and a completed turn reads "Worked" with no time. Pinned in Task 3.
2. **Hidden rows (`isHidden` markers) between tool calls.** They neither split a run nor count in its summary. Pinned in Task 3.
3. **A tool call the Mac marks `joins: false`** (a subagent, background task or compaction). It stays its own row and breaks the run. Pinned in Task 3.
4. **Image sources the phone can't fetch.** Covers `data:` URIs, `file://` URLs, relative paths, and `http(s)` URLs. Each is classified the same way as on the Mac; nothing crashes, and the alt text shows instead. Pinned in Task 5.
5. **A live turn on the phone grows past 5 steps.** The group stays open showing the last 5, collapsing it sticks, and new steps don't re-open it. This is the expansion store's existing behaviour, already pinned by the Mac tests that move with it. Checked by hand on the simulator in Task 4.

---

## PR 1: the fold moves to `AlasRemoteKit`

Branch `nacho/ios-transcript-fold` from `origin/main`. Carry the spec and this plan in the first commit.

### Task 1: Shared fold over fold items, Mac adapter

**Files:**
- Create: `Packages/AlasCore/Sources/AlasRemoteKit/Transcript/ACPTranscriptFold.swift`.
  - Moved types, made `public`: `ACPTranscriptVisibleRow` (stored `index` and `stableId`, plus `id` only), `ACPTranscriptToolCallGroup`, `ACPTranscriptRenderRow`, `ACPToolCallGrouping`, `ACPToolCallGroupSummary`, `ACPToolCallGroupExpansionSeeds`.
  - New types: `ACPTranscriptFoldItem`, `ACPTranscriptFoldToolCall`, `ACPTranscriptFoldSource`.
- Modify: `Alas/Sources/ACP/UI/ACPToolCallGrouping.swift`. It becomes the Mac adapter only (below).
- Modify: `Alas/Sources/ACP/UI/ACPTranscriptVisibleRow.swift`. The struct definition goes. `isHidden(_:hiddenToolCallIds:)` and the window-slicing statics stay, as an `extension ACPTranscriptVisibleRow`. `ACPTranscriptVisibleRowLookup` stays.
- Modify: `Packages/AlasCore/Sources/AlasSessions/ACP/Session/ACPSession.swift:4663`. `isFinalStatus` delegates to `ACPToolCall.isFinalStatus`.
- Modify: `Packages/AlasCore/Sources/AlasRemoteKit/Transcript/ACPToolCall.swift`. Add `public static func isFinalStatus(_ status: String) -> Bool`, moving the body: "completed", "failed", "canceled" and "cancelled" are final.
- Add `import AlasRemoteKit` wherever the Mac target needs it.

**Interfaces (produced):**

```swift
public struct ACPTranscriptFoldToolCall: Equatable, Sendable {
    public var status: String
    /// False for compactions, subagents, background tasks and hidden visual_show chips.
    public var joins: Bool
    public var verb: ACPToolCallGroupSummary.Verb
}
public enum ACPTranscriptFoldItem: Equatable, Sendable {
    case user, agent(isCommentary: Bool), thought, plan, toolCall(ACPTranscriptFoldToolCall), other
}
/// Lazy, so the Mac never maps a whole transcript per fold.
public struct ACPTranscriptFoldSource {
    public let count: Int
    public let item: (Int) -> ACPTranscriptFoldItem
    public let createdAt: (Int) -> Date?
}
public enum ACPToolCallGroupSummary.Verb: String { case read, search, run, edit, other }  // raw values go on the wire
```

- `ACPToolCallGrouping.fold(rows: [ACPTranscriptVisibleRow], source: ACPTranscriptFoldSource, options: Options, isExpanded:, memberLimit:) -> [ACPTranscriptRenderRow]`. Today's algorithm, with `messages[i]` reads replaced by `source.item(i)`.
- `isCollapsible(_ item: ACPTranscriptFoldItem) -> Bool`. A thought is collapsible. A tool call is collapsible when `joins`, and its status is final or `"in_progress"` or `"pending"`.
- `currentTurnAnswerIndex(source:currentTurnUserIndex:isTurnActive:)` and `priorCurrentTurnCommentaryIndices(source:currentTurnUserIndex:visibleRange:)`. A non-commentary `.agent` is an answer.
- `ACPToolCallGroupSummary.init(toolCalls: [ACPTranscriptFoldToolCall], kind:isLive:)` and `static func verb(forLabel: String) -> Verb`. The latter is the existing label switch: "Read" and "Viewed Image" are `.read`; "Searched", "Find", "Web Search" and "Opened Page" are `.search`; "Ran" is `.run`; "Edit" is `.edit`; anything else is `.other`.
- Drop `@MainActor` from the pure fold functions, and keep it on `ACPToolCallGroupExpansionSeeds`.

**Mac adapter**, in `Alas/Sources/ACP/UI/ACPToolCallGrouping.swift`:
- `extension ACPTranscriptFoldItem { init(_ message: ACPMessage, hiddenToolCallIds: Set<String>) }`.
  - `joins` keeps today's `isCollapsible` exclusions: `ACPContextCompaction`, `ACPSubagentRowDescriptor`, `ACPBackgroundTask`, and `hiddenToolCallIds`.
  - The verb is `verb(forLabel: ACPToolCallPresentation.resolve(call).label)`.
  - `isCommentary` is `buffer.phase == .commentary`.
- Overloads with **today's exact signatures** that build a source over `messages` and forward:
  - `fold(rows:messages:options:hiddenToolCallIds:messageCreatedAt:isExpanded:memberLimit:)`;
  - `currentTurnAnswerIndex(messages:…)`, `priorCurrentTurnCommentaryIndices(messages:…)`, `isCollapsible(_ message:hiddenToolCallIds:)`;
  - `ACPToolCallGroupSummary.init(toolCalls: [ACPMessage.ToolCall], kind:isLive:)` and `verb(for presentation: ACPToolCallPresentation)`.

  Every existing call site and test then compiles unchanged.

- [ ] **Step 1:** Move the types and add the fold-item API as above. Leave the algorithm bodies textually the same apart from the item reads.
- [ ] **Step 2:** Build the package for iOS to prove `AlasRemoteKit` stays clean.
  - Run `xcodebuild -scheme AlasRemoteKit -destination 'generic/platform=iOS Simulator' -quiet build` from `Packages/AlasCore`.
  - If that scheme is missing, build the iOS app instead, as in Task 4 Step 4.
  - Expected: `BUILD SUCCEEDED`.
- [ ] **Step 3:** Run `swift test --package-path Packages/AlasCore`. Expected: the `Test run with N tests` line reports success.
- [ ] **Step 4:** Run the Mac suites unedited.
  ```bash
  xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation \
    -only-testing AlasTests/ACPToolCallGroupingTests -only-testing AlasTests/ACPToolCallGroupRowTests \
    -only-testing AlasTests/ACPTranscriptScrollerPolicyTests -only-testing AlasTests/ACPSubagentSessionTests test > /tmp/fold.log 2>&1
  ```
  Expected: the ✔ lines for all four suites, and no ✘ lines. Grep the log for `TEST SUCCEEDED`. Don't trust a piped exit code.
- [ ] **Step 5:** Commit with `refactor(transcript): fold transcript activity in AlasRemoteKit`. Push, open the PR, and run `/lassie <n> --merge`.

## PR 2: fold facts on the wire

Branch `nacho/ios-transcript-wire` from `origin/main` after PR 1 merges.

### Task 2: `phase`, `createdAt` and `fold` on `RemoteWireMessage`

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasRemoteKit/Protocol/RemoteMessageWireJSON.swift`. Add three optional fields to `RemoteWireMessage`, encoded only when non-nil:
  - `public var phase: String?`, which is `"commentary"` or omitted;
  - `public var createdAt: Int64?`, in epoch milliseconds;
  - `public var fold: Fold?`, where `public struct Fold: Codable, Equatable, Sendable { public let joins: Bool; public let verb: String }`.
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost+Transcripts.swift`. `HostTranscriptMessage` gains `createdAt: Int64?`. `init?(_:at:)` takes `createdAt: Date?`. Both builders pass `transcript.createdAt(forMessageAt:)`: `AlasHost+Transcripts.swift:232` and `AlasHost+Sessions.swift:278`.
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Gateway/RemoteTranscriptSync.swift` and `RemoteSessionGateway.swift`.
  - The sync state keeps `createdAt` per index, beside `messages`, where decoded messages are stored (gateway lines ~385 and ~849).
  - `toWire(_:index:fullToolCallContent:createdAt:)` sets the fields:
    - `createdAt` on every row that has one;
    - `phase = "commentary"` on `.agent` rows with commentary phase;
    - `fold` on visible `.toolCall` rows, from `ACPTranscriptFoldItem(message, hiddenToolCallIds: [])`'s tool call, with `verb` as `Verb.rawValue`.
  - **Check, don't assume:** confirm that every row the local Mac hides through `ACPTranscriptVisibleRow.isHidden` already goes out as an `isHidden` marker, except `.plan`. Pay particular attention to `planDocument` with `display == nil` against `document.hidden`. Close any gap in `toWire`.
- Test: `Packages/AlasCore/Tests/AlasCoreTests/RemoteWireCompatibilityTests.swift`. Add one `RemoteWireSamples.serverMessages` delta whose rows carry `phase`, `createdAt` and `fold`. The existing round-trip test then covers them.
- Test: extend the existing gateway `toWire` suite (`grep -rl "toWire(" Packages/AlasCore/Tests`) with one parameterized test, `toWireCarriesFoldFacts`:
  - a commentary agent row has `phase == "commentary"`, and a final-answer row has `phase == nil`;
  - a read tool call has `fold == .init(joins: true, verb: "read")`;
  - a subagent tool call has `fold?.joins == false`;
  - `toWire(..., createdAt: nil).createdAt == nil`.

- [ ] **Step 1:** Write `toWireCarriesFoldFacts` and the sample.
- [ ] **Step 2:** Run `swift test --package-path Packages/AlasCore --filter "RemoteWireCompatibilityTests|<gateway suite>"`. Expected: FAIL, because the fields don't exist yet.
- [ ] **Step 3:** Implement the fields and the gateway changes.
- [ ] **Step 4:** Run the same filter. Expected: PASS.

### Task 3: One wire fold for the phone and the Mac's peer view

**Files:**
- Create: `Packages/AlasCore/Sources/AlasRemoteKit/Transcript/RemoteTranscriptFold.swift`.
- Modify: `Alas/Sources/Remote/Native/NativePeerTranscriptPresentation.swift`. `NativePeerTranscriptFold.renderRows` forwards to `RemoteTranscriptFold.renderRows`. Proxies stay for the row views, but no longer feed the fold.
- Test: create `Packages/AlasCore/Tests/AlasCoreTests/RemoteTranscriptFoldTests.swift`.

**Interfaces (produced):**

```swift
public enum RemoteTranscriptFold {
    /// `messages` in transcript order; `isHidden` rows are dropped before folding.
    /// Row indices in the result are positions in `messages`.
    public static func renderRows(messages: [RemoteWireMessage], isTurnActive: Bool,
                                  isExpanded: (ACPTranscriptToolCallGroup) -> Bool,
                                  memberLimit: (ACPTranscriptToolCallGroup) -> Int?) -> [ACPTranscriptRenderRow]
    /// Fold facts for one wire row; falls back when an older Mac sent no `fold`.
    public static func item(for message: RemoteWireMessage) -> ACPTranscriptFoldItem
    public static func summaryToolCalls(of group: ACPTranscriptToolCallGroup,
                                        in messages: [RemoteWireMessage]) -> [ACPTranscriptFoldToolCall]
}
```

`item(for:)` maps each wire kind to a fold item:
- `"user"` → `.user`.
- `"agent"` → `.agent(isCommentary: phase == "commentary")`.
- `"thought"` → `.thought`.
- `"plan"` → `.plan`.
- `"toolCall"` → `.toolCall`:
  - with `status` from the decoded `ACPToolCall`;
  - with `joins` and `verb` from `fold` when present;
  - without `fold`, `joins = true` and the verb comes from `call.kind`: `read` → `.read`; `search` and `fetch` → `.search`; `execute` → `.run`; `edit`, `delete` and `move` → `.edit`; anything else → `.other`.
- Everything else → `.other`.

`createdAt` comes from the message, converted from milliseconds.

- [ ] **Step 1:** Write the tests. Each builds `[RemoteWireMessage]` with `RemoteWireMessage(stableId:kind:text:json:index:)` and encodes tool calls with `ACPToolCall`.
  - `readsAndRunsFoldIntoOneGroup`: user, read, read, run, agent (idle) gives `[.message(user), .toolCallGroup(g), .message(agent)]`. `g` has 3 members and `kind == .completedTurn(duration: nil)`. Its summary `label` is `"Worked · read 2 files, ran 1 command"`.
  - `durationComesFromWireTimes`: the same rows, with user `createdAt` 0 and agent `createdAt` 125_000. The label starts with `"Worked for 2m 5s"`.
  - `hiddenRowNeitherSplitsNorCounts`: read, hidden marker, read, then an agent row while active. This gives one group with 2 members.
  - `nonJoiningCallBreaksTheRun`: read, read, then a call with `fold: .init(joins: false, verb: "other")`, then read, read. This gives a group, the plain row, and a group.
  - `olderMacFallsBackToKind`, parameterized over `(kind, expectedVerb)` for `execute` → `.run`, `read` → `.read`, `fetch` → `.search` and `think` → `.other`. A row without `fold` gives `.toolCall` with `joins == true` and that verb.
  - `commentaryIsNotTheAnswer`: user, commentary agent, read, then a final agent while idle. The commentary and the read fold into the completed-turn group, and the final agent stays a plain row.
- [ ] **Step 2:** Run `swift test --package-path Packages/AlasCore --filter RemoteTranscriptFoldTests`. Expected: FAIL to compile.
- [ ] **Step 3:** Implement `RemoteTranscriptFold`. `renderRows` builds `ACPTranscriptVisibleRow(index: position, stableId:)` for non-hidden messages, and `ACPTranscriptFoldSource(count: messages.count, item: { item(for: messages[$0]) }, createdAt: …)`. It computes `currentTurnAnswerIndex` and `priorCurrentTurnCommentaryIndices` from the source, then calls `ACPToolCallGrouping.fold`.
- [ ] **Step 4:** Run the filter again. Expected: PASS.
- [ ] **Step 5:** Point `NativePeerTranscriptFold.renderRows` at it. The peer scroller builds the summary from `RemoteTranscriptFold.summaryToolCalls` instead of proxies (`NativePeerTranscriptScroller.swift:320`).
  - Run `xcodebuild … -only-testing AlasTests/NativePeerTranscriptPresentationTests test` if that suite exists (`ls AlasTests/Remote`). Otherwise do the Mac build from AGENTS.md. Expected: SUCCEEDED.
- [ ] **Step 6:** Commit with `feat(remote): send fold facts and message times to remote transcripts`. Push, open the PR, and run `/lassie <n> --merge`.

## PR 3: collapsed activity on the phone

Branch `nacho/ios-transcript-activity` from `origin/main` after PR 2 merges.

### Task 4: Group rows in the iOS transcript

**Files:**
- Modify: `Mobile/Sources/Transcript/TranscriptSession.swift`.
  - `TranscriptItem` gains `enum Kind { case message, groupHeader(ACPTranscriptToolCallGroup, ACPToolCallGroupSummary, expanded: Bool, hiddenCount: Int) }` and `let kind: Kind`.
  - Message items keep `row` and `message`. A group item uses the group's `id` and the first member's message.
  - `publish()` builds items from `RemoteTranscriptFold.renderRows(messages: state.messages, isTurnActive: streamingState != "idle", isExpanded: seeds.isExpanded, memberLimit: seeds.memberLimit)`. Item mapping:
    - `.message` and `.toolCallGroupMember` become message items, and members get `isGroupMember = true`;
    - `.toolCallGroup` becomes a header item with `expanded: false`;
    - `.toolCallGroupHeader` becomes a header item with `expanded: true` and `hiddenCount = members.count - shown`.
  - Before the fold, call `seeds.syncLineage` and `syncCollapsed` for each group, as the Mac does.
  - The session owns `let seeds = ACPToolCallGroupExpansionSeeds()`. `seeds.onChange` republishes: the fold result depends on expansion, so the `messagesGeneration` short-cut must also key on `seeds.generation`.
  - Add `func toggle(_ group: ACPTranscriptToolCallGroup)`, which calls `seeds.setExpanded(!seeds.isExpanded(group), members:)`. Add `func showAll(_ group:)`, which calls `seeds.setExpanded(true, members:)`.
- Create: `Mobile/Sources/Transcript/ToolCallGroupRow.swift`. It shows:
  - the `summary.iconSystemName` icon;
  - `summary.labelBeforeFailure`, followed by `summary.failureLabel` in `.red` after `ACPToolCallGroupSummary.failureSeparator`;
  - a chevron, down when collapsed and up when expanded;
  - when `hiddenCount > 0`, a "Show \(hiddenCount) earlier" button that calls `showAll`.

  The whole row toggles. It is `.secondary` styled, at the caption/subheadline size used by today's tool-call row.
- Modify: `Mobile/Sources/Transcript/TranscriptRowView.swift`. Group headers render `ToolCallGroupRow`. Member rows get a 12 pt leading inset and a thin leading rule, so they read as inside the group.
- Modify: `Mobile/Sources/Transcript/TranscriptCollectionView.swift`. A tap on a header calls `session.toggle(group)`. The existing keep-tapped-row-in-place logic applies.

- [ ] **Step 1:** Implement the above. Run `cd Mobile && xcodegen` for the new file.
- [ ] **Step 2:** Build the iOS app.
  ```bash
  cd Mobile && xcodebuild -project AlasMobile.xcodeproj -scheme AlasMobile -destination 'generic/platform=iOS Simulator' \
    -skipPackagePluginValidation -skipMacroValidation -quiet build > /tmp/ios.log 2>&1; echo $?
  ```
  Expected: `0`, and no `.swift:N:N: error` lines.
- [ ] **Step 3:** Verify on the simulator against a throwaway `alas-host`. Use the recipe in the spec's predecessor (`ALAS_APP_SUPPORT_DIR=/tmp/<dir>/Alas`, port 8799, reachability lan, pair over 192.168.1.143:8799). Never use the user's Alas on 8765. Check:
  - a finished turn shows "Worked for …" above the answer;
  - a running turn shows "Exploring · N so far", open with its last 5 steps;
  - collapsing it sticks while it grows;
  - "Show N earlier" reveals the rest.
- [ ] **Step 4:** Commit `feat(ios): fold transcript activity like the Mac`, but not the xcscheme. Push, open the PR, and run `/lassie <n> --merge`.

## PR 4: images on the phone

Branch `nacho/ios-transcript-images` from `origin/main` after PR 3 merges.

### Task 5: Image sources, markdown images, tool-call images

**Files:**
- Create: `Packages/AlasCore/Sources/AlasRemoteKit/Transcript/RemoteTranscriptImageSource.swift`.
- Test: `Packages/AlasCore/Tests/AlasCoreTests/RemoteTranscriptFoldTests.swift`. It is the remote-transcript suite, so add the image tests there rather than in a new file.
- Modify: `Mobile/Sources/Transcript/MarkdownBlocks.swift`. Add `case image(source: String, alt: String)`, emitted when a paragraph's only child is a `Markdown.Image`. An inline image inside other text renders as its alt text.
- Modify: `Mobile/Sources/Transcript/TranscriptRowView.swift`.
  - Image blocks and `ACPToolCall.assets` images render as `TranscriptImage`.
  - Assets show under the tool call's expanded content.
- Create: `Mobile/Sources/Transcript/TranscriptImage.swift`.
  - It resolves the source through `RemoteTranscriptImageSource`, and fits the width with a max height of 320 pt, keeping the aspect ratio.
  - It shows the alt text or name while loading and on failure.
  - Tap opens the viewer (Task 6).

**Interfaces (produced):**

```swift
public enum RemoteTranscriptImageSource: Equatable, Sendable {
    case inline(Data)          // data: URI or an asset's base64 `data`
    case host(path: String)    // fetched with readTranscriptImage; the host resolves relative paths
    case unavailable           // shown as alt text / name
    public static func resolve(source: String) -> RemoteTranscriptImageSource
    public static func resolve(asset: ACPToolCallAsset) -> RemoteTranscriptImageSource  // inline data first, then uri
}
```

**Rules to mirror:** read the Mac's `ACPToolCallAsset.canLoadImage` / `loadedTranscriptImage` (`grep -rn "func loadedTranscriptImage\|func canLoadImage" Alas/Sources Packages/AlasCore/Sources`) and resolve each scheme exactly as it does:
- `data:` → `.inline`;
- `file://` → `.host` with the path;
- relative and absolute paths → `.host`;
- `http(s)` → whatever the Mac does. If the Mac refuses these, use `.unavailable`.

- [ ] **Step 1:** Write `imageSourcesResolveLikeTheMac`, parameterized over `(source, expected)`:
  - `"data:image/png;base64,iVBORw0KGgo="` → `.inline` with the decoded bytes;
  - `"/tmp/a.png"` → `.host(path: "/tmp/a.png")`;
  - `"file:///tmp/a.png"` → `.host(path: "/tmp/a.png")`;
  - `"shots/a.png"` → `.host(path: "shots/a.png")`;
  - `"https://example.com/a.png"` → whatever the Mac rule gives;
  - `""` → `.unavailable`.

  Also write `assetPrefersInlineData`: an asset with both `data` and `uri` gives `.inline`, and one with neither gives `.unavailable`.
- [ ] **Step 2:** Run `swift test --package-path Packages/AlasCore --filter RemoteTranscriptFoldTests`. Expected: FAIL.
- [ ] **Step 3:** Implement the resolver, then the iOS views. `.host` goes through `TranscriptSession.image(for:)`, the existing cached and de-duplicated `readTranscriptImage` path.
- [ ] **Step 4:** Run the filter again (expected PASS), then the iOS build from Task 4 Step 2 after `xcodegen`.

### Task 6: Full-screen image viewer

**Files:**
- Create: `Mobile/Sources/Transcript/TranscriptImageViewer.swift`.
  - A `fullScreenCover` holding a `UIScrollView`-backed zoom view (`UIViewRepresentable`). Pinch zooms from 1× to 4×, and double-tap toggles between 1× and 2.5×.
  - A `ShareLink` with the image. A close button, plus swipe-down to dismiss when at 1×. A black background.
- Modify: `TranscriptImage.swift` and the user-attachment thumbnails in `TranscriptRowView.swift` to open it on tap.

- [ ] **Step 1:** Implement the viewer and wire both entry points. Run `cd Mobile && xcodegen`, then the iOS build. Expected: `0`.
- [ ] **Step 2:** Verify on the simulator against the throwaway host. Check:
  - an agent reply containing `![shot](/tmp/<dir>/shot.png)` shows the image;
  - a tool call with image output shows it when expanded;
  - tapping any image, including an attachment, opens the viewer;
  - pinch, double-tap, share and dismiss all work.
- [ ] **Step 3:** Commit `feat(ios): show transcript images with a full-screen viewer`. Push, open the PR, and run `/lassie <n> --merge`.
