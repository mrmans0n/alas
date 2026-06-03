# GitLab Review Request Provider Design

Date: 2026-06-03
Status: Approved for implementation planning

## Goal

Add GitLab support to the existing review readiness and draft review request
flow. GitLab should reach parity with the current GitHub integration: detect
the active review request, create a new review request from the draft tab,
display CI status, show actionable review feedback, support failed-check retry
when job details are available, and map mergeability into the shared readiness
model.

This design treats "full GitLab parity" as parity with the GitHub features
that Alas currently exposes. It does not add new merge, comment-posting, or
discussion-resolution actions.

## Context

The current integration layer is already provider-neutral:

- `CodeHostKind` includes `.gitlab`.
- `CodeHostRemoteDetector` recognizes `gitlab.com` and hosts whose first DNS
  label is `gitlab`.
- `ReviewRequest`, `ReviewCheck`, `ReviewThreadSummary`,
  `ReviewReadinessModel`, and the draft review request tab use provider-neutral
  concepts.
- `CodeHostProviderRegistry.live()` only registers `GitHubCLIProvider`.

The GitLab CLI installed locally is `glab 1.101.0`. Its local command surface
supports the required operations:

- `glab auth status --hostname <host>`
- `glab mr list --source-branch ... --target-branch ... --output json`
- `glab mr view <iid> --output json`
- `glab mr create --source-branch ... --target-branch ... --title ... --description ... --yes`
- `glab mr note list <iid> --state unresolved --output json`
- `glab ci get --merge-request <iid> --with-job-details --output json`
- `glab ci retry <job-id> --pipeline-id <pipeline-id>`

## User Experience

For GitLab remotes, the Changes tab drawer should use the same layout and
behavior as GitHub, with provider-native labels:

- `GitLab` for provider identity when no merge request exists.
- `GitLab !123` for an existing merge request.
- `Create MR`, `Open MR`, and `No MR` labels.
- Existing readiness chips for unpushed branches, remote-ahead branches, failed
  checks, pending checks, review feedback, review pending, and ready state.

The draft review request tab remains shared. When opened from a GitLab branch,
it should show `Draft MR`, call the selected AI tool with the same review
request prompt, default to a normal MR, and pass `isDraft` to the provider when
the checkbox is selected.

## Provider Architecture

Add `GitLabCLIProvider: CodeHostProvider` under
`Alas/Sources/Integrations/CodeHost/`.

Register it in `CodeHostProviderRegistry.live()`:

```swift
CodeHostProviderRegistry(providers: [
    .github: GitHubCLIProvider(),
    .gitlab: GitLabCLIProvider(),
])
```

Use the existing `CodeHostCommandRunning` abstraction for command execution so
provider tests can assert arguments and parse fixtures without invoking `glab`.

GitLab repository slugs can include subgroups. The existing `CodeHostRemote`
`repositorySlug` already preserves `group/subgroup/repo`, so provider commands
should pass `-R remote.repositorySlug`.

## Authentication And Availability

`isAvailable()` runs `glab --version` and returns true only for exit code 0.

`isAuthenticated(remote:cwd:)` runs:

```bash
glab auth status --hostname <remote.host>
```

GitLab Enterprise hosts should use the detected remote host, not assume
`gitlab.com`.

## Current Merge Request Detection

`currentReviewRequest(remote:branch:headOwner:baseBranch:cwd:)` should:

1. Normalize the base branch with the existing provider pattern: if the base is
   `remoteName/main`, pass `main`.
2. Query open MRs with:

   ```bash
   glab mr list \
     --source-branch <branch> \
     --target-branch <base> \
     --output json \
     --per-page 20 \
     -R <repositorySlug>
   ```

3. Select the first MR whose source branch matches the local branch. If the
   output includes source project information and `headOwner` is present, prefer
   the MR from that source namespace. If the fields are absent, use the first
   match.
4. Enrich the selected MR with `glab mr view <iid> --output json` when needed
   for merge state, draft state, source/target branches, web URL, or review
   approval fields not present in list output.
5. Load unresolved discussion summaries.
6. Load MR head pipeline checks.

The provider should tolerate missing optional fields by mapping them to shared
unknown values rather than failing the whole refresh.

## Merge Request Creation

`createReviewRequest(...)` should call:

```bash
glab mr create \
  --source-branch <branch> \
  --target-branch <base> \
  --title <title> \
  --description <body> \
  --yes \
  -R <repositorySlug>
```

Append `--draft` when `isDraft` is true.

Do not pass `--fill` because Alas is supplying the AI-assisted title and body.
Do not pass `--push`; the existing readiness validation already requires the
remote branch to be in sync before creation. Parse the created MR URL from
stdout. If stdout does not contain a valid HTTP(S) URL, throw
`CodeHostProviderError.malformedOutput`.

Fork support should be conservative. GitLab's `glab mr create --head` selects a
head project, but the first implementation should only use it if tests show a
stable mapping from `headOwner` to GitLab project path. Otherwise, creation from
same-project branches is supported and fork creation should fail clearly through
the provider command error.

## CI Checks

For an existing MR, load the head pipeline with:

```bash
glab ci get --merge-request <iid> --with-job-details --output json -R <repositorySlug>
```

Map the pipeline and its jobs into `ReviewCheck` values:

- `success` -> `.pass`
- `failed` -> `.fail`
- `running`, `pending`, `created`, `preparing`, `waiting_for_resource`,
  `manual`, `scheduled` -> `.pending`
- `canceled` -> `.cancel`
- `skipped` -> `.skipping`
- unknown values -> `.unknown`

Prefer job-level checks when job details are available because retry operates on
jobs. If no job details exist, expose one pipeline-level check so the drawer can
still show failed, pending, or passing status.

Stable check IDs should include provider, pipeline id, job id when present,
name, status, and detail URL.

## Retry Failed Checks

`rerunFailedChecks(remote:branch:headSHA:cwd:)` should find failed jobs for the
current branch or current MR. Because the provider protocol only receives
branch and head SHA, use:

```bash
glab ci list --ref <branch> --sha <headSHA> --status failed --output json -R <repositorySlug>
```

Then, for the newest failed pipeline, load failed jobs:

```bash
glab ci get --pipeline-id <pipeline-id> --status failed --with-job-details --output json -R <repositorySlug>
```

Retry each failed job with:

```bash
glab ci retry <job-id> --pipeline-id <pipeline-id> -R <repositorySlug>
```

If GitLab reports a failed pipeline but no failed job IDs, throw a provider
error instead of retrying an interactive command or guessing a job name.

## Review Feedback

Load unresolved MR discussions with:

```bash
glab mr note list <iid> --state unresolved --output json -R <repositorySlug>
```

Map each discussion that has at least one non-empty user-authored note to
`ReviewThreadSummary`:

- `id`: discussion id.
- `author`: first non-system note author username, when available.
- `body`: first non-system note body.
- `url`: note or discussion web URL, when available and valid.
- `isResolved`: false for this query.
- `isActionable`: true for unresolved diff or general discussions that are not
  system-only.

Skip system-only discussions because they should not trigger the review
feedback chip or agent handoff.

## Review Decision And Mergeability

GitLab approvals and mergeability differ from GitHub review decisions, so the
mapping should be conservative:

- Approved when approval fields indicate the MR has all required approvals.
- Review required when approvals are required and missing.
- Unknown when the response does not expose enough approval information.

Map GitLab merge status fields into shared merge states:

- mergeable / can be merged -> `.clean`
- conflicts / cannot be merged due to conflicts -> `.dirty`
- checks, approvals, discussions, draft, or policy blockers -> `.blocked`
- unchecked / checking / preparing -> `.unstable`
- missing or unrecognized values -> `.unknown`

The readiness drawer should continue to avoid a merge action. This preserves the
current GitHub boundary.

## Error Handling

Use existing provider errors:

- Missing CLI: `CodeHostProviderError.cliMissing("glab")`
- Missing auth: `CodeHostProviderError.unauthenticated(remote.host)`
- Failed command: include the `glab ...` command label and trimmed stderr.
- Malformed JSON or invalid URLs: `CodeHostProviderError.malformedOutput`.

Optional enrichment failures should not erase the discovered MR. If discussion
or pipeline loading fails after the MR is found, return the MR with empty
threads/checks for that enrichment path. Primary MR discovery failures should
still surface as provider errors.

## Testing

Add `GitLabCLIProviderTests` mirroring the GitHub provider tests:

- availability and auth command behavior.
- MR list/view parsing.
- create MR arguments for normal and draft MRs.
- create output URL parsing.
- base branch normalization.
- pipeline/job status mapping.
- pipeline-level fallback when job details are absent.
- failed job retry command sequence.
- unresolved discussion parsing and system-note filtering.
- command failure and malformed-output errors.

Update shared integration tests where useful:

- `CodeHostProviderRegistry.live()` includes GitLab.
- `ReviewReadinessModel` keeps MR labels/actions for GitLab.
- `ReviewLoopState` can refresh a GitLab remote using a fake provider.
- Draft review request validation/messages use provider-native labels where the
  current hard-coded `PR` wording would be wrong for GitLab.

Manual verification should cover:

- GitLab branch with no MR.
- GitLab branch with an existing MR.
- Draft tab creates normal MR by default.
- Draft checkbox creates draft MR.
- MR with passing pipeline.
- MR with pending pipeline.
- MR with failed jobs and retry available.
- MR with unresolved discussion feedback.
- Missing `glab`.
- Unauthenticated `glab`.

## Out Of Scope

- Adding a merge action.
- Posting MR comments or replies.
- Resolving or reopening MR discussions from Alas.
- Direct OAuth/token storage.
- GitLab issue integration.
- GitLab release integration.
- Rich pipeline logs inside the drawer.
- Browser-based interactive `glab mr create --web`.
