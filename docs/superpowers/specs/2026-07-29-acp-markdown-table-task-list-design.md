# ACP Markdown Table and Task-List Rendering

## Goal

Improve ACP transcript Markdown so tables use the full available message width and GitHub-style task-list items render as read-only checkboxes.

## Scope

The change applies only to `ACPMarkdownText`, the renderer used for ACP transcript content and the other existing surfaces that embed it. The general Markdown file preview remains unchanged.

Supported task markers are top-level `- [ ]`, `- [x]`, and `- [X]` items. Ordinary unordered lists and text that merely contains bracket characters retain their current rendering.

## Table Layout

Keep the existing table block parser, visual styling, and horizontal scrolling. The table renderer measures its available width and derives an outer column width:

`max(100, (availableWidth - dividerWidth * (columnCount - 1)) / columnCount)`

The 0.5-point dividers are subtracted before the remainder is shared across columns, so the outer cell widths and dividers exactly fill the available width. Every cell, including its existing horizontal padding, uses that minimum. The 100-point floor preserves the current effective 80-point text width plus padding. A table with a small number of columns therefore fills the transcript column, while a table with enough columns to exceed the available width retains horizontal scrolling. Cell text continues to wrap within its assigned column.

The width calculation will be isolated as a small testable helper. Empty or malformed tables continue to follow the parser's existing fallback behavior.

## Task Lists

Add a task-list block containing a sequence of items with:

- a Boolean checked state;
- the item's inline Markdown source.

The block parser recognizes contiguous supported task-item lines before paragraph collection. It stops when it reaches a blank line or a line that is not a supported task item. This keeps task items together without changing ordinary paragraph and list parsing.

Each task item renders as a row containing a native checkbox and `ACPMarkdownInlineTextView`. The checkbox reflects the parsed checked state and is disabled so transcript content cannot be edited. The label continues through the existing inline renderer, preserving links, emphasis, inline code, image handling, typography, selection, and caching behavior.

## Accessibility and Interaction

The checkbox exposes native checked or unchecked semantics and a disabled interaction state. The label remains selectable and retains its existing link behavior. Rendering introduces no state mutation or transcript update path.

## Testing

Focused Swift Testing coverage will verify:

- checked and unchecked task items parse into one task-list block;
- both lowercase and uppercase checked markers are accepted;
- ordinary bullets remain paragraphs;
- task labels retain their Markdown source for the inline renderer;
- table column widths fill the available width when possible;
- tables with many columns retain the current effective minimum and overflow horizontally;
- cached block parsing remains equal to direct parsing for task-list content.

The full project generation, build, and test commands required by `AGENTS.md` will run before completion.

## Non-Goals

This change does not add editable tasks, nested task lists, alternate bullet markers, task persistence, table sorting, resizable columns, or changes to the general Markdown preview.
