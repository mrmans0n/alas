# Right Sidebar Section Icons

Date: 2026-07-27
Status: Approved design

## Context

The Changes tab in the right sidebar uses a shared collapsible header for
Working Tree, Commits, active stacked diffs, and Stashes. Every header currently
starts with an expanded/collapsed chevron. When a stack is active, the Commits
header also changes to `Stack · <name>`.

The chevrons add repetitive disclosure chrome, while `Stack ·` repeats meaning
that a dedicated stack icon can communicate more economically. The headers
should use stable semantic icons to distinguish their content and give active
stacks a concise, persistent identity.

## Goals

- Replace the shared section-header chevron with an icon that identifies the
  section.
- Keep the semantic icon visually stable between expanded and collapsed states.
- Use the changes/diff icon for Working Tree, the existing commit glyph for
  Commits, the existing GG stack icon for an active stack, and an archive-box
  icon for Stashes.
- Show only the active stack's name as its section title.
- Keep the active stack name and stack icon visible even when the current
  comparison mode produces no visible commit rows.
- Preserve the existing header interaction, metadata, visual hierarchy, and
  loading transition.

## Non-goals

- Changing which sections are collapsible or adding a replacement visual
  expansion indicator.
- Changing counts, addition/deletion summaries, behind indicators, base-branch
  controls, branch actions, or stash behavior.
- Changing GG stack loading, persistence, mutations, or comparison modes.
- Changing section headers outside the Changes tab.
- Redesigning row icons or nested disclosure controls within a section.

## User Interface

The complete section identity mapping is:

| Context | Title | Icon |
|---|---|---|
| Working tree | `WORKING TREE` | Changes/diff (`plus.forwardslash.minus`) |
| Commits without an active stack | `COMMITS` | Existing commit glyph |
| Commits with an active stack | Uppercased stack name | Existing `GGStackIcon` |
| Stashes | `STASHES` | Archive box |

The icon occupies the chevron's existing leading slot and uses the current
muted header color. It does not change with expansion state. Whether section
content is visible communicates the expanded or collapsed state.

The entire header remains the click target for toggling the section. Existing
title typography, count pills, change statistics, trailing controls, padding,
background, and pinned-header behavior remain unchanged.

An active stack titled `nacho/feature` therefore appears as a stack icon
followed by `NACHO/FEATURE`, never `STACK · NACHO/FEATURE`. Long stack names
remain single-line and truncate before displacing count pills or trailing
controls.

## Component Design

Add a small semantic role to `SectionHeader`, with cases for Working Tree,
Commits, Stack, and Stashes. The role owns the icon mapping and presentation.
Callers pass a role rather than an arbitrary icon view, keeping the shared
vocabulary centralized and preventing title-based icon inference.

`expanded` remains an input because the header button still toggles the
section, but it no longer selects a leading glyph. Accessibility continues to
expose the header title and expanded/collapsed state.

Each fixed section supplies its matching role. `CommitsSectionView` derives its
role and title from the presence of an active `GGStack`:

- No active stack: `.commits` and `Commits`.
- Active stack: `.stack` and the raw stack name.

This identity is independent of whether the displayed commit collection is
empty. If GG stack data is absent or temporarily unavailable, the section
naturally falls back to the Commits identity.

The transitional right pane uses the same Working Tree and Commits icon
mappings in its skeleton headers. The real and transitional headers therefore
reserve the same leading space and do not shift horizontally as content loads.

## Edge Cases and Accessibility

- An empty non-stack commit section remains `COMMITS` with the commit icon.
- A fully synced or filtered-to-empty active stack retains its stack name and
  stack icon.
- Stack names use the existing header casing and truncation behavior.
- Removing the chevron does not remove the section button's accessible
  expanded/collapsed state.
- Nested rows, including stash entries, retain their own disclosure chevrons
  because those controls are outside the shared top-level header.

## Testing and Verification

Focused tests should verify:

- Every semantic section role maps to the intended icon primitive.
- Stack titles contain only the stack name and remain stable when the visible
  commit list is empty.
- Missing stack data produces the Commits title and commit icon.
- The full header row still invokes its toggle action.
- Header accessibility exposes the title and expansion state without a visual
  chevron.
- Transitional and real headers preserve compatible leading alignment.

Before completion:

1. Run SwiftFormat lint.
2. Regenerate the Xcode project with `xcodegen`.
3. Run focused right-pane and section-title tests.
4. Run the required macOS build and test commands.
