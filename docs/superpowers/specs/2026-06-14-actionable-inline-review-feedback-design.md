# Actionable Inline Review Feedback Design

## Context

The PR/MR details surface now defaults to the Files view, renders provider
diffs through the shared `DiffReviewSurface`, shows CI activity, and displays
unresolved actionable feedback cards near matching diff hunks. Feedback is
visible in the diff stack, but it is still mostly passive:

- selecting an item in the Feedback list does not jump to the matching inline
  card in Files
- inline cards do not expose the useful evidence actions from the Feedback
  browser
- Files and Feedback do not share a focused-thread state
- comment posting, replying, and resolving are not implemented

This phase makes inline feedback actionable and navigable without adding
provider write APIs.

## Goals

- Selecting a Feedback item with a mapped inline anchor switches to Files and
  scrolls the diff stack to the matching inline feedback card.
- Selecting or focusing an inline feedback card updates shared focused-feedback
  state so the Feedback list can reflect the same item.
- Inline feedback cards expose read-only actions:
  - open the provider thread/comment URL
  - copy comment context
  - send the focused feedback context to the configured agent when available
- Unmapped feedback remains visible in the Feedback section and in the file-level
  fallback area when it is associated with a file but not a hunk.
- Existing CI activity, Feedback detail, and Files diff behavior remain intact.

## Non-Goals

- No posting replies from Alas.
- No resolving or unresolving provider threads.
- No inline editing of comments.
- No exact row-level comment insertion inside the AppKit text renderer.
- No log streaming or CI action changes.

## Interaction Design

The Files view remains the primary PR/MR detail surface. Inline feedback cards
continue to render near matching hunks. Each card gets compact action buttons
using the same visual language as the evidence browser:

- Open: opens the provider URL for the thread/comment.
- Copy: copies a compact Markdown context block containing provider, author,
  file path, line, status, URL, and comment body.
- Send: sends the same focused context to the currently configured agent when
  `canSendToAgent` is true.

When the user selects a Feedback item in the secondary Feedback section:

1. If the item maps to an inline feedback card, the tab switches to Files.
2. The file rail selects the containing file.
3. The diff stack scrolls to the inline feedback card.
4. The card is highlighted with a focused-row treatment.

When the user clicks or focuses an inline card in Files:

1. The shared focused feedback ID updates.
2. The Feedback list uses the same selected item when the user switches to the
   Feedback section.
3. The detail pane can still load the provider evidence detail through the
   existing model path.

## Architecture

Add a small shared focus/navigation model around the existing inline feedback
data:

- `DiffReviewInlineFeedbackFocus`
  - focused feedback ID
  - optional target file ID
  - monotonic scroll command for repeated navigation
- `DiffReviewInlineFeedbackContextBuilder`
  - builds the copy/send-to-agent Markdown context from a feedback card and its
    file summary
- `DiffReviewInlineFeedbackActions`
  - optional action closures passed into `DiffReviewSurface`

`ReviewEvidenceTabView` owns the PR/MR-specific focus state because it already
owns section selection, agent availability, and evidence detail selection.
`DiffReviewSurface` stays provider-agnostic and only receives:

- inline feedback by file ID
- focused feedback ID
- a callback when an inline card is selected
- action closures for open/copy/send

The shared diff surface should expose stable scroll targets for inline feedback
cards. The target ID should be derived from the feedback ID and file ID, not from
visible row indexes, so it remains stable across layout mode, wrapping, and
virtualization changes.

## Data Flow

Loading does not change:

1. Provider evidence loads checks and feedback.
2. Provider diff loading builds `DiffReviewLoadedSession`.
3. `ReviewEvidenceInlineFeedbackMapper` maps actionable unresolved threads into
   `DiffReviewInlineFeedback`.
4. `ReviewEvidenceTabView` passes the mapping into `DiffReviewSurface`.

New navigation flow:

1. User selects a Feedback item.
2. `ReviewEvidenceModel.select(itemID:section:)` keeps the existing evidence
   selection.
3. `ReviewEvidenceTabView` checks whether the selected item ID exists in the
   inline feedback mapping.
4. If it exists, the tab sets selected section to Files and emits a feedback
   scroll command.
5. `DiffReviewSurface` scrolls to the inline feedback target and focuses it.

New action flow:

1. Inline card action invokes provider-agnostic closure.
2. `ReviewEvidenceTabView` handles the closure using existing app services:
   `NSWorkspace` for opening provider URLs, `NSPasteboard` for copy, and the
   existing review handoff/send-to-agent path for agent context.
3. If an action is unavailable, the button is not rendered.

## Error Handling

- If a Feedback item no longer maps to an inline card, selecting it stays in the
  Feedback section and behaves as it does today.
- If the Files session is still loading, selecting mapped feedback records the
  focus target and applies the scroll command after files load.
- If the provider URL is missing, the Open button is hidden.
- If no agent is configured or available, the Send button is hidden.
- Copy action is always available for inline feedback because it requires no
  provider or agent state.

## Testing

Focused tests should cover:

- `ReviewEvidenceTabView` maps selected Feedback items to Files scroll commands
  when inline feedback exists.
- Selecting an unmapped Feedback item stays in Feedback.
- Inline feedback cards expose Open, Copy, and Send action affordances only when
  those actions are available.
- Repeated selection of the same Feedback item emits a fresh scroll command.
- Focused inline cards render a distinct selected treatment.
- Copy/send context includes provider, author, path, line, URL, and body.
- Existing CI activity and Feedback detail tests continue passing.

Final verification remains:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

