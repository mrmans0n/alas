# Editor Display Projection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox syntax for tracking.

**Goal:** Integrate source-preserving display storage and complete default-on inlay hints from Task 14.

**Architecture:** An immutable interval map relates authoritative source UTF-16 coordinates to native display coordinates containing virtual attachments. A per-view adapter owns projection lifetime, source transactions, selection conversion, and rendering conversion. Existing buffer/LSP/undo ownership is retained.

**Tech Stack:** Swift, AppKit TextKit 1, SwiftUI settings, Swift Testing.

**Spec:** `docs/plans/2026-09-14-editor-display-projection-design.md`; existing Task 14 requirements in `docs/plans/2026-09-13-code-editor-lsp-implementation.md` remain binding.

## Global Constraints

- `EditorBuffer.storage` is authoritative source text. Attachments occur only in separate display storage.
- Native NSTextView selection/string APIs stay display-based; feature-facing APIs explicitly use source coordinates.
- Buffer transactions, LSP, undo, persisted selections, diagnostics, find, and serialization use source UTF-16 coordinates.
- Source selection/change notifications are distinct from projection/native selection changes. Hint-only refresh never advances source freshness or cancels a request whose source context still matches.
- Invalid or obsolete source revisions cannot apply edits or hint responses.
- Missing inlay settings default enabled; unclassified hints follow the enabled toggle.
- No delta or interaction capabilities are advertised before their consumers work.
- Use Swift Testing, English text, and no agent attribution.
- Keep production hints inactive until the input, geometry, and feature-consumer integration is complete.

## Task 1: Immutable projection and owned display storage

**Files:** Create `Alas/Sources/Code/Editor/Projection/EditorDisplayMap.swift`, `EditorDisplayDocument.swift`, and `EditorHintAttachment.swift`; create `AlasTests/Code/LSP/EditorDisplayMapTests.swift`, `EditorDisplayDocumentTests.swift`.

**Interfaces:** `EditorDisplayHint` contains `id: String`, `sourceOffset: Int`, `label: String`, `size: CGSize`; `EditorDisplayAffinity` has `beforeHints` and `afterHints`. `EditorDisplayMap.init(source: String, revision: Int, hints: [EditorDisplayHint]) throws`; methods `displayOffset(forSource: Int, affinity: EditorDisplayAffinity) throws -> Int`, `sourceOffset(forDisplay: Int) throws -> Int`, `sourceRange(forDisplay: NSRange) throws -> NSRange`, `displaySegments(forSource: NSRange) throws -> [NSRange]`. `EditorDisplayDocument` owns stable `NSTextStorage`, exposes `private(set) var map: EditorDisplayMap`, and `replace(source: NSAttributedString, revision: Int, hints: [EditorDisplayHint]) throws`. The initializer receives the same arguments. Source attributes are copied; virtual hint attachments never enter the supplied source.

- [ ] Add map tests with `a🙂b`, two hints at offset 1: source offset 1 maps before to 1 and after to 3; source emoji range `{1,2}` maps to display `{3,2}`; hint-only display `{1,2}` maps to source `{1,0}`. Reject scalar-splitting offsets, negative/overflow ranges, duplicate IDs, invalid sizes, and invalid hint offsets.

```swift
let source = "a🙂b"
let hints = [
    EditorDisplayHint(id: "first", sourceOffset: 1, label: "x:", size: CGSize(width: 12, height: 16)),
    EditorDisplayHint(id: "second", sourceOffset: 1, label: "type:", size: CGSize(width: 40, height: 16)),
]
let map = try EditorDisplayMap(source: source, revision: 1, hints: hints)
#expect(try map.displayOffset(forSource: 1, affinity: .beforeHints) == 1)
#expect(try map.displayOffset(forSource: 1, affinity: .afterHints) == 3)
#expect(try map.sourceRange(forDisplay: NSRange(location: 1, length: 2)) == NSRange(location: 1, length: 0))
#expect(try map.displaySegments(forSource: NSRange(location: 1, length: 2)) == [NSRange(location: 3, length: 2)])
```
- [ ] Implement sorted interval mapping with storage proportional to source runs/hints, not one allocated record per source character. Preserve incoming order for hints sharing an offset and binary-search lookup where practical.
- [ ] Implement atomic display replacement: validate and assemble off the live storage first, then replace without changing the source object. Preserve source font/paragraph attributes and use separate attachment cells for distinct sizes.
- [ ] Port the successful native geometry fixtures: 12/40-point hints, source-only rectangles, 60-point wrapping, tab stop 84, emoji and Hebrew. Include empty document and end-of-document hint mapping.
- [ ] Assert invalid replacement leaves previous map and display storage intact. Assert source serialized bytes and attributes unchanged and source U+FFFC is not mistaken for a virtual hint.
- [ ] Run new focused suites, xcodegen, build, formatter, and diff check; commit `feat: add source-preserving display document`.

## Task 2: Source-aware editor input and projection lifecycle

**Files:** Create `Projection/EditorDisplayAdapter.swift`, `Projection/EditorCompositionBridge.swift`; modify `CodeTextView.swift`, `CodeEditorCoordinator.swift`, `CodeEditorView.swift`, `EditorBuffer.swift`; create `AlasTests/Code/LSP/EditorDisplayInputTests.swift`.

**Interfaces:** A per-view `EditorDisplayAdapter` owns the document from Task 1 and binds an `EditorBuffer`. `CodeTextView.sourceString: String`, `sourceSelectedRanges: [NSValue]`, `setSourceSelectedRanges(_:)`, and `replaceSource(range: NSRange, with: String)` are explicit feature APIs. Native `string`, `selectedRange`, and `selectedRanges` retain native semantics. The adapter exposes mapping operations through its current document; identity behavior is used when no adapter is installed in legacy tests. Rebind detaches old observers before binding the new buffer.

- [ ] Add native input regressions that insert/delete/cut/copy across two hints and emoji, including hint-only selections and source-owned undo after refresh. Assert exact source bytes and no projection-only undo entries.
- [ ] Route native replacement through display-to-source mapping and the existing buffer undo registration. Observe source character and attribute edits separately; syntax attribute changes update display without advancing source revisions. Suppress recursive projection notifications. Preserve typing coalescing and transaction markers.
- [ ] Convert pairing, indentation, snippets, multi-cursor operations, and source edit helpers to explicit source APIs. Translate native replacement ranges only once. Cover Tab, Shift-Tab, Return, step-over completion cancellation, and snippet mirrors with hints present.
- [ ] Implement composition bridge with deferred hint refresh, correct attributed marked text handling and source replacement semantics. Cover automated marked text replacement/commit/cancel and unchanged source undo grouping; record real input-method candidate-window validation separately.
- [ ] Read `.superpowers/sdd/2026-09-14-editor-display-projection-implementation/input-contract-audit.md` before input implementation. Preserve absolute display replacement ranges and relative marked selection ranges. Capture original source content at composition start and finalize exactly one buffer inverse; do not derive the original content after provisional edits. Keep marked attributes in the display overlay, and retain native display-coordinate substring/candidate geometry APIs.
- [ ] Inventory reachable native mutation selectors: paste variants, drag/drop/move, Services, accessibility replacement, word/paragraph delete, transpose and cut. All map through the source transaction boundary. Hint-only ranges must never expand into a source deletion. Composition must settle before external reload/rebind; user workspace actions must reject or explicitly settle active composition before editing the source, with exact source/undo assertions.
- [ ] Preserve source selections and a source-line scroll anchor on display rebuild/rebind. Skip virtual positions in movement/selection commands without losing Unicode or bidi behavior. Cover vertical and word movement in addition to horizontal probe cases.
- [ ] Keep actual hint injection restricted to integration tests until Task 3 migrates all consumers. Run buffer/undo/input/completion/signature regressions and build; commit `feat: route editor input through source coordinates`.

## Task 3: Migrate feature geometry and accessibility consumers

**Files:** Modify `CodeEditorCoordinator.swift`, `CodeEditorLayoutManager.swift`, `CodeEditorLineNumberRulerView.swift`, `CodeEditorMinimap.swift`, `EditorFindController.swift`, `EditorFindHighlightRenderer.swift`, `EditorSemanticLayer.swift`, LSP feature consumers under `Alas/Sources/Code/LSP/Features/`; create `Projection/EditorDisplayAccessibility.swift` and `AlasTests/Code/LSP/EditorDisplayIntegrationTests.swift`.

**Interfaces:** Source geometry helpers convert source ranges to display segments for foreground, underline, find, and selection-adjacent annotations; inverse viewport and hit helpers produce source ranges/positions. Consumers never derive LSP text from display storage. Accessibility exposes source text/selection and supplementary hint descriptions/actions with mapped geometry.

- [ ] Audit every source/text/selection assumption using the consumer audit artifact. Replace each feature-facing native text or range call with explicit source API; keep native drawing and input methods display-based.
- [ ] Exercise real coordinator paths with hints: completion acceptance/import edits, rename/code actions, signature help, diagnostic links/next problems, and definition hit testing. Assert exact source positions sent to fake LSP and one undo transaction.
- [ ] Map syntax, semantic tokens, diagnostics, find and warnings to display segments excluding hint runs. Verify changing attributes never strips attachment attributes or source style.
- [ ] Migrate `EditorTabView` breadcrumbs, navigation anchors and find prefill to source selections. Feed `Shared/MinimapView.swift` source attributes and translate minimap scrolling through source line geometry.
- [ ] Keep ruler/minimap line numbering/source text independent of attachment indices. Cover wrapped geometry, end-of-document hints, source scroll anchoring, font changes, and tab switches.
- [ ] Implement accessibility value, selected-range setters/getters, range geometry, source text extraction, and hint actions. Verify parameterized accessibility calls with hints; explicitly record manual VoiceOver and real IME candidate-window results or environmental blockers.
- [ ] Measure projection construction/update time and memory on 10,000 and 100,000 source lines with 0, 100, and 1,000 hints. Record the comparison to source-only layout; avoid full-source copying/layout on every hint hit or selection movement. Add combining-mark, ZWJ emoji, ligature, mixed-bidi and EOF fixtures; preserve anchors at valid source boundaries and reject malformed anchors without altering source.
- [ ] Confirm no unconverted native offset consumers remain by source search and behavior tests. Run rendering/find/minimap/selection/accessibility and existing LSP regressions plus build; commit `feat: map editor features through display projection`.

## Task 4: Complete default-on inlay hint feature

**Files:** Create `Features/InlayHintsFeature.swift`, `EditorInlayLayout.swift`, typed hint wire models as needed; modify `LSPClient.swift`, `LSPCapabilities.swift`, coordinator/router, `AppConfig.swift`, `CodePane.swift`, `CodeLanguageDetailView.swift`; create `InlayHintsFeatureTests.swift`, `AppConfigInlayHintsTests.swift`, `EditorInlayLayoutTests.swift` in established test directories.

**Interfaces:** Preserve original Task 14 `InlayHintSettings(enabled:parameters:types:)`, `AppConfig.Code.inlayHintsByLanguage`, and visibility semantics. Rendered hints become Task 1 `EditorDisplayHint` values with retained protocol identity. `EditorInlayLayout` uses the completed adapter for mapping; it does not substitute the rejected virtual glyph implementation.

- [ ] Add old-config/default-on/unclassified setting tests, lossless labels/data/padding, range requests, cancellation and refresh tests before implementation.
- [ ] Request viewport plus one-screen margin with one active/latest pending request, strict source revision validation, and stale-hint clearing. Resolve tooltip/label actions lazily and retain server/host/context identity.
- [ ] Translate hint label parts/padding into display attachments and hit subregions. Location actions use Task 3 navigation; edit activations use the existing workspace preview/executor/undo service and user action gating.
- [ ] Add global/default and per-language parameter/type controls; quick toggle persists enabled for the active language without rewriting unrelated configuration. Advertise only tested interactions.
- [ ] Run full Task 14 geometry/input/minimap/find/accessibility suite and required macOS build/tests. Record environmental/live-input limits honestly. Commit `feat: add configurable default-on inlay hints`.

After this plan is independently reviewed and complete, resume original Task 15, whole-branch review, rebase on origin/main, PR publication, and the authorized CI/Codex/conflict loop.
