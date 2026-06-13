# PR Inline Feedback And CI Activity Design

## Goal

Make PR/MR details feel like a real review surface while preserving the files-first layout from the previous phase.

The Files section should show provider feedback where the reviewer is already looking: inside the diff stack, anchored to the relevant file and line when location data is available. The CI section should show useful activity while checks are pending or running, not only after a failure produces logs.

The target feel remains diffs.com, GitHub/GitLab review, and rudu-style review flows: changed files first, contextual feedback near code, and provider status visible without leaving the review tab.

## Scope

V1 applies to PR/MR review evidence tabs opened from the review-loop drawer.

In scope:

- Keep **Files** as the default PR/MR detail section.
- Render provider feedback as inline cards in the Files diff stack when a thread can be matched to a file.
- Anchor feedback cards to the closest supported position:
  - exact file and new-side line when available
  - exact file and old-side line when available
  - file-level card near the file header when the thread has a path but no usable line
  - Feedback section only when no file path is available
- Preserve the existing Feedback section as the complete list/detail browser.
- Preserve existing feedback actions: copy context, open in provider, and send to agent.
- Extend provider feedback models with optional location metadata.
- Show running, pending, passed, failed, skipped, and cancelled checks in the CI section.
- Keep failed-check log/detail actions for failed checks.
- Add CI activity rows for checks that do not have failure logs yet.
- Keep this pass display-only for comments: no posting, replying, resolving, or editing remote comments.

Out of scope:

- Creating new provider review comments from selected diff lines.
- Replying to or resolving provider review threads.
- Editing or deleting provider comments.
- Perfect placement for outdated comments whose provider position no longer maps cleanly to the current diff.
- Live log streaming for running checks.
- Provider-side review submission flows.
- Inline comments for local Review Changes or commit detail surfaces.

## Architecture

This phase adds review metadata beside the existing provider diff session instead of making `DiffReviewSurface` provider-aware.

New or refactored pieces:

- `ReviewThreadLocation`
  - provider file path
  - optional original path
  - optional line number
  - optional side, such as old/new/unknown
  - optional provider position metadata for future comment actions
- `ReviewThreadSummary.location`
  - optional structured location captured by GitHub/GitLab providers when available
- `DiffReviewInlineFeedback`
  - generic display model for inline cards inside a diff review file section
  - contains thread identity, title/body summary, provider URL, severity/actionability state, and source evidence item identity
- `ReviewEvidenceModel`
  - maps provider thread summaries into inline feedback grouped by file path
  - keeps the Feedback evidence list as the canonical complete list
- `DiffReviewSurface`
  - accepts optional per-file inline feedback
  - renders inline cards without knowing about GitHub or GitLab
- CI evidence model
  - includes status rows for every known check, not only failed checks with logs

The provider layer remains responsible for extracting provider-specific metadata. The shared diff review layer only sees generic file paths, sides, lines, and display text.

## Inline Feedback Data Flow

Loading a PR/MR details tab follows the existing files-first flow, with feedback enrichment:

1. `ReviewEvidenceModel` loads provider diff files, CI evidence, and feedback evidence independently.
2. Provider implementations populate `ReviewThreadSummary.location` when the provider exposes file/line data.
3. The model converts loaded thread summaries into `DiffReviewInlineFeedback` values.
4. Feedback is grouped by normalized provider file path.
5. `ReviewEvidenceTabView` passes grouped feedback into `DiffReviewSurface`.
6. The surface attaches cards to matching file sections:
   - line-anchored cards render before the nearest matching hunk row when the file display model contains that line
   - file-level cards render below the file header and above the first hunk
   - unmatched cards do not disappear; they remain visible in the Feedback section

Path matching should be deterministic and conservative. If both a current path and original path exist for a rename, the current path wins for new-side comments and original path is allowed for old-side comments. If side is unknown, current path wins.

## Inline Feedback UI

Inline cards should be compact and review-oriented:

- subtle bordered card using existing theme tokens
- provider/source label, such as `GitHub review`
- thread status/actionability indicator
- author and short body preview
- file/line label when known
- actions matching existing evidence detail actions where available:
  - open in provider
  - copy context
  - send to agent

Cards should not visually dominate the code. They are context markers, not a replacement for the Feedback section. Multiple cards at the same anchor should stack with tight spacing.

Line placement is best-effort in V1. If an exact line is outside the displayed hunks because context is collapsed, the card should attach to the closest visible row in that file rather than forcing the hunk open. Expanding collapsed context can improve placement in a later pass.

## CI Activity Data Flow

The CI section should render from the provider request’s check state immediately.

For every check in the current `ReviewRequest`:

- create a CI activity row with name, status, conclusion, provider URL, and timestamps when available
- mark running or pending rows with a non-blocking progress indicator
- keep passed/skipped/cancelled rows visible, but visually quieter than running and failed rows
- attach existing failed-log evidence detail when a failed check has fetched logs

Failed checks continue to support the existing rerun/copy/send-to-agent actions. Running and pending checks should offer open-in-provider and copy basic context, but not log-specific actions until logs exist.

If checks are still loading and no rows exist yet, the CI section should show a compact loading state rather than the current empty state.

## Error Handling

Inline feedback failures must not hide file diffs. If provider feedback loading fails but file diff loading succeeds, Files still renders the diff stack and the Feedback section shows the existing error state.

CI activity rows should render from whatever check summary is already available. Failure to fetch detailed logs should affect only the failed-check detail pane, not the CI activity list.

If provider location metadata is missing or malformed, the thread remains available in the Feedback section and is omitted from inline placement.

## Testing

Provider/model tests should cover:

- GitHub thread summaries preserve file path, line, side, URL, and provider IDs when available.
- GitLab thread summaries preserve file path, line, side, URL, and provider IDs when available.
- Missing location metadata does not drop the feedback evidence item.
- Renamed-file thread locations match current and original paths deterministically.

Diff review tests should cover:

- `DiffReviewSurface` renders inline feedback cards for matching file sections.
- File-level feedback appears below the file header.
- Line-level feedback appears near the matching displayed row.
- Multiple feedback cards at one anchor remain stable and ordered.
- Unmatched feedback is not rendered inline.
- Existing rail click and scroll-spy behavior still works with inline cards present.

CI tests should cover:

- Pending and running checks create visible CI rows.
- Passing/skipped/cancelled checks create quieter visible rows.
- Failed checks still show existing failure details and actions.
- Empty CI state is only shown when there are genuinely no checks and no check loading state.
- A check-log loading failure does not remove basic check activity rows.

View tests should cover:

- Files section shows inline feedback when feedback and file diffs both load.
- Feedback section still shows the full evidence list.
- CI section shows activity while checks are running.
- Existing copy/open/send-to-agent actions remain available.

## Migration Plan

1. Extend provider feedback location models and tests.
2. Add generic inline feedback display models and mapping from feedback evidence.
3. Add inline feedback rendering to the shared diff review surface.
4. Add CI activity rows for all check statuses while preserving failed-check details.
5. Update PR/MR review evidence views to pass inline feedback and render CI activity.
6. Run focused provider, review evidence, diff review, and CI tests, then `xcodegen`, quiet build, and the full test suite.
