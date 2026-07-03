# ACP Transcript Event Enrichment Design

## Context

Issue #615 asks Alas to surface richer events emitted by the active
`@agentclientprotocol/codex-acp` adapter. The Codex adapter now maps goals,
reasoning, review events, web search, image generation and image view events,
terminal output metadata, richer permission approvals, additional directories,
and API-key authentication into ACP.

Alas already handles many generic ACP concepts: text chunks, thoughts, plans,
tool calls, tool-call content blocks, permissions, usage, and terminal-backed
tool output. The main gaps are not Codex-specific UI branches; they are fields
and update shapes that Alas currently drops before the transcript renderer can
use them.

## Goals

- Preserve richer ACP update data in the protocol and transcript models.
- Improve transcript rendering for terminal output, web search, images, MCP
  calls, and review/thinking events through bridge-neutral presentation logic.
- Surface current goal metadata separately from ordinary transcript rows.
- Keep existing file and terminal safety boundaries intact.
- Avoid Codex-only branches unless a field has no generic ACP representation.

## Non-Goals

- Do not expand filesystem read/write containment for additional workspace
  directories in this pass.
- Do not build a new review workflow UI. Review-related events only receive
  clearer transcript rendering.
- Do not require provider-specific code paths for Codex when the same data can
  be represented by ACP fields.
- Do not rewrite the transcript architecture or persistence store beyond the
  fields needed for enriched events.

## Architecture

Add a small ACP enrichment layer between protocol decoding and SwiftUI
rendering. The layer has three responsibilities:

1. Decode and preserve richer protocol fields.
2. Apply those fields to session and transcript state.
3. Classify tool calls for rendering from generic ACP data.

This keeps the protocol parser generic, keeps `ACPSession.apply(_:)` as the
state transition point, and keeps UI-specific labeling in a presentation
resolver instead of scattering string checks through `ACPToolCallCard`.

## Protocol And Session Model

Extend `ACPSessionUpdate` to decode `session_info_update` instead of mapping it
to `.unknown`. The update should carry optional title and metadata. Metadata can
remain an `AnyCodable`-backed value at the protocol edge, with typed extraction
only for fields Alas understands.

Extend `ACPToolCallPayload` and `ACPToolCallUpdate` to decode `_meta`. Extend
`ACPToolCallUpdate` to decode optional `title`, `locations`, `rawInput`, and
`rawOutput`, because upstream adapters can send those on updates, not just on
the initial tool call.

Extend `ACPMessage.ToolCall` with:

- `rawOutput: String?`
- `metadata: AnyCodable?` or a stable string/structured wrapper suitable for
  persistence
- preserved image/resource content summaries where needed for rendering

`ACPSession.apply(_:)` should mutate existing tool-call rows with all updated
fields. Existing behavior for status and content replacement stays intact.

## Goal State

Add a typed `ACPGoalState` on `ACPSession`:

- `objective: String`
- `status: String`
- `tokenBudget: Int?`

When `session_info_update` metadata contains a goal object, update
`session.currentGoal`. When it contains a null goal, clear the goal. The Codex
adapter currently sends this under `_meta.codex.goal`, but the extraction
should be isolated so future bridge metadata can map into the same session
state.

Render the current goal outside normal transcript rows, most likely in the ACP
toolbar/header area near plan and context indicators. Show the objective and,
when present, status or token budget. Clearing the goal removes the indicator.
Historical goal audit rows are out of scope.

## Terminal Metadata

Support terminal metadata emitted through tool-call `_meta`:

- `terminal_info`
- `terminal_output`
- `terminal_output_delta`
- `terminal_exit`

Output metadata should feed a retained terminal-like buffer keyed by terminal
id. Reuse `ACPTerminalTailView` where practical so command rows render the same
whether output came from ACP `terminal/*` RPCs or from tool-call metadata.

The UI should show command lifecycle information cleanly: command/title, cwd
when available, running state, exit code or signal, and retained output. This
should reduce duplicate or blank command rows when an adapter uses metadata
instead of terminal RPCs.

## Tool-Call Presentation

Add an `ACPToolCallPresentation` resolver. It accepts an
`ACPMessage.ToolCall` and returns display attributes such as label, icon,
target chips, preview strategy, and expanded-body mode.

The resolver should classify bridge-neutral shapes:

- `kind == "search"` with titles such as `Web search`, `Open page`, or
  `Find in page` renders as web search/open/find.
- `kind == "other"` with title `Image generation` and image content or raw
  output renders as image generation.
- `kind == "read"` with image/resource link content renders as image view.
- `_meta.is_mcp_tool_call == true` or an `mcp.*` title renders as an MCP call.
- `kind == "think"` or title `Guardian Review` renders as review/thinking.
- Existing read/search/execute/edit behavior remains the fallback.

`ACPToolCallCard` should consume the resolver output rather than hard-coding
all labels and icons directly.

## Image Handling

Preserve `ACPContentBlock.image` details from tool-call output instead of
flattening them to `[image]` only. The renderer should show generated or viewed
images in expanded tool cards when inline image data or a usable URI is
available.

Fallback behavior:

- If only a resource link exists, show a file/resource chip.
- If image data is unavailable after restore, show a stable placeholder rather
  than an empty expanded card.
- Keep existing user-prompt image attachment behavior unchanged.

## Filesystem Boundaries

The Codex adapter advertises additional workspace directory support, but Alas
currently treats the session worktree as the containment boundary for file
reads, writes, and terminal context. This design does not change that boundary.

If additional workspace directories are needed later, they should get a separate
design covering trust, user visibility, read/write containment, and persistence.

## Data Flow

1. ACP client decodes `session/update`.
2. `ACPSessionUpdate` preserves enriched fields and metadata.
3. `ACPSession.apply(_:)` updates either session-level state, such as goal, or
   transcript rows, such as tool calls.
4. Persistence stores enriched tool-call rows with backwards-compatible
   decoding for older rows.
5. SwiftUI resolves each tool call through `ACPToolCallPresentation`.
6. Terminal metadata updates retained terminal buffers so existing terminal tail
   UI can render output and exit state.

## Error Handling

- Unknown metadata fields are preserved when possible and ignored by the UI.
- Malformed known metadata fields should not fail the whole session update.
- Missing image data or missing retained terminal buffers should render a clear
  fallback message, not an empty card.
- Session goal extraction should tolerate absent, null, or partial fields.
- Existing `.unknown` handling remains for unsupported session update kinds.

## Testing

Add Swift Testing coverage for:

- Decoding `session_info_update` with metadata and title.
- Decoding `_meta` on `tool_call` and `tool_call_update`.
- Applying tool-call updates that mutate title, locations, raw input, raw
  output, metadata, status, and content.
- Applying goal metadata updates and clears.
- Preserving image content from tool-call output.
- Feeding terminal output and exit metadata into retained terminal rendering
  state.
- Presentation classification for web search, image generation, image view,
  MCP calls, guardian review, and existing fallback kinds.

Final implementation verification should use the project-standard commands:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```
