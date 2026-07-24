# Image Diff Click-Drag Pan Design

## Problem

The side-by-side image diff overlays an AppKit view that consumes every
scroll-wheel event. Unmodified wheel and trackpad scrolling therefore pans the
images instead of reaching the enclosing vertically scrolling diff review.

## Interaction

- Unmodified wheel and trackpad scrolling passes through the image viewer to
  the enclosing scroll view.
- Command-scroll remains an explicit zoom gesture and is consumed by the image
  viewer.
- Panning requires a primary-button click and drag anywhere on the side-by-side
  image canvas.
- Both panes keep using the same transform, so panning and zooming remain
  synchronized.
- Double-click and the existing reset control continue to restore the identity
  transform.

## Implementation

`ScrollEventCapturingView` will decide whether it handled a scroll event. It
will forward unhandled events through the AppKit responder chain so an enclosing
`ScrollView` can process them.

`ImageDiffSideBySideView` will attach a SwiftUI `DragGesture` to the comparison
canvas. A transient translation will update the displayed offset while the
pointer is held; ending the gesture will commit that translation to
`ImageDiffTransform`. The gesture will not alter scale or the existing zoom
path.

## Testing

Focused tests will cover:

- unmodified scroll events are not captured by the image viewer;
- Command-scroll events remain captured for zoom;
- drag translation is combined with the existing committed pan offset;
- committing a drag preserves the accumulated transform.

The standard project generation, build, and test commands will verify the
integrated change.
