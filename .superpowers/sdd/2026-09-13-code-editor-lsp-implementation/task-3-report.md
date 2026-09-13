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
