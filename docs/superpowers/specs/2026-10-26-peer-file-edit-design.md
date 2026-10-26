# Editing files on a paired host's worktrees — design

## Intent

The user pairs a Mac with a headless `alas-host` and wants parity with local work. The Mac can browse a host worktree's files, but only read them: the peer document view is a read-only text view, and the file tree's New File / New Folder do nothing. Fixing a typo, tweaking a config or finishing an agent's half-done change means leaving the Mac and working on the host some other way.

This design lets the Mac edit a host worktree's files in the same editor as local files, with the host doing the writes.

## Current state (from recon, origin/main f8d7d2b89)

- **The local editor.** `Tab.editor` → `EditorTabView` → `CodeEditorView` over an `EditorBuffer`: 2,687 lines, app-only, AppKit, `NSTextStorage`.
  - **Dirty tracking** is text against the original.
  - **Conflicts:** `.changedOnDisk` and `.deletedOnDisk` raise the banner "File changed on disk while you have unsaved edits." with Reload from disk / Keep mine.
  - **Text:** UTF-8 only. Anything else becomes read-only (`.notUTF8`). LF/CRLF are preserved on save. A symlinked file loads read-only.
  - **Saves:** atomic temp file, `fsync`, replace, permissions kept, confined to the worktree's real root and to regular files.
- **The editor already has a non-local backend.** SSH remote projects get:
  - async load;
  - compare-and-swap save (`RemoteFileAccess.write(expectedMtime:expectedContent:)`, refused on mismatch);
  - remote watching plus polling;
  - the same conflict banner.

  It's hardcoded as `remoteHost: String?` plus static `RemoteFileAccess` calls, not a seam, but its load, save, conflict and watch paths are already isolated (`beginRemoteLoad`, `saveRemote`, `checkRemoteConflictOnce`, `startRemoteHelperWatching`). Save As and rename throw "not yet supported" for remote projects.
- **LSP** runs on the Mac (`WorkspaceLSPManager`). Tree-sitter highlighting, find/replace, undo and the minimap are local to the buffer and view, and work on any text.
- **The host's file read.** `HostWorktreeRead.file(path:)` → `remoteFileContents`.
  - **Path checks:**
    - `normalizedRelativePath`, `resolve` (symlinks resolved and kept inside the real root, `.git` refused);
    - a symlink is refused, and so is a gitignored path (except in folder projects);
    - `O_NOFOLLOW` read with a 512 KB cap.
  - **Reply:** `.fileContents(text:truncated:)`, with no mtime, hash or version.
- **No file-change notification from the host.** There's no file event, and the headless host runs no worktree watcher. The peer tree and open document refresh only on a manual refresh, a selection change or after a git action.
- **`refuseOutside`** (used for git pathspecs) doesn't check the final component or exclude `.git`, so it isn't safe for direct writes. `resolve` plus a final-component `lstat` is.
- **Locally, the file tree** offers only New File and New Folder; there's no rename or delete there.

## Goals

1. **Edit host files in the local editor.**
   - Opening a text file of a host worktree on the Mac opens it in the same editor as a local file, editable, with tree-sitter highlighting, find/replace and undo.
   - Save writes it on the host.
   - Binary, non-UTF-8, symlinked and over-cap files stay read-only, as locally. The cap is the host's existing 512 KB.
2. **Never overwrite someone else's change.**
   - Every read carries a version, and every save is a compare-and-swap against the version the Mac loaded.
   - If an agent or a terminal changed the file on the host since, the save is refused and the editor shows the existing "changed on disk" banner, with Reload from disk / Keep mine.
   - Keep mine re-saves against the new version, as locally.
3. **See outside changes while a file is open.**
   - When a file open on the Mac changes on the host, a clean buffer reloads and a dirty one shows the conflict banner, as locally.
   - When it's deleted, the "deleted on disk" banner appears.
4. **New File / New Folder** in the peer file tree create the item on the host. A new file opens in the editor.
5. **Save is gated like other host writes:**
   - refused while a checkpoint recovery is pending;
   - refused while a checkpoint restore holds the worktree;
   - refused when the listed branch no longer matches.
   The Mac shows the refusal in the editor.
6. **Capability-gated and compatible.**
   - A new headless-only capability gates the writes and the change notification.
   - Older hosts keep today's read-only view.
   - Older Macs are unaffected.

## Non-goals

- LSP on host files (diagnostics, completion, go-to-definition). The editor shows no LSP badge for them.
- Rename, Save As, delete and moving files. Remote projects don't support them locally either, and the local file tree has no rename or delete.
- Editing gitignored files, which the host already refuses to read, and anything under `.git`.
- Files over the read cap, non-UTF-8 text, and binary files.
- Hot-exit snapshots for host buffers. A dirty host buffer is still guarded by the usual unsaved-changes prompt on close.

## Anti-goals

- **No silent overwrite** of an agent's or a terminal's change on the host.
- **No write outside the worktree,** into `.git`, or through a symlink at any path component.
- **No change to local or SSH editing behaviour.**
- **No unbounded payload.** Writes are capped like reads.

## Constraints

- AGENTS.md:
  - Swift Testing, minimal sharp tests;
  - git stays real in tests, in temp dirs;
  - no UI imports in core; public cross-module types Sendable;
  - Conventional Commits, no attribution.
- The app can't be built locally, so CI is its first build.
  - Split long SwiftUI modifier chains.
  - Avoid property/method name collisions.
  - No `if let` that shadows a property a closure then assigns to.
- `EditorBuffer` is large and shared by local and SSH editing. Peer support goes behind a narrow seam, so local and SSH paths are unchanged.

## Decisions (my calls)

- **One editor for all three kinds of file.** The remote half of `EditorBuffer` becomes a small backend seam with two implementations: the existing SSH one, moved as is, and a peer one. The peer files then get the conflict banner, the CAS save and the reload-or-conflict handling for free.
  - It's a struct of closures, the same shape as `CommitEditorGit` from edit commit: load with a version, CAS write, watch.
  - Local file editing keeps its own path, untouched.
- **The version is a content hash plus mtime.** The read reply gains an optional version. A save carries the version it loaded and the new text. The host compares against the current file and refuses on any difference.
  - The content hash covers a touch-only mtime change. The mtime makes the common case cheap.
  - An older host sends no version, and the Mac then keeps the view read-only.
- **The host writes the way the local editor does.**
  - The path goes through `normalizedRelativePath` and `resolve`. The final component must be a regular file under `lstat`, or absent when creating. Nothing under `.git`, nothing gitignored, and no write through a symlink.
  - The write is atomic in the same directory: temp file, `fsync`, rename, permissions kept.
  - It runs through `mutateListedWorktree`, so the gate, branch, idle and recovery checks all apply, plus the checkpoint-restore hold.
- **Outside changes reach the Mac as an event.**
  - The Mac follows the host files it has open, and the host watches them, mirroring the local per-file watcher. It sends an opt-in `fileChanged(worktree, path, version)` event.
  - Polling the version would also work, but it's slower and costs a read each time. The event matches local's instant reload.
- **New file and new folder are host changes** through the same gate and path rules. A new file is empty.

## Decisions from the builder check (my calls, by parity with local)

- **File writes don't check the listed branch. The version check guards them instead.**
  - `mutateListedWorktree` refuses when HEAD no longer matches the listed branch, which would block saves mid-rebase (the moment a user resolves conflict markers by hand) and after any branch change. Locally neither blocks a save.
  - The compare-and-swap version already proves the file is what the Mac last saw. So the host's file writes go through their own entry point:
    - same worktree identity, project gate, idle, pending-recovery and checkpoint-restore-hold checks;
    - no branch-equality check.
  - Unsaved edits are never stuck behind a branch change, and saving works mid-operation.
- **Folder (non-git) projects are in scope,** as local editing covers them. With no branch check the write path needs no git. The gitignore rule mirrors reads: refused in git projects, allowed in folder projects.
- **The content hash decides; the mtime is only a fast path.**
  - A touch that changes the mtime but not the content isn't a conflict. The save succeeds, and the reported version is refreshed without a banner.
  - A `fileChanged` event for an unchanged hash doesn't reload a clean buffer or raise a conflict on a dirty one.
  - Formatters, same-content checkouts or agents touching files then cause no spurious banners.
- **A Mac with unsaved edits to a host worktree refuses its own checkpoint restore of that worktree,** as local refuses a restore over dirty editors. The message names the unsaved files, so the user saves or discards first.
  - A restore started by another client or by an agent is guarded by the version check. The Mac's next save gets the conflict banner, not a silent overwrite.
  - Reporting the Mac's dirty buffers to the host so every restore sees them is a possible follow-up.

## Left to the builder

- The exact names of the capability, requests, replies and event, and whether the version is one opaque string or a struct.
- How the backend seam is cut inside `EditorBuffer`, as long as the local and SSH paths stay behaviourally identical.
- How the peer document view hands a text file to the editor tab, and how the editor tab knows it's a host file.
- How the host's watcher is implemented (per-file `DispatchSource`, or a worktree watcher filtered to followed paths) and how follows are released.
- PR split. The suggested order:
  1. host reads with a version, CAS write, create, and the change event;
  2. the editor seam with the peer backend and the Mac wiring.
