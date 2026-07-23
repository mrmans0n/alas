# ACP Compact Task Control Design

## Summary

Replace the ACP chat's responsive right-side task sidebar with one compact task control in the existing top toolbar. The control remains inline with the session, MCP, recovery, and goal controls. Clicking it opens the existing full task checklist popover.

This change deliberately removes the second task presentation mode and the layout state needed to switch between modes.

## Goals

- Keep one predictable task affordance in the ACP toolbar at every pane width.
- Preserve the completed count and current step as at-a-glance information.
- Preserve access to the full checklist through the existing click popover.
- Match the compact geometry of neighboring toolbar controls such as MCP.
- Retain a visible active-work signal with a continuously traveling border highlight.
- Remove task-sidebar geometry, minimize, restore, and remembered-visibility behavior.

## Non-Goals

- Changing how ACP plan events are received, stored, or selected.
- Rendering plan events in the transcript.
- Redesigning the checklist popover contents.
- Adding a new user preference or persistence migration.
- Making the task control independently centered within the toolbar.

## Interaction

`ACPPlanPill` remains the canonical task presentation surface. It appears when `ACPTranscript.currentPlan` produces a non-empty `ACPPlanPillState`, remains inline in `ACPToolbar`, and disappears when the current plan disappears.

Clicking the control toggles a popover containing `ACPPlanChecklist` at its existing 320pt width. If the plan disappears while the popover is open, removing the control also dismisses the popover.

The right-side `ACPPlanSidebar` is removed. Users no longer minimize tasks to the toolbar or restore a task sidebar. Pane width does not change task presentation.

## Visual Treatment

The control uses the MCP control as its visual precedent:

- 24pt fixed height.
- 5pt continuous corner radius.
- Compact horizontal padding.
- Restrained accent-tinted background.
- Subtle base outline.
- No shadow, progress bar, chevron, wide capsule corners, or separate status dot.

The content is:

`Tasks 2/5 · Current step title`

The completed count uses monospaced numerals. The current step uses the regular toolbar font, stays on one line, and truncates at a bounded maximum width so it cannot crowd neighboring controls. The complete untruncated text remains available through the tooltip and accessibility label.

When `ACPPlanPillState.isAnimating` is true, a bright highlight head with a fading tail travels continuously around the control outline. The motion should read as one continuous circuit, similar to a light cycle trail, rather than a pulse or flashing border. When no item is in progress, the outline is static and subdued. Under Reduce Motion, the active state uses a static highlighted outline.

## State And Data Flow

`ACPPlanPillState` continues to derive:

- Completed item count.
- Total item count.
- Current step title.
- Whether an item is in progress.

No new model or persisted state is needed. Unknown plan statuses retain the existing fallback title behavior and do not animate.

Removing the sidebar also removes:

- `ACPSession.planSidebarMinimized`.
- `ACPSessionView`'s sidebar visibility and hydration-suppression state.
- `ACPSessionManager`'s remembered sidebar visibility.
- `ACPPlanSidebarVisibility`.
- The sidebar-width branch in `ACPChatLayout`.
- Sidebar-specific environment values, transitions, and minimize/restore callbacks.

The remembered visibility and minimized values are runtime-only, so this cleanup requires no database migration.

## Layout

`ACPTabView` returns to a single chat column beneath the toolbar. Chat content width remains derived from the measured chat-column width through `ACPChatLayout.contentMaxWidth(forChatColumnWidth:)`, but there is no longer a task-sidebar width to subtract.

Removing the responsive task mode also removes the full-pane geometry observation that existed solely to decide sidebar visibility. Geometry still used for transcript and composer sizing remains unchanged.

## Accessibility

The control exposes a descriptive label and tooltip using the full title:

`Tasks, 2 of 5 complete, <current step>`

The control remains keyboard-focusable as a standard SwiftUI button. The popover checklist retains its existing semantics. Reduce Motion replaces the traveling outline with a static active outline.

## Testing

- Preserve and extend `ACPPlanPillStateTests` for missing and empty plans, completion counts, active-step selection, completed plans, pending fallback, unknown statuses, and animation policy.
- Add focused coverage for any extracted presentation or accessibility-label derivation.
- Update `ACPChatLayoutTests` to describe a permanently full-width chat column.
- Remove `ACPPlanSidebarVisibilityTests` and `ACPSessionManagerPlanSidebarLayoutTests`.
- Remove obsolete sidebar assertions from any remaining ACP view or session tests.

Verification:

```bash
xcodegen
ALAS_FFF_TARGET_ARCH=arm64 xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/ACPPlanPillStateTests -only-testing:AlasTests/ACPChatLayoutTests
ALAS_FFF_TARGET_ARCH=arm64 xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

## Acceptance Criteria

- No right-side task surface appears at any ACP pane width.
- A non-empty current plan produces one compact top-toolbar control.
- The control shows `Tasks`, completed/total count, and the current step.
- The current step truncates without displacing or overlapping adjacent controls.
- Clicking the control opens the full checklist popover.
- The outline travels continuously only while a plan item is in progress.
- Reduce Motion produces a static active outline.
- Completed or otherwise inactive plans use a static subdued outline.
- Removing the sidebar does not change transcript wrapping beyond reclaiming the sidebar width.
