# Review Readiness Drawer Design

Date: 2026-06-02
Status: Approved for implementation planning

## Goal

Replace the current guided review-loop experience with a compact Review Readiness drawer in the Changes tab. The drawer should tell the user what is true about the current branch and review request, then offer direct controls for obvious actions. It should not frame the workflow as a single guided session or ask the user to "start" a review loop before useful controls appear.

The bottom drawer remains the right shape. The product stance changes from "assistant chooses the next step" to "branch readiness panel with agent handoff when useful."

## Context

The current branch adds a provider-neutral code-host integration under:

- `Alas/Sources/Integrations/CodeHost/CodeHostModels.swift`
- `Alas/Sources/Integrations/CodeHost/CodeHostProvider.swift`
- `Alas/Sources/Integrations/CodeHost/GitHubCLIProvider.swift`
- `Alas/Sources/Integrations/CodeHost/ReviewLoopPlanner.swift`
- `Alas/Sources/Integrations/CodeHost/ReviewLoopState.swift`
- `Alas/Sources/Integrations/CodeHost/ReviewLoopDrawer.swift`
- `Alas/Sources/Right/ChangesTabView.swift`

The useful foundation is the provider-neutral data model, remote detection, GitHub CLI adapter, refresh state, and bottom drawer placement. The weak point is the current planner/session product model: it reduces branch state to one primary action and gates push/create behind `Start review session`. That makes the drawer feel like a wizard instead of a compact control surface.

GitLab support is expected immediately after this iteration, so the design must not bake GitHub-only concepts into the drawer or readiness derivation.

## Product Shape

The drawer becomes `Review Readiness`.

The collapsed state is a dense status strip. It shows identity and readiness facts, not a primary instruction. The expanded state shows the same facts with labels and a compact row of direct controls.

Agent handoff remains available for failed checks and actionable review feedback, but it is one action among others. The drawer should not imply that an agent owns the workflow.

Remove the review-session approval gate. `Push` and `Create PR/MR` are explicit user actions, so the button click itself is the intentional approval. Riskier operations still require explicit confirmation or stay out of scope.

## Provider Neutrality

Use provider-neutral domain language in models and derivation:

- `ReviewRequest` for a pull request or merge request.
- `ReviewCheck` for GitHub checks, GitLab pipelines, jobs, or similarly bucketed status.
- `ReviewThreadSummary` for actionable review feedback.
- `ReviewCheckBucket` for shared pass/fail/pending/cancel/unknown/skipping status.
- `ReviewMergeState` for shared clean/blocked/dirty/unstable/unknown mergeability.

Display provider-native labels only at the UI edge:

- GitHub: `PR`, `Create PR`, `Open PR`, identity such as `GitHub #445`.
- GitLab: `MR`, `Create MR`, `Open MR`, identity such as `GitLab !82`.

Provider capabilities should be explicit. The readiness model should know whether the active provider can create a request, rerun failed checks or pipelines, open a request URL, or prepare an agent handoff. GitLab can then map rerun to pipeline retry later, or report that the action is unsupported, without changing the drawer.

Drawer/readiness tests should run against both `.github` and `.gitlab` remotes where possible. Behavior should be shared except for provider-native labels and unsupported capabilities.

## UX

### Collapsed Drawer

The collapsed drawer should fit in one row:

- Provider/request identity, such as `GitHub #445`, `GitLab !82`, `GitHub`, or `GitLab`.
- Compact readiness labels or chips, such as `Unpushed`, `No PR`, `CI failed`, `Review pending`, or `Ready`.
- Refresh spinner when state is loading.
- Expand/collapse chevron.

There is no `Start` button and no singular "next action" sentence in the collapsed state.

### Expanded Drawer

The expanded drawer remains compact enough for the right sidebar:

1. Identity/title row.
2. Branch/base context.
3. Fact rows:
   - `Branch`
   - `Remote`
   - `Review request`
   - `Checks`
   - `Review`
   - `Merge`
4. Action row:
   - `Push` when `local.needsPush`.
   - `Create PR/MR` when authenticated and no request exists.
   - `Open PR/MR` when a request exists.
   - `Rerun` when failed checks exist and the provider supports rerun.
   - `Open in Agent` when failed checks or actionable review feedback exist and an agent is available.
   - `Refresh` always.
5. Secondary menu for copy URL, provider help, install/auth guidance, or other low-frequency actions.

Long logs, review bodies, and timelines stay out of the drawer. They should open in the provider, browser, terminal, or agent surface.

## Architecture

Keep the current provider-neutral foundation and introduce a readiness derivation layer over `ReviewLoopSnapshot`.

The new layer should be named `ReviewReadinessModel`. It should be a pure value/model helper that exposes:

- `identity`: provider/request display identity.
- `facts`: normalized branch, remote, review request, checks, review, and merge facts.
- `chips`: compact readiness labels for the collapsed row.
- `availableActions`: direct actions the drawer can show.
- `blockingText`: missing CLI, auth, unsupported remote, or refresh error guidance.

`ReviewLoopPlanner` should no longer be the UI source of truth for one chosen next action. Implementation should remove it if no production callers remain; otherwise keep it as an internal compatibility helper outside the drawer path. Visible behavior must come from readiness facts and action availability.

`ReviewLoopState` should stop tracking:

- `sessionApproved`
- `approvedBranchName`
- `.startSession` as a primary action gate

Its job should be:

- refresh local and provider state,
- keep the latest `ReviewLoopSnapshot`,
- run explicit user-selected actions,
- store `lastError`,
- keep drawer expansion state.

The drawer should render from the readiness model and dispatch explicit actions through `ReviewLoopState`.

## Actions And Boundaries

Allowed as direct drawer actions:

- Refresh provider state.
- Open the PR/MR/provider URL.
- Push the current branch.
- Create a PR/MR for the current branch.
- Rerun failed checks or retry failed pipelines when supported.
- Open a focused agent handoff prompt.

Always require explicit confirmation or remain out of scope:

- Merge.
- Force-push.
- Posting comments or replies.
- Resolving review threads.
- Destructive git actions.
- Launching an editing agent automatically without user intent.

This iteration keeps merge disabled. A future confirmation flow can add merge as an explicit action after the readiness pivot is stable. The main goal is to remove the session gate and make safe/direct controls available.

## Error Handling

When the provider CLI is missing, show provider-specific guidance such as `GitHub CLI missing` or `GitLab CLI missing`. The install/help action can live in the secondary menu or action row depending on available space.

When auth is missing, show `GitHub auth needed` or `GitLab auth needed` and offer auth guidance.

When provider refresh fails, preserve local facts where possible and show the error in the expanded drawer. A refresh failure should not erase branch context if local inspection succeeded.

When the remote is unsupported, the collapsed drawer should show `No supported review host` and only offer `Refresh` when expanded. It should not dominate the Changes tab.

## Testing

Update tests toward readiness derivation instead of planner-driven next action selection:

- Readiness chips for unpushed branch, no request, failed checks, pending checks, review feedback, review pending, and ready states.
- Action availability without `sessionApproved` for push and create request.
- Provider-native labels for GitHub PRs and GitLab MRs.
- Capability-gated actions such as rerun failed checks.
- Drawer model behavior for collapsed and expanded identity/fact/action text.
- Error states for missing CLI, auth failure, provider refresh failure, and unsupported remote.

Keep existing provider parsing tests for `GitHubCLIProvider`. When GitLab is added, use the same readiness tests against GitLab fixtures so adapter differences stay behind `CodeHostProvider`.

Manual verification should cover:

- GitHub branch with unpublished commits.
- GitHub branch with no PR.
- GitHub PR with pending checks.
- GitHub PR with failed checks and agent handoff available.
- GitHub PR with actionable review feedback.
- Missing `gh` or unauthenticated `gh`.
- A GitLab remote fixture or fake provider path that verifies MR labels before the real `glab` adapter lands.

## Out Of Scope

- Implementing the GitLab CLI adapter in this iteration.
- Full activity timeline inside the drawer.
- Rich check logs or review-thread bodies in the drawer.
- Autonomous agent fixing.
- Merge automation.
- Direct OAuth/token storage.
- Large namespace churn that is not needed for the readiness pivot.
