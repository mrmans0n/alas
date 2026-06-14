# Local Review Workspace Design

## Context

Alas now has a polished diffs.com-style review surface:

- local multi-file review stacks
- commit and draft/create-PR diff review stacks
- PR/MR Files with provider feedback, CI activity, and inline feedback actions
- shared file rail, scroll sync, split/stacked diffs, rich gutters, and feedback
  cards

The remaining gap with `ai-review` is the local human-review loop: review any
diff or commit, write draft comments on exact lines, then hand those comments
back to an agent/chat to address. The remaining gap with rudu is provider write
actions for GitHub/GitLab review threads. This phase builds the common local
review workspace first, so provider mutations can later attach to the same
review-comment model instead of becoming a separate workflow.

## Goals

- Add a first-class Review Workspace for supported diff sources:
  - working tree and staged changes
  - commit and draft commit diffs
  - PR/MR Files
  - branch/create-PR draft diffs where a `DiffReviewLoadedSession` already
    exists
- Let users add local draft comments on exact old/new lines or line ranges.
- Render local draft comments at the selected row or range in the diff stack.
- Support editing, deleting, and locally resolving/dismissing draft comments.
- Persist draft comments per repo and review target.
- Add a review summary rail/panel for navigating local draft comments.
- Add a primary **Send Feedback To Agent** action and a secondary **Copy Prompt**
  action.
- Keep provider feedback visible and actionable as it is today.

## Non-Goals

- No posting comments to GitHub/GitLab.
- No replying to or resolving provider threads.
- No publishing local draft comments as a provider review.
- No arbitrary patch-file import.
- No full historical review browser.
- No exact row-level placement for provider feedback; provider feedback can keep
  the current conservative hunk-level placement.

## Product Shape

The Review Workspace is the shared review mode for any diff source Alas can
already load into `DiffReviewSurface`.

The main layout stays familiar:

- collapsible left file rail
- central stacked file diff stream
- session-level split/stacked, wrap, and whitespace controls
- diffs.com-style gutters, row fills, hunk chrome, and feedback cards

New review controls add a local feedback layer:

- selecting a diff line/range opens an inline comment composer
- saved comments appear exactly at their selected line/range
- the review summary lists active local comments grouped by file
- clicking a summary item scrolls to and focuses the inline comment
- finishing the review sends or copies a structured feedback prompt

The existing provider feedback cards remain separate from local draft comments
visually and semantically. They may appear in the same diff stack, but their
actions differ.

## Data Model

Add a local draft-review model:

- `ReviewDraftSessionID`
  - stable key for workspace/repo identity
  - source kind: local changes, staged, commit, range, branch, PR, MR, draft PR
  - source identifier: commit SHA, branch/ref pair, PR/MR provider identity, or
    local-change token
- `ReviewDraftComment`
  - id
  - session id
  - file id/path and optional original path
  - side: old, new, or unknown
  - start line and optional end line
  - selected text snapshot when available
  - markdown body
  - created/updated timestamps
  - local state: active, resolved, dismissed
- `ReviewDraftCommentStore`
  - persists comments by session id
  - loads comments when a review source opens
  - saves on add/edit/delete/state changes
- `ReviewFeedbackBundle`
  - groups active draft comments by file and line
  - includes review target metadata
  - formats prompt text for Copy and Send To Agent

Provider feedback continues to use `DiffReviewInlineFeedback`. The review
surface should get a display abstraction that can render both provider feedback
and local draft comments without erasing their different action sets.

## Diff Interaction

Local draft comments need exact placement. The AppKit-backed diff body already
has `DiffDisplayLine` and `DiffLineAnchor` metadata. This phase should expose
the minimum interaction hooks needed by the review workspace:

- identify the old/new side and line anchor under a click or gutter action
- support range selection through existing/extended diff selection primitives
- surface a stable insertion target for local comments in split and stacked
  layouts
- render comment accessories at the exact selected row/range

The line/range anchor must survive layout-mode changes because it is based on
file path, side, and line numbers, not visible row indexes.

For V1, the inline composer can be compact:

- markdown text field/editor
- Save and Cancel
- optional selected-range summary

Existing provider feedback placement should not be rewritten in this phase.

## Review Summary

The Review Workspace adds a collapsible right-side review summary rail for local
draft comments. The left rail remains file navigation. The right rail is review
state and finish actions. Collapsing the summary rail should leave a narrow
comment-count/finish-action strip so the review state remains visible while
reading code.

The summary shows:

- active comment count
- grouped comments by file
- line/range and side
- markdown preview
- resolved/dismissed status where relevant

Actions:

- click to scroll/focus the inline comment
- edit
- delete
- resolve/dismiss locally

Provider feedback remains in its current PR/MR Feedback evidence area and inline
cards. This phase should not merge provider feedback into the local summary
unless it can be done without confusing local-vs-remote state.

## Agent Handoff

The primary finish action is **Send Feedback To Agent**. It uses the same
formatter as **Copy Prompt** and includes:

- review target metadata
- repository/worktree path when available
- provider PR/MR metadata when the source is a provider review
- file paths
- old/new line or range anchors
- selected code snapshots when available
- markdown comment bodies

The prompt should be direct:

> Please address each review comment below. Inspect the referenced files and
> make the smallest safe changes. Explain what changed. Do not publish remote
> review comments unless explicitly asked.

Sending should use existing chat/ACP plumbing through an explicit target
selection step: list existing eligible chat sessions and a `New Chat` option. If
there are no eligible existing sessions, `New Chat` is the only target. The
selected target receives the formatted feedback bundle as the next user message.
`Copy Prompt` stays available as the manual fallback.

## Provider Boundary

Local draft comments are always local in this phase. Even when the review source
is a PR/MR, saving a local draft comment must not mutate GitHub/GitLab.

Provider feedback actions remain:

- Open
- Copy
- Send to Agent

Local draft comment actions are:

- Edit
- Delete
- Resolve/Dismiss locally
- Copy
- Send to Agent

Future provider-write phases can add:

- publish local draft comments to GitHub/GitLab review
- reply to provider threads
- resolve/unresolve provider threads
- submit provider review decisions

## Entry Points

Add or reuse entry points for:

- `Review Changes` from local changes
- `Review Commit` from commit/draft commit views
- `Review PR/MR Files` from PR/MR Files
- draft/create-PR branch diff review surface

Each entry point should create a `ReviewDraftSessionID` from its source and load
the same Review Workspace UI with the correct `DiffReviewLoadedSession`.

## Persistence

Draft comments should survive app restart. Persistence should follow the app’s
existing settings/state storage conventions rather than provider storage.

Required behavior:

- opening the same review target restores draft comments
- opening a different commit/branch/PR gets a separate session
- deleting a comment removes it from persistence
- resolving/dismissing a comment persists that local state

For local working-tree reviews, the session key should be stable enough to
survive reloads but scoped to the worktree/repo so comments do not leak between
repos.

## Error Handling

- If a saved comment no longer maps to a visible line, render it in the file’s
  fallback feedback area with an “unmatched” treatment.
- If a file no longer exists in the current review target, keep the comment in
  the summary under an unmatched/deleted file group.
- If persistence fails, keep comments in memory and show a non-blocking error.
- If Send To Agent is unavailable, hide or disable it and keep Copy Prompt
  available.
- If provider metadata is missing, generate a local-only prompt.

## Testing

Focused tests should cover:

- `ReviewDraftSessionID` stability for each supported source kind
- persistence round trip for add/edit/delete/resolve
- local comment exact placement in split and stacked layouts
- line-range anchors survive split/stacked mode changes
- unmatched comments fall back without disappearing
- review summary groups comments by file and scrolls to focused comments
- prompt bundle formatting matches ai-review-style grouped feedback
- Copy Prompt and Send To Agent use the same bundle formatter
- provider feedback cards and actions remain unchanged

Final verification remains:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```
