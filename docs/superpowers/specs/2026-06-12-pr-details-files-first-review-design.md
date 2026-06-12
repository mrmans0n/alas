# PR Details Files-First Review Design

## Goal

Make PR/MR details a files-first review experience. The tab should open on the changed files with the same left rail and stacked diff stream used by Review Changes and commit details, while preserving the current CI and feedback evidence workflow as secondary sections.

The target feel is the diffs.com/GitHub/GitLab review flow: changed files are the primary surface, the rail tracks scroll position, and evidence is available without displacing the diff stack.

## Scope

V1 applies to the existing `ReviewEvidenceTabView` opened from the review-loop drawer.

In scope:

- Make **Files** the default section for PR/MR detail tabs.
- Reuse `DiffReviewSurface` for the file rail, split/stacked controls, wrapping, whitespace, scroll-spy selection, and file stack.
- Keep **CI** and **Feedback** as secondary sections in the same tab.
- Preserve existing failed-check and feedback detail behavior, including rerun failed checks, copy context, open in browser, and send to agent.
- Load provider diffs through the code-host CLI:
  - GitHub: `gh pr diff <number> -R <owner/repo>`
  - GitLab: `glab mr diff <number> -R <namespace/project>`
- Parse provider unified diff output with the existing `DiffParser`.
- Convert parsed provider diffs into a `DiffReviewLoadedSession`.
- Keep unsupported files visible as placeholder cards.
- Preserve provider-aware header identity, status chips, refresh, and open-in-provider action.

Out of scope for V1:

- Inline rendering of existing review threads on diff lines.
- Posting new review comments from the diff.
- Resolving remote review threads.
- Local-ref fallback when provider CLI diff output fails.
- Image diff rendering inside PR/MR details. Images remain placeholder cards.
- Progressive streaming of very large provider diffs.

Fast follow:

- Attach existing review threads to stable diff anchors.
- Let selected lines/ranges be sent to an agent with file and provider context.
- Add local git-ref fallback for provider CLI diff failures or unavailable CLIs.
- Add inline review comment drafting and provider submission.
- Add progressive loading or virtualization if very large PR/MR diffs show performance issues.

## Architecture

Extend the code-host provider abstraction with a read-only diff-loading capability. The provider remains responsible for fetching provider-specific diff text, while shared loaders remain responsible for parsing and building the review session.

New or refactored pieces:

- `CodeHostProvider.reviewDiff(remote:request:cwd:) async throws -> String`
  - GitHub implementation calls `gh pr diff`.
  - GitLab implementation calls `glab mr diff`.
- `ReviewRequestDiffLoader`
  - Calls the provider diff method.
  - Parses the unified diff.
  - Builds `DiffDisplayModel` values off-main.
  - Produces `DiffReviewLoadedSession`.
- `ReviewEvidenceModel`
  - Continues to load CI and feedback evidence.
  - Gains file-review loading state, selected file state, and a selected section that includes `.files`.
- `ReviewEvidenceTabView`
  - Keeps the current header.
  - Replaces the top-level two-section segmented control with a files-first section control.
  - Renders `DiffReviewSurface` for `.files`.
  - Renders the existing evidence list/detail browser for `.ci` and `.feedback`.

The shared `DiffReviewSurface` should not learn about GitHub or GitLab. It receives a generic `DiffReviewLoadedSession` just like Review Changes and commit details.

## Provider Diff Data Flow

Loading a PR/MR details tab follows this flow:

1. `ReviewEvidenceTabView` receives the active `ReviewLoopSnapshot`.
2. It validates that provider CLI support and authentication are available.
3. It creates `ReviewEvidenceModel` with the active `ReviewRequest` and provider.
4. The model loads CI evidence, feedback evidence, and file diffs as independent async work.
5. The file loader calls `provider.reviewDiff(remote:request:cwd:)`.
6. The provider returns provider-native unified diff text.
7. `DiffParser` parses the unified diff into file-level `ParsedDiff` values.
8. The loader converts each parsed file into a `DiffReviewFileSectionModel`.
9. `DiffReviewSurface` renders the loaded file session.

The loader should use the parsed diff header to derive path, original path, and status. Counts should be derived from parsed hunk lines so they match what the pane renders.

The loaded session uses a provider-specific namespace, such as `github-pr` or `gitlab-mr`, and disables source grouping. File order should match provider diff order.

## UI Behavior

The tab header remains provider-aware:

- provider name and request number
- repository slug
- request title
- checks, review, and merge chips
- refresh action
- open in provider action

Below the header, the section control should include:

- `Files`
- `CI`
- `Feedback`

`Files` is selected by default for new tabs. Restored tabs should keep their last selected section when possible.

The Files section:

- Shows `DiffReviewSurface`.
- Uses a collapsible left file rail.
- Shows all changed files in a continuous diff stack.
- Synchronizes rail selection with scroll position.
- Scrolls to a file when clicked in the rail.
- Reuses global diff display preferences for split/stacked layout, wrapping, and whitespace.
- Shows source badges only when they help disambiguate provider/source context. For V1, provider PR/MR files should not show staged/unstaged badges.
- Does not show `Open File` by default unless the file exists locally and the app can safely open it from the current worktree.

The CI and Feedback sections keep the current evidence browser shape:

- left list of evidence items
- right detail pane
- existing detail actions
- current empty states

If file diff loading fails but evidence loading succeeds, the Files section should show a clear error state while CI and Feedback remain usable.

## Review Thread Handling

V1 does not render review threads inline on diff lines.

Existing actionable feedback stays in the Feedback section. The data model should preserve thread file path and line metadata when providers expose it, but line placement is intentionally deferred. This avoids inaccurate pins for outdated threads, renamed files, or provider-specific diff positions while still leaving a path for inline comments later.

## Testing

Provider tests should cover:

- GitHub calls `gh pr diff <number> -R <owner/repo>`.
- GitLab calls `glab mr diff <number> -R <namespace/project>`.
- Non-zero CLI exits surface `CodeHostProviderError.commandFailed`.

Loader tests should cover:

- A provider unified diff becomes a `DiffReviewLoadedSession`.
- File order follows provider diff order.
- Added, modified, deleted, and renamed files produce correct summaries.
- Add/delete counts are derived from parsed hunk lines.
- Unsupported image files remain visible as placeholders.
- Display models are built outside SwiftUI body evaluation.
- Cancellation prevents stale file sessions from being published.

Model tests should cover:

- New models default to `.files`.
- Restored section selection is preserved when valid.
- CI and feedback evidence still load and select as before.
- File diff load errors do not erase loaded CI or feedback evidence.
- Revision keys include enough request and head metadata to reload when provider diff content can change.

View tests should cover:

- The header remains present.
- Files section hosts `DiffReviewSurface`.
- CI and Feedback sections still host the evidence list/detail browser.
- Existing evidence actions remain visible in detail panes.
- Rail display controls are available in the Files section.

## Migration Plan

1. Add provider diff capability to GitHub and GitLab providers.
2. Add `ReviewRequestDiffLoader`.
3. Extend `ReviewEvidenceSection` with `.files` and update tab state persistence.
4. Extend `ReviewEvidenceModel` to load file review sessions independently from CI/feedback evidence.
5. Update `ReviewEvidenceTabView` to make Files the default section and render `DiffReviewSurface`.
6. Preserve and retest CI/Feedback evidence behavior.
7. Run focused provider, loader, model, and view tests, then `xcodegen`, quiet build, and the full test suite.
