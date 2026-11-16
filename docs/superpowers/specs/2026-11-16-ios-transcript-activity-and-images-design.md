# iOS transcript parity, slice 1: collapsed activity and images

## Intent

The phone's transcript should read like the Mac's. Today the iOS app
(`Mobile/`) draws every tool call as its own card, drops images inside agent
replies, and ignores the images tool calls produce. A long agent turn becomes
a wall of cards on the phone while the Mac shows one line, "Worked for 2m ·
read 6 files, ran 3 commands", above the answer.

The goal is 1:1 parity with the Mac transcript, everything in it. That is
several projects. This document covers the first slice, which the user picked:
**collapsed activity** and **images**. The rest is listed at the end in the
order proposed for later slices.

## Goals

- The phone folds thinking and tool calls into the same bundles the Mac's
  **own local transcript** shows (not its peer view, which today gets less
  data), with the same labels, icons and failure counts:
  - activity runs ("Read 4 files, ran 2 commands", "Thought");
  - completed-turn bundles ("Worked for 2m · …") above a turn's answer;
  - the live tail ("Exploring · 3 so far", "Running · …"), open while the
    turn runs, showing its last 5 steps with the rest one tap away.
- The Mac and the phone fold from the **same code**, so they cannot drift.
- Images show on the phone wherever the Mac shows them:
  - markdown images in agent replies;
  - image output attached to tool calls (`ACPToolCall.assets`);
  - user attachments (already shown as thumbnails).
- Any transcript image opens full screen on tap, with pinch to zoom and share.

## Non-goals (this slice)

- The Mac's drawing code. It is AppKit and stays as is; the phone gets its own
  SwiftUI/UIKit drawing.
- Richer tool-call cards, diffs, syntax colouring, mermaid, terminal output,
  subagents. These are later slices, listed at the end.
- A setting to turn bundling off on the phone. The Mac has one; the phone
  always bundles. Add the setting if someone asks.

## Anti-goals

- **Any change in what the Mac transcript shows or how it scrolls.** The fold
  feeds a scroller with scroll-anchor invariants that took several fixes to get
  right. Moving the fold must be behaviour-neutral on the Mac, and the
  existing Mac grouping and scroller tests must pass unchanged in meaning.
- A phone copy of the fold rules. Rejected below; it drifts.
- Breaking older Macs or older phones. Every wire addition is optional.

## Constraints

- `AlasRemoteKit` must build for iOS: Foundation, CryptoKit and Observation
  only. Its only package dependency is swift-crypto. Anything moved into it
  must lose its imports of `AlasSessions`, `AlasACP`, `AlasFeatures` and the like.
- AGENTS.md testing policy: fewer, sharper tests; extend existing suites; move
  tests with the code they cover rather than duplicating them.
- There is no iOS test target. Shared logic is tested in `AlasCoreTests`
  (`swift test --package-path Packages/AlasCore`); the phone's views are
  checked on the simulator.
- Rows over `RemoteTranscriptSync.maxMessageBytes` are replaced by a notice
  before they reach the phone. Inline image bytes inside tool-call assets
  are already subject to that limit; larger images must be fetched by path.
- Multi-PR work ships one PR at a time, each merged before the next starts.

## Approaches considered

1. **Move the fold rules into `AlasRemoteKit`, used by both apps.** Picked.
   Only the decisions move: what joins a run, where a turn ends, live-tail
   detection, the summary counts and labels, and expansion state. Each app
   keeps its own drawing. One implementation, so the two can't disagree. The
   cost is touching the Mac's grouping code, which the existing tests guard.
2. **The Mac sends ready-made groups to the phone.** Rejected. A group's shape
   changes as later rows arrive (a completed turn re-kinds earlier rows), so
   the Mac would have to keep re-sending earlier rows. It adds protocol work
   and traffic for no gain over 1.
3. **Copy the rules into the phone app.** Rejected. Fastest, but it drifts the
   first time the Mac's rules change. That defeats the point.

## Design

### A. The fold, shared

Today the fold is in `Alas/Sources/ACP/UI/ACPToolCallGrouping.swift`:
`ACPTranscriptToolCallGroup`, `ACPTranscriptRenderRow`, `ACPToolCallGrouping`
(`fold`, `isCollapsible`, `currentTurnAnswerIndex`,
`priorCurrentTurnCommentaryIndices`), `ACPToolCallGroupSummary` and
`ACPToolCallGroupExpansionSeeds`. It runs over `[ACPMessage]`, which lives in
`AlasSessions`. The phone can't link `AlasSessions`.

The Mac already folds transcripts that arrive over the wire:
`Alas/Sources/Remote/Native/NativePeerTranscriptPresentation.swift` turns
each `RemoteTranscriptRow` into a proxy `ACPMessage` and calls the same
`fold`. That proves the fold needs only a small amount of information per row.

The move:

- The fold runs over a small per-row value defined in `AlasRemoteKit`, not over
  `ACPMessage`. This document calls it the fold item. Per row it carries:
  - the role: user, agent, thought, plan, tool call, or other;
  - for agent rows, whether the text is commentary;
  - for tool calls, the status, the summary verb (read, search, run, edit,
    other), and whether the call can join a bundle at all;
  - the row's creation time, when known.
- Both apps build these items. The Mac builds them from `ACPMessage` for its
  own sessions and its peer view. The phone builds them from
  `RemoteTranscriptRow`. `fold` and `currentTurnAnswerIndex` take items.
- *Decision (mine):* the per-tool-call facts are **classified on the Mac
  and sent on the wire**, not recomputed on the phone. These facts are
  whether the call can join a bundle and its summary verb. Recomputing them
  doesn't work: the classifiers read fields the gateway strips before
  sending:
  - `ACPSubagentRowDescriptor`, `ACPBackgroundTask` and
    `ACPToolCallPresentation` read `metadata`;
  - the "Viewed Image" check reads `rawOutput`;
  - `visual_show` calls are rewritten before they go out.

  So the classifiers stay in `AlasSessions`, untouched. The Mac builds fold
  items from them as it does today, and the gateway puts their answers on
  the wire (B). Only the fold, summary, expansion store and render-row types
  move. Peer-view parity comes free, because the Mac's peer view reads the
  same wire facts.
- Hidden rows: the local Mac folds over rows already filtered by
  `ACPTranscriptVisibleRow.isHidden`, and passes `hiddenToolCallIds` and the
  prior-commentary indices. *Decision (mine):* the Mac's wire already marks
  most of those rows `isHidden`. The gateway extends that to every row the
  local transcript hides, so the phone and the peer view drop `isHidden`
  rows before folding. The one exception is plan rows: the phone keeps
  showing them as its checklist because it has no plan pill. The fold
  already treats plans as transparent to runs.
  `priorCurrentTurnCommentaryIndices` is computed from fold items on each
  side, so it moves with the fold.
- The summary labels and icon choice move with the fold. Both apps show the
  same strings. Icons are SF Symbol names, which exist on both platforms.
- The expansion store `ACPToolCallGroupExpansionSeeds` moves too. It depends
  only on the group type. On the phone, its explicit-collapse and lineage
  rules matter for the same reason they do on the Mac: the phone pages older
  rows in, and a live group keeps growing.
- `ACPTranscriptRenderRow` (collapsed group / expanded header / member /
  plain message) moves as well. Expanded members tile as their own rows on
  both platforms, as the Mac's design requires.
- The fold's tests move with it, from `AlasTests/ACP/UI/ACPToolCallGroupingTests.swift`
  to `AlasCoreTests`, rewritten over fold items where they built
  `ACPMessage`s. Mac scroller tests stay where they are.

### B. Two optional fields on the wire

Completed-turn bundles need two facts the phone doesn't receive today.
Without them, the Mac's own peer view also shows "Worked" with no duration,
and treats commentary as the turn's answer.

- `RemoteWireMessage.phase`, on agent rows: whether the text is commentary.
  The Mac maps it from `StreamingText.phase`.
- `RemoteWireMessage.createdAt`, as epoch milliseconds, on at least user and
  agent rows. These are the rows whose times give a turn's duration.
  *Decision (mine):* send only what `ACPTranscript.createdAt(forMessageAt:)`
  knows, which is the same source the Mac's own "Worked for" uses. Omit
  the field when it is nil. Never fall back to now, as
  `ACPSessionRunner.createdAt(forMessageAt:)` does, or old turns would show
  bogus durations. Where the Mac shows "Worked" with no time, the phone does
  too.
- `RemoteWireMessage.fold`, on tool-call rows: `{joins: Bool, verb: String}`.
  This is the Mac's classification from A. An older Mac omits it. The phone
  then falls back: a call with a final or running status joins, and its verb
  comes from `ACPToolCall.kind`. That fallback may disagree with the Mac on
  subagents and MCP tools, which is acceptable for an old Mac.

Both are optional. An older Mac omits them, and the phone falls back to what
the Mac's peer view does today. An older phone ignores them. Encoding them
must keep `RemoteWireCompatibilityTests` round-tripping. The Mac's peer view
uses them too, so it gains durations as a side effect.

### C. The phone draws the bundles

- `TranscriptSession` and `TranscriptScreen` build `[TranscriptItem]` from the
  shared render rows instead of one item per wire row. That is a collapsed
  group, an expanded group's header followed by its members as ordinary rows,
  or a plain message.
- A group row shows the summary icon and label, the failure part in red, and
  a chevron. Tapping it toggles expansion through the shared store.
  `TranscriptCollectionView` already keeps a tapped row in place when it
  changes height, so the toggle doesn't jump.
- A live group opens automatically and shows its last 5 members. Its header
  offers the earlier ones, matching the Mac.
- A member row is today's tool-call or thought row, unchanged. Better tool
  cards are a later slice.
- Group ids are derived from the first member's stable id, as on the Mac. The
  collection view's diffing therefore updates a growing group in place.

### D. Images on the phone

- Markdown images: `MarkdownBlocks` gains an image block, with the source and
  the alt text. Its source is handled the way the Mac's markdown image view
  (`ACPMarkdownImageBlockView` / `ACPTranscriptImageReader`) handles it:
  - a file path is read from the Mac with the existing `readTranscriptImage`
    request, as the Mac's peer view already does;
  - other schemes follow the Mac's rules (allowed or refused).
  Alt text shows while the image loads and if it fails.
- Tool-call images: `ACPToolCall.assets` are shown under the tool call's
  content. Inline bytes are used when present; otherwise the image is fetched
  by its `uri` with `readTranscriptImage`.
  *Decision (mine):* an image the agent returned only inline, such as a
  base64 MCP screenshot, can be too big for the gateway's inline budget.
  It then arrives with neither a `uri` nor bytes. It shows as a placeholder
  with its name. Spilling such bytes to a file the phone can fetch is new
  host protocol, and is listed under later slices.
- Layout: images fit the column width, with a capped height (around 320 pt)
  and their aspect ratio kept. A bundle's collapsed row shows no images; they
  appear when it is expanded.
- Viewer: tapping any transcript image opens a full-screen viewer with pinch
  and double-tap zoom, a share button, and swipe-down or a button to close.
  User attachments use the same viewer.
- Loaded images go through `TranscriptSession`'s existing image cache and
  request de-duplication.

### Delivery

Four PRs, in order, each merged before the next:

1. Move the fold into `AlasRemoteKit`. The Mac's behaviour does not change, and
   its tests move or stay green.
2. Add the wire fields `phase`, `createdAt` and `fold`, and the extended
   `isHidden` coverage. The Mac sends them and its peer view uses them.
3. Collapsed activity on the phone.
4. Images on the phone.

## Left to the builder

- The exact shape and name of the fold item, and of the moved helpers.
- Which pieces of `ACPToolCallPresentation` the verb needs, and how to split
  them out without changing Mac labels.
- How `ACPVisibleRowsCache` and the scroller adapt to the new fold input.
- Exact viewer and image-cell layout, within the description above.
- Whether a phone-side memo of the fold result is needed. Measure first.

## Later slices (proposed order)

1. Tool-call cards: preview line, duration, verb titles, locations, and
   command output. Data is on the wire.
2. Diffs: proper hunks for `ACPFileEdit` and `ACPToolCall.diffs`. Data is on
   the wire.
3. Markdown:
   - syntax colouring and a copy button on code;
   - real tables;
   - numbered and nested lists, and task lists.
4. Mermaid diagrams. Check whether BeautifulMermaid builds for iOS; otherwise
   use a web view like `VisualAidWebView`.
5. Answered-question and outcome cards, and failure incidents. These need
   structured data on the wire.
6. Plan documents shown in full.
7. Live terminal output in tool calls. This needs new protocol.
8. Subagent rows and child sessions. This needs new protocol.
9. File links: detect paths and open them through the existing file-read
   route.
10. Inline-only tool images too big for the wire: spill them to a fetchable
    file on the host.
