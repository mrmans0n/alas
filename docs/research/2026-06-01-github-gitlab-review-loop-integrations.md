---
title: "Provider-neutral GitHub/GitLab review loop integrations"
date: 2026-06-01
project: alas
phase: design
prior_art:
  - Alas/Sources/Right/ChangesTabView.swift
  - Alas/Sources/Right/RightPaneState.swift
  - Alas/Sources/Right/WorkingTreeSectionView.swift
  - Alas/Sources/Right/CommitsSectionView.swift
  - Alas/Sources/Settings/ChangesPane.swift
  - Alas/Sources/ACP/Session/ACPSessionManager.swift
---

## TL;DR

Add a provider-neutral review-loop integration surface to the bottom of the
Changes tab. V1 ships a GitHub PR pilot backed by the `gh` CLI while keeping
the model and UI vocabulary ready for GitLab through `glab`.

The feature is a narrow, user-controlled bottom drawer: collapsed by default
for scanning, expandable for a compact next-action view. It owns orientation
and action dispatch, not long-form reading. Full logs, review bodies, and
agent work happen in existing larger surfaces such as the browser, terminal,
or ACP agent tabs.

## Product Direction

The long-term goal is an end-to-end "babysit this change" loop: publish the
branch, create or update the PR/MR, watch CI and review state, help route
failures or comments to an agent, and eventually merge when policy allows.

V1 deliberately stops short of full automation. It should feel useful for a
single GitHub PR without hard-coding GitHub concepts into the rest of the app.

## Scope Confirmation

### In Scope For V1

- Detect whether the current worktree maps to a supported GitHub remote.
- Detect an existing PR for the current branch, or offer to create one.
- Push the branch and create/update the PR after the user starts a babysit
  session.
- Poll PR state, check state, review state, and merge readiness.
- Show one primary next action at a time in a bottom drawer in Changes.
- Prepare agent handoff prompts for failing checks and review feedback.
- Keep provider-facing data types neutral enough for GitLab to implement the
  same protocol later.

### Out Of Scope For V1

- GitLab implementation beyond designing the shared provider interface.
- Direct API tokens, OAuth, or app-managed credential storage.
- Autonomous code edits for failing CI or review comments.
- Posting comments, resolving review threads, or merging without explicit
  confirmation.
- Auto-merge policy.
- Full activity timeline inside the sidebar.
- Rich log or review-thread reading inside the drawer.

## UX Design

The Changes tab gets a bottom drawer below the local working-tree and commit
sections. It is persistent but user-controlled.

### Collapsed State

The collapsed drawer is one dense row:

- Provider and PR/MR identity, such as `GitHub #428`.
- High-signal state, such as `Needs push`, `CI failed`, `Review pending`, or
  `Ready`.
- One short next-action label.
- One primary action button when an action is available.
- Overflow menu for refresh, open in browser, copy URL, rerun checks, and
  other secondary actions.

### Expanded State

The expanded drawer remains one column so it fits the existing right sidebar.
It should not become a dashboard.

Order of content:

1. Next action card.
2. Primary action button.
3. Compact status facts: branch, checks, reviews, merge readiness.
4. Secondary controls in an overflow menu.

The drawer should open larger material elsewhere:

- Check logs open in the browser or provider page in v1.
- Review thread bodies can open in the provider page in v1.
- Agent prompts open or queue in an ACP/agent tab.
- Future richer detail views can live in a center tab or sheet, not inside the
  right sidebar.

## Architecture

Add a new integration area under `Alas/Sources/Integrations/` with a
provider-neutral core and CLI-backed providers.

### Core Types

- `CodeHostProvider`: protocol for GitHub/GitLab-style hosts.
- `CodeHostRemote`: parsed host, owner/group, repository, and remote name.
- `ReviewRequest`: provider-neutral PR/MR summary.
- `ReviewCheck`: provider-neutral check or pipeline/job summary.
- `ReviewThread`: provider-neutral review discussion summary.
- `ReviewLoopState`: per-worktree observable state.
- `ReviewLoopPlanner`: maps local git state plus provider state to one next
  action.
- `ReviewLoopDrawer`: SwiftUI drawer mounted at the bottom of
  `ChangesTabView`.

### Provider Adapters

V1 implements `GitHubCLIProvider` using `gh` JSON commands. The first GitLab
implementation should be `GitLabCLIProvider` using `glab` behind the same
protocol.

Use CLIs first because they inherit user auth and enterprise host config. The
provider protocol should still hide CLI details from the planner and UI so
individual operations can move to direct APIs later if needed.

### Data Flow

1. Local git reads branch, upstream, dirty/staged state, commits ahead, and
   push need.
2. Remote detection parses `git remote -v` URLs and picks a provider.
3. Provider adapter reads PR/MR identity, checks/pipelines, review threads,
   and mergeability.
4. Planner chooses one primary next action.
5. Drawer renders summary plus the primary action.
6. Confirmed actions route back through `ReviewLoopState`, then refresh local
   and provider state.

## Next-Action Planner

The UI should not expose raw state as the main product. It should answer,
"What should happen now?"

Representative actions:

- `installProviderCLI`: `gh` is missing or unavailable.
- `authenticateProvider`: `gh auth status` fails.
- `pushBranch`: branch has unpublished commits.
- `createReviewRequest`: no PR exists for the branch.
- `updateReviewRequest`: PR exists but metadata is stale.
- `waitForChecks`: checks are pending.
- `prepareCheckFailureHandoff`: at least one check failed.
- `prepareReviewHandoff`: actionable review feedback exists.
- `rerunFailedChecks`: failed checks can be rerun.
- `waitForReview`: checks passed but review is pending.
- `readyToMerge`: provider says the PR is mergeable and policy gates are
  satisfied.
- `blocked`: provider/local state requires manual work.

Planner tests should cover mixed local/provider state combinations so the
drawer stays predictable as providers evolve.

## Action Boundaries

Starting "babysit this branch" grants session approval for remote workflow
maintenance only.

Allowed after session approval:

- Push the current branch.
- Create a PR if none exists.
- Update PR title/body when requested by the planner.
- Poll PR, check, review, and mergeability state.
- Rerun failed checks if supported by the provider.

Always require explicit confirmation:

- Posting comments or replies.
- Resolving review threads.
- Merging.
- Launching an agent in a mode that edits files.
- Force-push or destructive git operations.

## Agent Handoff

V1 prepares handoff context but does not run autonomous fixes.

For a failing check or review thread, Alas should build a focused prompt with:

- Provider name and PR URL.
- Branch and base branch.
- Check or review-thread title.
- Log excerpt or review text.
- Changed files and recent commits.
- Local diff summary when useful.
- Clear instruction to inspect, explain, and propose or implement a fix only
  after the user sends the prompt in the agent surface.

Primary drawer action can be `Open in agent` or `Queue in agent`, depending on
current ACP/agent session state. After the user or agent changes files, the
loop returns to normal local git flow: review changes, commit, push, and update
the PR.

## Settings

V1 should keep settings minimal:

- Preferred agent for review-loop handoff can initially reuse or sit near the
  existing Changes agent setting.
- Provider CLI detection should be automatic.
- If `gh` is missing or unauthenticated, the drawer should show a next action
  with install/auth guidance instead of adding a settings-first flow.

Provider-specific credentials and direct API token storage are out of scope.

## Testing Strategy

Focused unit tests should cover:

- Remote URL provider detection for common GitHub SSH/HTTPS forms.
- `gh` JSON parsing for PR summaries, checks, reviews, and error states.
- Planner outputs for local-only, provider-ready, CI-failing, review-pending,
  and ready-to-merge states.
- Confirmation policy for session-approved vs explicit-confirmation actions.
- Agent handoff prompt building with bounded context.
- Drawer rendering in collapsed, expanded, unavailable-provider, and action
  states.

Integration tests can use fake provider adapters. Real `gh` subprocess tests
should be limited or manually gated to avoid depending on developer auth.

## Risks And Mitigations

- **Sidebar width pressure**: Keep the drawer one-column and action-oriented.
  Send long content to larger surfaces.
- **Provider abstraction drift**: Build GitHub first, but name domain types for
  review requests, checks, and threads rather than GitHub-specific concepts.
- **CLI output instability**: Use `--json` where available, parse structured
  output only, and isolate parsing behind adapter tests.
- **Authentication ambiguity**: Detect CLI auth state and make it a next action
  instead of failing silently.
- **Automation trust**: Keep comments, thread resolution, merge, editing agents,
  force-push, and destructive git actions behind explicit confirmations.
- **Scope creep toward C too early**: V1 prepares agent handoffs; autonomous
  agent fixes belong to a later iteration after the provider loop is stable.

## Acceptance Criteria

1. A GitHub-backed worktree can show a review-loop drawer in Changes.
2. The drawer can identify missing CLI/auth, unpublished branch, no PR,
   pending checks, failed checks, review feedback, and ready states.
3. Starting a babysit session allows non-destructive remote workflow actions
   for that session.
4. Explicit confirmations are enforced for comments, review-thread resolution,
   merge, editing agents, force-push, and destructive actions.
5. Failing checks and review feedback can produce a focused agent handoff.
6. The provider model can support a future `GitLabCLIProvider` without
   replacing the drawer or planner.
7. Unit tests cover provider detection, CLI parsing, planning, confirmation
   policy, handoff prompt building, and drawer states.

## Open Questions For Implementation Planning

1. Should `ReviewLoopState` live directly inside `RightPaneState`, or should
   `RightPaneStore` own a parallel per-worktree cache?
2. Should the babysit session approval reset when the worktree changes, the app
   restarts, or the branch changes? Recommendation: reset on any of those.
3. Should PR body generation use commit summaries only in v1, or reuse the
   existing commit-message agent prompt style? Recommendation: start with
   deterministic commit summaries and leave AI-generated PR text for later.
4. Should check-log retrieval be part of v1, or should v1 link to the provider
   page and only prepare handoff from available summary data? Recommendation:
   include bounded log excerpts when `gh` exposes them cleanly; otherwise link.
