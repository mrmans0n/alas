# New Worktree Issue Autocomplete Design

## Summary

Add optional issue autocomplete to the **Attach issue** entry field opened from
the new worktree dialog. Typing `#` lists the newest open issues from the
selected project's preferred GitHub or GitLab remote. The user can filter the
list by issue number or title and select a result without losing the existing
ability to enter an issue number or arbitrary HTTP(S) URL.

The completion path is advisory. The existing issue resolver remains the
authority for resolving the selected `#<number>` and preparing the worktree's
issue context, branch name, and initial Chat prompt.

## Goals

- Offer autocomplete when the reference begins with `#`.
- Support GitHub and GitLab issues through the existing authenticated CLI
  providers.
- Use only the selected project's preferred supported remote so a short issue
  number remains unambiguous.
- Show open issues newest-first and limit the initial result set to 50.
- Filter the cached results by issue-number prefix and case-insensitive title
  text.
- Support keyboard and mouse selection without changing the dialog layout.
- Preserve manual issue numbers, arbitrary HTTP(S) URLs, and fallback ticket
  metadata behavior.

## Non-Goals

- Pull request or merge request autocomplete.
- The GitLab `!` reference syntax.
- Provider discovery beyond GitHub and GitLab.
- Pagination beyond the newest 50 open issues.
- Persistent or cross-dialog issue caching.
- Changes to the issue confirmation and editing screen.
- Changes to issue resolution semantics.

## Existing Flow

`NewWorktreeDialog` opens `AttachIssueDialog`, whose entry field accepts either
`#42` (or `42`) or an absolute HTTP(S) URL. `AttachIssueDialogModel` passes the
reference to `IssueResolver`. GitHub and GitLab resolution delegates to
`CodeHostIssueProviding` implementations backed by `gh` and `glab`; other URLs
fall through to the manual metadata provider.

The code-host providers currently fetch one issue by number but cannot list
issues. The editor's completion popup is tied to LSP candidates and editor
documentation, although its non-activating AppKit panel establishes the desired
interaction pattern.

## Architecture

### Suggestion Model

Introduce `CodeHostIssueSuggestion`, a small sendable value containing:

- provider kind
- issue number
- title
- canonical URL
- creation date

The creation date is retained so provider responses can be normalized to a
deterministic newest-first order even if a CLI or server returns an unexpected
ordering.

### Provider Listing

Extend `CodeHostIssueProviding` with an asynchronous operation that returns the
newest open issue suggestions for a remote and a caller-provided limit.

`GitHubCLIProvider` will request open repository issues through `gh api`, sorted
by creation time descending. GitHub's issues endpoint also returns pull
requests, so entries containing pull-request metadata must be discarded before
the limit is applied.

`GitLabCLIProvider` will request opened project issues through `glab api`, with
`created_at` descending and the same limit.

Both implementations decode only the fields required by
`CodeHostIssueSuggestion`. They validate positive issue numbers, non-empty
titles, valid canonical URLs, and creation timestamps. Malformed command output
uses the existing provider error conventions.

### Suggestion Loader

Add an `IssueSuggestionLoader` with injected project, remote, and provider
dependencies. For the selected project it:

1. Reads fetch remotes through `GitService`.
2. Uses `CodeHostRemoteDetector.detect` with the supported provider kinds. This
   preserves the existing remote priority, including `origin` preference.
3. Checks that the provider CLI is available and authenticated.
4. Requests up to 50 open issues from that one remote.

The loader does not fall through to a second remote after selecting the
preferred one. This prevents a chosen `#<number>` from resolving against a
different repository later.

### Autocomplete State

Add a main-actor observable model owned by the entry phase of
`AttachIssueDialog`. The model owns:

- the selected project identity
- cached suggestions for that project
- loading and non-blocking failure state
- the filtered rows and selected row index
- the active asynchronous task and request generation

The first reference beginning with `#` starts a load if there is no cache.
Repeated edits filter the cached values without additional provider requests.
Changing project cancels the active task, increments the generation, clears the
cache, and closes the popup. A late result is accepted only when its generation
and project still match.

## Filtering

The query is the text after the first `#`, with surrounding whitespace removed.

- An empty query shows all cached suggestions.
- A numeric query matches issue numbers whose decimal representation begins
  with the query. It also matches titles containing the query.
- A non-numeric query matches titles case-insensitively.
- Filtering never changes the cached newest-first relative order.
- Input that does not begin with `#`, including every URL, closes autocomplete
  and performs no load.

## User Interface

Use a focused AppKit-backed issue autocomplete field. It retains the existing
Alas field chrome and focus behavior while exposing the field view as an anchor
for a non-activating popup panel. The popup follows the LSP completion visual
language but uses issue-specific rows rather than LSP models.

Each suggestion row shows `#<number>` and the issue title. The panel width
matches the field, has a capped height, scrolls when necessary, and opens below
the field unless screen bounds require it to open above. Showing it must not
resize or reflow the sheet.

Interaction rules:

- Up and Down move the selected row and keep it visible.
- Return accepts the selected row while the popup has results.
- Return invokes the existing Resolve action when the popup is closed or has no
  selectable result.
- Escape closes the popup without clearing the field.
- Clicking a row accepts it.
- Accepting a row replaces the entire reference with `#<number>` and closes the
  popup.
- Losing focus, leaving the entry phase, or dismissing the sheet closes the
  popup and cancels view-owned work.

While a request is active, the popup contains a compact loading row. CLI,
authentication, network, provider, or decoding failures appear only as a
compact unavailable/error row in the popup. They do not set the dialog's
resolution error and do not disable the field or Resolve button. The existing
resolver remains available and will provide its normal actionable error if the
user submits the reference.

## Data Flow

1. The user opens **Attach issue** for a selected project.
2. The user types `#`.
3. The autocomplete model asks the loader for suggestions if its cache is
   empty.
4. The loader resolves the preferred supported remote and invokes its CLI
   provider.
5. The provider returns normalized open-issue suggestions newest-first.
6. The model caches the result and applies the current number/title filter.
7. The user selects a row, inserting `#<number>`.
8. The user resolves the issue through the existing `IssueResolver` flow.

## Testing

Use Swift Testing for focused behavior coverage.

Provider tests cover:

- GitHub and GitLab command construction.
- Successful decoding and canonical URLs.
- GitHub pull-request exclusion.
- Open-state request parameters.
- Limit enforcement and newest-first normalization.
- Malformed output and command failures.

Loader and model tests cover:

- Preferred-remote selection, including `origin` priority.
- Unsupported remotes, missing CLIs, and authentication failures.
- Trigger recognition and non-triggering URLs.
- One-load dialog caching.
- Project-change cancellation and stale-result rejection.
- Empty, numeric, and title filtering while preserving order.
- Selection movement, clamping, acceptance, and dismissal.

UI utility tests cover deterministic popup anchoring geometry where the existing
overlay test hooks allow it. Existing issue parsing, resolution, and new
worktree attachment suites provide regression coverage for short references and
arbitrary URLs.

## Verification

Run:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

