# Previewing a paired host's images and binary files from the Mac — design

## Intent

The user pairs a Mac with a headless `alas-host` and wants parity with local work. Locally:
- Opening an image shows it, with its pixel size and byte count.
- A changed image in Changes or in a commit shows an image diff: side by side, overlay, swipe or difference.
- Any other known binary, such as a PDF or an archive, shows a placeholder card with Open with System.

On a host worktree, every one of these shows the same red note, "Binary files cannot be shown.", or "This file is too large to show." for anything over 512 KB. Checking a screenshot an agent produced, or reviewing a changed icon, means leaving the Mac.

## Current state (from recon, origin/main 67372f5c6)

- **Local open** (`AppState.openFile`):
  - `ImageFileType` covers png, jpg, jpeg, gif, tiff, tif, bmp, heic, heif, webp and svg. These open `ImagePreviewTabView`, which decodes bytes in memory with `NSImage(data:)`. SSH projects already read through `RemoteFileAccess`.
  - `BinaryFileType` (an extension allowlist) opens `BinaryPreviewTabView`: icon, name, "Binary file", Open with System and Reveal in Finder. There is no PDF, video or QuickLook view anywhere in the app.
  - Anything else opens the editor, which sniffs content and shows a binary fallback.
- **Local image diffs.**
  - `DiffTabView` and the commit, stash and checkpoint diff views render `ImageDiffView(pair:)` for image paths.
  - The pair is built from the old blob (`git show`) and the new side (working tree or commit) by `GitService.imageSide(fromRawData:)` and `ImageDiffPairResolver`. Both are pure, and already work on bytes that didn't come from git.
- **The host's read.**
  - `HostWorktreeRead.file(path:)` goes to `remoteFileContents`.
  - The path chain is `normalizedRelativePath` (no `..`, no `.git`), then `resolve` (symlinks contained), symlink refused, gitignored refused (except in folder projects), and an O_NOFOLLOW, regular-file-only, capped read with no TOCTOU.
  - The read is capped at 512 KB, and a NUL byte or invalid UTF-8 gives `.fileUnavailable(reason: .binary)`. So a small PNG is read and then thrown away, and a large one gets `.tooLarge`. Both carry `byteSize`, which the Mac drops.
  - Binary diffs answer `.fileDiffFailed(reason: .binary)`.
- **Transport.**
  - One WebSocket of JSON text frames, so `Data` travels as base64 (+33%).
  - The frame limit is 16 MB on both ends; the comment there cites "a ~10 MB image base64-encoded".
  - Requests time out at 60 s.

## Goals

1. **Images open as locally.** Opening an image of a host worktree from the Files tab, Changes or a commit's file list shows it decoded, with its pixel size and byte count, the way `ImagePreviewTabView` shows a local one.
2. **Image diffs as locally.**
   - A changed image in a host worktree's Changes, staged or unstaged, or in one of its commits, shows the local image diff with the same modes.
   - Added, deleted and renamed images get their missing side as locally.
3. **Other binaries get the local placeholder.**
   - A known binary that isn't an image, or any file the host finds binary, shows the local card: icon, name, kind and size.
   - Open with System and Reveal are hidden, as they are for remote files today.
4. **Size is honest.**
   - Images up to a cap of 5 MB raw (up to about 14 MB on the wire, as JSON escapes `/` in base64) are previewed.
   - Above that, the card says the file is too large to preview, with its size.
   - The 512 KB text cap is unchanged.
5. **Same path rules as reading text.** No `.git`, nothing gitignored (except folder projects), no symlinks, contained in the worktree, regular files only.
6. **Capability-gated and compatible.**
   - A new capability gates the byte reads.
   - Older hosts keep today's note for images, but their text read's binary and too-large refusals now show the placeholder card with the size they already send. Older Macs are unaffected.

## Non-goals

- A PDF, video, audio, font or archive viewer. Local has none; the placeholder is parity.
- Opening a host file with a Mac app (Open with System), or downloading it.
- Image diffs for stash and checkpoint diffs on a host. They keep the note for now and are a follow-up.
- Chunked or streamed transfer. One capped read per side is enough for previews.
- Changing the text-editing path, or the 512 KB text cap.

## Anti-goals

- **No byte read that the text read's path rules would refuse.**
- **No reply above the frame limit.** The host refuses before reading past the cap.
- **No git command built from a Mac string.** An old side names its revision by the same validated forms the host's diffs already use: index, HEAD or comparison ref, or a commit SHA it verifies.
- **No change to local previews or SSH behaviour.**

## Constraints

- AGENTS.md:
  - Swift Testing, minimal sharp tests;
  - git stays real in tests (template repos);
  - no UI imports in core; public cross-module types Sendable;
  - Conventional Commits, no attribution.
- The app can't be built locally, so CI is its first build. Split long SwiftUI chains, avoid name collisions, and no shadowing `if let`.
- Peer worktrees have no center tab strip. Previews show in the peer document area, as text and diffs already do.

## Decisions (my calls)

- **One new read, `HostWorktreeRead.fileBytes(path:revision:)`, under a new capability.**
  - `revision` is nil for the working-tree file. Otherwise it is one of the forms the host's diff reads already accept: the index, HEAD, the comparison ref, or a verified commit SHA (or its parent).
  - The reply is new: `.fileBytes(path, data, byteSize)`, or the existing `.fileUnavailable` with `.tooLarge` or `.notFound`.
  - The host reuses the text read's path chain verbatim, with the cap raised to 5 MB and no binary or UTF-8 gate. Revisions are read with `git show <rev>:<path>` through `Process.gitData`, checked against the cap before replying.
- **Bytes stay in memory on the Mac.** `NSImage(data:)` for previews and `GitService.imageSide(fromRawData:)` for diffs. No temp files.
- **The Mac decides what to request by extension,** as local does with `ImageFileType` and `BinaryFileType`. The host's `.binary` reply to a text read also switches the document to the placeholder card, which now shows the `byteSize` it used to drop.
- **The peer document area gets two new contents:** an image (with its footer), and an image diff built with the existing `ImageDiffView`. The placeholder reuses `BinaryPreviewTabView`'s layout without its buttons.
- **Two PRs.**
  1. The host read with an integration test over a real repo: the working tree, the index and a commit, a cap refusal, and the path rules.
  2. The Mac: image preview, image diffs for Changes and commits, and the placeholder card.

## Left to the builder

- Exact names of the capability, request, reply and document cases.
- How the image diff's revisions map from the peer's diff document (stage, commit SHA, comparison mode) to the host's revision forms.
- Whether svg previews as an image or opens as text when the host serves file editing. Follow local: it previews unless a line is being revealed.
