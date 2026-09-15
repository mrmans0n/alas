# Code editor LSP expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Default to inline execution unless the user chooses delegation.

**Goal:** Deliver sustained coding workflows with capability-aware editor commands, reliable cross-file actions, and rich typing assistance, locally and over SSH.

**Architecture:** Retain workspace-manager server ownership and TabsManager buffer ownership. Add a captured editor context and shared command router, then a workspace-edit planner/executor with coordinated undo. Keep each feature controller separate from protocol models and file I/O.

**Tech Stack:** Swift 5.9+, AppKit text system, SwiftUI presentation, Swift Testing, existing JSON-RPC LSP transport, existing SSH/helper file access, XcodeGen.

**Spec:** [2026-09-13-code-editor-lsp-design.md](2026-09-13-code-editor-lsp-design.md)

## Global constraints

- Deliver complete workflows in stages, with equivalent support for local and SSH worktrees in every stage.
- Open buffers are authoritative, including unsaved content.
- Text-only edits confined to the current document may apply directly with undo.
- Changes affecting other documents or resource operations require a preview before applying.
- Undo covers the whole operation, including unopened files and resource operations.
- Inlay hints are enabled by default, with a quick toggle and persisted per-language controls.
- Typing and menu opening must not wait on the server.
- Advertise only protocol behaviors implemented and tested by the completed stage.
- Use Swift Testing, not XCTest. Keep code and copy in English. Add no agent attribution.
- Preserve existing editor, diff, external-file, format-on-save, and remote-helper fallback behavior.
- Regenerate and commit `Alas.xcodeproj` when adding source/test files or changing `project.yml`; do not edit generated plist values.
- This plan is documentation. None of the tests below has been run as part of writing it.

## Scope, repository findings, and ordering

This is one coordinated editor project with three independently releasable milestones. Complete A before B, and B before C; each milestone ends in usable software. Do not open all feature work concurrently. Shared protocol models are added with their first consumer.

| Milestone | Tasks | User-visible result |
| --- | --- | --- |
| A | 1–4 | Native code menu, consistent navigation, references, history |
| B | 5–9 | Previewable rename/refactoring, safe workspace edits, undo |
| C | 10–14 | Signature help, complete completions, diagnostics, semantic coloring, hints |
| Final verification | 15 | Recorded real-server and full regression results |

Inspected integration facts:

- `CodeEditorCoordinator` repeats client/URI lookup for existing features. Extract that lookup into a binding; do not add another independent lookup for every feature.
- `EditorBuffer.openLSPDocumentIfReady()` excludes remote buffers. Trace and repair remote editor attachment in Task 1; successful remote server launch alone is not proof that an editor document is synchronized.
- `TabsManager` owns active buffers and buffer keys. `EditorBufferStore` primarily stores snapshots and external buffers; it is not the complete active-buffer lookup.
- `CodeEditorCoordinator` clears the text view's undo manager on rebind/detach. Workspace undo cannot be owned only by that reused text view.
- `EditorBuffer.formatAndSave` already guards edit generation and routes remote saves. Reuse its save contract while sharing edit validation; do not make explicit Format Document save implicitly.
- `RemoteFileAccess.write` accepts `expectedMtime` and `expectedContent`. Reuse these checks, and audit fallback behavior for ambiguous failures.
- `RemoteFileOps.removeCommand` generates recursive deletion. Do not use it as an unchecked workspace-edit resource operation.
- `CodeEditorLayoutManager` draws invisible-character markers. Inlay hints must coexist with those markers, selection geometry, and the minimap without entering buffer text.

Protocol reference for implementers: [LSP 3.17 specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/). Consult the specific method/type definition when implementing each wire model. The snippets below define proposed interfaces and regression seeds, not claims that those APIs already exist.

## File responsibilities

Paths below are relative to the repository. New files named in tasks are proposed files.

In task file lists, an unqualified existing basename refers to the unique file identified in the repository findings or this map: editor files are under `Alas/Sources/Code/Editor/`, LSP files under `Alas/Sources/Code/LSP/`, `TabsManager.swift` and `EditorTabView.swift` under `Alas/Sources/Center/`, and remote files under `Alas/Sources/SSH/`. `Features/`, `WorkspaceEdits/`, and `Highlight/` are relative to `Alas/Sources/Code/LSP/`, `Alas/Sources/Code/LSP/`, and `Alas/Sources/Code/` respectively. `CodeLanguageDetailView.swift` is under `Alas/Sources/Settings/`.

| Area | New files | Responsibility |
| --- | --- | --- |
| `Alas/Sources/Code/LSP/` | `LSPCapabilities.swift`, `LSPPositionCodec.swift`, `LSPServerRequests.swift` | Capability snapshots, strict position conversion, inbound request routing |
| `Alas/Sources/Code/Editor/` | `EditorLSPBinding.swift`, `EditorCommandRouter.swift`, `EditorNavigationStore.swift`, `EditorNavigationResultsView.swift` | Captured editor context, commands, worktree-owned history/results, UI |
| `Alas/Sources/Code/LSP/WorkspaceEdits/` | `LSPWorkspaceEdit.swift`, `WorkspaceEditPlanner.swift`, `WorkspaceEditFileAccess.swift`, `WorkspaceEditExecutor.swift`, `WorkspaceEditJournal.swift`, `WorkspaceEditUndoCoordinator.swift`, `WorkspaceEditPreview.swift` | Wire edits, pure planning, host-aware I/O, execution, recovery, undo, review |
| `Alas/Sources/Code/LSP/Features/` | `NavigationFeature.swift`, `RenameFeature.swift`, `CodeActionsFeature.swift`, `SignatureHelpFeature.swift`, `SnippetSession.swift`, `SemanticTokensFeature.swift`, `InlayHintsFeature.swift` | One feature interaction per file |
| `Alas/Sources/Code/Editor/` | `EditorSemanticLayer.swift`, `EditorInlayLayout.swift` | Non-source rendering and geometry |
| `Alas/Sources/App/` | `EditorCommands.swift` | App-menu selectors backed by the same router |
| `AlasTests/Code/LSP/` | Corresponding suites listed per task | Deterministic tests using transport and file fakes |

Avoid enlarging `LSPMessages.swift` with all future feature shapes at once. Put workspace edits in their own file and feature-specific Codable models with their feature or a neighboring dedicated messages file when needed. Existing `LSPClient` remains the request owner; expose typed methods there, with model decoding elsewhere.

## Verification and commit recipe

Each task has a red/green cycle, a named suite, and a focused commit. Compile failure due to the new API being absent is an acceptable initial red result; unrelated infrastructure failure is not. Use the task suite name as the selector in this command:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -derivedDataPath /private/tmp/alas-code-editor-lsp-dd -only-testing:AlasTests/LSPPositionCodecTests test
```

Use that isolated DerivedData path throughout this worktree's execution. Do not share it with simultaneous builds. If source membership changes, rerun `xcodegen` before the focused test. Run SwiftFormat on changed Swift files using the repository's configuration. Before each task commit run `git diff --check`, stage only that task's files and generated project changes, and use the supplied message. At each milestone run the required full build and tests in Task 15 as well as focused suites. Do not run build/tests merely to validate this Markdown plan.

## Milestone A: navigation and commands

### Task 1: Make request context and remote attachment explicit

**Files:** Create `Alas/Sources/Code/Editor/EditorLSPBinding.swift`, `Alas/Sources/Code/LSP/LSPPositionCodec.swift`; modify `CodeEditorCoordinator.swift`, `WorkspaceLSPManager.swift`, `EditorBuffer.swift`, `LSPClient.swift`; create `AlasTests/Code/LSP/LSPPositionCodecTests.swift`, `AlasTests/Code/LSP/EditorLSPBindingTests.swift`.

**Interfaces:** Define the following shared values in the binding file. `serverGeneration` is assigned by the manager on holder creation/restart; `version` is the server document version after ordered synchronization, not an independently guessed UI count.

```swift
struct EditorDocumentID: Hashable, Sendable {
    let host: String? // nil means local; remote uses resolved registry identity
    let worktreeID: String
    let uri: String
}
struct EditorRequestContext: Equatable, Sendable {
    let document: EditorDocumentID
    let version: Int
    let serverGeneration: UUID
    let range: LSPRange
}
// Add Equatable to LSPRange if absent.
// @MainActor EditorLSPBinding:
// func synchronize(range: NSRange) async throws -> EditorRequestContext
// func isCurrent(_ context: EditorRequestContext) -> Bool
// LSPPositionCodec:
// static func offset(_ position: LSPPosition, in text: String) throws -> Int
```

- [ ] Add an executable Unicode regression in `LSPPositionCodecTests`:

```swift
@Test func utf16PositionAfterEmoji() throws {
    #expect(try LSPPositionCodec.offset(
        LSPPosition(line: 0, character: 3), in: "a😀b") == 3)
}
```

- [ ] Run `LSPPositionCodecTests` and `EditorLSPBindingTests` red. Add cases for CRLF, final empty line, negative/out-of-range positions, surrogate splitting, equal URIs on two hosts, and restart during synchronization. Use UTF-16 negotiation initially; reject an incompatible server-selected encoding explicitly rather than interpreting it as UTF-16.
- [ ] Implement the binding: resolve existing holder through manager ownership, await document open, flush pending edits, capture acknowledged ordering/version, then verify generation. Preserve reference-counted external/diff holders. Add a remote-editor test proving open/change/request/close ordering and remove or replace the remote early-exit only with one identified lifecycle owner.
- [ ] Replace repeated coordinator closures with binding access; cancel old requests on rebind, language override, reconnect, and detach. Generalize completion's pending-change flush for all position requests.
- [ ] Run both suites green and existing `LSPClientLifecycleTests`, `EditorBufferTests`, and remote buffer tests. Commit `refactor: bind editor LSP requests to document sessions`.

### Task 2: Capability snapshots and native command entry points

**Files:** Create `LSPCapabilities.swift`, `EditorCommandRouter.swift`, `Alas/Sources/App/EditorCommands.swift`; modify `LSPClient.swift`, `CodeTextView.swift`, `CodeEditorCoordinator.swift`, `Alas/Sources/App/AlasApp.swift`; create `AlasTests/Code/LSP/EditorCommandRouterTests.swift`, `AlasTests/Code/LSP/LSPCapabilitiesTests.swift`.

**Interfaces:** `EditorCommandID: String, CaseIterable` defines `definition`, `typeDefinition`, `implementation`, `references`, `rename`, `codeActions`, `formatSelection`, `formatDocument`, `hover`, `back`, `forward`, `nextProblem`, `previousProblem`, `toggleInlayHints`. `LSPCapabilities` exposes `supports(_ command: EditorCommandID) -> Bool`; router exposes `availableCommands() -> [EditorCommandID]`, `invoke(_ command: EditorCommandID, range: NSRange)`, and the pure selection helper below. Only completed feature handlers are registered.

```swift
@Test func clickInsideSelectionPreservesRange() {
    let selection = NSRange(location: 4, length: 5)
    #expect(EditorCommandRouter.targetRange(clickOffset: 6,
        selection: selection) == selection)
    #expect(EditorCommandRouter.targetRange(clickOffset: 12,
        selection: selection) == NSRange(location: 12, length: 0))
}
```

- [ ] Write the selection test, capability bool/object/absent fixtures, and a no-network-on-menu-open test; run `EditorCommandRouterTests` and `LSPCapabilitiesTests` red.
- [ ] Decode immutable capability snapshots in the client. Publish readiness separately from support; a previously supported action may be disabled with server-unavailable status while reconnecting. Do not advertise dynamic registration yet.
- [ ] Override `CodeTextView.menu(for:)` to build the specified groups synchronously. Route selectors and `validateUserInterfaceItem` through the router, preserve native clipboard selectors, and use only one selection as the LSP target. Existing hover/definition/formatting get handlers first. Show brief inline status for empty/error responses.
- [ ] Install an app Code menu. Proposed defaults: F12 definition, Shift-F12 references, F2 rename, Option-Return actions, Control-Space existing completion. Audit existing shortcuts before binding; retain existing bindings on collision and leave the new action menu-accessible. Display actual shortcuts in context menus. Add Back/Forward and problem commands without taking existing app bindings.
- [ ] Run suites green plus text-view selection/clipboard tests; commit `feat: add capability-aware editor commands`.

### Task 3: Navigation methods and persistent reference results

**Files:** Create `NavigationFeature.swift`, `EditorNavigationStore.swift`, `EditorNavigationResultsView.swift`; modify `LSPClient.swift`, `LSPMessages.swift`, `Features/DefinitionFeature.swift`, `Features/DefinitionSnippetCache.swift`, `EditorTabView.swift`, `TabsManager.swift`, `CodeEditorCoordinator.swift`; create `AlasTests/Code/LSP/NavigationFeatureTests.swift`.

**Interfaces:** `LSPClient.locations(method: String, uri: String, position: LSPPosition) async throws -> [LSPLocation]` is private to typed definition/typeDefinition/implementation methods; `references(uri:position:includeDeclaration:) async throws -> [LSPLocation]` is typed. Define `EditorNavigationTarget: Hashable` with `document: EditorDocumentID` and `position: LSPPosition`. `EditorNavigationStore` is owned per worktree by `TabsManager`, holds results independent of editor view lifetime, and exposes `replaceResults(_ targets: [EditorNavigationTarget])` and `groupedResults` keyed by document.

```swift
@Test @MainActor func equalPathsOnDifferentHostsStaySeparate() {
    let store = EditorNavigationStore()
    let position = LSPPosition(line: 0, character: 0)
    store.replaceResults(["host-a", "host-b"].map {
        EditorNavigationTarget(document: EditorDocumentID(host: $0,
            worktreeID: "w", uri: "file:///src/main.swift"), position: position)
    })
    #expect(store.groupedResults.count == 2)
}
```

- [ ] Add grouping test and wire fixtures for null, single Location, Location arrays, and LocationLink arrays; run `NavigationFeatureTests` red. Preserve target selection ranges from links.
- [ ] Implement typed methods and reuse definition picker behavior for single/multiple targets. Use binding context checks before displaying results. Fetch remote snippets via `RemoteFileAccess`, with cache keys including host, document, and freshness. Deduplicate exact locations and bound concurrent snippet reads to four.
- [ ] Put a collapsible, resizable results area under `CodeEditorView` in `EditorTabView`, default height 220 points. It has a References title, count, close button, file groups, snippets, and loading/error/empty states. Use lazy rows; fetch snippets for visible rows. State belongs to the worktree store and survives jumping to another editor tab. Hide it in non-editor tabs without discarding results.
- [ ] Route target opening through `TabsManager` and existing external-file routing with explicit host context; never feed a remote path into local `FileManager`. Verify keyboard selection, Return activation, Escape returning focus, and accessibility labels.
- [ ] Run suite green and definition/diff regression suites. Commit `feat: add LSP navigation and reference results`.

### Task 4: Navigation history and stale-result lifecycle

**Files:** Modify `EditorNavigationStore.swift`, `NavigationFeature.swift`, `EditorCommandRouter.swift`, `TabsManager.swift`; create `AlasTests/Code/LSP/EditorNavigationHistoryTests.swift`.

**Interfaces:** Store exposes `recordJump(from: EditorNavigationTarget, to: EditorNavigationTarget)`, `goBack() -> EditorNavigationTarget?`, and `goForward() -> EditorNavigationTarget?`. Back/forward activation must not append another jump.

```swift
@Test @MainActor func backReturnsSource() {
    let store = EditorNavigationStore()
    let doc = EditorDocumentID(host: nil, worktreeID: "w", uri: "file:///a")
    let a = EditorNavigationTarget(document: doc, position: .init(line: 0, character: 0))
    let b = EditorNavigationTarget(document: doc, position: .init(line: 8, character: 0))
    store.recordJump(from: a, to: b)
    #expect(store.goBack() == a)
    #expect(store.goForward() == b)
}
```

- [ ] Write the test plus forward-branch truncation, duplicate suppression, missing target, and independent worktree cases; run `EditorNavigationHistoryTests` red.
- [ ] Implement history with a 200-entry bound per worktree. Keep unavailable entries but report failed activation without losing the user's current location. New successful jumps truncate forward history. References remain browsable after edits, with a stale label and rerun command instead of silently treating old positions as fresh.
- [ ] Test delayed responses after tab switch and server restart, then run Milestone A full build/tests. Commit `feat: preserve editor navigation history`.

## Milestone B: workspace edits and actions

### Task 5: Decode and preflight ordered workspace edits

**Files:** Create `WorkspaceEdits/LSPWorkspaceEdit.swift`, `WorkspaceEdits/WorkspaceEditPlanner.swift`; create `AlasTests/Code/LSP/WorkspaceEditPlannerTests.swift`.

**Interfaces:** Codable `LSPWorkspaceEdit` preserves `changes`, ordered `documentChanges`, annotations, versions, and resource options. Define a shared lossless Codable `LSPJSONValue` in this file for opaque data used by later actions, completions, diagnostics, and hints; preserve null, arrays, objects, booleans, strings, and numeric values without passing them through lossy display strings. `WorkspaceFileSnapshot` contains `document: EditorDocumentID`, `content: Data?` (nil means absent), `bufferVersion: Int?`, `isOpen: Bool`, and `isDirty: Bool`. `WorkspaceEditPlanner.plan(edit: LSPWorkspaceEdit, context: EditorRequestContext, snapshots: [EditorDocumentID: WorkspaceFileSnapshot]) throws -> WorkspaceEditPlan`. Plan stores ordered steps, before/after snapshots, review annotations, and `requiresPreview: Bool`.

```swift
@Test func decodesResourceOperationWithoutDroppingIt() throws {
    let data = Data(#"{"documentChanges":[{"kind":"rename","oldUri":"file:///a","newUri":"file:///b"}]}"#.utf8)
    let edit = try JSONDecoder().decode(LSPWorkspaceEdit.self, from: data)
    #expect(edit.documentChanges?.count == 1)
}
```

- [ ] Add the decode test and table-driven planner cases; run `WorkspaceEditPlannerTests` red. Cases: stale version, missing snapshot, malformed ranges, overlapping replacements, equal-position insert order, edit-rename-edit sequence, overwrite/ignore options, mixed annotations, and host mapping.
- [ ] Implement a pure planner that simulates operations sequentially against captured snapshots; convert ranges with Task 1 codec and apply each document's text edits in validated reverse-offset order. Honor legal equal-position insert ordering. Reject unsupported schemes, unbounded directory deletion, symlink ambiguity, and non-text input before writes. Refuse conflicting duplicate representations rather than merging them heuristically.
- [ ] Mark preview required unless all steps are text-only in the initiating document. Preserve resource options and annotation confirmation in the preview. For open dirty deletion or destination overwrite, include unsaved content in recovery snapshots and explicit preview warning; no automatic discard.
- [ ] Run suite green; commit `feat: validate LSP workspace edit plans`.

### Task 6: Apply plans through buffers and host-aware file access

**Files:** Create `WorkspaceEditFileAccess.swift`, `WorkspaceEditExecutor.swift`, `WorkspaceEditJournal.swift`; modify `TabsManager.swift`, `EditorBuffer.swift`, `RemoteFileAccess.swift`, `RemoteFileOps.swift`; create `AlasTests/Code/LSP/WorkspaceEditExecutorTests.swift` and `WorkspaceEditRemoteTests.swift`.

**Interfaces:** Define `WorkspaceEditFileAccess` protocol with `snapshot(_ document: EditorDocumentID) async throws -> WorkspaceFileSnapshot` and `replace(_ before: WorkspaceFileSnapshot, with after: WorkspaceFileSnapshot) async throws`. Resource moves use a separate `move(from:to:expectedSource:expectedDestination:) async throws` requirement with both snapshots; do not emulate them as unchecked delete/write. Executor exposes `apply(_ plan: WorkspaceEditPlan) async -> WorkspaceEditOutcome`, where outcome cases are `applied(UUID)`, `conflict([EditorDocumentID])`, `recovered(String)`, `recoveryRequired(UUID, String)`. Journal owns before/after snapshots and per-step states `pending`, `started`, `confirmed`, `restored`, `unknown`.

```swift
// Executor core ordering contract; journal and access are injected dependencies.
try await journal.recordPrepared(plan)
try await revalidateAll(plan)
for step in plan.steps {
    try await journal.recordStarted(step.id)
    try await applyStep(step)
    try await journal.recordConfirmed(step.id)
}
```

- [ ] Build a test-only in-memory `WorkspaceEditFileAccess` fake with a call log, conflict injection, and a write-then-disconnect fault. Run `WorkspaceEditExecutorTests` and `WorkspaceEditRemoteTests` red for a two-file rename with one dirty open buffer and one unopened file. Assert exact contents, save states, and call ordering; not merely success status.
- [ ] Add `TabsManager` lookup by host/worktree/URI over all active and external buffers. Add buffer mutation/identity-rebind hooks that preserve language overrides, snapshots, watchers, tabs, and LSP close/open ordering. Keep buffer-owned content modifications on MainActor. Unopened files use the file-access adapter.
- [ ] Implement preflight/revalidation and per-step content checks. Reuse remote expected-content writes; inspect helper and shell paths so ambiguous mutation errors cannot fall back to a second write. Compare actual state after reconnect before marking success or attempting recovery. Local operations use same-directory temporary writes preserving permissions; document the residual external-writer race instead of claiming filesystem-wide transactions.
- [ ] Capture known open-document generations before requesting a workspace mutation and compare them when its result arrives. For unversioned unopened files, snapshot on receipt, recheck after preview, and check again before each write. Do not claim this proves which disk revision the server analyzed; the protocol may supply no version. Reject observed changes during the request using available file-watch generations, and retain the preview for reviewing server assumptions.
- [ ] Store journals under the existing application-support data root in a dedicated `workspace-edits` directory, atomically write manifests, restrict snapshot permissions, and retain pending/recovery records until resolved. Successful records remain only while reachable from live undo history; clean orphaned successful records on next launch. Never put file content in logs.
- [ ] Apply resource operations only to validated exact targets. Reject recursive directory operations in this release and do not advertise stronger resource support. Recheck identity after each async suspension before touching buffers. Run recovery in reverse confirmed order, guarded by expected post-content; preserve conflicting later content and report exact unresolved paths.
- [ ] Run suites green plus remote save/move tests; commit `feat: apply recoverable workspace edits locally and over SSH`.

### Task 7: Cross-file undo that survives editor rebind

**Files:** Create `WorkspaceEditUndoCoordinator.swift`; modify `TabsManager.swift`, `EditorBuffer.swift`, `CodeEditorCoordinator.swift`, `CodeTextView.swift`; create `AlasTests/Code/LSP/WorkspaceEditUndoTests.swift`.

**Interfaces:** `@MainActor WorkspaceEditUndoCoordinator` is owned by `TabsManager` per worktree, retains journals, and exposes `register(operationID: UUID, affectedDocuments: Set<EditorDocumentID>)`, `undo(operationID: UUID) async -> WorkspaceEditOutcome`, `redo(operationID: UUID) async -> WorkspaceEditOutcome`. Buffer undo managers must survive view rebind; `CodeTextView.undoManager` resolves its current buffer's manager. Shared operation markers reference one coordinator entry rather than duplicate inverse mutations.

```swift
// Every participating buffer gets a marker, not an independent edit inverse.
undoManager.registerUndo(withTarget: coordinator) { owner in
    Task { await owner.undo(operationID: operationID) }
}
undoManager.setActionName("Rename Symbol")
```

- [ ] Write a two-buffer test: rename, edit one buffer again, switch tabs, undo later edit, undo rename, redo rename. Assert unopened disk content as well. Add conflict, closed-tab, double-marker activation, and SSH-unknown-outcome cases. Run `WorkspaceEditUndoTests` red.
- [ ] Move per-document undo ownership out of the reused text view. Remove blanket rebind/detach clearing only after the replacement manager is installed. During workspace application suppress automatic per-view registration and add shared markers. Normal typing stays in the buffer's normal history.
- [ ] Implement one-at-a-time asynchronous undo/redo with explicit action state; do not depend on `UndoManager.isUndoing` after an `await`. Consume/rearm markers only after confirmed success. If affected content has changed, keep the operation available and identify the required intervening undo or conflict, without overwriting. An already-consumed marker cannot replay the transaction.
- [ ] Verify regular typing undo, format-on-save, tab close/reopen, and external-buffer behavior. Run suite green; commit `feat: coordinate undo across workspace edits`.

### Task 8: Preview, rename, and explicit formatting

**Files:** Create `WorkspaceEditPreview.swift`, `Features/RenameFeature.swift`; modify `LSPClient.swift`, `EditorCommandRouter.swift`, `CodeEditorCoordinator.swift`, `EditorBuffer.swift`, `EditorTabView.swift`; create `AlasTests/Code/LSP/RenameFeatureTests.swift`, `WorkspaceEditPreviewTests.swift`.

**Interfaces:** `LSPClient.prepareRename(uri:position:) async throws -> LSPPrepareRenameResult?`, `rename(uri:position:newName:) async throws -> LSPWorkspaceEdit?`, `rangeFormatting(uri:range:options:) async throws -> [LSPTextEdit]`. `WorkspaceEditPreview` consumes immutable `WorkspaceEditPlan` and apply/cancel closures. Rename captures Task 1 context once, prepares when supported, then requests the edit for the entered name.

```swift
// Feature policy after a validated edit has been prepared.
if plan.requiresPreview {
    presentPreview(plan)
} else {
    await applyAndReport(plan)
}
```

- [ ] Add fixtures for prepare range, range+placeholder, default behavior, null rejection, and rename returning null. Add preview tests for another single file, multiple files, resource operations, and stale content after opening. Run `RenameFeatureTests` and `WorkspaceEditPreviewTests` red.
- [ ] Present a compact name popover anchored at the captured symbol with Return/Escape and server rejection text. Show workspace edits in a sheet with grouped paths, selected-file diff, explicit resource badges, unsaved/disk labels, total counts, and Apply/Cancel. Keep all-or-nothing selection. Disable Apply during revalidation/application and retain errors in the sheet.
- [ ] Register rename and formatting commands only now. Explicit formatting uses actual indentation settings and does not save. Refactor format-on-save's edit validation to use the shared text planner while preserving its existing fallback-to-save contract and external/read-only restrictions. Preview follows the same policy for any non-current target.
- [ ] Run suites green, formatting regression tests, and an actual two-file rename over SSH. Commit `feat: preview and apply LSP rename operations`.

### Task 9: Code actions, server requests, and configuration

**Files:** Create `LSPServerRequests.swift`, `Features/CodeActionsFeature.swift`; modify `LSPClient.swift`, `LSPMessages.swift`, `WorkspaceLSPManager.swift`, `EditorCommandRouter.swift`; create `AlasTests/Code/LSP/CodeActionsFeatureTests.swift`, `LSPServerRequestsTests.swift`.

**Interfaces:** `LSPCodeAction` preserves title, kind, diagnostics, disabled reason, edit, command, data, and preferred flag. Client adds typed `codeActions`, `resolveCodeAction`, and `executeCommand` methods. `LSPServerRequests` routes `workspace/configuration` and `workspace/applyEdit` using an injected async edit handler returning applied/failure details. Preserve request IDs as `LSPID`; incoming IDs are independent of outgoing IDs.

```swift
@Test func retainsDisabledActionReason() throws {
    let data = Data(#"{"title":"Extract method","disabled":{"reason":"Select an expression"}}"#.utf8)
    let action = try JSONDecoder().decode(LSPCodeAction.self, from: data)
    #expect(action.disabled?.reason == "Select an expression")
}
```

- [ ] Add decode test, Command-vs-CodeAction union fixtures, resolve data round-trip, and server request ID collision tests. Run `CodeActionsFeatureTests` and `LSPServerRequestsTests` red.
- [ ] Build an anchored searchable action picker with quick fixes, refactorings, and source actions. Request selection plus original diagnostic metadata; narrow Organize Imports by action kind. Keep disabled actions visible with their reasons. Resolve lazily and validate the captured context before running. Apply an action's edit before its command; canceling the edit preview prevents the command.
- [ ] Dispatch inbound requests without blocking response consumption while a preview is open. Reply to configuration with one value per requested item using scoped existing settings or null when unknown. Unknown requests receive MethodNotFound. Cancellation/closing the initiating context returns an edit failure, never an implicit acceptance. Server commands execute only after user action and only on the captured server; follow-up applyEdit requests use the shared service.
- [ ] Advertise workspace edit features accurately, including resource operations actually supported and no transactional failure guarantee. Register refresh handling as consuming features land in Milestone C. Keep dynamic registration false until implemented; explicitly reject unsupported registration requests rather than silently accepting them.
- [ ] Run suites green, cancellation/timeout lifecycle tests, and Milestone B full build/tests. Commit `feat: expose LSP fixes and refactorings`.

## Milestone C: typing assistance

### Task 10: Signature help with active parameters

**Files:** Create `Features/SignatureHelpFeature.swift`; modify `LSPClient.swift`, `LSPCapabilities.swift`, `CodeTextView.swift`, `CodeEditorCoordinator.swift`; create `AlasTests/Code/LSP/SignatureHelpFeatureTests.swift`.

**Interfaces:** Codable `LSPSignatureHelp` retains signatures, active signature, and parameter metadata. `SignatureHelpFeature.activeParameter(in: LSPSignatureHelp) -> Int?`; client `signatureHelp(uri:position:context:) async throws -> LSPSignatureHelp?`, with context modeled from the protocol. Feature uses existing `EditorOverlayPanel` behavior.

```swift
@Test func selectsServerActiveParameter() throws {
    let raw = Data(#"{"signatures":[{"label":"f(a, b)","parameters":[{"label":"a"},{"label":"b"}]}],"activeSignature":0,"activeParameter":1}"#.utf8)
    let help = try JSONDecoder().decode(LSPSignatureHelp.self, from: raw)
    #expect(SignatureHelpFeature.activeParameter(in: help) == 1)
}
```

- [ ] Write test plus parameter label string/offset forms, per-signature override, empty signatures, invalid indices, trigger/retrigger, nested calls, and stale-response cases; run suite red.
- [ ] Request after ordered sync; honor triggers and allow a manual command. Display one signature, active parameter emphasis, documentation, and signature cycling. Completion has priority for its own keyboard handling; signature display must not steal typing focus. Dismiss on Escape or invalid context, and reposition on scroll.
- [ ] Run suite green and completion overlay tests; commit `feat: show LSP signature help while typing`.

### Task 11: Completion resolution, snippets, and imports

**Files:** Create `Features/SnippetSession.swift`; modify `LSPMessages.swift`, `LSPClient.swift`, `Features/CompletionFeature.swift`, `Features/CompletionEngine.swift`, `Features/CompletionDocumentationRenderer.swift`, `CodeTextView.swift`; create `AlasTests/Code/LSP/Features/SnippetSessionTests.swift`; extend existing completion suites.

**Interfaces:** `SnippetSession.parse(_ source: String) throws -> SnippetExpansion`, with expansion `text: String`, ordered tab-stop ranges, linked placeholders, and final caret. Client `resolveCompletion(_ item: LSPCompletionItem) async throws -> LSPCompletionItem`. Preserve completion data, commands, insert/replace edits, list defaults, insert text format/mode, and existing sorting/filter behavior.

```swift
@Test func expandsNumberedPlaceholderAndFinalStop() throws {
    let expansion = try SnippetSession.parse("call(${1:value})$0")
    #expect(expansion.text == "call(value)")
    #expect(expansion.tabStops[1] == [NSRange(location: 5, length: 5)])
    #expect(expansion.finalCaret == 11)
}
```

- [ ] Run snippet and completion suites red for resolved imports, invalid extra edit, insert/replace ranges, defaults, placeholder mirrors, choices, variables, escaping, nested placeholders, and transforms. Use exact before/after content assertions and UTF-16 offsets.
- [ ] Implement snippet parsing separately from editing and session navigation. Tab/Shift-Tab moves stops, mirrors follow edits, Escape exits snippet mode, and final stop ends the session. Map supported editor variables from captured context. Validate transform syntax and limits; do not advertise snippet support until the standard syntax corpus is handled without corrupting text.
- [ ] Resolve highlighted-item documentation with cancellation; resolve the accepted item before applying required edits. Apply primary text and additional imports through one validated plan and undo group. Invalid or stale additional edits cancel the whole acceptance. Preserve follow-up command metadata and execute only after successful insertion. Never display raw snippet syntax as inserted source on parser failure.
- [ ] Run suites green, manual completion tests locally/SSH, and ordinary Tab/indentation regressions; commit `feat: support resolved completions and snippet editing`.

### Task 12: Rich diagnostics and problem navigation

**Files:** Modify `LSPMessages.swift`, `Features/DiagnosticsFeature.swift`, `Features/HoverFeature.swift`, `CodeEditorCoordinator.swift`, `EditorCommandRouter.swift`, `CodeActionsFeature.swift`; create `AlasTests/Code/LSP/Features/DiagnosticDetailsTests.swift`.

**Interfaces:** Extend `LSPDiagnostic` with code, code description, source, tags, related information, and opaque data using Task 5's `LSPJSONValue`. `DiagnosticsFeature.nextRange(after: LSPPosition, backwards: Bool) -> LSPRange?` supports wraparound. Details reuse the hover overlay and Task 9 action picker.

```swift
@Test func preservesDiagnosticSourceAndCode() throws {
    let raw = Data(#"{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"message":"Unknown name","source":"ts","code":2304}"#.utf8)
    let diagnostic = try JSONDecoder().decode(LSPDiagnostic.self, from: raw)
    #expect(diagnostic.source == "ts")
    #expect(diagnostic.code != nil)
}
```

- [ ] Add test, round-trip opaque data, related remote locations, severity ordering, zero-width ranges, push/pull replacement, and next/previous wrapping cases; run suite red.
- [ ] Display message/source/code/severity plus related-location links; activate links through Task 3 navigation. Pass the original diagnostic into code-action context. Keep rendering ranges distinct from wire ranges so clamping display cannot alter follow-up metadata. Use the primary caret for next/previous problems in the current document.
- [ ] Run suite green and existing diagnostics range tests; commit `feat: expose diagnostic details and quick fixes`.

### Task 13: Semantic highlighting as a replaceable display layer

**Files:** Create `Features/SemanticTokensFeature.swift`, `EditorSemanticLayer.swift`; modify `LSPClient.swift`, `LSPCapabilities.swift`, `CodeEditorCoordinator.swift`, `Highlight/HighlightCapture.swift`; create `AlasTests/Code/LSP/Features/SemanticTokensFeatureTests.swift`.

**Interfaces:** `SemanticTokensFeature.decode(_ data: [Int], legend: [String], text: String) throws -> [HighlightSpan]`. Client adds full/range requests based on supported providers; initially advertise no delta support. `EditorSemanticLayer.replace(_ spans: [HighlightSpan], context: EditorRequestContext)` and `clear()` affect presentation only.

```swift
@Test func rejectsIncompleteTokenTuple() {
    #expect(throws: (any Error).self) {
        try SemanticTokensFeature.decode([0, 0, 2], legend: ["variable"], text: "ab")
    }
}
```

- [ ] Add tuple test, relative line/column decoding, invalid legend indices, multiline constraints, invalid ranges, and stale context cases; run suite red.
- [ ] Negotiate supported token types/modifiers, map them to theme categories, and retain tree-sitter fallback for unmapped categories. Reapply semantic foreground after syntax refresh without overriding diagnostic underlines, find highlights, or selections. Clear stale semantic spans immediately after incompatible edits/restart.
- [ ] Coalesce updates with one in-flight request and one latest pending refresh per document. Prefer visible-range requests when supported; for full-only servers debounce changes and apply strict context checks. Bound response size using existing transport limits and reject malformed token data atomically. Handle server semantic refresh requests by scheduling work, then replying promptly.
- [ ] Run suite green and syntax/diagnostics rendering regressions; commit `feat: layer semantic tokens over syntax highlighting`.

### Task 14: Default-on inlay hints without source mutations

**Files:** Create `Features/InlayHintsFeature.swift`, `EditorInlayLayout.swift`; modify `LSPClient.swift`, `LSPCapabilities.swift`, `CodeEditorLayoutManager.swift`, `CodeTextView.swift`, `CodeEditorCoordinator.swift`, `Alas/Sources/Persistence/AppConfig.swift`, `Alas/Sources/Settings/CodePane.swift`, `CodeLanguageDetailView.swift`; create `AlasTests/Code/LSP/Features/InlayHintsFeatureTests.swift`, `AlasTests/AppConfigInlayHintsTests.swift`, `AlasTests/Code/LSP/EditorInlayLayoutTests.swift`.

**Interfaces:** Codable `InlayHintSettings` has `enabled`, `parameters`, `types` defaulting true; `AppConfig.Code.inlayHintsByLanguage: [String: InlayHintSettings]` defaults empty. `InlayHintsFeature.isVisible(kind: Int?, settings: InlayHintSettings) -> Bool`. Client adds `inlayHints(uri:range:)` and lazy hint resolution. `EditorInlayLayout` maps source offsets to visual glyph positions and inverse hit testing without altering source storage.

```swift
@Test func unclassifiedHintsFollowGeneralToggle() {
    #expect(InlayHintsFeature.isVisible(kind: nil,
        settings: InlayHintSettings(enabled: true, parameters: false, types: false)))
    #expect(!InlayHintsFeature.isVisible(kind: nil,
        settings: InlayHintSettings(enabled: false, parameters: true, types: true)))
}
```

- [ ] Write settings test and old-config decoding test proving default on. Add geometry tests for two hints at one offset, wrapped lines, RTL, emoji, selection, caret movement, hit testing, find, copy, and unchanged serialized text; run the three suites red.
- [ ] First implement and verify a source-to-display glyph mapping in `EditorInlayLayout` that reserves space and draws labels through the existing layout manager. Keep hints outside `EditorBuffer.storage`; do not insert attributed attachments into source text. Route text-view hit testing through the inverse mapping. If TextKit constraints prevent correct mapping, stop this task with the failing geometry evidence and revise the rendering design before shipping a workaround.
- [ ] Add viewport requests with one-screen margin, coalescing, version checks, and lazy tooltip/label-part resolution. Render server padding, retain opaque data and label metadata, and route location links through Task 3. Any user-activated hint edits use the workspace-edit service. Register inlay refresh handling. Hide stale hints while refetching.
- [ ] Add global toggle and per-language parameter/type controls in Code settings. Quick editor toggle updates the active language's persisted enabled setting; unclassified hints follow enabled. Decode missing settings as enabled without rewriting unrelated configuration. Advertise supported hint interactions only after they work.
- [ ] Run suites green plus minimap, warning-marker, find, accessibility, and editor selection regressions. Run Milestone C full build/tests. Commit `feat: add configurable default-on inlay hints`.

## Final verification

### Task 15: Exercise real servers and record evidence

**Files:** Create `docs/plans/2026-09-13-code-editor-lsp-verification.md`; update only implementation files implicated by a demonstrated failure and add regression coverage in that feature's suite.

- [ ] Run generation, formatting of changed Swift files, full build, full tests, and diff check. Record actual commands, head commit, exit codes, and result bundle paths:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -derivedDataPath /private/tmp/alas-code-editor-lsp-dd -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -derivedDataPath /private/tmp/alas-code-editor-lsp-dd -resultBundlePath /private/tmp/alas-code-editor-lsp-final.xcresult test
git diff --check
```

Use a new explicit result path if that bundle already exists; do not erase prior evidence. A build lock or missing Ghostty framework is infrastructure failure, not a passing check.

- [ ] In disposable local Swift, TypeScript, and Rust projects, record server executable/version and advertised capabilities, then exercise hover, definitions, references/history, rename, quick fixes/refactorings, formatting, completion imports/snippets, signature help, diagnostics, semantic coloring, and hints. Record unsupported separately from failed. Use the same project fixture over an available SSH host; do not provision hosts or install tools without task-specific authorization.
- [ ] For cross-file tests, dirty one open file, keep another closed, rename, inspect preview, apply, navigate away, undo/redo, and compare both buffer and disk content. Add an external edit during preview and prove rejection. Disconnect during a remote write and verify reconciliation/recovery; never run destructive failure drills against user project files.
- [ ] For responsiveness, use a fake server delayed by two seconds and verify typing/menu interaction continues. In a large generated fixture, inspect bounded snippet reads, one-in-flight semantic/hint requests, and stale results during rapid switches. Record fixture sizes and observed timings rather than an unmeasured performance claim.
- [ ] Self-review against the coverage table below, record remaining unavailable live-server checks explicitly, and commit `docs: record editor LSP verification`. Do not call the whole project fully verified while required live checks remain unrun.

## Spec coverage and handoff

| Spec contract | Tasks |
| --- | --- |
| Capability-aware menus and shared commands | 1, 2, 8, 9 |
| Navigation, grouped references, back/forward | 3, 4 |
| Local/SSH document identity and stale response checks | 1, 3, 6, 15 |
| Workspace edit preflight, preview, application | 5, 6, 8 |
| Resource operations, unsaved buffers, recovery, undo | 5, 6, 7 |
| Rename, formatting, actions, configuration, inbound edits | 8, 9 |
| Signature help, complete completions, diagnostics | 10, 11, 12 |
| Semantic highlighting and default-on hints | 13, 14 |
| Full regressions and actual-server evidence | Every milestone, 15 |

Planning choices made concrete here: reference results live below editor content; workspace undo outlives text views; UTF-16 is the initial negotiated position encoding; recursive directory resource operations and dynamic registration are explicitly unsupported initially. These limits must be reflected accurately in protocol capabilities and errors. They do not remove cross-file text edits or individual file create/rename/delete support.

Execution may proceed inline with checkpoints after each task, or with user-selected delegated execution. No application implementation was performed while writing this plan.
