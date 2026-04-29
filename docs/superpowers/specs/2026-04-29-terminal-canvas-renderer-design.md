# Ghostty-First Terminal Canvas Renderer Design

## Context

Alas currently uses `libghostty-vt` for terminal state, but translates render output into a lossy `TerminalGridSnapshot` and paints the terminal with GPUI `div`/flex text runs. This improved basic shell responsiveness, but modern TUIs such as Claude Code still render incorrectly because terminal rendering is cell-grid based, not flex/text-flow based.

Observed problems:

- Text/background areas in the terminal use a hardcoded background (`0x111827`) that differs from the pane background (`0x1e1f22`).
- `ghostty_adapter.rs` trims trailing whitespace cells, destroying styled spaces and background-only cells that TUIs rely on.
- The visual renderer paints only emitted text runs, not the full terminal grid.
- The renderer has no first-class model for wide/spacer cells, cursor visual style, default Ghostty colors, or mouse/key protocol modes.
- Manual key mapping does not fully respect terminal modes such as application cursor keys, Kitty keyboard protocol, modifyOtherKeys, mouse tracking, or bracketed paste.

The goal is to make Ghostty a first-class terminal engine inside Alas: close to running Ghostty itself, while keeping Alas's GPUI-native workspace UI flexible.

## Decision

Implement a Ghostty-first terminal renderer using `libghostty-vt` as the terminal engine and GPUI lower-level painting APIs for the app-integrated renderer.

Chosen path:

1. Use everything exposed by `libghostty-vt` for terminal state, render cells, colors, cursor metadata, keyboard encoding, mouse encoding, and terminal mode awareness.
2. Replace the visual dependency on `TerminalGridSnapshot` with direct Ghostty render-state access for painting.
3. Paint via a custom GPUI terminal canvas/element so Alas retains native panes, tabs, inspector, overlays, and styling.
4. Include a bounded feasibility spike for embedding or reusing Ghostty's actual renderer/surface. The spike informs future direction but does not block the GPUI canvas renderer.

Non-goal for this pass: continue refining the `div`/flex terminal renderer as the long-term solution. It may remain temporarily during migration, but it is not the target architecture.

## Architecture

The terminal stack becomes:

```text
PTY reader/writer
   ↓
GhosttyTerminalBackend session state
   ├─ Ghostty Terminal
   ├─ Ghostty RenderState
   ├─ Ghostty key encoder
   ├─ Ghostty mouse encoder
   └─ render/input APIs exposed to UI
        ↓
GPUI TerminalCanvas element
   ├─ paints full terminal background
   ├─ paints per-cell/per-run backgrounds from Ghostty render cells
   ├─ paints glyphs at exact grid coordinates
   ├─ paints cursor from Ghostty cursor metadata
   └─ dispatches keyboard/mouse events back through Ghostty encoders
```

`TerminalGridSnapshot` stops being the visual source of truth. It may be removed or reduced to a non-visual compatibility layer during migration, but the terminal view should render from Ghostty-native render state.

Suggested module boundaries:

- `src/terminal/ghostty_adapter.rs` — PTY/session lifecycle, draining output, resize, process status.
- `src/terminal/ghostty_render.rs` — Ghostty render-state access, viewport application, row/cell iteration helpers, colors, cursor metadata.
- `src/terminal/ghostty_input.rs` — Ghostty-first key, paste, and mouse encoding.
- `src/ui/terminal_canvas.rs` — GPUI custom element/canvas that paints terminal frames and converts app input positions to cells.

The UI may intentionally depend on Ghostty render/input concepts through these narrow modules. Ghostty is first-class, but raw PTY/process details remain encapsulated in the backend.

## Components and Data Flow

### Backend/session state

Each terminal session keeps:

- PTY master/writer/child/reader thread.
- `libghostty_vt::Terminal`.
- `libghostty_vt::RenderState`.
- Row/cell iterators or render helpers.
- Current terminal size in cells and pixels.
- Scrollback viewport state.
- Key/mouse encoding state derived from Ghostty terminal modes.

The backend exposes render/input methods similar to:

```rust
fn with_render_state<R>(
    session: TerminalBackendSession,
    viewport: TerminalViewport,
    f: impl FnOnce(GhosttyRenderFrame<'_>) -> R,
) -> anyhow::Result<R>;

fn encode_key_event(...ghostty-aware key input...) -> Option<Vec<u8>>;
fn encode_mouse_event(...ghostty-aware mouse input...) -> Option<Vec<u8>>;
```

The exact Rust API can vary during implementation. The key requirement is that rendering code visits Ghostty render cells directly instead of using `TerminalGridSnapshot`.

### GPUI terminal canvas

`TerminalCanvas` becomes the main terminal body element. On each paint/frame:

1. Drain PTY output into Ghostty.
2. Update Ghostty `RenderState`.
3. Resolve viewport rows.
4. Paint one full terminal background rectangle.
5. For each row:
   - Paint background runs, including spaces and background-only cells.
   - Paint text glyphs at `col * cell_width`.
   - Skip wide spacer-tail cells for glyph painting.
   - Use two-cell width for wide glyph heads.
6. Paint cursor from Ghostty cursor visual style.

### App shell data flow

`AlasShell::render` should no longer call `terminal_snapshot()` for visual painting. It passes the active backend session handle and viewport/input callbacks to `TerminalCanvas` or to a small view adapter that owns render borrowing.

Runtime status (`running`, `exited`, `failed`) remains app metadata separate from visual cell content.

## Input Fidelity

Input should become Ghostty-first.

Current manual key mapping in `src/terminal/input.rs` is insufficient for full terminal behavior. It handles basics, but it does not track terminal modes such as application cursor keys, keypad mode, Kitty keyboard protocol, modifyOtherKeys, bracketed paste, or mouse tracking.

New behavior:

- Use `libghostty-vt` key encoding where possible.
- Before encoding a key, read relevant Ghostty terminal mode state from the session.
- Send encoded bytes to the PTY writer.
- Keep a narrow fallback only for GPUI events Ghostty's encoder cannot represent.

Mouse input:

- Convert GPUI mouse down/up/move/wheel positions into terminal cell coordinates using the same measured metrics as rendering.
- Route mouse events through Ghostty's mouse encoder.
- Emit mouse reports only when terminal mouse tracking modes are enabled.
- Otherwise keep mouse events at the app level for focus, scrollback, and future text selection.

Paste behavior:

- If bracketed paste is enabled, wrap pasted text in bracketed paste sequences.
- Otherwise write paste bytes directly.
- Normalize line endings according to terminal expectations.

This should make Claude Code, vim/nvim, less, htop/top, and future mouse-aware TUIs behave closer to Ghostty itself.

## Rendering Correctness

The renderer is explicitly grid-based, not flex/text-flow based.

Rules:

- Paint a full default terminal background over the entire terminal rect.
- Paint exactly `cols` cells per row, including trailing spaces and background-only cells.
- Stop trimming trailing whitespace/styled cells in the Ghostty adapter/render path.
- Use default foreground/background from Ghostty render-state colors, not hardcoded constants.
- Make pane and terminal background intentionally match or become configurable; avoid accidental mismatch.
- Position text by terminal cell coordinates:
  - `x = origin.x + col * cell_width`
  - `y = origin.y + row * cell_height`
- Merge adjacent same-background cells into background runs for efficiency.
- Merge adjacent same-style narrow glyph cells into text runs where safe, but keep origins grid-anchored.
- Wide characters:
  - Wide head paints over two cells.
  - Spacer tail is skipped for glyph painting but still participates in background painting.
- Cursor:
  - Use Ghostty cursor visibility, position, shape, and blink metadata if exposed.
  - Block cursor paints cell background/foreground inversion or explicit cursor color.
  - Bar/underline cursors paint as small rectangles.
- Decorations:
  - Underline and strikethrough from Ghostty style render at cell positions.
  - Bold and italic use matching font weight/style where possible.
- Clip all painting to terminal viewport bounds.
- Resize uses measured cell metrics to compute columns/rows and passes cell size/pixel size to Ghostty resize where supported.

Claude Code's background bars, padded boxes, prompts, and text fields depend on preserving and painting empty styled cells; this design makes those cells first-class.

## Font and Cell Metrics

Hardcoded terminal metrics should be replaced with measured metrics.

Behavior:

- Resolve configured terminal font.
- Shape/measure representative monospace glyphs such as `M` or `W`.
- Derive cell width from measured glyph advance.
- Derive cell height from font metrics plus a line-height policy.
- Cache metrics per font family/size/weight.
- Use the same metrics for:
  - rendering positions,
  - PTY/Ghostty resize,
  - mouse coordinate conversion,
  - scroll row conversion.
- Keep a fallback metric if measurement fails.

## Performance

Correctness comes first, but the canvas renderer should avoid known performance traps.

Requirements:

- Paint one background rect for the terminal default background.
- Merge adjacent same-background cells into background runs.
- Merge adjacent same-style narrow glyph cells into text runs where safe.
- Avoid one GPUI element per cell.
- Keep painting in a single custom element/canvas pass.
- Continue active terminal refresh at approximately 60fps.
- Leave room for later dirty-region or PTY-output-driven refresh if needed.

## Testing

Automated tests should cover the deterministic data/model pieces:

- Ghostty render rows preserve trailing styled/background cells.
- Wide/spacer cells are represented correctly.
- Background run construction spans full row width.
- Cursor shape/color mapping.
- Mouse coordinate-to-cell coordinate conversion.
- Key/mouse encoder behavior for common modes where practical.
- Resize calculations from measured/fallback metrics.

Manual testing should extend `docs/manual-test.md` with:

- Claude Code launch and prompt area.
- vim/nvim.
- less alternate screen.
- htop/top.
- 16/256/truecolor scripts.
- Wide characters, emoji, and box drawing.
- Mouse scrolling/clicking in supported TUIs.
- Resize correctness via `stty size`.

## Ghostty Renderer Feasibility Spike

Run a separate bounded research spike for using Ghostty's actual renderer/surface.

Spike questions:

- What Ghostty renderer components are accessible from Rust/Zig or reusable outside Ghostty's app?
- Does the renderer assume Ghostty-owned windows, surfaces, event loops, or GPU pipelines?
- Can a Ghostty-rendered surface live inside a GPUI element with correct clipping, focus, resize, and input routing?
- What would integration cost and maintenance risk look like?
- Are there specific Ghostty internals worth exposing upstream or wrapping in `libghostty-vt`?

Spike deliverable:

- Short written feasibility report with blockers, possible paths, estimated effort, and recommendation.
- Do not block the GPUI canvas renderer unless the spike reveals an unexpectedly easy path.

## Migration Notes

A likely migration order for implementation planning:

1. Add Ghostty render-frame APIs and stop lossy visual translation.
2. Add cell metadata required for painting: default colors, wide/spacer status, cursor visual style.
3. Build `TerminalCanvas` with full background and per-cell background painting.
4. Add glyph painting at grid coordinates.
5. Add measured terminal metrics and resize/mouse coordinate updates.
6. Replace visual usage of `TerminalGridSnapshot` in the UI.
7. Replace manual key/mouse/paste paths with Ghostty-first encoding.
8. Expand manual and automated coverage.
9. Run the Ghostty renderer feasibility spike independently.

## Open Implementation Questions

These are intentionally left to implementation planning:

- Exact Rust API shape for borrowing Ghostty render state safely during GPUI paint.
- Whether `TerminalGridSnapshot` is deleted immediately or retained briefly for status/plain-text tests.
- Exact GPUI text painting APIs and their stability boundaries.
- How to expose user-configurable terminal font/theme settings.
- How much selection/copy behavior is included in the first canvas pass versus follow-up work.
