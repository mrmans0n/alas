# Diff Comment Composer Focus

## Problem

Pressing a diff gutter comment button creates a draft comment composer but does
not reliably move keyboard focus into its text editor. The same failure can
occur when an existing empty composer is relocated by pressing another gutter
button.

The composer is shared by the unified diff review surfaces and the standalone
staged/unstaged diff tab. It wraps an `NSTextView` in `NSViewRepresentable`.
The current coordinator attempts to make the text view first responder
synchronously during representable creation and updates. Those attempts can run
before the text view has a window or can be superseded later in the same AppKit
event cycle.

## Behavior

- Creating a draft composer from any enabled diff gutter immediately focuses
  its text editor.
- Moving an existing empty composer to another gutter location immediately
  restores focus to its text editor.
- Saving and cancelling retain their existing behavior and shortcuts.
- Reply and existing-comment edit composers are outside this change.

## Design

Each diff surface will issue an explicit focus request whenever its pending
draft anchor changes to a non-nil value. The request is represented by a
monotonically changing generation rather than a persistent Boolean, so moving a
composer while it is already considered focused still creates a new event.

`ReviewDraftComposerTextEditor` will remain the shared focus owner. Its
coordinator will observe the request generation and schedule a guarded
first-responder attempt on the next main-loop turn. It will also retry after the
underlying text view moves into a window. A scheduled request will verify that
it is still current and that the text view remains attached before calling
`makeFirstResponder`.

The existing focus binding continues to report actual editing focus for UI and
accessibility state. It will not be used as the sole trigger for initial focus.

## Testing

An AppKit-hosted regression test will exercise the real shared representable in
an `NSWindow`:

1. Mount the editor with an initial focus request and verify its `NSTextView`
   becomes the window's first responder.
2. Move first-responder status elsewhere, issue a new request generation, and
   verify the editor regains focus.

Existing diff surface tests and the full project build/test commands will guard
rendering and integration behavior.
