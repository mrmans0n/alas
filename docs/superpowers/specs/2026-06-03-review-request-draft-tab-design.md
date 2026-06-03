# Review Request Draft Tab Design

## Context

Alas already surfaces GitHub pull request readiness in the Changes tab through
the review readiness drawer. When a branch has pushed commits but no review
request, the drawer can create a PR through the code host provider. Today that
path submits directly with a branch-name title and fixed body.

Commit creation has a better workflow: a draft commit tab lets the user inspect
the relevant diff, generate text with the selected AI agent, edit the result,
and only then publish the commit. Review request creation should follow the same
shape so users can generate and review a proper PR title and description before
opening the request.

## Goals

- Replace the direct Create PR action with a center-pane draft tab.
- Generate PR title and description with AI assistance.
- Keep the first implementation provider-neutral in shape, with GitHub support
  through `gh` first.
- Generate from committed branch content only: base branch to `HEAD`.
- Let users customize the review request generation prompt in Settings.
- Support normal PR creation by default, with an opt-in Draft checkbox.
- Preserve user edits and keep failures local to the draft tab.

## Non-Goals

- GitLab `glab` support in the first implementation.
- Generating PR content from uncommitted working tree or index changes.
- Automatically submitting a generated PR without user review.
- Editing existing review request titles or descriptions.
- Reworking the entire review readiness drawer.

## Architecture

Add a provider-neutral center tab type, tentatively named
`DraftReviewRequestTabState`. It stores the worktree id, a stable tab id,
review kind metadata from the current snapshot, editable title, editable body,
selected context item, and `createAsDraft`, defaulting to `false`.

The existing readiness drawer action remains the entry point. When the model
offers `createReviewRequest`, `RightPaneState.handleReviewReadinessAction`
should open or focus the draft review request tab instead of calling
`ReviewLoopState.createReviewRequest(snapshot:)` directly. The tab initializes
from the current `ReviewLoopSnapshot`: provider kind, remote, branch, head
owner, base branch, ahead commit count, push state, and current head SHA.

Submission remains in the code host provider layer. Extend
`CodeHostProvider.createReviewRequest(...)` with an `isDraft: Bool` argument.
`GitHubCLIProvider` should pass `--draft` to `gh pr create` only when that flag
is true. GitLab remains unavailable until a GitLab provider implements creation
capability.

Remove the old user-facing fixed-title/fixed-body creation path. Keep only a
lower-level submit operation that requires caller-supplied title, body, and
draft mode. User-facing creation should flow through the tab.

## User Flow

When the readiness drawer shows that the branch has committed work but no PR,
the create action opens the draft tab. The tab title starts as "Draft PR" for
GitHub and can use provider labels for future hosts.

The tab header shows the provider and target repository, a title field, a
Markdown body editor, a sparkle button for AI generation, a Draft checkbox, and
a primary "Create PR" action. The Draft checkbox is off by default, so the
default behavior creates a normal open PR.

Below the editor, the tab shows committed branch context. The left side lists
changed files from base to `HEAD`, with a compact commit-subject summary above
the file list. The right side previews the selected file diff. The split should
reuse existing commit and diff views where practical, but the editor remains the
primary task surface.

After successful creation, the draft should not disappear without feedback.
Convert the tab into a simple created state, update the title to the provider
identity when available, show the provider URL, and offer an Open action. The
readiness drawer refresh should then pick up the new request.

## AI Generation

The draft tab uses the same selected AI tool as commit generation
(`changes.aiToolId`), but with a dedicated prompt:
`changes.reviewRequestPrompt`.

The generated context should include:

- provider and repository identity
- branch name
- base branch
- commit subjects between base and `HEAD`
- branch diff from base to `HEAD`
- status facts such as uncommitted changes existing, without including those
  uncommitted diffs

The generator must exclude working tree and staged changes from the diff. If
such changes exist, the tab should show a warning that they are not represented
in generated PR content.

The default prompt should require strict output:

```text
Line 1: PR title
Line 2: blank
Line 3+: Markdown body with:
## Summary
- ...

## Testing
- ...
```

The UI parses line 1 as the title and the remaining text as the Markdown body,
matching the existing commit-message generation behavior.

## Settings

Add a "Review requests" section to the Changes settings pane. It should expose
the review request prompt editor and show a Custom chip when the value differs
from `AppConfig.defaultReviewRequestPrompt`.

Config migration should preserve legacy files by defaulting missing
`changes.reviewRequestPrompt` to `AppConfig.defaultReviewRequestPrompt`.

The existing AI tool picker remains shared. The selected agent controls commit
message generation, merge help, review handoffs, and review request draft
generation.

## Validation And Error Handling

The draft tab should disable creation when:

- title is empty
- body is empty
- no branch is checked out
- no code host remote exists
- provider is unavailable or unauthenticated
- provider cannot create review requests
- branch has no ahead commits
- branch needs push before PR creation

If the branch needs push, the readiness drawer remains responsible for guiding
the push action. The draft tab can show the stale/push-needed state, but it
should not submit until the snapshot is refreshed after push.

AI failures should appear as inline tab errors. Manual edits must remain intact.
Clicking sparkle may replace the title/body with newly generated output, but no
background task should overwrite edited text without the user explicitly asking
for generation.

Provider creation failures should keep the draft open with the user's current
title, body, and Draft checkbox state intact.

## Testing Plan

- `AppConfig` tests for default `reviewRequestPrompt`, legacy decode, and
  round-trip persistence.
- Prompt status/settings tests for the review request prompt custom chip.
- Provider tests proving `GitHubCLIProvider` adds `--draft` only when requested.
- Prompt context builder tests proving committed branch context is included and
  uncommitted diffs are excluded.
- Tab manager tests for open/focus/update behavior of the draft review request
  tab.
- Readiness action tests proving Create PR opens the draft tab instead of
  directly submitting.
- Draft-tab model tests for title/body validation, push-needed gating, and
  creation failure preservation.

## Open Decisions Resolved

- Entry behavior: Create PR opens a draft tab.
- Diff scope: committed branch changes only.
- Provider scope: provider-neutral design, GitHub implementation first.
- Prompt: dedicated customizable review request prompt.
- Body shape: Summary and Testing sections by default.
- PR mode: normal PR by default, Draft checkbox available.
