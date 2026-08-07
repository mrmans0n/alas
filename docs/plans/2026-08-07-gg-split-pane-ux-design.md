# GG Split Pane UX Design

## Goal

Make split-commit hunk assignment faster and clearer while giving each resulting commit enough preview space to inspect comfortably.

## Design

The split editor uses a resizable horizontal split. Its left rail groups hunks by file, starts groups expanded, and replaces ambiguous checkboxes with a single pill naming the hunk's current destination: **New Commit** or **Original Commit**. Pressing the pill moves the hunk without changing preview focus. Each selectable file also has a menu to assign all of its hunks to either destination. Non-text files remain labeled **Original only**.

The right side replaces the two equal-height previews and separate message grid with two compact commit cards above one full-height preview. Both cards keep their message and exact content counts visible. Selecting a card changes the preview. Clicking a hunk body selects its current destination and scrolls the preview to that file.

Incomplete assignments and messages remain valid editing states. Existing validation disables **Apply Split** and explains what is missing. Existing draft and GG plan fields retain their current wire names; only user-facing copy changes from First/Remainder to New/Original.

## Boundaries

- Reuse SwiftUI split controls and the existing AppKit diff-scroller request API.
- Keep expansion and selected-preview state local to the tab.
- Navigate to the affected file, not an exact diff line.
- Preserve equivalent file navigation in the legacy scroller fallback.
- Do not add drag-and-drop, global assignment controls, dependencies, persistence changes, or a generalized rail component.

## Verification

Cover individual and per-file assignment, counts, validation, stable preview row targets, navigation requests, destination/card accessibility, narrow and wide layouts, reload, and existing failure states. Finish with `xcodegen`, the macOS build, and the full test suite.
