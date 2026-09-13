# Code editor LSP expansion

Date: 2026-09-13
Status: Conversation design approved; written spec awaiting review.

## Goal

Make Alas comfortable for sustained coding sessions by using language-server information for navigation, editing, and contextual assistance. Deliver complete workflows in stages, with equivalent support for local and SSH worktrees in every stage.

This is a product design and acceptance contract. The implementation plan will identify concrete changes and verification commands. No application changes accompany this document.

## Current codebase

The inspected checkout already implements hover, completion, Cmd-click definitions, document symbols, diagnostics, and document formatting. Relevant code lives in:

- `Alas/Sources/Code/LSP/LSPClient.swift` and `LSPMessages.swift`: requests, response models, initialization, and server messages.
- `Alas/Sources/Code/LSP/WorkspaceLSPManager.swift`: worktree language-server ownership.
- `Alas/Sources/Code/LSP/Features/`: existing editor integrations and popup presentation.
- `Alas/Sources/Code/Editor/CodeTextView.swift` and `CodeEditorCoordinator.swift`: native text interaction and feature wiring.
- `Alas/Sources/Code/Editor/EditorBuffer.swift` and `EditorBufferStore.swift`: document storage and lifecycle.
- `Alas/Sources/SSH/RemoteLSPLauncher.swift`: remote server launch.

The current editor does not provide a custom code context menu. The client does not expose references, rename, code actions, signature help, semantic tokens, or inlay hints. Capability handling and server-initiated request handling need expansion alongside the features that use them.

## Delivery approach

We considered breadth-first feature additions, completing workflows in stages, and expanding the entire protocol client before adding UI. Complete workflows in stages is the selected approach. It provides usable improvements while building shared edit handling before introducing cross-file mutations.

1. **Navigation and commands:** shared command routing, capability-aware context menus, existing-feature entry points, references, implementations, type definitions, and navigation back/forward.
2. **Editing actions:** shared workspace-edit handling, rename, quick fixes, refactorings, server-provided organize imports, selection formatting, previews, and operation-wide undo.
3. **Typing assistance:** signature help, completion improvements, richer diagnostics, semantic highlighting, and inlay hints.

Protocol and lifecycle improvements land with their first consuming workflow. Each stage includes local and SSH behavior, failure handling, and relevant tests. Existing functionality must remain usable throughout.

## Command and context-menu behavior

One command layer serves right-click menus, keyboard shortcuts, and app menus. It owns availability and invocation so the entry points cannot disagree about the target or supported action.

A command captures host, worktree, document identity, document version, clicked position or selection, and server session identity. Right-clicking inside the current selection preserves it. Right-clicking elsewhere targets the clicked position. Keyboard commands use the caret or current selection. A contextual operation has one target; it must not silently execute separately at every secondary caret.

The context menu groups:

- Navigation: Go to Definition, Go to Type Definition, Go to Implementation, Find References.
- Editing: Rename Symbol, Code Actions, Format Selection or Format Document as supported.
- Information: Show Hover, relevant diagnostic details, and applicable quick fixes.
- Standard editing: Cut, Copy, Paste, Select All.

Unsupported LSP commands are omitted. Standard editing availability follows native editability rules. Supported actions that return no results provide brief feedback. A temporarily unavailable server is distinguishable from a server that does not support an action.

The native menu opens promptly without waiting for network requests. Code Actions opens a picker that can show loading, results, failure, and no-action states. It presents server-supplied titles and disabled reasons. Diagnostic quick fixes use the same action implementation. Requests and results remain bound to their captured context; moving to a different document cannot retarget an action.

## Navigation and results

A single definition, type-definition, or implementation target opens directly. Multiple targets use a compact picker with file locations and snippets. Find References opens a persistent results view grouped by file with snippets and keyboard navigation. Results retain their originating host and worktree, including when a target is outside the current worktree but navigable through the existing file-opening model.

Back and forward track source and destination locations for editor navigation. Result activation uses the correct local or remote file route, never a local interpretation of an SSH path. Missing files and disconnected hosts produce clear feedback. Final placement and visual treatment of the persistent results view belong in the implementation plan; they must preserve worktree navigation.

## Workspace edits, rename, and refactoring

One workspace-edit service applies edits from rename, code actions, completion additions where applicable, and server requests. Feature controllers submit operations rather than independently writing files or mutating buffers.

The service resolves host-aware document identities, loads current content, validates versions and ranges, constructs a reviewable operation, and coordinates application and undo. It supports text edits across open and unopened files, plus explicitly represented file creation, renaming, and deletion. It preserves server-specified operation ordering and rejects operations it cannot implement correctly before making changes.

Open buffers are authoritative, including unsaved content. Applying an edit to an open buffer preserves unrelated unsaved changes and its normal save lifecycle. Unopened existing files are updated through the matching local or remote file service. The preview identifies changes that will be written to disk and changes that will remain unsaved in open buffers. Resource operations update affected buffer identities and server document lifecycle consistently; deleting a file with unsaved content must not silently discard that content.

Text-only edits confined to the current document may apply directly with undo. Changes affecting other documents or resource operations require a preview before applying. The preview lists every affected file, text diff, and creation, rename, or deletion. The user accepts or cancels the complete operation; selective application is outside this design because it can invalidate a refactoring.

Rename supports server preparation when available, an editable proposed name, and clear rejection feedback. Quick fixes, refactorings, and organize imports are offered when supplied by the server. Lazily resolved actions and server commands feed into the same edit path rather than bypassing review.

The complete operation is validated before application and checked again after a preview has been open. Versioned edits must match the buffer version. Unversioned edits also need captured-content checks; absence of a server version is not permission to overwrite newer content. Conflicts explain which file changed and allow a fresh request.

Validation does not make multiple filesystem writes atomic. Capture recoverable pre-operation state and record each completed step. On failure, attempt restoration where the content still matches what the operation wrote. If recovery is incomplete, report exactly what changed and retain recovery information. A remote disconnect must not be reported as success or trigger blind replay when a write's outcome is unknown.

Undo covers the whole operation, including unopened files and resource operations. It checks for intervening changes before restoring content, rather than overwriting later user edits. Register one operation with the editor undo flow and coordinate with per-buffer history so the same changes cannot be undone twice independently.

Server-requested workspace edits use the same validation, preview, application, and outcome reporting. Do not claim transactional rollback or other protocol guarantees beyond those actually implemented. Commands that produce later edits are not assumed to have supplied their full edit set up front; any resulting workspace edit still goes through the shared service.

## Information while typing

- **Signature help:** display function signatures during calls, track the active parameter, and respect server trigger/retrigger information. Dismiss when the request context no longer applies.
- **Completion:** retain existing behavior while supporting lazy documentation resolution, snippets with tab stops, and additional edits such as imports. Completion acceptance remains one undoable action, and incompatible or stale edits cannot partially insert a completion.
- **Diagnostics:** expose severity, message, source, related locations, and available fixes. Provide next/previous problem navigation. Diagnostic association must retain the metadata needed by subsequent action requests.
- **Semantic highlighting:** supplement existing syntax highlighting when supported. Preserve syntax fallback if the server is unavailable, delayed, or returns invalid data.
- **Inlay hints:** enabled by default. Provide a quick editor toggle and persisted per-language controls, with separate parameter and type controls when the server identifies those kinds. Hints without a kind follow the general language toggle. Hints remain presentation metadata and never become saved or copied source text.

Server capabilities determine which features are available. The client should retain fields required for resolution and follow-up requests instead of reducing responses prematurely to display strings.

## Ownership and protocol behavior

Keep protocol encoding, decoding, capability state, and server request handling in the LSP layer. Keep host/worktree session ownership in the workspace manager. Feature controllers own interaction state and presentation. Buffers own document content. The workspace-edit service coordinates mutations through those owners.

Expand initialization and server-capability interpretation with each implemented feature. Support configuration requests and applicable server-initiated edits. Handle dynamic registration only for features whose lifecycle is implemented; do not advertise unsupported registration or response formats. Unknown server requests receive an explicit protocol response and cannot strand pending client requests.

Before position-sensitive requests, synchronize pending document changes in order. Use one tested position/range conversion policy consistent with the negotiated encoding, including non-ASCII text. Bind asynchronous work to document and server generations, cancel obsolete work, and discard stale responses even if the server does not honor cancellation.

Typing and menu opening must not wait on the server. Bound and coalesce requests for viewport-related information. Refresh semantic information and hints after relevant document or capability changes. Clear obsolete presentation when a server restarts or a document changes identity.

## Remote parity

Every feature uses explicit host and worktree context for requests, file reads, previews, writes, navigation, and undo. Remote files are read and changed through remote services. Identical path strings on different hosts must never identify the same document.

Server restart, reconnect, tab changes, and remote worktree changes invalidate requests from the prior session as appropriate. A disconnected host has a visible unavailable state. Remote mutations require outcome reconciliation before retrying an operation with an uncertain result.

## Verification and acceptance

Use Swift Testing for unit and integration coverage and the repository's required generation, build, and test checks during implementation. This documentation-only change does not require generating or building the application.

Acceptance coverage includes:

1. Menus and keyboard commands agree on availability and target. Right-click preserves a containing selection and otherwise targets the clicked position.
2. Unsupported actions are absent; supported empty results, disabled actions, and server errors have distinct useful feedback.
3. Definitions, type definitions, implementations, references, and back/forward work locally and over SSH, including multiple targets and unopened files.
4. Rename and actions edit multiple files correctly, preserve unsaved buffers, preview non-current-document changes, and support operation-wide undo.
5. Invalid ranges, overlapping invalid edits, stale versions/content, and unsupported operations are rejected before mutation. Preview acceptance revalidates content.
6. File creation, rename, deletion, partial write failure, recovery, and undo conflicts are exercised. SSH disconnects include uncertain-write outcomes.
7. Rapid typing, tab switching, server restart, and worktree switching cannot display or apply responses in the wrong context.
8. Completion snippets, resolved items, additional imports, signature parameters, diagnostic details, semantic fallback, and hint toggles behave as specified.
9. Unicode position conversion, file URI handling, and equal paths on different hosts have regression coverage.
10. Slow server responses do not block typing or opening menus. Large reference lists and viewport hints avoid unbounded work.

Use protocol fixtures for deterministic response variants and failure injection. Supplement them with actual-server exercises in representative Swift, TypeScript, and Rust projects, including an SSH project, recording server versions and supported capabilities. Report unsupported server features separately from implementation failures. Record completed checks and any unverified cases without treating an unrun test as passed.

## Scope limits

This work does not replace the editor engine, implement a debugger, add a plugin marketplace, or promise every LSP extension. Call/type hierarchies, code lenses, workspace-wide symbol search, and additional protocol features can follow when their user workflow is designed. Server capability alone does not automatically create a new UI feature.

## Next step

Review this written specification, then create a repository-aware implementation plan with staged changes, concrete UI placement, verification, and dependencies. Application implementation follows that plan.
