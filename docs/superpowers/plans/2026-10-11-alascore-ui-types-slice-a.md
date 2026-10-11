# AlasCore: core-used types out of UI folders, slice A

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** UI-free core files stop referencing types that live in UI folders or in SwiftUI/AppKit-importing files, for every case that only needs a file move or a type extraction.

**Architecture:** Same module, so the compiler sees no difference. Every change is a `git mv` or a cut-and-paste of whole type declarations into a new file that imports only `Foundation`, so the type can only compile if it is UI-free. No signatures, bodies or behavior change.

**Tech Stack:** Swift 6, xcodegen. New files need `xcodegen` before the build sees them.

**Spec:** #1917 (part of #1915).

## Global Constraints

- Move or extract whole declarations verbatim. Do not rename types, change access, or edit bodies. The one exception is the imports at the top of a new file.
- A new file imports `Foundation` only, plus `os`, `CryptoKit` or `Observation` when the moved code already used them. If a type needs SwiftUI or AppKit to compile, it is not part of this slice. Put it back and record a ruling.
- Run `xcodegen` after adding or moving files. Commit `Alas.xcodeproj` with the sources.
- Do not touch the `Persistence/AppConfig` UI preference types. Those belong to #1918.
- Conventional Commits, with no attribution trailers.

## Measure

`/tmp/alascore/uirefs.py`, a throwaway scanner, lists UI-free core files that reference types declared in UI folders or UI-importing files. Treat `Search/` outside `Search/Views/` as core: it has no UI imports. Before this slice, the scan finds 118 (declaring file, type, user file) triples. Slice A must remove every item listed below from the scan, and add none.

## Review Focus

1. **A type extracted from a UI file that silently depended on that file's imports through member leakage.** For example, a `Color` member used through a `Theme` extension would compile there but not in the new file. The `Foundation`-only build catches this. Never fix it by adding `import SwiftUI`.
2. **`private` or `fileprivate` helpers in the source file that the extracted type uses.** Extracting the type breaks access to them. Move each such helper along with the type, keeping it `fileprivate` in the new file, or leave the type where it is.
3. **Ordering-sensitive `extension`s that live next to an extracted type in its old file.** They stay where they are; extensions work across files in the same module.
4. **Folder renames that scripts or tests hardcode.** `LSPTransportTests`-style tests read sources by path. Grep `AlasTests`, `scripts` and `.github` for every moved path.
5. **Large files where an `@MainActor` annotation sits on the line above the declaration.** It must move together with the declaration.

---

### Task 1: Move pure model files to core folders

Run `git mv` for each file:

| From | To |
|---|---|
| `ACP/UI/ACPImageStaging.swift` | `ACP/Session/` |
| `ACP/UI/ACPToolCallPresentation.swift` | `ACP/Session/` |
| `ACP/UI/ACPTranscriptQueuePolicy.swift` | `ACP/Session/` |
| `ACP/UI/ACPUserInputFormState.swift` | `ACP/Session/` |
| `ACP/UI/ACPMentionSymbols.swift` | `ACP/Mentions/` (new) |
| `Terminal/Zmx/` (whole folder, 7 files) | `Zmx/` (top level) |
| `Terminal/StartupScriptInstaller.swift` | `Zmx/` |
| `Terminal/TerminalCLIInjection.swift` | `ACP/Session/` |
| `App/WorktreePathTemplateRenderer.swift` | `Workspace/` |
| `Code/Editor/EditorLSPStatus.swift` | `Code/LSP/Status/` |
| `WebPreview/WebPreviewCommand.swift` | `Harness/` |

- [ ] Run `git mv` for every row, then run `xcodegen`.
- [ ] Run `grep -rn` across `AlasTests`, `scripts` and `.github` for each old path, and update any hits.
- [ ] Run the build (see Verification) and expect `BUILD SUCCEEDED`.
- [ ] Commit: `refactor(core): move core-used model files out of UI folders`

### Task 2: Extract model types from UI-importing files

For each row, cut the declaration (including its doc comment and attributes) from the source file into the target file. Create the target with `import Foundation` if it doesn't exist.

| Type(s) | From | To (new file) |
|---|---|---|
| `ACPSessionMentionCandidate`, `MentionSessionRanking`, `MentionFuzzy` | `ACP/UI/ACPMentionPicker.swift` | `ACP/Mentions/MentionRanking.swift` |
| `ACPCodeLanguage` | `ACP/UI/ACPCodeBlockHighlighter.swift` | `ACP/Session/ACPCodeLanguage.swift` |
| `ACPSessionAttachFreshness` | `ACP/UI/ACPTabView.swift` | `ACP/Session/ACPSessionAttachFreshness.swift` |
| `GGStackLoadState` | `Right/RightPaneState.swift` | `Integrations/GG/GGStackLoadState.swift` |
| `GGStackChipModel` | `Integrations/GG/GGStackChip.swift` | `Integrations/GG/GGStackChipModel.swift` |
| `CheckpointPresentation` | `Right/Checkpoints/CheckpointRows.swift` | `Checkpoints/CheckpointPresentation.swift` |
| `RunScriptCapturePaths` | `App/AppState+RunScripts.swift` | `RunScripts/RunScriptCapturePaths.swift` |
| `LSPPrepareRenameResult` | `Code/LSP/Features/RenameFeature.swift` | `Code/LSP/LSPRenameTypes.swift` |
| `LSPSignatureHelp`, `LSPSignatureHelpContext`, `LSPSignatureHelpParams` | `Code/LSP/Features/SignatureHelpFeature.swift` | `Code/LSP/LSPSignatureHelpTypes.swift` |
| `PluginCommandSlot`, `PluginCommandContribution`, `PluginCommandTarget`, `PluginCommandRunParams` | `Plugins/PluginCommands.swift` | `Plugins/PluginCommandModels.swift` |
| `PluginDecorationKey`, `PluginDecoration`, `PluginDecorationSetParams`, `PluginDecorations` | `Plugins/PluginDecorations.swift` | `Plugins/PluginDecorationModels.swift` |
| `PluginPanelBadge` | `Plugins/PluginPanelView.swift` | `Plugins/PluginPanelBadge.swift` |

- [ ] Extract all rows, then run `xcodegen` and the build.
- [ ] If a row fails to compile without SwiftUI or AppKit, revert that row only and record `Ruling: <type> needs <UI symbol> — deferred to slice D`.
- [ ] Rerun the measure and expect every listed type to be gone from it.
- [ ] Commit: `refactor(core): extract core-used models from UI files`

## Verification

Build with the arm64 recipe (memory: alas-local-arm64-build), using `-quiet build`. Then run these suites with `-only-testing`:

- `MentionFuzzyTests` (if present)
- `ACPSessionManagerTests`
- `PluginHostTests`
- `RunScriptCompletionMonitorTests` (if present)
- `ZmxClientTests` (if present)
- `LSPClientTests`

These cover the types touched. CI runs the full sweep.

## Out of scope (later slices of #1917)

- **B:** the review and diff model domain (`DiffReviewModels`, `ReviewSessionModels`, `ReviewDraftModels`, `PendingReview`, `DiffDisplayModel*`, `DiffContextExpansion`, `TrackedRevision*`, `ImageFileType`, `ImageDiffPairKind`).
- **C2:** `ACPMarkdownBlockCache` and its `ACPMarkdownText` parser, and `PluginWebPolicy`.
- **D:** AppKit-backed types and inversions:
  - `ImageDiffPair`, which uses `NSImage`
  - `ACPImageEncoding`
  - `ACPElicitationCoordinator`, which uses `NSWorkspace`
  - `NotificationService`
  - `WorktreeCheckpointService`'s `NSImage` use
  - `AppState` references in `ACPDetectedAgentUpdates`, `UsageHistoryStore` and `RunScriptStackCatalog`
  - `ProjectsManager` in `SSH/RemotePath`
  - `TabsManager` and `EditorBuffer` in LSP workspace edits
  - `Theme` and `MarkdownRenderer` in `CompletionDocumentationRenderer`
  - `AlasGhostty` in `PeerConsoleViewer`
  - `RenameFeature` in `WorkspaceLSPManager`
  - `AgentSidebarRollup` in plugin snapshots
  - `TabID` in GG
