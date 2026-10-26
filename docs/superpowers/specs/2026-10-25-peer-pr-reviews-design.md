# Pull request reviews on a paired host's worktrees — design

## Intent

The user pairs a Mac with a headless `alas-host` and wants parity with local work. Draft reviews of a host worktree now work from the Mac (#2218–#2220): the Mac lists the host's reviews, opens local-changes, commit, range and branch reviews, and comments go both ways.

Provider reviews are the missing half. These are reviews of a GitHub pull request or a GitLab merge request. An agent on the host can already open one (`review <PR#|URL>`) and file draft comments on it. The paired Mac lists that session but opens it as "Not available from this Mac yet." The user can't read the PR's existing threads, add their own comments, reply to or resolve a thread, or publish the review with a verdict.

This design lets the Mac do on a host PR review what it can do on a local one, with the host doing the provider work.

## Current state (from recon, origin/main 3b1dfc8cb)

- **Model.**
  - `ReviewSessionTargetKind.reviewRequest` has the payload `.reviewRequest(provider:host:repositorySlug:number:headSHA:)` (AlasModel `ReviewSessionModels.swift`).
  - `draftReviewRequest` (a PR about to be created) also exists.
- **Local flow (the "new" review-session flow).** This is the one to mirror.
  - **Loader (app).** `ReviewSessionLoader.production` (`ReviewSessionLoader.swift:230-260`) calls `provider.reviewRequest(...)` to get the PR with its `threads`. It then calls `ReviewRequestDiffLoader.load`, which lives in AlasIntegrations and runs `provider.reviewDiff`, the provider's own diff: `gh pr diff` or `glab mr diff --raw`.
  - **Existing threads** render inline from `providerContext.reviewRequest.threads` (`ReviewSessionTabView.swift:~1053`).
  - **Draft comments** are ordinary `ReviewDraftComment`s in `ReviewDraftCommentStore`. Each carries `providerPublish` and `providerError`.
  - **Publish (app).** `ProviderReviewMutationController` (`:19-78`) calls `provider.publishReview` with a `ProviderReviewDecision` (comment, approve or request changes), then marks each draft published or records its error. The confirmation UI is `ProviderReviewPublishConfirmationView` (`ReviewSessionTabView.swift:990`).
  - **Thread actions.** Reply, resolve and unresolve go through `mutateReviewThread(ProviderThreadMutation)` and are immediate provider calls.
- **Legacy flow.** The `.reviewPR` tab with `ReviewTabView`, `VerdictSheet` and `PendingReview` creates a real GitHub pending review (`startReview` … `submitReview`). This design does not touch it.
- **Provider access.** Provider access runs `gh` and `glab` as subprocesses in AlasIntegrations, using their own login; there is no keychain. The code is headless-safe, and the host already uses it: `review <PR>` on a headless host calls `registry.provider(...).reviewRequest` and saves the session (`AlasHost+ReviewOpen.swift`).
- **Host gaps.**
  - `HeadlessHostEnvironment.providerReviewOriginalPath` returns nil (`AlasHostEnvironment.swift:203`), so a GitLab comment on a renamed file filed on the host loses its original path. The app implements it (`AppState.swift:14740`).
  - `mutateReview` add-comment refuses provider kinds (`AlasHost+PeerReviews.swift:139-141`).
  - Nothing on the host publishes.
- **Peer today.**
  - The Reviews list already includes a host's `.reviewRequest` sessions, since `PeerReviews.list` doesn't filter by kind.
  - `ReviewSessionLoader.peer(git:)` throws `unsupportedTarget` for them.
  - `reviewStatus` already carries the worktree's `ReviewLoopSnapshot` with its `ReviewRequest`: checks, threads, SHAs and URL. The peer drawer's only PR action is "open in browser".

## Goals

1. **Open a host PR review on the Mac.**
   - The Reviews list opens a host `.reviewRequest` session in the same peer review view as draft reviews, through `DiffReviewSurface`.
   - The view shows the PR's diff, as the provider computes it, the PR's existing threads inline, and the review's draft comments.
2. **Start one from the Mac.** When the host worktree has a PR, the Mac can start a review of it from the PR drawer and the Reviews list. The host opens or reuses the `.reviewRequest` session, exactly as an agent's `review <PR#>` does.
3. **Draft comments, as for draft reviews.** The user can add, edit, delete, resolve and dismiss draft comments. These are host requests, so the drafts live in the host's store, next to the agent's.
4. **Thread actions.** The user can reply to, resolve and unresolve the PR's existing threads. The host runs each one against the provider immediately, as locally.
5. **Publish with a verdict.**
   - The user publishes the review's unpublished drafts with a decision (comment, approve or request changes) and an optional body.
   - The host runs `publishReview` and records the per-draft result: published, or the provider's error.
   - The Mac shows the result, including partial failures and a verdict the provider dropped, as locally.
6. **Host-side parity fix.** The headless host resolves `providerReviewOriginalPath`, so GitLab comments on renamed files keep their original path whether the agent or the Mac files them.
7. **Capability-gated and compatible.** A new capability gates the new requests: provider read, thread mutation, publish and open. Older Macs and hosts are unaffected, and the Mac keeps "Not available from this Mac yet." for a host without the capability.

## Non-goals

- The legacy `.reviewPR` tab, `VerdictSheet` and `PendingReview`, which hold a provider-side pending review.
- `draftReviewRequest` sessions (a PR not yet created).
- Creating or merging PRs from the Mac. `pr_create` already exists for agents.
- Running gh or glab on the Mac for a host's PR.

## Anti-goals

- **No double publishing.** The host's draft store is the only record of what was published. The Mac never publishes a host review itself and never holds its own copy of the drafts.
- **No provider-side pending review left behind** by anything this design adds.
- **No change to local review behaviour or storage.**
- **No credential crosses the wire.** The provider work runs with the host's gh or glab login.

## Constraints

- AGENTS.md:
  - Swift Testing, minimal sharp tests;
  - no UI imports in core;
  - public cross-module types are explicitly Sendable;
  - Conventional Commits, no attribution.
- Tests don't call real providers. The provider protocol takes a command runner (`CodeHostCommandRunning`), so tests fake gh and glab output, as the existing provider tests do. Git stays real.
- The app can't be built locally, so CI is its first build. Keep `Alas/` and `AlasTests/` edits mechanical, and prefer no new files there.
- Reuse what exists:
  - `ProviderReviewMutationController`'s publish and mark logic;
  - `ReviewRequestDiffLoader`;
  - the draft-review peer requests from #2218–#2220.
  Where publish logic sits in the app target today, move the UI-free part into AlasFeatures so the host and the app share it, rather than copying it.

## Decisions (my calls)

- **The host owns the provider review.** It calls the provider for the diff, threads, thread mutations and publishing. The Mac renders what the host returns, and drafts stay in the host's store. That one place makes "already published" true for agents and the Mac alike.
- **The provider's diff comes from the host, not from git ranges.** The local flow uses the provider's own diff (`gh pr diff`), and a range read could differ: fork heads, stale bases, renames. The host serves the parsed provider diff. Image reads use the provider's base and head SHAs, through the existing commit reads when the host has those objects. Otherwise image previews are left out.
- **The new review-session flow only.** It never creates a provider-side pending review, so a Mac and host on the same account can't collide.
- **Publishing posts as the host's account** (its gh or glab login). The Mac shows which account will post, as reported by the host, in the publish confirmation.
- **Threads refresh on change.** After a thread action or a publish, the host re-reads the PR and emits `reviewsChanged`, so the Mac re-reads. Otherwise the existing 45 s `reviewStatus` refresh keeps the drawer current, and the review view's Reload button re-reads on demand.
- **Headless hosts only,** like draft reviews: the same `servesWorktreeGit`-style gating.

## Decisions from the builder check (my calls, all by parity with local)

- **Publish at the head the Mac showed.**
  - Locally, publish anchors drafts at the `headSHA` of the PR the open tab loaded, even if the PR moved since.
  - The Mac's publish request carries the head SHA of the diff it displayed, and the host publishes at that head. Re-reading threads after a mutation never changes which head a publish uses.
  - If the provider rejects the anchor, the existing per-draft error path reports it, as locally.
- **Publish all or a selection.** The publish request takes optional draft ids: nil means every unpublished draft, and a list means those drafts, which is how local per-comment publish works.
  - It carries the local controller's refusals as errors: "selected draft not publishable" and "no drafts for a comment review".
  - The peer view offers both the review-level publish and the per-comment publish.
- **Only the Mac publishes and mutates threads.** Agents get no publish or thread actions: locally, an agent's `review_finish` sets a verdict but never publishes, and nothing here changes that. The host still serializes publishes per review session, so two Macs, or a double click, can't publish the same drafts twice.
- **The posting account** comes from the host's provider login: `gh api user` or `glab`'s current user. It is shown in the confirmation, and left out if the host can't tell.

## Left to the builder

- Exact request and response names: for example `HostReviewMutation` cases `.publish(decision:body:)` and `.thread(ProviderThreadMutation)`, a read for the provider diff, and an open request.
- How the provider context (PR plus threads) travels: a field on `HostReview`, or its own read.
- Where the PR-drawer "Review" entry point sits in the peer right pane.
- PR split. The suggested order:
  1. host requests, shared publish logic and the original-path fix;
  2. the Mac view, threads and publish UI.
