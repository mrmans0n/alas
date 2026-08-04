# Provider-Neutral Mission Sources

Date: 2026-08-04
Status: Approved design

## Context

Missions currently begin with a GitHub or GitLab issue. That first release uses
the code-host issue for two independent purposes: it supplies the work context,
and its repository identity lets Alas select a configured project. The rest of
the Mission workflow then creates a worktree, starts an ACP session, tracks one
or more repository legs, and observes an eventual PR or MR.

This coupling prevents a Jira ticket, Linear issue, design document, incident,
or other arbitrary work-item URL from starting a Mission even though none of
the worktree or ACP operations intrinsically require the source to live on the
Git host. It also makes a source ticket appear to own one repository when a
single work item may span several Mission legs.

This design separates the Mission's source context from its repository legs.
GitHub and GitLab retain their current rich behavior through source adapters.
Any other HTTP or HTTPS URL can create a manual source with user-entered title
and context. Dedicated Jira and Linear metadata integrations can be added later
without another Mission-domain migration.

## Goals

- Create a Mission from any valid HTTP or HTTPS work-item link.
- Preserve current GitHub and GitLab issue loading, refresh, repository
  matching, short-reference, and duplicate behavior.
- Require the user to enter a title and optionally context for a link without a
  supported source adapter; never scrape an arbitrary webpage.
- Require one primary repository at creation, with additional repositories
  continuing through the existing Add Repository Mission-leg flow.
- Keep source identity and repository-leg identity independent.
- Let users edit manually entered title and context after creation while
  keeping the source URL stable.
- Keep PR or MR discovery and readiness based on each leg's Git remote rather
  than on the source provider.
- Establish an adapter boundary for later Jira, Linear, and other work-item
  integrations.
- Migrate existing Mission records without losing source snapshots, duplicate
  identity, refresh state, activity, repository legs, or linked reviews.

## Non-goals

- Dedicated Jira or Linear API integration in this implementation.
- Fetching a page title, Open Graph metadata, or page content for an arbitrary
  URL.
- Creating a Mission without a source link.
- Selecting multiple repositories in the initial New Mission flow.
- Editing the source URL after Mission creation.
- Mutating a source work item, including its state, labels, assignees, or
  comments.
- Inferring a repository from arbitrary page content, URL query parameters, or
  ticket text.
- Changing PR or MR discovery, publication, merge, or Mission-readiness policy
  beyond removing its dependency on source-provider identity.

## Terminology

The user-facing term is **work item**. It covers provider issues, tickets,
incidents, documents, and manual links without implying a particular system.

The domain term is **Mission source**. UI actions use neutral labels such as
`Open source`, `Refresh source`, and `Edit source context`.

`Mission leg` retains its existing meaning: one repository-specific workstream
with a project, base, branch, worktree, ACP session, and optional linked PR or
MR.

## User Experience

### Entry

The New Mission sheet keeps one initial field, relabeled `Work item link`.

The field accepts:

- A GitHub or GitLab issue URL recognized by an installed source adapter.
- A short positive issue reference such as `#940`, resolved through the
  selected project's GitHub or GitLab remote as it is today.
- Any other valid absolute HTTP or HTTPS URL as a manual source.

Unsupported schemes, relative URLs, empty input, and malformed non-URL input
are rejected. A manual URL causes no network request.

### Adapter-backed resolution

GitHub and GitLab adapters parse the URL, fetch the source snapshot, and return
an optional repository locator. Alas matches that locator against configured
project remotes and preselects the current project when several configured
projects point to the same repository.

If metadata loading fails because the CLI is unavailable, authentication is
missing, access is denied, the item cannot be found, or output is malformed,
the sheet shows the specific error and offers `Continue Manually`. Continuing
retains the adapter-derived identity and repository locator but requires the
user to enter source content. This fallback means source-loading availability
does not unnecessarily block a Mission whose repository is already known.

### Manual resolution

When no adapter recognizes the URL, the confirmation form requires:

- Work-item title.
- Optional work-item context.
- One primary repository selected from projects configured in Alas.
- Base ref, Mission branch, ACP agent, and initial prompt through the existing
  controls.

The currently selected project is preselected when available. The user must
confirm a repository; Alas never guesses from the arbitrary URL. Additional
repositories are added later from the Mission tab through the existing Add
Repository flow.

### Branch and prompt defaults

Provider issues retain the existing number-and-title branch seed. A manual
source uses the configured branch prefix followed by a sanitized title slug,
for example `nacho/fix-login-timeout`. Existing occupied-branch handling adds
the established numeric suffix when needed.

The generated initial prompt uses a provider-neutral Work Item Context section
containing the source label, canonical URL, title, context, and available
optional metadata. It does not call a manual source an issue or invent an issue
number. Additional-leg prompts reuse the same shared source context.

### Duplicate handling

Source adapters produce a stable, opaque identity. GitHub and GitLab preserve
their current normalized host, repository, and issue-number identity, including
repository-rename migration. A manual source uses its normalized canonical URL.

When an active Mission already uses the same source identity, the sheet retains
the existing `Open Existing` and `Create Another` choice. Completed Missions do
not block reuse.

Manual URL normalization:

- Lowercases scheme and host.
- Removes the fragment.
- Removes a default port for the scheme.
- Preserves the path and query exactly.

Alas does not remove suspected tracking parameters because doing so could
change the identity semantics of an arbitrary ticketing system.

### Mission tab and sidebar

Mission presentation no longer assumes every source has a code-host provider,
repository slug, or integer number. It displays the source's provider label or
host, optional display reference, title, and canonical URL.

The Mission tab offers:

- `Open source` for every source.
- `Refresh source` when the source adapter supports refresh.
- `Edit source context` when the stored content is manual.

Editing a manual source can change its title and context but not its canonical
URL or stable identity. The Mission title follows the edited source title just
as it follows a refreshed provider title today.

An adapter-recognized source that was created through `Continue Manually`
remains editable and can also be refreshed later. Before the first successful
refresh replaces manually entered content, Alas presents the fetched snapshot
for confirmation. It never silently overwrites user-authored context.

## Domain Model

### Mission source identity

`MissionSourceIdentity` contains:

- A string-backed provider ID, initially `github`, `gitlab`, or `manual`.
- An opaque stable ID produced by that provider.

Mission code compares identities but does not parse provider stable IDs. This
keeps provider-specific canonicalization inside adapters and permits later
providers such as Jira or Linear without adding repository-shaped fields to
the Mission core.

### Mission source snapshot

`MissionSourceSnapshot` contains:

- Identity and canonical URL.
- Provider display label and optional display reference.
- Title and body/context.
- Optional normalized state, labels, assignees, and provider update timestamp.
- Capture timestamp and optional refresh error.
- Content origin: provider or manual.
- Explicit edit and refresh capabilities.

Optional metadata remains empty or unknown when unavailable. Consumers render
capabilities and optional values rather than switching directly on provider
kind.

### Repository locator

`MissionRepositoryLocator` is a separate, optional resolution result. It
contains the code-host kind, host, and repository slug needed to match a
configured Git remote. It is used during creation and provider refresh but is
not the Mission source identity and is not required for a manual source.

The selected `projectId` remains stored on each Mission leg. Linked review
identity remains a code-host concept on the leg. Consequently, a Jira or
manual source can own GitHub and GitLab legs without pretending the source
belongs to either code host.

## Source Adapter Boundary

A focused `MissionSourceProviding` interface owns:

1. Recognizing and parsing supported references.
2. Producing a canonical source identity and URL.
3. Resolving a complete provider snapshot.
4. Optionally returning a repository locator.
5. Refreshing an existing identity when supported.

The registry tries concrete adapters before the manual fallback. The manual
provider validates and canonicalizes an HTTP or HTTPS URL but performs no
network request and returns no repository locator.

The existing GitHub and GitLab issue implementations move behind this boundary
while continuing to use their structured CLI commands and host-aware
authentication. Code-host review providers remain separate because source
metadata and repository review operations have different capabilities and
lifecycle.

A future Jira or Linear adapter may recognize its URLs, return ticket metadata,
and expose refresh without returning a repository locator. The New Mission flow
will therefore still require explicit repository selection for those sources
unless a future, separately designed mapping feature is introduced.

## Data Flow

1. The user submits a work-item link or supported short reference.
2. The source registry selects a provider and canonicalizes the identity.
3. The provider attempts metadata resolution and optionally returns a
   repository locator.
4. Alas automatically matches a returned locator or requires explicit primary
   repository selection.
5. The user confirms source content, repository, base, branch, agent, and
   prompt.
6. Alas persists the Mission source and primary leg before creating external
   artifacts, preserving the existing restart-safe creation sequence.
7. Worktree and ACP setup proceed independently of source kind.
8. Source refresh updates only source metadata. Review observation uses each
   leg's Git remote and updates only leg review/readiness state.

## Persistence and Migration

The Mission database schema advances in one transaction:

1. Create the provider-neutral `mission_sources` table.
2. Convert every `mission_issue_sources` row to a source identity and snapshot
   without changing its Mission ID.
3. Rebuild the `missions` table without the obsolete `source_kind = 'issue'`
   constraint; every Mission still requires exactly one source row.
4. Preserve all Mission legs, events, checkpoints, linked reviews, and
   timestamps.
5. Replace the issue-specific identity index with a provider-ID/stable-ID
   index used by active-Mission duplicate lookup.
6. Remove the legacy issue-source table only after all migrated rows and
   relationships validate successfully.

Migration validation checks row counts, one source per Mission, decodable
provider metadata, and unchanged Mission-to-leg relationships before commit.
Any failure rolls the whole migration back.

Repository rename refresh remains adapter-owned. When GitHub or GitLab confirms
a canonical repository change, the store migrates the affected source identity
and explicitly duplicated active-Mission cohort using the existing collision
rules. Manual source identities never change because their URLs are immutable.

## Error and Recovery Behavior

- **Unrecognized valid URL:** create a manual draft without network access.
- **Recognized adapter cannot resolve metadata:** show the classified error and
  offer `Continue Manually` when the repository locator is usable.
- **No repository locator:** require explicit primary repository selection.
- **Manual title missing:** keep the confirmation form open with focused
  validation.
- **Refresh failure:** retain the last successful snapshot and mark it stale,
  matching current Mission behavior.
- **First refresh after manual fallback:** require confirmation before replacing
  manual content.
- **Manual edit failure:** retain the previous snapshot atomically.
- **Migration failure:** roll back to the previous schema and data.
- **Worktree or ACP failure:** use the existing checkpointed Mission recovery;
  source kind does not alter setup recovery.

## Testing

Focused coverage includes:

- GitHub and GitLab URL and short-reference behavior remains unchanged.
- Arbitrary HTTP and HTTPS URLs resolve without a network call.
- Manual URL normalization and duplicate detection.
- Rejection of unsupported schemes, relative URLs, and empty titles.
- Explicit repository selection and selected-project preselection.
- Manual branch generation and occupied-name suffixing.
- Provider-neutral primary and additional-leg prompts.
- Manual source editing, immutable URL/identity, and Mission-title updates.
- Adapter failure followed by manual continuation.
- Confirmed first refresh of manually entered adapter content.
- Source-independent PR/MR discovery and readiness for GitHub and GitLab legs.
- Lossless migration of existing source snapshots, duplicate cohorts,
  repository renames, events, checkpoints, legs, and linked reviews.
- Presentation without provider repository or numeric issue fields.

The normal focused Mission suites, SwiftFormat lint, project generation, build,
and full test command remain required before implementation completion.

## Delivery Boundary

This implementation delivers the provider-neutral source model, migrates
existing GitHub/GitLab Missions, and adds the manual arbitrary-link flow. Jira
and Linear links work immediately as manual sources with editable context and
explicit repository selection.

Dedicated Jira and Linear adapters are follow-up features. Adding either must
use this source-provider boundary and must not reintroduce a mandatory mapping
between one source ticket and one repository.
