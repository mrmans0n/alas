# ACP Session → Markdown: Export & Per-Message Copy

**Date:** 2026-05-29
**Status:** Design approved, ready for implementation plan

## Problem

The ACP conversation is rendered as a list of typed SwiftUI views
(`ACPMessage` → per-row views in `ACPMessageList`). Each row is its own
non-selectable view, so a user cannot drag-select text across the
conversation to copy/paste it elsewhere. There is currently no way to
get conversation text out of the pane.

## Goal

Give the user two ways to extract conversation text as Markdown:

1. **Whole-session export** from the tab context menu — both *copy to
   clipboard* and *save to a `.md` file*.
2. **Per-message copy** — a hover-revealed copy button on user and agent
   messages that copies that one message's raw Markdown.

Non-goals (explicitly deferred — YAGNI):

- Including tool calls, file edits, thoughts, plans, or system notices in
  the output. Output is **conversation only** (user + agent).
- True arbitrary mouse text-selection inside the conversation.
- A "Copied ✓" confirmation toast (existing copy actions are silent).
- An include-tool-activity toggle (possible future enhancement, noted
  only).

## Scope of decisions (locked during brainstorming)

- Granularity: **both** whole-session export and per-message copy.
- Whole-session lives in the **tab context menu** (`TabBarView`, the
  `.acpSession` case, alongside "Rename…").
- Whole-session offers **both** `Copy session as Markdown` and
  `Save session as Markdown…`.
- Export content: **conversation only** — `.user` and `.agent` messages.
- Per-message copy button appears on **both user and agent** rows, shown
  **only on hover**, and copies the message's **raw Markdown source as
  plain text** with no role label or decoration.

## Architecture

One small pure serializer, two thin call sites.

### Core: `ACPTranscriptMarkdown` (pure, no UI, no I/O)

```swift
enum ACPTranscriptMarkdown {
    /// Whole conversation → Markdown document (user + agent only).
    static func document(title: String, agentName: String?, messages: [ACPMessage]) -> String

    /// One message's raw Markdown source, or nil for non-conversation kinds.
    static func messageBody(_ message: ACPMessage) -> String?
}
```

This is the single source of truth for formatting, so per-message copy
and whole-session export render identically. It is trivially
unit-testable with no views.

### Data source

For **conversation-only** output, the in-memory `transcript.messages`
array is fully faithful:

- Session eviction is whole-session (when no UI references it); while a
  session is open its `transcript.messages` holds the complete array.
- Only **tool-call** content is ever truncated off-window
  (`ToolCall.truncateForOffWindow`). `.user` text and `.agent`
  `StreamingText` buffers are never truncated.
- Since we export only `.user` and `.agent`, **no SQLite round-trip is
  needed.** Read straight from `transcript.messages`.

### Call sites

**1. Tab context menu (`TabBarView` `.acpSession` case)**

Add two buttons next to "Rename…":

```swift
Button("Copy Session as Markdown") { onCopyACPSession(tab.id) }
Button("Save Session as Markdown…") { onExportACPSession(tab.id) }
```

These add two new callbacks to `TabBarView`:
`onCopyACPSession: (TabID) -> Void` and
`onExportACPSession: (TabID) -> Void`, wired in `CenterPaneView` like the
existing `onRenameACPSession`. Both resolve the session via
`state.acpManager(forWorktreeId:)` → `sessions[s.sessionId]` and call into
`AppState` methods.

**2. `AppState` methods** (mirroring existing `newFile` /
`saveActiveTabAs` patterns)

- `copyACPSessionMarkdown(worktreeId:tabId:)` — resolve session, build
  the document via `ACPTranscriptMarkdown.document`, then
  `NSPasteboard.general.clearContents()` +
  `setString(_:forType: .string)` (same as `onCopyPath`).
- `exportACPSessionMarkdown(worktreeId:tabId:)` — resolve session, build
  the document, present `NSSavePanel` (default name = sanitized title +
  `.md`), and on `.OK` write the string. On failure call the existing
  `showFileActionError(title:message:)`.

**3. Per-message hover copy button (`ACPMessageList`)**

`UserMessageRow` and `AgentMessageRow` gain an `@State private var
hovering` and an `.onHover`. When hovering, overlay a small copy button
(SF Symbol `doc.on.doc`) that calls a closure copying
`ACPTranscriptMarkdown.messageBody(message)` to the pasteboard. The
button is positioned to not disturb layout (overlay, not inline) and is
hidden when not hovering. Thought / tool-call / file-edit / system-notice
rows get no button.

## Markdown format

### Whole-session document

```markdown
# <session title>

## You

<user message text, verbatim>

## <Agent display name>

<agent reply, verbatim>

## You

…
```

- Title: session title; falls back to `ACP session` when empty or
  "New session".
- Agent heading: agent display name (resolved from the session's agent /
  `agentLookup`), e.g. `## Claude Code`; falls back to `## Agent`.
- User heading: `## You`.
- Bodies inserted **verbatim** — raw Markdown source, no escaping, no
  quoting, no code-fencing — so headings/lists/code in a reply stay
  intact.
- Messages in transcript order, filtered to `.user` and `.agent`.
- Sections separated by a blank line.

**Accepted ambiguity:** if an agent reply contains a literal `## You`
line, the role-heading scheme is technically ambiguous on re-read. This
is acceptable (reads fine for humans and paste targets); we deliberately
do **not** add a fancier delimiter.

### Per-message copy

`messageBody` returns the raw text of that one message (user `text` or
agent `buffer.value`) with no heading or decoration. Returns `nil` for
all non-conversation kinds.

## Error handling & edge cases

- **Empty conversation:** `document` returns just the title line. Hover
  buttons only exist on user/agent rows, so there is nothing to copy when
  there are none. No error state.
- **Clipboard:** no failure path (matches `onCopyPath`).
- **Save panel cancel:** do nothing.
- **Save write failure:** `showFileActionError(title: "Export Failed",
  message: error.localizedDescription)`.
- **Filename sanitization:** strip/replace path separators, newlines, and
  other filesystem-hostile characters from the title; ensure `.md`
  extension. Empty/sanitized-to-empty → `acp-session.md`.
- **Session not resolvable from `TabID`** (evicted / edge timing): menu
  actions guard-return silently (same as `onCopyPath`).
- **No confirmation toast:** silent, matching existing copy-path actions.

## Testing

Unit tests on the pure core (`ACPTranscriptMarkdown`) — no UI:

- `document` filters out non-conversation messages (thought, toolCall,
  fileEdit, plan, systemNotice).
- Role headings and message ordering are correct.
- Agent name resolves; falls back to `## Agent` when absent.
- Empty transcript → just the title line.
- Title fallback (`""` / "New session" → `# ACP session`).
- `messageBody` returns raw text for `.user` / `.agent`, `nil` for other
  kinds.
- Verbatim passthrough: Markdown inside a reply is not mangled.

Filename sanitizer tests: title with `/`, newlines, emoji → safe `.md`
filename; empty title → `acp-session.md`.

UI wiring: extend existing smoke tests that construct `TabBarView`
(`TouchTargetSmokeTests`, `TabActivityIconTintTests`) with the two new
callbacks.

## Files touched (anticipated)

- **New:** `Alas/Sources/ACP/Session/ACPTranscriptMarkdown.swift`
- **New:** `AlasTests/ACPTranscriptMarkdownTests.swift`
- `Alas/Sources/Center/TabBarView.swift` — two menu buttons + two
  callbacks.
- `Alas/Sources/Center/CenterPaneView.swift` — wire callbacks to
  `AppState`.
- `Alas/Sources/App/AppState.swift` — `copyACPSessionMarkdown` /
  `exportACPSessionMarkdown`.
- `Alas/Sources/ACP/UI/ACPMessageList.swift` — hover copy button on
  user/agent rows.
- Test files constructing `TabBarView` — add the two new callbacks.
