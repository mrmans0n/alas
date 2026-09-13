# Task 3 report: LSP navigation and reference results

## Scope completed

- Added typed LSP location requests for definition, type definition, implementation, and references. All decode `null`, one `Location`, location arrays, and `LocationLink` arrays; links retain `targetSelectionRange`.
- Added `EditorNavigationTarget` and a worktree-owned `EditorNavigationStore`. Results are host-qualified, deduplicated, and remain available while editor views/tabs are recreated.
- Registered type-definition, implementation, and references handlers only after their implementations existed. Each request synchronizes through `EditorLSPBinding` and rejects a stale response before changing UI or opening a target.
- Added a resizable/collapsible References surface below `CodeEditorView`, with count, close button, loading/error/empty states, lazy rows, keyboard-accessible buttons, Escape focus return, and visible-row snippets.
- Routed all LSP targets through `TabsManager.openNavigationTarget`, preserving host context. Remote snippets use `RemoteFileAccess`; remote paths do not go through local `FileManager`. Concurrent snippet reads are capped at four.
- Regenerated `Alas.xcodeproj` for the new source and test membership.

## Red / green evidence

### Red

After adding `NavigationFeatureTests.swift` and regenerating the project:

```text
Cannot find 'EditorNavigationStore' in scope
Cannot find 'EditorNavigationTarget' in scope
Value of type 'LSPClient' has no member 'typeDefinition'
Value of type 'LSPClient' has no member 'implementation'
Value of type 'LSPClient' has no member 'references'
** TEST FAILED **
```

Command:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/alas-code-editor-lsp-dd \
  -only-testing:AlasTests/NavigationFeatureTests test
```

The first sandboxed invocation was blocked before compilation because SwiftPM could not write its manifest diagnostics cache. The same command was rerun with the required cache access and produced the intended missing-interface failures above.

### Green

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/alas-code-editor-lsp-dd \
  -only-testing:AlasTests/NavigationFeatureTests \
  -only-testing:AlasTests/DefinitionSnippetCacheTests \
  -only-testing:AlasTests/DiffPaneLSPLineMapTests test -quiet
```

Passed (exit 0). The final rerun followed the remote-definition picker safety correction.

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/alas-code-editor-lsp-dd -quiet build
```

Passed (exit 0). The build printed pre-existing Swift 6-concurrency warnings in unrelated ACP, app, center, git, and workspace sources; it reported no task-specific compile diagnostics.

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/alas-code-editor-lsp-dd -quiet test
```

Passed (exit 0).

```bash
swiftformat Alas/Sources/Center/EditorTabView.swift \
  Alas/Sources/Center/EditorNavigationResultsView.swift \
  Alas/Sources/Center/TabsManager.swift \
  Alas/Sources/Code/Editor/CodeEditorCoordinator.swift \
  Alas/Sources/Code/Editor/EditorNavigationStore.swift \
  Alas/Sources/Code/LSP/Features/DefinitionFeature.swift \
  Alas/Sources/Code/LSP/Features/DefinitionSnippetCache.swift \
  Alas/Sources/Code/LSP/Features/NavigationFeature.swift \
  Alas/Sources/Code/LSP/LSPClient.swift \
  AlasTests/Code/LSP/NavigationFeatureTests.swift
git diff --check
```

Passed. SwiftFormat changed no files on the final run.

## Files changed

- `Alas/Sources/Code/LSP/LSPClient.swift`
- `Alas/Sources/Code/LSP/Features/NavigationFeature.swift` (new)
- `Alas/Sources/Code/LSP/Features/DefinitionFeature.swift`
- `Alas/Sources/Code/LSP/Features/DefinitionSnippetCache.swift`
- `Alas/Sources/Code/Editor/EditorNavigationStore.swift` (new)
- `Alas/Sources/Code/Editor/CodeEditorCoordinator.swift`
- `Alas/Sources/Center/TabsManager.swift`
- `Alas/Sources/Center/EditorNavigationResultsView.swift` (new)
- `Alas/Sources/Center/EditorTabView.swift`
- `AlasTests/Code/LSP/NavigationFeatureTests.swift` (new)
- `Alas.xcodeproj/project.pbxproj` (regenerated)

## Self-review

- Verified host is part of `EditorDocumentID`, so equal paths on different SSH hosts remain separate; regression coverage exercises this directly.
- Verified protocol fixtures cover null, single location, location array, and `LocationLink` selection range behavior.
- Verified the persistent store checks binding context and request generation before publishing results.
- Verified remote snippets go through `RemoteFileAccess`, and the legacy synchronous definition picker explicitly avoids local reads for a registered remote path.
- Verified target opens pass through `TabsManager`; remote targets never take the local `FileManager` route.
- Verified new handlers are limited to type-definition, implementation, and references, which are implemented in this stage.

## Residual verification gap

Automated coverage validates store grouping and protocol decoding plus focused definition/diff regressions. The AppKit/SwiftUI surface's visual resizing and first-responder behavior were compile- and code-path-verified, but not manually exercised in a running GUI during this task.

## Fix round 1: navigation ownership, cancellation, and typed picker behavior

### Changes

- `NavigationFeature` now resolves its `EditorNavigationStore` immediately before a references request rather than retaining the setup worktree's store. A coordinator reused for another worktree therefore publishes into the same worktree-owned store rendered by `EditorTabView`.
- Cancelling a pending references request immediately clears its owning store's loading state. Nil synchronization, cancellation after the LSP call, and stale binding-context responses also clear the current request's loading state, guarded by request generation.
- Type definition and implementation now share `DefinitionFeature`'s established zero/single/multiple-target behavior. Multiple targets use the existing `DefinitionPicker`; only references populate the persistent References surface.
- Added host prefixes to remote result-group labels, so otherwise identical URIs are distinguishable.
- Added regression coverage for worktree-store selection and cancellation cleanup, stale-response loading cleanup, and a matching remote-host target opening through `TabsManager` as a worktree-relative editor tab.

### Red / green evidence

The initial store-switch test was intentionally written against the old static-store initializer and failed to compile as expected:

```text
Cannot convert value of type '() -> EditorNavigationStore' to expected argument type 'EditorNavigationStore'
```

After the implementation and focused test fixture correction, the requested final focused command is awaiting the existing full-suite Xcode process that holds `/private/tmp/alas-code-editor-lsp-dd/Build/Intermediates.noindex/XCBuildData/build.db`. An overlapping retry correctly failed as infrastructure contention, not as a test result:

```text
error: unable to attach DB: error: accessing build database ... build.db: database is locked
Testing cancelled because the build failed.
```

Final focused command to rerun after the lock releases:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/alas-code-editor-lsp-dd \
  -only-testing:AlasTests/NavigationFeatureTests \
  -only-testing:AlasTests/TabsManagerTests test -quiet
```

`swiftformat` completed with no formatting changes for the seven changed Swift files, and `git diff --check` passed before the final test retry.

### Fix-round files changed

- `Alas/Sources/Center/EditorNavigationResultsView.swift`
- `Alas/Sources/Code/Editor/CodeEditorCoordinator.swift`
- `Alas/Sources/Code/Editor/EditorNavigationStore.swift`
- `Alas/Sources/Code/LSP/Features/DefinitionFeature.swift`
- `Alas/Sources/Code/LSP/Features/NavigationFeature.swift`
- `AlasTests/Code/LSP/NavigationFeatureTests.swift`
- `AlasTests/TabsManagerTests.swift`

### Fix-round self-review

- The store resolver reads the coordinator's current worktree ID at request start, while the captured initial store remains only a safe fallback after coordinator teardown.
- Request IDs prevent obsolete completions from mutating either results or loading state; cancellation clears the captured owning store before a later action begins.
- The typed navigation paths retain the existing definition picker’s target-opening closure, which routes each selected target through host-qualified `TabsManager.openNavigationTarget`.
- The remote routing regression verifies a remote-root target becomes a relative editor tab without requiring a local file to exist.

### Fix-round residual verification gap

The new target-opening regression verifies the remote in-worktree routing branch. The AppKit picker presentation and external-target branch remain code-path reviewed rather than UI-automated; this avoids brittle popover tests while preserving focused unit coverage of the routing contract.

### Fix-round final verification

After the full-suite process released the required DerivedData lock and the asynchronous test assertions were made deterministic, the focused regression command completed successfully:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/alas-code-editor-lsp-dd \
  -only-testing:AlasTests/NavigationFeatureTests \
  -only-testing:AlasTests/TabsManagerTests test -quiet
```

Passed (exit 0). The test bundle emitted existing Swift 6-concurrency warnings in unrelated test sources, with no task-specific warnings or failures.

## Fix round 2: direct Cmd-click supersession and stale-result protection

### Changes

- Added `DefinitionFeature.cancelPendingNavigation`, wired by `CodeEditorCoordinator` to `NavigationFeature.cancelPendingRequest()`. The direct `commandClickHandler` now invokes it before starting definition resolution, so direct Cmd-click and menu commands consistently supersede an in-flight references request.
- Strengthened the stale-context regression to deliver a non-empty references response after an existing result is present. It verifies the stale response does not replace that result.
- Added a direct Cmd-click regression using the real `CodeTextView` command-click handler, a pending `NavigationFeature` request, and `DefinitionFeature`; it verifies the references store exits loading when Cmd-click definition begins.

### Red / green evidence

The direct-Cmd-click regression was first added against the intended injection point and failed before implementation:

```text
NavigationFeatureTests.swift:91:38: error: extra argument 'cancelPendingNavigation' in call
Testing cancelled because the build failed.
```

Command:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/alas-code-editor-lsp-dd \
  -only-testing:AlasTests/NavigationFeatureTests test -quiet
```

After the callback was wired and the stale non-empty fixture was added, the same focused command passed (exit 0). It printed existing unrelated Swift 6-concurrency warnings only.

```bash
swiftformat Alas/Sources/Code/Editor/CodeEditorCoordinator.swift \
  Alas/Sources/Code/LSP/Features/DefinitionFeature.swift \
  AlasTests/Code/LSP/NavigationFeatureTests.swift
git diff --check
```

Passed; SwiftFormat changed no files. Its local cache write was unavailable, but formatting completed normally.

### Fix-round files changed

- `Alas/Sources/Code/Editor/CodeEditorCoordinator.swift`
- `Alas/Sources/Code/LSP/Features/DefinitionFeature.swift`
- `AlasTests/Code/LSP/NavigationFeatureTests.swift`

### Fix-round self-review

- The cancellation closure is optional with a no-op default for isolated feature consumers, and production injects the current coordinator navigation feature weakly.
- The callback runs at the direct command-click entry point, before the definition request is launched, covering the path that bypasses the editor command router.
- The stale-result test asserts a hand-created pre-existing target remains unchanged after the non-empty stale response reaches the context-current gate.
