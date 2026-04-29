# UI Framework Feasibility Decision

Date: 2026-04-29

## Decision

Proceed with GPUI for V1.

## Required Capabilities

- Custom terminal grid/cell rendering: PASS — `examples/terminal_probe.rs` uses GPUI `canvas(...)` and `window.paint_quad(fill(...))` to draw a fixed cell grid; local GPUI source exposes `Element::paint` and lower-level paint hooks.
- High-frequency repaint without excessive CPU: PASS — probe schedules a 16 ms `background_executor().timer(...)` tick and calls `cx.notify()` for repaint; `cargo check --example terminal_probe` confirms this path compiles. Manual CPU observation is still required when running the window interactively.
- Keyboard/text input fidelity: PASS — probe tracks focus and uses `.on_key_down(...)` to display `KeyDownEvent.keystroke.key`, `key_char`, modifiers, and held state; local GPUI source exposes `ElementInputHandler`/`window.handle_input(...)` for lower-level text input if the terminal needs IME-style handling later.
- Trackpad/mouse scroll events: PASS — local GPUI source exposes `ScrollWheelEvent` and high-level `.on_scroll_wheel(...)`; probe records scroll count, phase, cursor position, and pixel/line deltas.
- Drag selection coordinates and mouse capture: PASS — local GPUI source exposes `MouseDownEvent`, `MouseMoveEvent`, `MouseUpEvent`, and drag helpers; probe records mouse down/move coordinates plus `pressed_button`/`dragging()` so terminal selection can map pointer positions to cells.
- Clipboard copy path: PASS — local GPUI source and `examples/input.rs` expose `cx.write_to_clipboard(ClipboardItem::new_string(...))`; probe triggers that concrete path on the platform secondary modifier + `C`.
- Right-click or overflow menu support: PASS — local GPUI source exposes `MouseButton::Right` and `ClickEvent::is_right_click`; probe counts right-button `MouseDownEvent`s directly.
- Focus handling for terminal input: PASS — probe owns a `FocusHandle`, calls `.track_focus(&self.focus)`, and GPUI source confirms tracked focus registers tab stops and focuses on mouse down.

## Notes

Local capability inspection was run with:

```bash
rg -n "on_scroll|ScrollWheelEvent|MouseDownEvent|MouseMoveEvent|ElementInputHandler|handle_input|on_key_down|paint\(" ~/.cargo/registry/src/index.crates.io-*/gpui-0.2* -g '*.rs'
```

The search found GPUI 0.2.2 support for scroll wheel events, keyboard events, mouse down/move/up events, high-level interactive `div()` handlers, `ElementInputHandler`, `window.handle_input(...)`, and custom `Element::paint`/`canvas` paint paths.

Headless/CLI validation compiled the probe with `cargo check --example terminal_probe`; `cargo run --example terminal_probe` also launched and was stopped by the command timeout because manual interaction is not available in this context. Full manual validation remains to run the example in an interactive desktop session and confirm typing, scrolling, dragging, right-clicking, clipboard copy, and smooth tick advancement visually.
