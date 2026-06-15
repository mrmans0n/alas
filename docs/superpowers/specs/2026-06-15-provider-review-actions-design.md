# Provider Review Actions Design

## Context

Alas now has a polished diff review surface, persistent local draft review
comments, in-app review sessions, and native agent handoff. Those pieces cover
most of the local `ai-review` workflow. The remaining Rudu-sized gap is provider
write support: Alas can read GitHub/GitLab review state, but it cannot yet
participate in the remote review by publishing comments, replying to threads, or
resolving provider discussions.

This design adds explicit provider review actions for both GitHub and GitLab in
the same V1. The implementation stays CLI-backed (`gh`, `glab`, plus
`api`/GraphQL subcommands where needed) so auth, host routing, and enterprise
configuration remain delegated to the existing provider tools.

## Product Shape

Provider writes layer onto existing review workspaces and PR/MR review surfaces:

1. The user opens a GitHub PR or GitLab MR review session.
2. The user adds local draft comments on exact lines/ranges as they do today.
3. The user chooses `Publish review`.
4. Alas shows a confirmation with provider, PR/MR number, review decision,
   comment count, and any comments that cannot be published.
5. Alas writes the comments/review through the provider CLI.
6. Alas refreshes provider state from the remote source.
7. Alas marks successfully published local drafts with provider metadata and
   leaves failed drafts active with an attached warning.

Existing provider feedback cards gain provider-backed actions when the loaded
thread contains the provider identifiers required by that action:

- Reply
- Resolve
- Unresolve

Local drafts never publish automatically. Typing, saving, editing, or sending a
draft to an agent remains local-only until the user explicitly chooses a publish
action.

## Provider Model

Add a write-side provider API beside the current read-side `CodeHostProvider`
methods.

Core model:

- `ProviderReviewDraftComment`
  - local draft comment id
  - file path and original path
  - side: old, new, or unknown
  - start/end lines
  - selected text snapshot
  - Markdown body
- `ProviderReviewDecision`
  - `comment`
  - `approve`
  - `requestChanges`
- `ProviderReviewPublishRequest`
  - remote
  - review request
  - comments
  - decision
  - summary body
  - repository cwd
- `ProviderReviewPublishedComment`
  - local draft id
  - provider thread id, required for thread-level publish/resolve actions
  - provider comment id, optional and stored when returned
  - provider URL, optional and stored when returned
- `ProviderReviewPublishResult`
  - published comment mappings
  - failed comment results
  - refreshed `ReviewRequest`
  - provider warnings
- `ProviderThreadMutation`
  - reply
  - resolve
  - unresolve

`CodeHostProviderCapabilities` should expose write capabilities explicitly:

- can publish review comments
- can reply to review threads
- can resolve review threads
- can unresolve review threads
- can approve
- can request changes

Capabilities can be static where the provider CLI/API support is known and can
also be filtered at action time when a request lacks enough provider identifiers
or the thread is outdated.

## GitHub Path

GitHub uses `gh` for auth and host routing.

Implementation rules:

- Use `gh api graphql` for thread resolution and unresolution.
- Use `gh api` or `gh api graphql` for creating review comments and submitting
  review decisions.
- Use one review submission for batch publish. If GitHub rejects one comment in
  the batch, retry publish for the remaining individually commentable drafts and
  report the rejected draft as a per-comment failure.
- Preserve the provider's canonical response: collect provider thread/comment
  ids and URLs when returned.
- Map local anchors to GitHub file/line/side fields. If GitHub rejects an exact
  anchor because the line is outdated or uncommentable, keep that draft local
  and surface the provider error for that comment.
- After publish/reply/resolve/unresolve, refresh the PR through the existing
  provider loading path before reporting success.

GitHub decisions:

- `comment`: publish comments and submit a comment review.
- `approve`: publish comments if present, then submit approval.
- `requestChanges`: publish comments if present, then submit request changes.

## GitLab Path

GitLab uses `glab` for auth and host routing.

Implementation rules:

- Use `glab api` for MR discussions and notes because high-level `glab mr`
  commands do not cover all review-thread mutations cleanly.
- Create line/range discussions from local drafts using GitLab diff refs and
  position payloads.
- Reply to discussions by creating notes.
- Resolve/unresolve discussion threads using the discussions API. Hide these
  actions when the loaded thread does not include a discussion id.
- Use the MR approval endpoint for `approve`. If the endpoint is unavailable or
  the user lacks permission, surface that provider error and leave local drafts
  unchanged except for comments that were already published before the approval
  call.
- Represent `requestChanges` as publishing draft discussions plus a clear
  review-status note, because GitLab does not map one-to-one to GitHub review
  decisions in all tiers/versions.
- After publish/reply/resolve/unresolve, refresh the MR through the existing
  provider loading path before reporting success.

If GitLab rejects a position payload, keep the local draft active and attach the
provider error to that draft. Do not silently fall back to a file-level comment
unless the user explicitly chooses a later fallback action.

## UI and Safety

Summary rail:

- Show `Publish review` when the session has provider context and active local
  drafts or a provider decision action.
- The publish flow presents a confirmation popover/sheet before any remote
  mutation.
- Confirmation shows provider, PR/MR number, decision, comment count, and
  warnings for unpublishable drafts.
- The user selects `Comment`, `Approve`, or `Request changes`.

Local draft cards:

- Show `Publish` when the draft has provider context and a commentable anchor.
- Per-comment publish still confirms provider target and action.
- Successful per-comment publish marks only that draft as published.

Provider feedback cards:

- Show `Reply` when reply is supported for the thread.
- Show `Resolve` for unresolved threads with a provider thread/discussion id.
- Show `Unresolve` for resolved threads with a provider thread/discussion id.
- Mutating actions show a small inline progress/error state and refresh provider
  state after success.

Published local drafts:

- Local draft comments are not deleted on publish.
- Each successful draft stores provider metadata: provider kind, remote identity,
  PR/MR number, provider thread id/comment id, URL, and published timestamp.
- Failed comments remain active local drafts with an error message.
- Re-publish actions are hidden for already-published drafts.

## Data Flow

Publish review:

1. UI builds a `ProviderReviewPublishRequest` from the current review session,
   active local drafts, selected decision, and provider context.
2. UI asks the provider for unsupported/unpublishable drafts before showing the
   confirmation.
3. User confirms.
4. Provider writes comments/review through `gh` or `glab`.
5. Provider returns published mappings, failures, warnings, and refreshed
   request data.
6. Draft comment store records provider metadata for successful drafts and
   provider errors for failed drafts.
7. Review session reloads refreshed provider state and re-renders remote threads.

Thread mutation:

1. User chooses Reply, Resolve, or Unresolve on a provider feedback card.
2. UI builds a `ProviderThreadMutation` with provider thread/comment ids.
3. Provider writes through `gh` or `glab`.
4. Provider refreshes the request state.
5. UI replaces the stale request state with the refreshed state.

## Error Handling

Provider mutation failures should be specific and recoverable:

- Missing CLI: show install/auth guidance and leave local drafts unchanged.
- Unauthenticated CLI: show provider auth guidance and leave local drafts
  unchanged.
- Unpublishable anchor: leave that draft active and attach the provider error.
- Partial batch failure: mark successful drafts as published; keep failed drafts
  active with errors.
- Refresh failure after successful write: preserve successful provider mappings
  and show that refresh failed, so the user can manually refresh.
- Unsupported provider capability: hide the action or show a disabled reason in
  the confirmation.

No provider write should be retried automatically without another explicit user
action.

## Scope

V1 includes:

- GitHub and GitLab publish local draft comments.
- GitHub review decisions: comment, approve, request changes.
- GitLab publish discussions and call the MR approval endpoint for approve.
- GitLab request-changes normalization as discussions plus status note.
- Reply to provider feedback threads.
- Resolve/unresolve provider threads when the loaded thread has the required
  provider thread/discussion id.
- Refresh provider state after writes.
- Persist published metadata and failed provider errors on local drafts.
- UI confirmation before every provider write.

Out of scope:

- Provider suggestion blocks and apply-suggestion flows.
- Editing or deleting remote comments after publish.
- Importing pending GitHub reviews created outside Alas.
- Offline provider mutation queue.
- Arbitrary patch-file provider publishing.
- Automatic fallback from line comment to file-level comment.

## Testing

Provider tests:

- GitHub command/payload tests for publish, reply, resolve, unresolve, and
  review decisions.
- GitLab command/payload tests for discussion creation, reply, resolve,
  unresolve, approve, and request-changes note.
- Anchor mapping tests for old, new, unknown, and range anchors.
- Partial failure tests: successful drafts get provider metadata; failed drafts
  remain active with errors.
- Refresh-after-write tests for both providers.

UI tests:

- Publish actions show only when provider context and capabilities allow them.
- Confirmation lists provider, PR/MR number, decision, comment count, and
  unpublishable comments.
- Provider feedback cards expose Reply/Resolve/Unresolve according to
  capabilities and current thread state.
- No-write safety: editing or saving local drafts does not call provider APIs.

Persistence tests:

- Published metadata survives store round trip.
- Provider error state survives store round trip.
- Already-published drafts do not appear in the default active publish set.

## Implementation Notes

Keep the review surface provider-neutral. GitHub/GitLab details should stay in
provider implementations and shared provider-write models. The review surface
should render capabilities and actions, then delegate mutations to a controller
owned by the review session/provider tab.

The first implementation plan should split the work into:

1. Provider write models and draft metadata.
2. GitHub provider mutations and tests.
3. GitLab provider mutations and tests.
4. Review-session controller and persistence wiring.
5. UI confirmation/actions.
6. Refresh/error handling.
7. Final verification and PR loop.
