---
name: lassie
description: Shepherd an Alas GitHub pull request through Codex review, targeted fixes, CI, conflict resolution, and an optional merge. Use when the user invokes /lassie or asks to babysit, shepherd, finish, ready, or land an Alas pull request.
compatibility: Requires git, an authenticated GitHub CLI, and network access to github.com.
---

# Lassie

Own the pull request until it is ready to merge. Prioritize valid Codex feedback, keep CI green, and leave no merge conflicts. Do not stop merely because a review or check is still running.

## Invocation

Accept a pull request number or URL. Without one, infer the pull request for the current branch.

The optional `--merge` flag authorizes a squash merge after every gate passes. Without `--merge`, stop at ready-to-merge and leave the merge to the user.

## Invariants

- Work only in `mrmans0n/alas`.
- Treat feedback from `chatgpt-codex-connector` as the first gate. Evaluate it against the current code. Fix correct findings and respond with concrete evidence when a finding is wrong.
- Never change code solely to silence incorrect feedback.
- Every final result must describe the same pull request head SHA. A push or a changed head invalidates earlier review, CI, and mergeability observations.
- Follow `AGENTS.md`. Run affected tests locally, not the entire test plan. If CI skips the only relevant suite, run that suite locally.
- Never discard, stash, overwrite, or commit unrelated local changes.
- Never force-push. Merge the base branch into the pull request branch when conflict resolution requires an update.
- Do not merge a draft pull request or bypass branch protection.

## Start

1. Confirm the repository with `gh repo view --json nameWithOwner`.
2. Confirm `gh auth status` succeeds.
3. Require a clean working tree before changing the branch. If unrelated work makes that impossible, report the exact blocker.
4. Resolve the pull request and collect its number, URL, base branch, head branch, head SHA, draft state, merge state, reviews, comments, and checks.
5. If the pull request comes from a fork or the local checkout cannot safely update its head branch, finish all read-only assessment and report the write-access blocker.

## Shepherd loop

Run these gates in order. Restart at the Codex gate after every push or whenever the head SHA changes.

### 1. Codex gate

1. Find the Codex summary comment containing `codex-pull-request-review-summary` and fetch review threads through the GitHub GraphQL API. `gh pr view` alone does not expose thread resolution state.
2. Wait while Codex reports that review is running for the current head SHA. Poll without posting duplicate comments.
3. Inspect every current, unresolved thread whose author login is `chatgpt-codex-connector`. Also inspect unresolved older threads when the issue still exists in the current diff. Ignore outdated threads only after confirming the current code no longer has the problem.
4. Classify each finding:
   - Correct and actionable: make the smallest complete fix.
   - Correct but already fixed: reply with the commit or current code evidence.
   - Incorrect or inapplicable: reply with concise technical evidence. Do not edit the code.
   - Ambiguous and consequential: ask the user only after repository evidence cannot resolve it.
5. Run the affected local tests required by `AGENTS.md`. Commit and push fixes. Restart the loop immediately after a push.
6. Resolve addressed review threads when permissions allow. An unresolved thread with a valid current finding keeps this gate closed.

The gate passes only when Codex has completed against the current head and no valid Codex finding remains unaddressed.

### 2. Conflict gate

1. Refresh `headRefOid`, `baseRefOid`, `mergeable`, and `mergeStateStatus`. Wait and retry when GitHub reports mergeability as `UNKNOWN`.
2. If the pull request conflicts with its base branch, fetch the base branch and merge it into the pull request branch. Resolve every conflict from the intended behavior and repository conventions. Do not choose one side mechanically.
3. Run affected local tests, commit the conflict resolution, and push.
4. Restart at the Codex gate after the push.

The gate passes only when GitHub reports the current head as mergeable and not conflicting.

### 3. CI gate

1. Inspect checks for the current head. Wait for required checks to finish.
2. For each failure, inspect the failing job and logs before editing code.
3. Fix failures caused by the pull request, run the affected local tests, commit, push, and restart at the Codex gate.
4. Rerun a failed job only when evidence points to an infrastructure or flaky failure. Do not hide a deterministic failure by rerunning it repeatedly.
5. If an external service is unavailable or a persistent failure is unrelated to the pull request, report the evidence and exact blocker.

The gate passes only when all required checks for the current head succeed.

### 4. Stability check

Fetch a fresh pull request snapshot. Restart the loop if the head SHA changed, the base branch moved and introduced a conflict, Codex started another review, new valid feedback appeared, or a required check is no longer successful.

Ready-to-merge requires all of the following on one head SHA:

- Codex review completed.
- No valid Codex feedback remains unaddressed.
- All required CI checks succeeded.
- GitHub reports no merge conflict.
- The pull request is not a draft.
- No branch-protection requirement remains pending.

## Finish

Without `--merge`, report:

- Pull request number and URL.
- Verified head SHA.
- Codex review result and any rejected finding with its evidence.
- Required CI result.
- Mergeability and remaining non-code blockers, if any.
- Local tests run while fixing the pull request.

With `--merge`, squash-merge only after the stability check passes. Confirm the pull request state is `MERGED`, then report the merge commit and the same verification evidence. If the merge command fails because state changed, restart the loop instead of bypassing the gate.
