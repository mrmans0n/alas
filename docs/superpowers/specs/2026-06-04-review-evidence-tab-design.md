---
title: "Review evidence center tab for PR/MR CI and feedback"
date: 2026-06-04
project: alas
phase: design
---

# Review Evidence Center Tab

## Summary

Add a center tab for inspecting review-loop evidence from GitHub and GitLab.
The first completed section is CI failure inspection; unresolved review
feedback uses the same tab because both workflows are evidence the user reviews
before deciding whether to ask an agent to act.

The Changes drawer remains a compact status and next-action surface. It should
show states such as `CI failed`, `Review feedback`, and `Ready`, then open the
center tab with an `Inspect` action when detailed evidence needs real estate.

## Goals

- Help users review agent output safely before publishing or continuing.
- Make CI failures explorable inside Alas instead of forcing a browser jump for
  every failed job.
- Surface actionable PR/MR feedback as individual work items.
- Preserve the current provider-neutral GitHub/GitLab architecture.
- Avoid turning the right sidebar drawer into a provider dashboard.

## Non-Goals

- Replace GitHub or GitLab PR/MR pages.
- Store provider credentials or bypass `gh` / `glab` authentication.
- Fetch large logs during normal Changes drawer refresh.
- Add autonomous remote commenting, thread resolution, or merge behavior.
- Build a full provider timeline in this iteration.

## UX

The center tab should feel like a review workbench, not a provider clone.

### Entry Points

- The Changes drawer keeps showing compact review-loop state.
- When CI has failed or actionable feedback exists, the primary action becomes
  `Inspect`.
- `Inspect` opens or focuses the review evidence tab for the worktree.
- Opening from a CI failure selects the first failed check.
- Opening from review feedback selects the first actionable thread.
- If both CI failure and feedback exist, generic `Inspect` selects CI first
  because CI is objective and often blocks review.

### Tab Layout

Top bar:

- Provider identity, such as `GitHub #465` or `GitLab !42`.
- PR/MR title.
- Status chips for checks, review, and merge readiness.
- Actions for refresh and open PR/MR.

Main layout:

- A left evidence list.
- A right detail pane.
- A segmented control for `CI` and `Feedback`.

CI evidence rows show:

- Check/job name.
- Workflow, pipeline, or source; omit this line when the provider does not
  return one.
- Provider status and severity.
- Timestamp; omit this line when the provider does not return one.

CI details show:

- Check/job name.
- Workflow or pipeline.
- Status.
- Provider link.
- Bounded log excerpt.
- Whether the excerpt was truncated.

Feedback evidence rows show:

- Reviewer.
- Short comment preview.
- File and line; omit this line when the provider does not return location
  metadata.
- Resolved/actionable state.

Feedback details show:

- Reviewer.
- Comment body.
- File and line; omit this line when the provider does not return location
  metadata.
- Provider link.
- Thread state.

Footer/detail actions:

- `Copy Context`.
- `Open in Browser`.
- `Rerun Failed` for CI where supported.
- `Send to Agent`.

Empty and blocking states should be factual:

- `No failed checks`.
- `No actionable feedback`.
- `Review request not found`.
- `Provider CLI unavailable`.
- `Provider authentication required`.

## Architecture

Add a new center tab type named `reviewEvidence`.

Core pieces:

- `ReviewEvidenceTabState`: worktree id, provider identity, request number/url,
  selected section, and selected item id.
- `ReviewEvidenceTabView`: center-pane UI with `CI` and `Feedback` sections.
- `ReviewEvidenceModel`: observable tab model that loads evidence lists and
  detail data lazily.
- `ReviewEvidenceItem`: provider-neutral list row data.
- `ReviewEvidenceDetail`: provider-neutral selected-item detail.

The existing `ReviewLoopDrawer` and `ReviewReadinessModel` continue to render
summary state. They should open the tab rather than fetch or display heavy
evidence details.

### Data Flow

1. Review loop refresh detects local/provider summary state.
2. The drawer shows `CI failed`, `Review feedback`, or another compact state.
3. The user selects `Inspect`.
4. `TabsManager` opens or focuses the worktree's review evidence tab.
5. The tab loads detailed CI/thread evidence through the provider registry.
6. Selecting an evidence item loads detail data lazily.
7. User actions copy context, open provider URLs, rerun failed jobs, or send a
   focused prompt to the configured agent.
8. After rerun or agent work, normal Changes refresh updates both the drawer
   and the tab.

### Provider-Neutral Detail Model

Use small provider-neutral types for the first pass:

```swift
enum ReviewEvidenceSection: String, Codable, Equatable, Sendable {
    case ci
    case feedback
}

enum ReviewEvidenceStatus: String, Codable, Equatable, Sendable {
    case failed
    case pending
    case passed
    case cancelled
    case actionable
    case resolved
    case unknown
}

struct ReviewEvidenceItem: Identifiable, Equatable, Sendable {
    let id: String
    let section: ReviewEvidenceSection
    let title: String
    let subtitle: String?
    let status: ReviewEvidenceStatus
    let providerURL: URL?
}

struct ReviewEvidenceDetail: Equatable, Sendable {
    let item: ReviewEvidenceItem
    let body: String
    let filePath: String?
    let line: Int?
    let isTruncated: Bool
}
```

Extend `CodeHostProvider` with detail-oriented reads:

```swift
func failedCheckEvidence(
    remote: CodeHostRemote,
    request: ReviewRequest,
    cwd: URL
) async throws -> [ReviewEvidenceItem]

func checkEvidenceDetail(
    remote: CodeHostRemote,
    request: ReviewRequest,
    item: ReviewEvidenceItem,
    cwd: URL
) async throws -> ReviewEvidenceDetail

func feedbackEvidence(
    remote: CodeHostRemote,
    request: ReviewRequest,
    cwd: URL
) async throws -> [ReviewEvidenceItem]

func feedbackEvidenceDetail(
    remote: CodeHostRemote,
    request: ReviewRequest,
    item: ReviewEvidenceItem,
    cwd: URL
) async throws -> ReviewEvidenceDetail
```

GitHub maps this through `gh pr checks`, `gh run view`, job/log APIs where
available, and GraphQL review threads. GitLab maps through `glab ci get`,
`glab ci trace` or job APIs where needed, and unresolved MR discussions.

The drawer refresh must not call log/detail APIs. Only the center tab fetches
heavy detail data.

## Error Handling

- If the provider CLI is missing or unauthenticated, the tab shows the same
  provider-blocking state as the drawer.
- If logs cannot be fetched, keep the evidence row visible and show a detail
  error with `Open in Browser` and `Copy Provider URL`.
- If a check or thread disappears between refresh and selection, clear the
  selection and reload the list.
- If log output is too large, truncate deterministically and show a truncation
  marker.
- If rerun fails, show the command error inline in the CI detail pane and
  preserve the selected item.

## Testing

Add focused Swift Testing coverage for:

- GitHub failed check and log-reference parsing.
- GitLab pipeline/job evidence parsing.
- Evidence model section selection, including CI winning over feedback for
  generic `Inspect`.
- Tab open/focus behavior and stable selected item ids.
- Handoff builder output for selected CI and feedback evidence.
- UI/model states for empty, loading, error, truncated-log, missing CLI, and
  unauthenticated provider states.

Provider subprocess tests should use fake command runners. Real `gh` and
`glab` subprocess coverage should stay manual or separately gated because it
depends on developer authentication and remote state.

## Acceptance Criteria

1. A worktree with a failed GitHub or GitLab check can open a center review
   evidence tab from the Changes drawer.
2. The CI section lists failed checks/jobs and shows a bounded detail excerpt
   for the selected item.
3. The user can copy selected CI context, open the provider URL, rerun failed
   jobs where supported, and send selected CI context to an agent.
4. The Feedback section lists unresolved/actionable PR/MR threads and shows a
   selected thread detail preview.
5. The user can copy selected feedback context, open the provider URL, and send
   selected feedback context to an agent.
6. The Changes drawer stays compact and does not fetch heavy log or thread
   detail during normal refresh.
7. Provider errors are visible in the tab without losing the selected evidence
   context when possible.

## Future Work

- Add a `Local Review` section for guided review of unmerged local changes.
- Add ready-to-merge and post-merge archive flows after evidence review is
  stable.
- Add richer provider metadata if users need labels, assignees, reviewers, or a
  short timeline.
