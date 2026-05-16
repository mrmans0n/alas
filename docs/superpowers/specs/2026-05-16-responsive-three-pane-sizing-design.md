# Responsive Three-Pane Sizing Design

Date: 2026-05-16

## Goal

Make the main Alas window behave better at compact widths. The current layout keeps the left and right columns at their persisted absolute widths while the center pane absorbs nearly all window shrink. At smaller sizes this leaves an oversized pair of sidebars and an unusably narrow terminal/editor center.

The target behavior is a balanced three-pane resize: sidebars and center all participate while the window narrows, and the right pane temporarily disappears only when all three panes can no longer stay readable.

## Non-goals

- Replacing the three-pane architecture.
- Changing the user-facing manual width preferences.
- Persisting width changes caused only by window resizing.
- Redesigning the sidebar, right pane, tab bar, terminal, or editor contents.
- Adding a new settings UI for responsive breakpoints.

## Design Approach

Use render-time adaptive sizing in `ThreePaneLayout`.

`AppConfig.sidebarWidth`, `AppConfig.rightPaneWidth`, and `AppConfig.rightPaneVisible` remain the user's preferred expanded layout. `ThreePaneLayout` measures the available container width and derives effective widths for the current render. These effective widths can be narrower than the saved preferences, and the right pane can be temporarily hidden, but those adaptations do not mutate persisted config.

Manual divider drags continue to update the saved preferred widths through the existing bindings and `onWidthsChanged`.

## Layout Model

Add a small layout calculation unit, either as a nested helper in `ThreePaneLayout` or as a package-private type in the layout module. It should be independent of SwiftUI view rendering so it can be tested directly.

Inputs:

- available container width,
- preferred left sidebar width,
- preferred right pane width,
- saved right-pane visibility,
- divider width,
- minimum and maximum widths.

Outputs:

- effective left sidebar width,
- effective right pane width,
- whether the right pane is visible for this render,
- center pane's remaining width.

Preferred widths are clamped to their existing manual ranges before calculation.

## Responsive Behavior

When the right pane is manually hidden, the layout is two-pane:

```text
[ left sidebar ][ center ]
```

The left sidebar uses its preferred width when possible, then shrinks toward its minimum if the center pane would otherwise become too narrow.

When the right pane is manually visible, the layout is three-pane as long as this minimum set fits:

```text
left minimum + center minimum + right minimum + divider widths
```

If that set fits, use all three panes. Start from preferred sidebar widths and give the center the remaining width. If the center would be below its useful minimum, shrink the left and right columns proportionally from their preferred widths toward their minimums until the center reaches its minimum or both sidebars are at minimum.

If the three-pane minimum set does not fit, temporarily render as two-pane by hiding the right pane. This temporary collapse does not change `rightPaneVisible`.

When the window grows and the three-pane minimum set fits again, the right pane reappears automatically if `rightPaneVisible` is still true.

## Width Constants

Keep current manual ranges:

- left sidebar minimum: `200`
- left sidebar maximum: `420`
- right pane minimum: `240`
- right pane maximum: `560`

Add a center pane minimum of `400` for terminal/editor readability.

Use the existing drag handle width as the divider width. Today the horizontal `DragHandle` renders at `6` points.

## Drag Behavior

Manual drag must operate on persisted preferred widths, not temporary effective widths.

Dragging the left divider updates `sidebarWidth` and clamps it to `200...420`.

Dragging the right divider updates `rightPaneWidth` and clamps it to `240...560`.

If the right pane is temporarily collapsed because the window is too narrow, its divider is not visible and cannot be dragged. The saved `rightPaneWidth` remains intact and applies again when the pane reappears.

## State and Data Flow

No new persisted state is needed.

State flow:

1. `RootView` passes persisted width bindings and `rightPaneVisible` into `ThreePaneLayout`.
2. `ThreePaneLayout` measures available width with `GeometryReader`.
3. The layout helper computes effective widths and transient right-pane visibility.
4. SwiftUI renders sidebar, center, optional right divider, and optional right pane from those effective values.
5. User divider drags update persisted preferred widths through the existing bindings and save config through `onWidthsChanged`.

## Error Handling

The sizing helper must defensively handle very small, zero, or non-finite available widths by clamping outputs to non-negative values. SwiftUI must never receive negative frame widths.

If there is not enough room for the left sidebar minimum plus center minimum, the layout must still render both panes with the best non-negative widths available rather than hiding the left sidebar or crashing.

## Testing

Add focused Swift Testing coverage for the layout math.

Important cases:

- wide window uses preferred left and right widths,
- compact window shrinks left and right proportionally before collapsing right,
- right pane temporarily collapses when the three-pane minimum set cannot fit,
- temporary collapse does not require changing the saved visibility input,
- manually hidden right pane stays hidden even when there is enough room,
- two-pane mode shrinks the left sidebar only as needed to protect center width,
- very small widths produce non-negative effective widths.

The view implementation can stay thin enough that direct UI tests are not required for this pass.

## Verification

Run the standard project checks after implementation:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```
