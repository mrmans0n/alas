# Shared Composer Paired Delimiters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every authored-content composer in Alas the code editor's selection wrapping, empty-caret delimiter pairing, and closer step-over behavior.

**Architecture:** A pure `PairedDelimiterEditing` resolver owns the canonical six pairs and returns semantic actions without touching views. AppKit adapters apply those actions to plain or attributed text, while reusable SwiftUI representables migrate authored-content fields without changing utility inputs or each surface's existing chrome and focus behavior.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit `NSTextView`/`NSTextField`, Swift Testing, XcodeGen, macOS 15.

## Global Constraints

- Canonical pairs are exactly `()`, `[]`, `{}`, `""`, `''`, and a pair of single backticks.
- Selection wrapping keeps the inner text selected; empty-pair insertion puts the caret between delimiters; an existing closer is stepped over.
- Symmetric empty-caret pairing is disabled when escaped or directly adjacent to an identifier-like character; explicit selections always wrap.
- Multi-character input, paste, dictation, and marked-text composition use native insertion.
- ACP wrapping preserves attributed text, mention chips, and image attachments.
- Every paired operation is one undoable edit and emits normal text-change notifications.
- Include authored content only: ACP prompts; commit and review-request titles/bodies; review comments/replies/summaries; Mission instructions/prompts; reusable prompts; and scripts.
- Exclude search/filter fields, names, paths, branches, picker queries, session titles, structured numeric/date inputs, and language-server configuration lists.
- Preserve existing fonts, colors, chrome, sizing, scrolling, submit shortcuts, focus state, disabled/read-only state, and accessibility identifiers.
- Keep code, comments, logs, and UI strings in English; tests use Swift Testing, not XCTest.

---

### Task 1: Extract the delimiter policy and retain code-editor parity

**Files:**
- Create: `Alas/Sources/UI/PairedDelimiterEditing.swift`
- Create: `AlasTests/PairedDelimiterEditingTests.swift`
- Modify: `Alas/Sources/Code/Editor/CodeTextView.swift:16-25,236-272,323-354,895-946`
- Modify: `AlasTests/CodeTextViewAutoPairTests.swift`
- Modify: `Alas.xcodeproj/project.pbxproj` via `rtk xcodegen`

**Interfaces:**
- Produces: `enum PairedDelimiterEditAction: Equatable { case wrap(opening: Character, closing: Character); case insertPair(opening: Character, closing: Character); case stepOver; case native }`
- Produces: `PairedDelimiterEditing.resolve(insertedText:in:selectedRange:) -> PairedDelimiterEditAction`
- Consumes: UTF-16 `NSRange`, matching AppKit selection APIs.

- [ ] **Step 1: Add failing resolver tests**

Create table-driven Swift Testing coverage whose core assertions include:

```swift
@Test(arguments: [
    ("(", "value", NSRange(location: 0, length: 5), .wrap(opening: "(", closing: ")")),
    ("[", "", NSRange(location: 0, length: 0), .insertPair(opening: "[", closing: "]")),
    (")", "()", NSRange(location: 1, length: 0), .stepOver),
    ("`", "word", NSRange(location: 4, length: 0), .native),
    ("paste", "", NSRange(location: 0, length: 0), .native),
])
func resolvesRepresentativeEdits(input: String, text: String, range: NSRange, expected: PairedDelimiterEditAction) {
    #expect(PairedDelimiterEditing.resolve(insertedText: input, in: text, selectedRange: range) == expected)
}
```

Add separate tests for all six pairs, odd/even backslash escaping, identifier adjacency on both sides, selected symmetric delimiters, closer mismatch, and out-of-bounds/`NSNotFound` ranges.

- [ ] **Step 2: Run the new tests and verify RED**

Run:

```bash
rtk xcodegen
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/PairedDelimiterEditingTests test
```

Expected: compilation fails because `PairedDelimiterEditing` and `PairedDelimiterEditAction` do not exist.

- [ ] **Step 3: Implement the pure resolver**

Implement the exact public shape below and move the current identifier/backslash rules out of `CodeTextView`:

```swift
enum PairedDelimiterEditAction: Equatable {
    case wrap(opening: Character, closing: Character)
    case insertPair(opening: Character, closing: Character)
    case stepOver
    case native
}

enum PairedDelimiterEditing {
    static let pairs: [Character: Character] = [
        "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`",
    ]

    static func resolve(
        insertedText: String,
        in text: String,
        selectedRange: NSRange
    ) -> PairedDelimiterEditAction
}
```

Use `NSString` for bounds and adjacent-character reads. When a symmetric delimiter already appears immediately after an empty caret, resolve closer step-over before empty-pair insertion so the existing editor behavior is preserved.

- [ ] **Step 4: Refactor `CodeTextView` to consume semantic actions**

Replace its private pair table and symmetric helpers with the resolver. Keep editor-owned concerns in place: multi-cursor replacement calculation, closing-bracket indentation, completion notifications, and `autoPairDisabled`. Map `.wrap`/`.insertPair` to the existing replacement and selection math, `.stepOver` to caret movement, and `.native` to `super.insertText`.

- [ ] **Step 5: Run focused policy and editor compatibility tests**

Run:

```bash
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/PairedDelimiterEditingTests -only-testing:AlasTests/CodeTextViewAutoPairTests -only-testing:AlasTests/CodeTextViewMultiCursorTests test
```

Expected: all selected suites pass.

- [ ] **Step 6: Commit Task 1**

```bash
git add Alas/Sources/UI/PairedDelimiterEditing.swift Alas/Sources/Code/Editor/CodeTextView.swift AlasTests/PairedDelimiterEditingTests.swift AlasTests/CodeTextViewAutoPairTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "refactor(editor): share paired delimiter policy"
```

---

### Task 2: Build reusable pair-aware AppKit composer controls

**Files:**
- Create: `Alas/Sources/UI/PairedComposerTextControls.swift`
- Create: `AlasTests/PairedComposerTextControlsTests.swift`
- Modify: `Alas.xcodeproj/project.pbxproj` via `rtk xcodegen`

**Interfaces:**
- Consumes: `PairedDelimiterEditing.resolve(insertedText:in:selectedRange:)` from Task 1.
- Produces: `class PairedDelimiterTextView: NSTextView`, usable as a superclass by specialized composers.
- Produces: `struct PairedTextField: NSViewRepresentable` with text, placeholder, font, text color, enabled state, optional `Binding<Bool>` focus, and optional submit callback.
- Produces: `struct PairedTextEditor: NSViewRepresentable` with text, font, text color, enabled state, optional `Binding<Bool>` focus, and configurable `textContainerInset`.

- [ ] **Step 1: Add failing native-control tests**

Cover plain selection wrapping, empty pairing, closer step-over, binding synchronization, disabled controls, focus round-tripping, and single-step undo. Include an attributed selection test:

```swift
let storage = NSTextStorage(attributedString: NSAttributedString(
    string: "value",
    attributes: [.toolTip: "keep-me"]
))
let textView = makePairedTextView(storage: storage)
textView.setSelectedRange(NSRange(location: 0, length: 5))
textView.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
#expect(textView.string == "`value`")
#expect(textView.textStorage?.attribute(.toolTip, at: 1, effectiveRange: nil) as? String == "keep-me")
#expect(textView.selectedRange() == NSRange(location: 1, length: 5))
```

- [ ] **Step 2: Run the control tests and verify RED**

Run:

```bash
rtk xcodegen
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/PairedComposerTextControlsTests test
```

Expected: compilation fails because the reusable controls do not exist.

- [ ] **Step 3: Implement `PairedDelimiterTextView`**

Override `insertText(_:replacementRange:)`, normalize `String`/`NSAttributedString` input, and bypass pairing whenever `hasMarkedText()` or the resolver returns `.native`. For `.wrap`, build one attributed replacement from an opening delimiter, `textStorage.attributedSubstring(from:)`, and a closing delimiter, then call `super.insertText` once. For `.insertPair`, call `super.insertText` once with both delimiters. For `.stepOver`, move the selection without mutating storage. Set the final selection after the native edit.

Delimiter attributes come from `typingAttributes`; the selected attributed substring is appended unchanged. This ensures the edit is one native undo unit and preserves attachments.

- [ ] **Step 4: Implement `PairedTextField` and `PairedTextEditor`**

Use AppKit coordinators that update bindings only when values differ. The text field coordinator intercepts `control(_:textView:shouldChangeCharactersIn:replacementString:)`, resolves the action, and uses a recursion guard while applying the replacement through the shared field editor. The multiline control instantiates `PairedDelimiterTextView` in an `NSScrollView`.

Both controls must update font, color, enabled/editable state, external binding changes, and optional focus bindings in `updateNSView`. Do not add visual chrome inside the representables; callers retain their existing SwiftUI backgrounds, overlays, padding, frames, and accessibility identifiers.

- [ ] **Step 5: Run focused tests and a build**

Run:

```bash
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/PairedComposerTextControlsTests test
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: tests and build pass.

- [ ] **Step 6: Commit Task 2**

```bash
git add Alas/Sources/UI/PairedComposerTextControls.swift AlasTests/PairedComposerTextControlsTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(editor): add paired composer text controls"
```

---

### Task 3: Add pairing to the attributed ACP composer

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPComposer.swift:562-700`
- Create: `AlasTests/ACP/UI/ACPComposerPairedDelimiterTests.swift`
- Modify: `Alas.xcodeproj/project.pbxproj` via `rtk xcodegen`

**Interfaces:**
- Consumes: `PairedDelimiterTextView` from Task 2.
- Preserves: `ACPNSTextView` slash/mention pickers, image paste, typography, attributed draft extraction, and submit shortcuts.

- [ ] **Step 1: Add failing ACP attributed-content tests**

Instantiate `ACPNSTextView` and prove that backticks wrap selected styled text while retaining its custom attribute and selected range. Add a second test with a one-character attachment carrying `.attachmentURI` and prove the attribute survives between the new delimiters. Add empty-pair and closer-step tests.

- [ ] **Step 2: Run ACP pairing tests and verify RED**

Run:

```bash
rtk xcodegen
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPComposerPairedDelimiterTests test
```

Expected: the wrapping assertions fail because `ACPNSTextView` still inherits directly from `NSTextView`.

- [ ] **Step 3: Adopt the shared text-view superclass**

Change only the superclass:

```swift
final class ACPNSTextView: PairedDelimiterTextView {
```

Keep `keyDown`, image insertion, picker reconciliation, typing attributes, and coordinator behavior unchanged. Ensure `keyDown` continues to call `super` so normal character insertion reaches the pairing override after ACP-specific shortcut handling.

- [ ] **Step 4: Run ACP pairing plus composer regression suites**

Run:

```bash
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ACPComposerPairedDelimiterTests -only-testing:AlasTests/ACPComposerDraftBridgeTests -only-testing:AlasTests/ACPComposerImageExtractTests test
```

Expected: all selected suites pass.

- [ ] **Step 5: Commit Task 3**

```bash
git add Alas/Sources/ACP/UI/ACPComposer.swift AlasTests/ACP/UI/ACPComposerPairedDelimiterTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(acp): pair delimiters in composer"
```

---

### Task 4: Migrate commit and review-request message editors

**Files:**
- Modify: `Alas/Sources/Center/Commit/CommitMessageEditorView.swift:110-164`
- Modify: `Alas/Sources/Center/ReviewRequest/DraftReviewRequestTabView.swift:300-354`
- Modify: `Alas/Sources/Integrations/GG/GGSplitCommitTabView.swift:307-317`
- Modify: `AlasTests/CommitMessageEditorViewTests.swift`
- Create: `AlasTests/PairedPrimaryComposerSurfaceTests.swift`

**Interfaces:**
- Consumes: `PairedTextField` and `PairedTextEditor` from Task 2.
- Preserves: enum-backed focus state in commit/review-request editors and GG draft change callbacks.

- [ ] **Step 1: Add failing representative surface tests**

Extend the commit-message render harness to locate the AppKit pair-aware controls and exercise backtick wrapping in both subject and body. Add a review-request harness proving the title/body bindings update. Add a GG split-message test proving the existing `draftDidChange` path still runs after a paired edit.

- [ ] **Step 2: Run primary-composer tests and verify RED**

Run:

```bash
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/CommitMessageEditorViewTests -only-testing:AlasTests/PairedPrimaryComposerSurfaceTests test
```

Expected: pair-aware AppKit controls are absent from these surfaces.

- [ ] **Step 3: Migrate the three primary composer families**

Replace only the authored fields:

- commit subject/body;
- review-request title/body;
- GG split commit messages.

Bridge enum focus to optional Boolean bindings with explicit get/set closures, for example:

```swift
Binding(
    get: { focused == .subject },
    set: { value in
        if value { focused = .subject }
        else if focused == .subject { focused = nil }
    }
)
```

Copy the current font, color, disabled state, padding, frame, background, overlays, and clipping exactly. Preserve GG's `.onChange` callback.

- [ ] **Step 4: Run focused tests and commit**

Run:

```bash
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/CommitMessageEditorViewTests -only-testing:AlasTests/PairedPrimaryComposerSurfaceTests test
```

Then:

```bash
git add Alas/Sources/Center/Commit/CommitMessageEditorView.swift Alas/Sources/Center/ReviewRequest/DraftReviewRequestTabView.swift Alas/Sources/Integrations/GG/GGSplitCommitTabView.swift AlasTests/CommitMessageEditorViewTests.swift AlasTests/PairedPrimaryComposerSurfaceTests.swift
git commit -m "feat(commit): pair delimiters in message composers"
```

---

### Task 5: Migrate review feedback composers

**Files:**
- Modify: `Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift:1066-1270,2398-2425`
- Modify: `Alas/Sources/Center/Review/DiffInlineCommentCard.swift:160-290`
- Modify: `Alas/Sources/Center/Review/VerdictSheet.swift:20-40`
- Modify: `Alas/Sources/Center/ReviewWorkspace/ProviderReviewPublishConfirmationView.swift:44-72`
- Modify: `Alas/Sources/Center/ReviewWorkspace/ReviewDraftSummaryRail.swift:672-692`
- Modify: `AlasTests/DiffReviewSurfaceTests.swift`
- Create: `AlasTests/PairedReviewComposerSurfaceTests.swift`

**Interfaces:**
- Consumes: `PairedDelimiterTextView` and `PairedTextEditor` from Task 2.
- Preserves: `ReviewDraftComposerKeyboardAction`, focus generation, save/cancel shortcuts, staged reply bindings, and accessibility identifiers.

- [ ] **Step 1: Add failing review-composer tests**

Exercise the hosted `ReviewDraftComposerTextEditor` text view for selection wrapping and keyboard-action routing. Add representative hosting tests for inline reply/edit, verdict summary, provider publish summary, and draft-summary editing; verify their bindings receive the wrapped string.

- [ ] **Step 2: Run review-composer tests and verify RED**

Run:

```bash
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/PairedReviewComposerSurfaceTests -only-testing:AlasTests/DiffReviewSurfaceTests test
```

Expected: wrapping is missing from at least the existing `ReviewDraftComposerNSTextView` and SwiftUI-only editors.

- [ ] **Step 3: Migrate review feedback controls**

Make `ReviewDraftComposerNSTextView` inherit `PairedDelimiterTextView`; retain its `keyDown` override and call to `super`. Replace authored SwiftUI text editors with `PairedTextEditor`, including the vertical provider-reply field currently expressed as `TextField(axis: .vertical)`. Preserve each binding, focus behavior, font, foreground color, minimum height, background, overlay, disabled state, and accessibility identifier.

- [ ] **Step 4: Run review surface regression tests**

Run:

```bash
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/PairedReviewComposerSurfaceTests -only-testing:AlasTests/DiffReviewSurfaceTests -only-testing:AlasTests/ACPMarkdownInlineRendererTests test
```

Expected: all selected suites pass, including existing focus-generation coverage.

- [ ] **Step 5: Commit Task 5**

```bash
git add Alas/Sources/Center/DiffReview/DiffReviewFileSection.swift Alas/Sources/Center/Review/DiffInlineCommentCard.swift Alas/Sources/Center/Review/VerdictSheet.swift Alas/Sources/Center/ReviewWorkspace/ProviderReviewPublishConfirmationView.swift Alas/Sources/Center/ReviewWorkspace/ReviewDraftSummaryRail.swift AlasTests/DiffReviewSurfaceTests.swift AlasTests/PairedReviewComposerSurfaceTests.swift
git commit -m "feat(review): pair delimiters in feedback composers"
```

---

### Task 6: Migrate Mission, prompt, and script authoring surfaces

**Files:**
- Modify: `Alas/Sources/Missions/EditMissionSourceDialog.swift:56-65`
- Modify: `Alas/Sources/Missions/AddMissionLegDialog.swift:160-177`
- Modify: `Alas/Sources/Missions/NewMissionDialog.swift:680-739`
- Modify: `Alas/Sources/Settings/PromptEditorBody.swift:28-36`
- Modify: `Alas/Sources/Settings/TerminalPane.swift:50-72`
- Modify: `Alas/Sources/Dialogs/NewProjectDialog.swift:508-536`
- Create: `AlasTests/PairedAuthoredContentSurfaceTests.swift`

**Interfaces:**
- Consumes: `PairedTextEditor` from Task 2.
- Preserves: Mission model bindings and validation, prompt reset/save flows, terminal config bindings, and new-project script inheritance modes.

- [ ] **Step 1: Add failing authored-content surface tests**

Create hosting harnesses that exercise one Mission instruction/body binding, `PromptEditorBody.draftPrompt`, one terminal startup-script binding, and one new-project script binding. Select `command`, insert backticks, and expect `` `command` `` in each backing binding.

- [ ] **Step 2: Run authored-content tests and verify RED**

Run:

```bash
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/PairedAuthoredContentSurfaceTests test
```

Expected: the hosted fields are still native SwiftUI `TextEditor` instances and do not apply shared pairing.

- [ ] **Step 3: Migrate the approved surfaces only**

Replace Mission body/context/instructions/initial-prompt editors, the reusable prompt editor, terminal startup-script editors, and new-project script editors with `PairedTextEditor`. Keep Mission work-item title fields unchanged because they are identity inputs under the approved boundary. Keep Run Script palette search/edit query, ACP structured input forms, language-server args/root markers, and every search/filter/name/path/branch field unchanged.

Copy each editor's font, foreground color, frame bounds, padding, background, overlay, disabled state, and binding exactly.

- [ ] **Step 4: Run focused and full local verification**

Run:

```bash
rtk xcodegen
ALAS_FFF_TARGET_ARCH=arm64 rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/PairedDelimiterEditingTests -only-testing:AlasTests/PairedComposerTextControlsTests -only-testing:AlasTests/ACPComposerPairedDelimiterTests -only-testing:AlasTests/PairedPrimaryComposerSurfaceTests -only-testing:AlasTests/PairedReviewComposerSurfaceTests -only-testing:AlasTests/PairedAuthoredContentSurfaceTests test
rtk git diff --check
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: focused tests, full tests, diff check, and build all pass. A run that stops before `xctest` is incomplete and must be rerun or reported honestly.

- [ ] **Step 5: Commit Task 6**

```bash
git add Alas/Sources/Missions/EditMissionSourceDialog.swift Alas/Sources/Missions/AddMissionLegDialog.swift Alas/Sources/Missions/NewMissionDialog.swift Alas/Sources/Settings/PromptEditorBody.swift Alas/Sources/Settings/TerminalPane.swift Alas/Sources/Dialogs/NewProjectDialog.swift AlasTests/PairedAuthoredContentSurfaceTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(editor): pair delimiters across authored content"
```

---

## Publication and readiness

After all six tasks pass their per-task reviews and the final whole-branch review:

1. Re-run `rtk git diff --check`, the full macOS test suite, and the quiet macOS build on the final tree.
2. Rebase the branch onto current `origin/main`; resolve only task-related conflicts and rerun affected verification.
3. Push `nacho/backticks` and create a non-draft PR against `main` with summary and verification sections.
4. Request one fresh `@codex review` if the repository automation has not started one.
5. Run `gh-pr-ready-loop` with the Codex gate until the current head has green required CI, a fresh positive Codex signal, no actionable unresolved review feedback, and clean mergeability.
6. Do not merge the PR unless the user separately requests it.
