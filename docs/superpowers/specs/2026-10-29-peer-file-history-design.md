# File History for a paired host's worktree files — design

## Intent

The user pairs a Mac with a headless `alas-host` and wants parity with local work. Locally, "File History" in the Files tab's or Changes' context menu, or in the editor breadcrumb, opens a tab listing the commits that touched the file, following renames. Clicking one opens that commit.

On a host worktree the Files tab shows the same menu item, but it does nothing (`onFileHistory: { _ in }`). Seeing how a file came to be, or which agent turn changed it, means leaving the Mac.

## Current state (from recon, origin/main 9f6bca2dd)

- **Local.**
  - `AppState.openFileHistory` opens a `Tab.fileHistory` center tab (`FileHistoryTabView`), which calls `GitService.fileHistory`. That runs `git log --follow -n 200 … --numstat -- <path>` and returns `[CommitInfo]` (Codable): sha, author, date, subject, and the file's +/− for each commit.
  - The view lists `CommitRow`s with a Retry state. A click opens the whole commit tab. Copy SHA is the only other action.
  - There is no per-file diff in the list, no paging and no blame.
- **Host.**
  - `HostWorktreeRead` has commit reads (`commitFiles`, `commitDiff(sha, path)`, ranges, `fileBytes` at `.commit`/`.parent`), but no "commits touching a path" read.
  - SHAs are validated by `isCommitSHA` and `rev-parse`; paths by `normalizedRelativePath` (no `..`, no `.git`).
  - `commitDiff` requires the path to be one of that commit's files, so a commit from before a rename needs the old path.
- **The Mac's peer view.**
  - The center shows one thing at a time: an opened review, the commit editor, an opened host file, or the workspace document (text, diff, image, image diff, card).
  - The review and commit editor are center views opened over the document, each with a close button.
  - The Changes rail lists commits and opens a file's `.commitDiff` document, including image diffs.

## Goals

1. **File History on a host file.** The Files tab's and Changes' "File History" item, on a host worktree that serves it, opens the file's history in the center. It replaces the no-op.
2. **The same list as local.**
   - Up to 200 commits that touched the file, following renames.
   - Each row is a `CommitRow`: subject, author, relative date and the file's +/−.
   - It has a loading state, a Retry, and a note when the list was cut at 200.
3. **See what each commit did to the file.**
   - Selecting a row shows that commit's diff of the file, under the path the file had in that commit. Image diffs work as in Changes.
   - The history stays on screen beside the diff, so moving between commits is one click. The peer view has no tabs to go back to.
4. **Close it.** A close button returns to the previous document, as the review and commit editor do.
5. **Capability-gated and compatible.**
   - A new capability gates the read.
   - The menu item is disabled on hosts without it, and on older hosts.
   - Older Macs are unaffected.

## Non-goals

- Paging past 200 commits. Local has none.
- Blame.
- Opening the whole commit's file list from a history row. The diff of this file is what History is for on the Mac; the Changes rail already lists a commit's files.
- History from the editor breadcrumb of a host file. It can follow once the menu path works.

## Anti-goals

- **No git argument from a Mac string.** The path goes through `normalizedRelativePath` and after `--`, and the limit is clamped on the host.
- **No change to local File History.**

## Constraints

- AGENTS.md:
  - Swift Testing, minimal sharp tests;
  - git stays real in tests (template repos, including a rename);
  - no UI imports in core; public cross-module types Sendable;
  - Conventional Commits, no attribution.
- The app can't be built locally, so CI is its first build. Split long SwiftUI chains, avoid name collisions, and no shadowing `if let`.

## Decisions (my calls)

- **One new read, `HostWorktreeRead.fileHistory(path:)`, under a new capability.**
  - The reply is a new `fileHistory(path, entries, truncated)` or `fileHistoryFailed(path, reason, message)`.
  - Each entry is the `CommitInfo` local shows, plus `pathAtCommit`, the file's path in that commit, which differs before a rename.
  - The host runs one `git log --follow -n 201 --name-status`-style call. It extends `GitService.fileHistory`, or adds a sibling that also reports each commit's path. It caps the list at 200 and sets `truncated`.
- **The Mac shows history as a center view, like the commit editor:** a list on the left and, for the selected row, the existing `.commitDiff(path: pathAtCommit, sha:)` document on the right. That reuses the text and image diff views unchanged.
- **The first row is selected on open,** so the view never starts empty.
- **One PR per side,** as before.
  1. The host read, with an integration test over a real repo with a rename: the entries, `pathAtCommit` before and after the rename, the cap and `truncated`, and path refusals.
  2. The Mac view and its wiring, including whatever the image diff needs to use `pathAtCommit` for a commit whose file list isn't loaded.

## Left to the builder

- Exact names of the capability, request, reply and view.
- Whether the history list and diff split horizontally or vertically. Follow the review view's layout if it has a list and a detail.
- How Copy SHA appears, if at all. Local has it in the row's context menu.
