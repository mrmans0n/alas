# Image diffs for pull requests whose commits a host lacks

Date: 2026-11-02
Status: design, not implemented

## Intent

A paired Mac reviewing a headless host's GitHub pull request or GitLab merge
request shows image diffs since #2313, but only when the host's repository
already has the review's commits. A fork PR (and any PR whose head was never
fetched on the host) fails both image sides. The Mac should see the same images
it sees for a local review, without letting a Mac string choose a repository,
commit or URL on the host.

## Current state (evidence)

### Host path (#2313, `host.worktrees.fileBytes.v3`)

- The Mac asks `readWorktree(.fileBytes(path:, revision: .providerReview(sessionID:after:head:)))`
  (`Alas/Sources/Center/ReviewWorkspace/ReviewSessionLoader.swift`, `peer(git:providerReview:)`).
- When the host serves the review's diff it stores the request it fetched:
  `core.providerReviewImages[session] = ProviderReviewImages(request:)`
  (`Packages/AlasCore/Sources/AlasHostCore/Core/Reviews/AlasHost+ProviderReviews.swift`).
- `providerReviewImageRevisions` checks the session belongs to the worktree,
  refuses a `head` other than the stored request's, and asks the host's own
  provider once per diff read (`reviewImageRevisions`: GitHub `compare`
  merge base + head; GitLab `diff_refs`).
- `remoteFileBytes` (`.../Remote/Gateway/AlasCoreContext+RemoteInspection.swift`)
  validates the path with `RemoteWorktreeFileAccess.normalizedRelativePath`
  (no leading `/`, `..` or `.git`), checks the SHA with `isCommitSHA`, resolves it
  with `git rev-parse --verify`, and answers `.notFound` when git has no such
  commit ("only ones it has: it fetches none for a Mac"). Size is checked with
  `cat-file --batch-check` before the blob is read, against
  `RemoteWorktreeFileAccess.maxPreviewBytes` (5 MB).
- On the Mac, `NativePeerProviderDiff.reviewFileData` turns any non-`.fileBytes`
  reply into a thrown error, so a fork PR shows both sides as failed images.

### Local path (the Mac's own provider review)

- `ReviewRequestDiffLoader.hostedImageProvider` reads every side through the
  provider API, never local git: before = `remote.repositorySlug` at
  `beforeSHA` (merge base), after = `request.headRepositorySlug ?? remote.repositorySlug`
  at `afterSHA`, cached per `(repository, revision, path)` in `ImageDiffDecoding`.
- GitHub `reviewFileData` (`GitHubCLIProvider.swift`):
  `gh api --hostname <host> --method GET -H "Accept: application/vnd.github.raw+json" repos/<repo>/contents/<%-encoded path>?ref=<sha>`
  through `runner.runData`. The raw media type returns the blob bytes directly;
  GitHub's contents API serves files up to 100 MB this way (1-100 MB only with
  the raw or object media types). It returns the stored blob, so an LFS-tracked
  image is its pointer, exactly as the host's `git cat-file` read is.
- GitLab `reviewFileData` (`GitLabCLIProvider.swift`):
  `glab api projects/<%-encoded project>/repository/files/<%-encoded path>?ref=<sha>`
  read as a `String`, JSON-decoded, base64-decoded. The response is about 4/3
  of the file plus JSON; the `/raw` variant of the same endpoint returns bytes.
- Neither path caps the size. `ProcessCodeHostCommandRunner.runData` calls
  `Process.runData`, which buffers all of stdout until exit. The only streaming
  cap in the tree is `Process.gitDataPrefix` (kills the child once `maxBytes`
  are buffered; git only) and `boundedFetch` for URLSession.
- Paths are percent-encoded with `urlPathAllowed` minus `/`, so `?`, `#`, `/`
  and `%` in a path can't change the URL's shape. `ref=` is not encoded; it is
  safe only because it is a provider-named SHA.

### Facts that matter for every option

- The PR head lives in the base repository too: GitHub keeps it at
  `refs/pull/N/head`, GitLab at `refs/merge-requests/N/head` in the target
  project. The merge base is an ancestor of the head. So the base repository
  alone can serve both sides, even when the fork was deleted
  (`headRepositorySlug` is then nil and the local loader already falls back to
  the base repository).
- The host's provider already proved it can authenticate for this review: it
  fetched the request, the diff, and the image revisions with the same CLI and
  token before any image read reaches it.
- `CodeHostRemote` (persisted in the review record on the host) carries `kind`,
  `host`, `owner`, `repository` and the host's git `remoteName`.

## Options

### A. Host falls back to its own provider API

When `rev-parse --verify` finds no commit, the host calls
`provider.reviewFileData` itself.

- Repository: host-derived only. Before side = `remote.repositorySlug`; after
  side = `request.headRepositorySlug ?? remote.repositorySlug`, from the request
  stored in `ProviderReviewImages` (mirrors the local loader). Neither comes
  from the Mac.
- Revision: the SHA `providerReviewImageRevisions` already returns, still gated
  by `isCommitSHA`.
- Path: the Mac's path after `normalizedRelativePath`, and additionally required
  to be a file (new path, or old path for the before side) in the diff the host
  served for this session. The host has that diff in `providerReview(withDiff:)`;
  store its paths in `ProviderReviewImages` next to the request. This replaces
  the `isPathIgnored` check, which has no meaning for a commit the host lacks,
  and keeps the provider call to files of this PR.
- Cap: add a byte limit to the runner, enforced while reading: the child is
  terminated once stdout exceeds `maxBytes` and the call throws a too-large
  error (same readability-handler loop as `gitDataPrefix`, but failing instead
  of returning a prefix). Thread it through `reviewFileData(…, maxBytes:)`.
  GitLab switches to `repository/files/<path>/raw?ref=<sha>` via `runData` so
  the cap counts file bytes, not base64 JSON. The Mac's local path can adopt the
  same cap for free.
- Auth scope: the same as loading the diff (GitHub `repo` or fine-grained
  Contents: read; GitLab `read_api`). No new credential on the host.
- Rate limits: two REST calls per image pair, against GitHub's 5,000/h
  authenticated budget (GitLab per-instance). The Mac already caches decoded
  sides per `host-before:<base>:<head>` / `host-after:<head>` key, so the host
  needs no cache. Revisions are already deduped per diff read.
- Cost: no repository mutation, no git transport credentials, works for
  deleted forks (via the base repo fallback), matches what the local Mac does.

### B. Host fetches the PR head into a private ref

On a local miss (or when the diff is served), run, as
`remoteBranchContainsCommit` already does for `refs/alas/publish-check/*`:

```
git fetch --no-tags --no-write-fetch-head --no-recurse-submodules --refmap= \
  -- <remote.remoteName> +refs/pull/<N>/head:refs/alas/review/<session>/head
```

(GitLab: `refs/merge-requests/<N>/head`.) `N` is the record's integer and the
remote name is the host's own, so no Mac string reaches git. Then the existing
local read works unchanged.

- Credentials: git transport, not `gh`. Under `Process.neverPromptsForGit` the
  host sets `GIT_TERMINAL_PROMPT=0`, `GCM_INTERACTIVE=never` and
  `ssh -o BatchMode=yes`, so a remote needing a passphrase or an unlocked
  keychain fails fast instead of hanging. That is a second, independent way to
  be unauthenticated even though `gh` works; it is common for a launchd host.
- Network and disk: the whole object closure of the PR head lands in the user's
  repository. `git fetch` has no byte cap; a PR that adds a 2 GB asset fetches
  2 GB to show a 40 KB icon. `--depth` would make the repository shallow and
  `--filter` turns the remote into a promisor; both change the user's repo.
- Clutter and cleanup: one ref per reviewed PR under `refs/alas/review/`,
  visible to `for-each-ref`, `git log --all` and some GUIs, kept alive until
  deleted. Cleanup needs a hook on review close and on host start for leftovers;
  objects then wait for `gc`.
- Security: objects only, no checkout, so no hooks or filters of the fork run
  (the user's own `reference-transaction` hook does run). Malformed-pack bugs in
  git are the residual risk; `transfer.fsckObjects` is off by default.
- Contradicts the explicit #2313 rule that the host "fetches none for a Mac".

### C. The Mac reads through its own provider

The Mac uses `remote` and `request` from `HostProviderReview` and its own `gh`
or `glab`.

- Trust: the repository slug, host name and SHAs would be host-sent strings
  reaching the Mac's `gh api` with the Mac user's token. A compromised host
  could aim that token at any repository the Mac user can read (the bytes stay
  on the Mac, so exposure is limited, but it is a new direction of trust).
- Works only when the Mac has the CLI, is logged in to that provider host, the
  account can see the repository, and the Mac can reach the provider host at
  all (a GitHub Enterprise or self-managed GitLab reachable only from the host's
  network fails).
- Splits identity: every other remote PR operation (diff, threads, publish) acts
  as the host's user.
- Small code change, but the least predictable for the user.

## Recommendation

**Option A**, as a fallback inside the existing `.providerReview` branch of
`remoteFileBytes`: local commit first (free, offline), provider API second.
Reject B (repository mutation, uncapped download, separate git credentials,
cleanup lifecycle) and C (Mac auth and reachability, reverse trust).

### Trust model

| Input | Who resolves it | Check |
| --- | --- | --- |
| Review / worktree | Host, from the Mac's `sessionID` | `isFor(worktreeID:)` + saved record (existing) |
| Provider, host name, base repository | Host's persisted `CodeHostRemote` | never from the Mac |
| Head repository | Host's stored `ReviewRequest` from its own provider | slug shape checked (`owner/name`; GitLab may nest groups); nil falls back to base |
| Before / after SHA | Host's provider (`reviewImageRevisions`) | `isCommitSHA`; Mac's `head` only compared |
| Path | Mac | `normalizedRelativePath`, no control characters, and present in the diff the host served for this session; then percent-encoded |
| Size | Host | streaming cap `maxPreviewBytes`; child killed past it |

### Failure behaviour

- Path not in the served diff: `.pathRejected` (as an unknown path is today).
- Provider 404 for that path and SHA: `.notFound` (the Mac shows "missing",
  which is right for an add/delete side).
- Over the cap: `.tooLarge` with `byteSize: nil` (the size is unknown once the
  read stops).
- Provider auth, CLI missing, network: `.gitFailed` with the provider's
  message, as `providerReview` already reports its failures.
- Revisions unavailable, stale head, diff not loaded: unchanged from #2313.

### Capability gating

None new. The request and reply shapes are unchanged, so a Mac gated on
`host.worktrees.fileBytes.v3` gets images from an upgraded host and the old
`.notFound` from an older one. Bump only if the Mac must show different copy
for "host can't fetch" (see open questions).

### Tests

Extend `aMacReadsStashCheckpointAndRangeSidesBytes` (or its PR section) in
`Packages/AlasCore/Tests/AlasCoreTests/HostProtocolServerTests.swift`; teach
`FakeReviewProvider` `reviewFileData` (records `repository`, `revision`, `path`,
`maxBytes`; returns canned bytes or throws). One test, assertions:

1. A side whose SHA the repo lacks is served from the provider with the
   host's repository (base for before, head repo for after, base when the head
   repo is nil), the provider's SHA and the diff's path.
2. A path the served diff doesn't list is refused without a provider call.
3. A local commit never reaches the provider.
4. A provider error maps to `.notFound` / `.gitFailed` as above.

Plus one runner test for the streaming cap (a child writing past `maxBytes` is
terminated and throws), next to the existing `gitDataPrefix` coverage. Drop any
GitLab parse test made redundant by the switch to `/raw`.

### Effort

About a day: runner cap (~40 lines), `reviewFileData` signature and two
providers (~30), host fallback and diff-path set (~40), fakes and tests.

## Goals

- Fork and unfetched PR image diffs render on a paired Mac as they do locally.
- No Mac-supplied repository, host, SHA or URL reaches git or a provider URL.
- Every byte read from the provider is capped while it streams.

## Non-goals

- LFS content (both paths show the pointer today; unchanged).
- Host-side byte cache; the Mac's image cache covers repeat views.
- Images outside a provider review (local changes, commits, stashes).

## Anti-goals

- Fetching a fork's objects into the user's repository (Option B).
- Using the Mac's provider identity for a host's review (Option C).
- Taking a repository or SHA from the Mac "because the host checks it later".

## Risks

- The GitHub contents API with a fork head SHA on the head repository needs the
  host user to see the fork; a private fork they can't see fails where the base
  repository would have worked. Mitigation in open question 1.
- `glab api` binary output: verify `/raw` bytes pass through unmodified before
  relying on it; keep the JSON form with a cap of `4/3 × maxPreviewBytes` if not.
- Killing `gh` mid-response leaves no state behind, but must not be reported as
  a CLI failure; the runner must distinguish its own termination.

## Open questions for the user

1. Use the base repository for both sides (works for deleted and invisible
   forks, one fewer host-derived string) instead of mirroring the local loader's
   head-repository choice? Default proposed: mirror local, fall back to base
   when the head repository is nil.
2. Should the Mac's local provider review adopt the same streaming cap now, or
   only the host path?
3. Is `maxPreviewBytes` (5 MB) the right cap for review images, or should
   provider reads get their own (e.g. 10 MB)?
4. Any appetite for Option B as an opt-in for hosts that already fetch PR refs
   (`remote.origin.fetch` with `+refs/pull/*/head:…`)? Default: no; the local
   read already wins whenever those refs exist.
