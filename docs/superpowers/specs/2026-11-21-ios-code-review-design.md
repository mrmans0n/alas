# iOS code review: one scroll, line comments, send to agent

## Intent

Reviewing code on the phone should feel like reviewing it on the Mac, not like a
fallback. Today the user doesn't review on the phone at all because it isn't
good enough. They want to:

- see every change in a diff comfortably, in one place;
- comment on one line or a range of lines, the way the Mac does, including by
  dragging;
- read it with proper syntax colouring;
- send the review to the right agent, or submit it to GitHub/GitLab for a PR.

Success: the user picks up the phone, goes through an agent's change or a pull
request top to bottom, leaves line comments, and sends them, without wishing
they were at the Mac.

## Current state (main, 2026-11-21)

- **Changes tab** (`Mobile/Sources/Workspace/ChangesView.swift`): a flat file
  list; a file pushes `DiffView` for that one file.
- **`DiffView`** (`Mobile/Sources/Workspace/DiffView.swift`): unified, syntax
  coloured; lines batched into SwiftUI `Text` blocks. Hunk menu: stage, unstage,
  discard, "Comment on Hunk…". Comments anchor to the whole hunk's changed
  lines, or the file.
- **Reviews tab** (`ReviewsView.swift`): the worktree's draft reviews; for a
  pull/merge request, its provider threads (reply, resolve) and Submit Review
  (#2661, #2665).
- **Protocol:** `RemoteReviewAnchor.line(side:startLine:endLine:)` already
  carries line ranges; `RemoteReviewMutation.add` takes it. Working-tree
  comments go to the worktree's local-changes review
  (`RemoteReviewRequest.localChangesSessionID`, see
  `SessionWorkspace.commentOnDiff`). Diffs are fetched per file
  (`fileDiff`, `commitDiff`, `rangeDiff`, `checkpointDiff`, `stashDiff`).
  `readProviderReview(withDiff: true)` returns a PR's raw diff (up to ~4 MB).
- **Send to agent** exists only in the Mac app:
  `Alas/Sources/Center/ReviewWorkspace/ReviewFeedbackAgentSender.swift`,
  `ReviewFeedbackBundle`, `ReviewFeedbackAgentTarget` (model in
  `Packages/AlasCore/Sources/AlasModel/Model/`). There is no host request for it.
- **The Mac has no "viewed file" state.** It has a wrap toggle in its diff views
  (`wrapLines` in `CommitDiffView`, `CheckpointDiffTabView`).

## Goals

1. **One review screen** for a whole change: every file in one vertical scroll.
2. **File strip** at the top: one chip per file, following the scroll, tap to
   jump. Viewed files show a check.
3. **Sticky file header** for the file being read: path, +/− counts, fold
   toggle, Viewed checkbox.
4. **Line comments**: one line or a range.
   - Tap a line number to select it; tap another line number to extend the
     selection to a range.
   - Long-press a line and drag to select a range, as on the Mac; the list
     auto-scrolls when the finger nears the top or bottom edge.
   - A selection opens a comment sheet quoting the selected lines.
5. **Wrap / scroll toggle**, as on the Mac. Wrap folds long lines under the
   code; scroll pans each file's code sideways while line numbers stay pinned.
6. **Syntax colouring**, as today.
7. **Inline comments**: draft comments appear as rows under their lines; for a
   pull request, its provider threads appear the same way (reply/resolve from
   the row, as in #2661).
8. **Action bar** at the bottom: draft count, plus **Send to agent**, and for a
   pull request also **Submit…** (the #2665 sheet).
9. **Viewed files**: a per-review "viewed" mark, phone-only. Viewed files fold.
10. **Large or generated files start folded**, e.g. lock files and files over a
    line threshold. The builder picks the threshold.

## Non-goals

- Split (side-by-side) diff: no room on a phone.
- Editing code.
- Comments on lines outside the diff (unchanged lines beyond the hunks' context).
- A Mac-side "viewed" state, or syncing viewed marks between devices.
- Merging pull requests, or opening a PR review by number.
- Polling a pull request for updates: refresh is pull-to-refresh, as in #2661.

## Anti-goals

- Taking the phone back to the list between files. If moving through a
  20-file change means drilling in and out, this has failed.
- Janky scrolling on a big change. Scrolling must stay smooth with thousands of
  syntax-coloured rows.
- A gesture model where scroll, sideways pan and drag-select fight each other.
  Every touch must have one obvious meaning.
- Comments the phone writes that the Mac or the provider can't use. Phone
  comments must anchor to lines like the Mac's do, so they publish to a PR.

## Approaches considered

### Moving through the change

- **A. One long scroll.** Every file stacked, sticky header per file.
- **B. A file per page.** Swipe sideways between files.
- **C. A with a file strip** on top to jump between files.

**Picked: C.** A keeps the flow; the strip fixes jumping around a long change.

### Long lines

- **Wrap**: everything visible, but code loses its shape.
- **Sideways scroll**: code keeps its shape, but you pan to read it.
- **A toggle between them.**

**Picked: a toggle, as on the Mac.**

### Rendering

- **A. `UICollectionView`, one row per line** (header, hunk, line, comment
  rows). Pinned section headers, cell reuse and self-sizing cells come from
  UIKit; drag-select and auto-scroll are UIKit gestures on top; scroll mode is
  one shared horizontal offset applied to the file's rows.
- **B. One hand-drawn view**, as T3 Code's mobile app does
  (`pingdotgg/t3code`, `apps/mobile/modules/t3-review-diff/ios/T3ReviewDiffView.swift`,
  about 3,000 lines). Most control and speed, but text layout, hit testing and
  VoiceOver all hand-built.
- **C. SwiftUI** `List` or `LazyVStack` with pinned headers. Least code, weakest
  at exactly the hard parts: drag-select with auto-scroll, a shared sideways
  offset, steady scrolling through thousands of attributed rows.

**Picked: A.** It is the smallest option that does all of it. If a huge change
ever profiles badly, only the row drawing would need to change.

## Decisions

- **Replaces `DiffView`.** Tapping a file in Changes opens the review screen
  scrolled to that file. Hunk actions (stage, unstage, discard) stay in each
  hunk header's menu. "Comment on Hunk…" is replaced by line selection.
- **Both kinds of review use it**: local changes (working tree, unstaged and
  staged) and a pull/merge request review. Commit, checkpoint and stash diffs
  should open it too where that's cheap, read-only or with comments only where
  the protocol already allows them; the builder decides per source.
- **Comments are the Mac's drafts.** A local-changes comment goes to the
  worktree's local-changes review, as `commentOnDiff` does today, but with a
  `.line` anchor for the selection. A PR comment goes to that PR's review
  session. Comments written on either device show on both.
- **Selection rule.** A range stays on one side: new-side lines for added and
  context lines, old-side for removed lines, as the Mac anchors them. A range
  that spans both an added and a removed line anchors to the new side.
  Selection stays within one hunk. Ranges never span files.
- **Send to agent** offers the same targets as the Mac
  (`ReviewFeedbackAgentSender.availableTargets`): every open chat in the
  worktree, plus "New chat" with the agent set in Settings → Changes. The
  session the phone is inside is preselected when it's one of them. With a
  single target the button sends straight away; with more, it opens a picker.
  With none, it shows the Mac's message ("No agent to send to. …"). A send also
  advances the "since last review" baseline, as the Mac's does
  (`recordingReviewedWorkingTree`); the host records it at send time, as the
  Mac does when its user sends. This needs a new host request and capability
  that take any review session. The send logic stays in the Mac app; the host
  core gets a seam the app installs, per AGENTS.md. *(Builder check: targets,
  default and baseline settled by matching the Mac.)*
- **Pull request reviews get Send to agent too**, as on the Mac. Their action
  bar has both: **Send to agent** and **Submit…**. *(Builder check: matches the Mac.)*
- **Staged and unstaged stay separate** for local changes, as in the Mac's
  local-changes review. A file changed in both shows up twice, once in each
  section, each with its own line numbers and its own `RemoteReviewFileID`
  namespace, so comments match the Mac's review and hunk stage/unstage keep
  their current mapping. *(Builder check: matches the Mac.)*
- **Viewed marks** are stored on the phone per review session and file entry,
  with a hash of the diff text the phone saw when it was marked. On every load
  or refresh, viewed files are fetched like any other (folding hides them; it
  doesn't skip the fetch), and a file whose diff hash changed loses its mark and
  unfolds. No protocol change is needed. *(Builder check: a viewed file's diff
  must be fetched, or its mark could never clear.)*
- **Loading.** The screen gets the file list first, then fetches each file's
  diff as the user scrolls near it. Files folded for size are not fetched until
  unfolded; viewed files are (see Viewed marks). Syntax spans are computed off the main thread, as today.
- **The wrap/scroll choice persists** on the phone, like the Mac's.
- **Accessibility.** Each line row reads as "line 42, added, <code>". Selection
  works with VoiceOver through a rotor or row actions (select line, extend
  selection to here, comment). The builder picks the mechanism.

## Constraints

- iOS app is its own xcodegen project (`Mobile/project.yml`); new files mean
  `cd Mobile && xcodegen`.
- `AlasRemoteKit` must build for iOS: Foundation, CryptoKit and Observation only.
- Shared protocol changes need a capability advertised in the hello, a
  `callerIsPhone` exemption where the request is phone-only, and the Mac
  AlasTests hello pins updated (`AlasTests/Remote/RemoteProtocolTests.swift`,
  `AlasTests/Remote/RemoteServerIntegrationTests.swift`) as well as
  `HostProtocolTests`.
- Swift Testing; tests only for pure logic (selection → anchor, fold rules,
  file-strip positions, viewed invalidation), per AGENTS.md's Testing policy.
- Should ship as several small PRs, each usable on its own.

## Left to the builder

- **Where a PR review's diff comes from.** One option is `rangeDiff` per file
  over the PR's base and head, if the host has those commits. The other is
  `readProviderReview(withDiff: true)`'s raw diff, parsed on the phone. Check
  what the Mac's PR review workspace uses.
- **Fold thresholds and the generated-file list.** Reuse the Mac's if it has
  one.
- **Visual details**: row metrics, colours, the strip's chip style.
  Match the app's existing diff colours (`StatusBadge`, today's `DiffView`).
- **How to split the work into PRs.** Suggested order: the review screen
  replacing `DiffView` (scroll, strip, headers, toggle, folding); then line
  selection and comments; then PR threads inline plus Submit in the bar; then
  Send to agent.

## Builder check

A fresh reader planned from this doc and asked four questions. Each was
settled by matching the Mac, and the answers are marked in the decisions
above:

1. How viewed marks clear if viewed files aren't fetched.
2. Send-to-agent targets, default and baseline.
3. Whether PR reviews get Send to agent.
4. How a file both staged and unstaged appears.
