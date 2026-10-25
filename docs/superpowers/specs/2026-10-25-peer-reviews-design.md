# Reviews on a paired host's worktrees — design

## Intent

The user pairs a Mac with a headless `alas-host` and wants parity with local work. Agents on the host can open reviews and work on review comments: `review`, `review_comments`, `review_reply`, `review_resolve`, `review_comment_add` and `review_finish` all run on the host through `host.reviews.*`. But the paired Mac can't see or answer them, so the review loop "you comment, the agent fixes and replies, you resolve" only works on a Mac running the app.

This design brings Alas's own draft reviews to host worktrees: local changes, commits, ranges and branches. The paired Mac shows them in a review tab like the local one, comments go both ways, and the user is told when an agent opens a review or replies. Provider PR/MR reviews (pending reviews, publishing to GitHub or GitLab) are a later step.

## Current state (from recon, origin/main)

- **Models (core).**
  - `ReviewSessionRecord` and its kinds (`ReviewSessionTargetKind`) are in AlasModel; `ReviewDraftSessionID` is a string encoding kind and worktree.
  - Draft comments are `ReviewDraftComment`: file, line or image anchors; state active, resolved or dismissed; author user or agent; replies; `resolvedBy`. They live in AlasFeatures.
  - Both are persisted as JSON in the profile by `ReviewDraftCommentStore` and `ReviewSessionStore`, which `AlasCoreContext` holds.
- **Host API.**
  - `ReviewsAPI` (`AlasHost+Reviews.swift`) has `comments`, `addComment(author:)`, `reply`, `resolve` (with reopen), `finish` and `open`.
  - `reply` and `resolve` hardcode the agent author.
  - Edit, delete, dismiss and list-sessions are missing.
  - `fileIDNamespace` (`AlasHost+Reviews.swift:~363`) decides comment file identity, for example staged versus unstaged.
- **UI (app).**
  - `DiffReviewSurface` renders a `DiffReviewLoadedSession` plus `draftCommentsByFileID`. Changes go out through closures and `ReviewDraftCommentActions`, and it reads no app state.
  - `ReviewSessionTabView` and `ReviewChangesTabView` wrap it but are wired to the local stores, `ReviewDraftCommentController` (synchronous writes) and `AppState`.
  - Loaders take git-client protocols, such as `ReviewChangesLoader` over `ReviewChangesGitClient` and `RangeReviewLoader` over `RangeReviewGitClient`.
- **Headless gaps.**
  - An agent's `review <target>` only saves the record; nobody is shown it.
  - `reviewReplyAdded` is a no-op on the host, so no attention is raised.
  - `reviewCommentsDidChange` publishes `reviewCommentChanges`, but nothing listens.
- **Peer side today.**
  - The peer protocol carries `reviewStatus`, the PR and check state, but no review sessions or comments.
  - The peer diff view (`NativePeerDocumentView`, `DiffPaneView`) has review line selection turned off.
  - `HostWorktreeRead` serves changes, file diffs, commit files and commit diffs, but not ranges.

## Goals

1. **The Mac sees a host worktree's reviews.** The peer right pane lists the worktree's review sessions: kind, target, status, verdict, open comment count. It updates live as the host's reviews change.
2. **A review tab for host reviews.**
   - Opening a review shows the same diff review surface as local (`DiffReviewSurface`), fed from host data, with the comments inline.
   - Covers local changes, commits, ranges and branches.
   - Diffs come from the host. Range and branch diffs get new `HostWorktreeRead` cases.
3. **Comments go both ways.** From the peer tab, the user can do what they can locally: add a comment on a line or a file, edit or delete their own, resolve, reopen, dismiss, and reply. Each action becomes a host request, and the tab updates from the host's change event.
   - Comments use the host's own file identity, so they line up with what agents on the host see through `review_comments`.
4. *(Dropped: see the decisions below. Local has no finish UI for draft reviews.)*
5. **The user hears about agent activity.** When an agent on the host opens a review, or replies to or resolves the user's comment, the paired Mac shows a banner. This uses the existing worktree-notice and session-notice relay, and clicking it opens that review tab.
6. **Capability-gated and compatible.** A new host capability gates the requests and the change event, which is an opt-in event kind. Older Macs and hosts are unaffected.

## Non-goals

- Provider PR/MR reviews: pending review, threads from GitHub or GitLab, publishing, `VerdictSheet`. That is a later step.
- "Send to agent" from the peer review tab. Agents read comments through `review_comments`. A send-to-agent button can follow, mapped onto the existing peer prompt path.
- Image anchors from the Mac. File and line anchors only, unless image anchors fall out of the shared surface for free.
- The "since snapshot" and draft-commit kinds, unless they fall out of the same loaders.

## Anti-goals

- No change to local review behaviour or storage.
- No comment orphaned by a file-identity mismatch between the Mac and the host.
- The Mac never writes the host's review files directly; every change goes through host requests.

## Constraints

- AGENTS.md:
  - Swift Testing;
  - testing policy: test the host review requests and their validation, the file-identity mapping, the change event and its opt-in, and a peer git client feeding the existing loader, using real git and temp dirs; don't test views;
  - no UI imports in core;
  - Conventional Commits, no attribution.
- The app can't be built locally, so CI is the first build. Prefer a thin peer review view around `DiffReviewSurface` over refactoring `ReviewSessionTabView`.
- Public types that cross modules or appear in `@Test(arguments:)` must be explicitly Sendable.

## Decisions (my calls)

- **Draft reviews first, provider reviews later.** The user agreed.
- **A thin `NativePeerReviewView` around `DiffReviewSurface`.** It fills the surface from host reads, rather than threading async mutations through `ReviewSessionTabView` and the local controller.
- **The host owns comment identity and ordering.** The Mac shows what the host returns and re-reads after each change event.
- **Agent attention relays through the existing notice path.** `reviewReplyAdded` on a relaying host becomes a notice. An agent opening a review becomes a worktree notice.

## Decisions from the builder check (my calls; these override the Goals where they conflict)

- **No finish from the Mac.** Local has no finish or verdict UI for draft reviews; only the agent-side `ReviewsAPI.finish` sets one. Goal 4 is dropped. The Mac shows a verdict an agent set, read-only.
- **Headless hosts only.** The capability is served by `alas-host`, like the git actions (`servesWorktreeGit`'s headless-only list), not by a Mac running the app. That avoids racing the host app's in-memory comment controller and two people writing as the same `.user` author.
- **The local-changes review appears in the list.** The list includes a synthesized local-changes entry for the worktree when it has comments, or when an agent opened it. No `ReviewSessionRecord` is persisted for it, so host review storage is unchanged.
  - An agent's `review` with no target on a headless host raises the "opened a review" notice from the headless router's open path.
- **Banners for replies only,** matching local `observeReviewReplyAttention`. A resolve with an attached reply notifies; a bare resolve does not.
- **Kinds covered:**
  - `localChanges`, `commit`, `trackedCommit` (the same commit diff), `commitRange` and `branch`;
  - `branchWithLocalChanges`, `sinceSnapshot` and `draftCommit` are listed but open as "not available from this Mac yet".
- **Notices link to their review.** `HostWorktreeNotice` gains an optional review target, so clicking opens that review tab. Older Macs ignore the field.

## Left to the builder

- Exact request, response and event names. For example `listReviews`, `readReview`, `mutateReview` with a `ReviewMutation` enum, and `reviewChanged(worktreeID:)`.
- How range and branch diffs are read: new `HostWorktreeRead` cases over the existing range git client.
- Where the list lives in the peer right pane (a Reviews section or tab), mirroring how local reviews are listed.
- PR split. The suggested order is wire and host first, then the peer review tab for local changes and commits, then ranges and branches plus entry points and attention.
