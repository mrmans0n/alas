# In-App Review Sessions And Agent Handoff Design

## Context

Alas now has the core review surface pieces: a diffs.com-like multi-file diff
surface, local draft comments, inline comment cards, summary rail actions,
provider PR/MR evidence loading, commit review surfaces, create PR draft
surfaces, and direct ACP prompt sending.

The remaining gap with `ai-review` is not the visual diff reader anymore. The
gap is the review workflow: start a review over any useful diff target, keep
that review as a first-class in-app object, collect human comments, then send
the resulting feedback to an agent with enough context for the agent to address
it correctly.

The remaining gap with Rudu is provider mutation: creating/replying/editing and
resolving GitHub/GitLab review comments. This phase prepares the data model for
that work, but it does not implement provider mutation.

## Goals

- Add an in-app review session launcher for reviewable diff targets.
- Make review sessions persistent and resumable inside Alas.
- Use the existing `DiffReviewSurface` and local draft comments as the review
  body.
- Add native "send selected/all feedback to agent" workflows that target Alas
  ACP sessions directly.
- Track feedback handoff state so the review UI can distinguish unsent,
  sent, and addressed feedback.
- Keep the model ready for future GitHub/GitLab write-backed comments.

## Non-Goals

- Do not add an external `air`-style CLI or blocking `--wait --json` bridge.
- Do not add agent skills in this phase.
- Do not implement GitHub/GitLab comment mutation APIs in this phase.
- Do not replace existing provider evidence loading.
- Do not change ACP protocol behavior or introduce a second agent transport.

## Review Targets

V1 supports review sessions for targets that already have data loaders or nearby
loader patterns:

- local working-tree changes, with scope `all`, `unstaged`, or `staged`
- draft commit / staged changes
- a single commit
- a commit range
- a branch diff, including stack-style branch ranges
- a provider PR/MR diff loaded through existing review evidence providers
- a draft PR/MR request context

Each target gets a stable `ReviewSessionTarget` value containing:

- target kind
- worktree ID
- repository path
- provider identity when applicable
- base/head/revision identifiers when applicable
- human-readable title and source description

The target stores all revision/context fields needed to build both the diff
session and the agent handoff prompt without depending on current checkout
state.

## Review Session State

Add a durable review session record separate from individual draft comments.

A review session owns:

- stable session ID
- target identity
- created/updated timestamps
- selected file
- display preferences inherited from global diff preferences
- focused comment ID when one is selected
- handoff history
- lightweight status: `active`, `sent`, `addressing`, `addressed`, `archived`

The existing `ReviewDraftSessionID` remains the comment-storage key. The new
review session record references or derives the relevant `ReviewDraftSessionID`
for its target. This avoids migrating existing comments while giving Alas a
place to track session-level state.

Session persistence uses the same app-support/storage style as existing review
draft comments and ACP sessions. The persisted format is versioned or decodes
unknown fields safely so provider-backed comments can be added later.

## Launcher UX

Add a review launcher reachable from the places where users already discover
diffs:

- Changes tab: "Review Changes"
- Draft Commit tab: "Review Staged Changes"
- Commit tab: "Review This Commit"
- commit/range contexts: "Review Range"
- Review Evidence / PR/MR details: "Review Pull Request" or "Review Merge Request"
- Create PR/MR draft tab: "Review Branch Diff"

The launcher opens or focuses a review session tab. If an active session already
exists for the same target, Alas resumes it instead of creating a duplicate
unless the user explicitly starts a new review.

The review session tab is a thin shell around the shared diff review surface:

- title/header describes the target
- file rail and diff stack come from `DiffReviewSurface`
- local draft comments are editable/resolvable/dismissible
- a feedback summary rail shows active/resolved/sent counts
- send actions are available from the summary rail and individual comment cards

## Native Agent Handoff

The handoff uses existing ACP session mechanisms directly. No CLI or skill
bridge is needed.

Supported actions:

- send selected comment to an existing writable ACP session
- send selected comment to a new ACP session using the configured default agent
- send all active comments to an existing writable ACP session
- send all active comments to a new ACP session

The prompt is built from `ReviewFeedbackBundle`, extended to include:

- review session title
- repository path
- target kind
- base/head/revision identifiers
- provider URL when applicable
- file path and original path
- side and line/range
- selected code snippet
- comment status
- whether this feedback was previously sent

When a send succeeds, Alas records a `ReviewFeedbackHandoff` entry:

- handoff ID
- review session ID
- comment IDs included
- ACP session ID or new-session target
- timestamp
- prompt hash or revision key
- status: `sent`, `failed`, `addressed`

V1 marks handoffs as `sent` when the prompt is accepted or queued by ACP. It does
not infer addressed status from code changes. Addressed state is user-controlled
through existing resolve/dismiss actions.

## Provider Write Readiness

The model distinguishes local draft comments from future provider-backed
threads:

- local comments remain mutable locally
- provider comments will carry provider thread/comment IDs
- provider comments can have write capabilities: reply, edit, resolve, submit
- provider write actions can reuse the same visible card/action surfaces

This phase does not call GitHub/GitLab mutation APIs. It uses neutral names like
review comments, handoffs, and capabilities rather than local-only names where
the data will become provider backed.

## Error Handling

If a target cannot be loaded, the review session tab shows a retryable error and
preserves the session record.

If some files cannot render, keep the file in the rail and show the existing
placeholder behavior.

If there is no available agent target, show copy actions and an unavailable
send state. Do not hide comments.

If sending to an ACP session fails synchronously, keep the feedback unsent and
show a small error on the session/summary rail. If ACP accepts the prompt for
queueing, record the handoff as sent.

If a target revision changes, the review session shows a "target moved" state.
Provider PR/MR sessions can reload against the new head; immutable commit
sessions stay pinned.

## Testing

Add focused model tests for:

- target identity stability for local changes, commit, range, branch, provider,
  and draft PR/MR targets
- review session persistence round trips
- review session reuse for the same target
- handoff records and status transitions
- prompt context includes target/revision/provider data

Add loader/view tests for:

- launching a local changes review session
- launching a commit review session pinned to its SHA
- launching or resuming a provider review session
- sending all active comments to a mocked ACP target
- sending one selected comment to a mocked ACP target
- unavailable send state when no writable ACP target exists

Final verification remains:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

## Fast Follows

- Provider write actions for GitHub/GitLab comments and review decisions.
- Review queue keyboard navigation.
- Exact row-level inline comment insertion inside the AppKit diff body.
- Automatic addressed-state detection from later diffs.
- Saved review templates or prompt variants for different agent types.
