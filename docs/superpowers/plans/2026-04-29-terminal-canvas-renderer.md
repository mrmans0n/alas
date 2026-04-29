# Ghostty-First Terminal Canvas Renderer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the lossy div/flex terminal renderer with a Ghostty-first, cell-accurate GPUI canvas renderer and route keyboard/mouse/paste through Ghostty-aware encoders.

**Architecture:** `libghostty-vt` becomes the first-class terminal engine for render cells, colors, cursor metadata, key encoding, mouse reporting, and terminal modes. The app paints terminal frames through a focused GPUI custom/canvas element while preserving Alas's native tabs, inspector, and pane UI. A separate bounded spike investigates whether Ghostty's actual renderer/surface can be embedded later.

**Tech Stack:** Rust 2024, GPUI 0.2, libghostty-vt 0.1, portable-pty, cargo test, macOS manual app testing.

---

## Scope Decisions

- **Selection/copy:** Defer full terminal text selection/copy to follow-up work. This plan should not block on selection. Existing app-level focus/click behavior must continue to work.
- **Renderer spike:** The actual Ghostty renderer/surface embedding investigation is documentation-only and bounded. It must not expand the main implementation path.
- **Compatibility:** It is acceptable to keep `TerminalGridSnapshot` temporarily for non-visual tests/status while migrating, but the terminal visual path must use Ghostty render data rather than `TerminalGridSnapshot`.
- **TDD:** Each implementation task starts with failing tests for pure logic or reachable integration behavior. GPUI paint internals that cannot be asserted directly should be isolated behind pure run-building functions that are tested.

## File Structure

Create or modify these files:

- Create: `src/terminal/ghostty_render.rs`
  - Ghostty-first render model used by the UI: `GhosttyRenderFrame`, `GhosttyRenderRow`, `GhosttyRenderCell`, `GhosttyCellWidth`, `GhosttyRenderCursor`, default colors.
  - Conversion helpers from `libghostty-vt` render iterators.
  - Pure helpers for background/text run construction.

- Create: `src/terminal/terminal_metrics.rs`
  - `TerminalMetrics { cell_width_px, cell_height_px, font_size_px }`.
  - Fallback metrics and pixel-to-cell coordinate conversion.
  - Fallback metrics for early tests plus required GPUI font measurement integration in Task 9; fallback is only for invalid/failed measurement.

- Create: `src/terminal/ghostty_input.rs`
  - GPUI-to-Ghostty key conversion and fallback path.
  - GPUI mouse-to-Ghostty event conversion helpers.
  - Bracketed paste helper.

- Create: `src/ui/terminal_canvas.rs`
  - GPUI custom/canvas element for terminal painting.
  - Paints background runs, glyph runs, and cursor from `GhosttyRenderFrame`.
  - Exposes `render_terminal_canvas(...)` for `terminal_pane.rs`.

- Modify: `src/terminal/ghostty_adapter.rs`
  - Add render-frame access APIs.
  - Stop trimming styled/trailing cells in the visual render path.
  - Add key/mouse/paste backend methods.
  - Keep lifecycle/status behavior intact.

- Modify: `src/terminal/mod.rs`
  - Export new render/input/metrics APIs.
  - Keep old exports as needed during migration.

- Modify: `src/ui/terminal_pane.rs`
  - Render `TerminalCanvas` instead of `render_terminal_grid` for active terminal content.
  - Keep failure/exited/retry UI around terminal body.

- Modify: `src/ui/shell.rs`
  - Pass active terminal session/backend hooks to the canvas.
  - Route key/mouse/paste events through Ghostty-first backend methods.
  - Keep status bar and workspace tab state working.

- Modify: `src/ui/terminal_view.rs`
  - Either delete old grid renderer after migration or leave as legacy/test-only until no longer referenced.

- Modify: `docs/manual-test.md`
  - Add Claude Code, vim/nvim, htop/top, mouse, wide-char, and resize checks.

- Create: `docs/research/ghostty-renderer-surface-spike.md`
  - Bounded feasibility report for embedding/reusing Ghostty's actual renderer/surface.

---

## Task 1: Add terminal metrics helpers

**Files:**
- Create: `src/terminal/terminal_metrics.rs`
- Modify: `src/terminal/mod.rs`

- [ ] **Step 1: Write failing tests for fallback metrics and coordinate conversion**

Add tests in `src/terminal/terminal_metrics.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fallback_metrics_compute_terminal_size_from_pixels() {
        let metrics = TerminalMetrics::fallback();
        assert_eq!(metrics.size_from_pixels(180.0, 76.0).cols, 20);
        assert_eq!(metrics.size_from_pixels(180.0, 76.0).rows, 4);
        assert_eq!(metrics.size_from_pixels(900.0, 380.0).cols, 100);
        assert_eq!(metrics.size_from_pixels(900.0, 380.0).rows, 20);
    }

    #[test]
    fn fallback_metrics_convert_pixels_to_cell_coordinates() {
        let metrics = TerminalMetrics::fallback();
        assert_eq!(metrics.cell_at(0.0, 0.0), Some((0, 0)));
        assert_eq!(metrics.cell_at(8.9, 18.9), Some((0, 0)));
        assert_eq!(metrics.cell_at(9.0, 19.0), Some((1, 1)));
        assert_eq!(metrics.cell_at(-1.0, 0.0), None);
    }
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
cargo test terminal_metrics --lib
```

Expected: FAIL because `terminal_metrics` module/types do not exist.

- [ ] **Step 3: Implement minimal metrics module**

Create `src/terminal/terminal_metrics.rs`:

```rust
use super::TerminalSize;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TerminalMetrics {
    pub cell_width_px: f32,
    pub cell_height_px: f32,
    pub font_size_px: f32,
}

impl TerminalMetrics {
    pub fn fallback() -> Self {
        Self {
            cell_width_px: 9.0,
            cell_height_px: 19.0,
            font_size_px: 14.0,
        }
    }

    pub fn size_from_pixels(self, width_px: f32, height_px: f32) -> TerminalSize {
        TerminalSize {
            cols: (width_px / self.cell_width_px).floor().max(20.0) as u16,
            rows: (height_px / self.cell_height_px).floor().max(4.0) as u16,
        }
    }

    pub fn cell_at(self, x_px: f32, y_px: f32) -> Option<(u16, u16)> {
        if x_px < 0.0 || y_px < 0.0 {
            return None;
        }
        Some(((x_px / self.cell_width_px).floor() as u16, (y_px / self.cell_height_px).floor() as u16))
    }
}
```

Modify `src/terminal/mod.rs`:

```rust
pub mod terminal_metrics;
pub use terminal_metrics::TerminalMetrics;
```

- [ ] **Step 4: Run tests and verify they pass**

Run:

```bash
cargo test terminal_metrics --lib
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/terminal/terminal_metrics.rs src/terminal/mod.rs
git commit -m "feat(terminal): add terminal metrics helpers"
```

---

## Task 2: Add Ghostty render-frame model and pure run builders

**Files:**
- Create: `src/terminal/ghostty_render.rs`
- Modify: `src/terminal/mod.rs`

- [ ] **Step 1: Write failing tests for full-width background runs and wide-cell text runs**

Add tests in `src/terminal/ghostty_render.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn color(r: u8, g: u8, b: u8) -> TerminalColor {
        TerminalColor::rgb(r, g, b)
    }

    #[test]
    fn background_runs_cover_trailing_empty_cells() {
        let row = GhosttyRenderRow {
            cells: vec![
                GhosttyRenderCell::narrow("a", GhosttyCellStyle::default()),
                GhosttyRenderCell::empty(GhosttyCellStyle { background: Some(color(1, 2, 3)), ..Default::default() }),
                GhosttyRenderCell::empty(GhosttyCellStyle { background: Some(color(1, 2, 3)), ..Default::default() }),
            ],
        };

        let runs = background_runs(&row, color(0, 0, 0));

        assert_eq!(runs.len(), 2);
        assert_eq!(runs[0].col, 0);
        assert_eq!(runs[0].cell_count, 1);
        assert_eq!(runs[1].col, 1);
        assert_eq!(runs[1].cell_count, 2);
        assert_eq!(runs[1].background, color(1, 2, 3));
    }

    #[test]
    fn text_runs_skip_wide_spacer_tail_cells() {
        let row = GhosttyRenderRow {
            cells: vec![
                GhosttyRenderCell::wide("表", GhosttyCellStyle::default()),
                GhosttyRenderCell::spacer_tail(GhosttyCellStyle::default()),
                GhosttyRenderCell::narrow("x", GhosttyCellStyle::default()),
            ],
        };

        let runs = text_runs(&row);

        assert_eq!(runs.len(), 2);
        assert_eq!(runs[0].col, 0);
        assert_eq!(runs[0].cell_count, 2);
        assert_eq!(runs[0].text, "表");
        assert_eq!(runs[1].col, 2);
        assert_eq!(runs[1].cell_count, 1);
        assert_eq!(runs[1].text, "x");
    }
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
cargo test ghostty_render --lib
```

Expected: FAIL because `ghostty_render` does not exist.

- [ ] **Step 3: Implement render model and run builders**

Create `src/terminal/ghostty_render.rs` with these public types and helper constructors:

```rust
use super::{TerminalColor, TerminalCursorShape};

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct GhosttyCellStyle {
    pub foreground: Option<TerminalColor>,
    pub background: Option<TerminalColor>,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub inverse: bool,
    pub strikethrough: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GhosttyCellWidth {
    Narrow,
    Wide,
    SpacerTail,
    SpacerHead,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GhosttyRenderCell {
    pub text: String,
    pub style: GhosttyCellStyle,
    pub width: GhosttyCellWidth,
}

impl GhosttyRenderCell {
    pub fn narrow(text: impl Into<String>, style: GhosttyCellStyle) -> Self { Self { text: text.into(), style, width: GhosttyCellWidth::Narrow } }
    pub fn wide(text: impl Into<String>, style: GhosttyCellStyle) -> Self { Self { text: text.into(), style, width: GhosttyCellWidth::Wide } }
    pub fn spacer_tail(style: GhosttyCellStyle) -> Self { Self { text: String::new(), style, width: GhosttyCellWidth::SpacerTail } }
    pub fn empty(style: GhosttyCellStyle) -> Self { Self { text: String::new(), style, width: GhosttyCellWidth::Narrow } }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GhosttyRenderRow { pub cells: Vec<GhosttyRenderCell> }

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GhosttyRenderFrame {
    pub cols: u16,
    pub rows: u16,
    pub default_foreground: TerminalColor,
    pub default_background: TerminalColor,
    pub cursor: Option<GhosttyRenderCursor>,
    pub rows_data: Vec<GhosttyRenderRow>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GhosttyRenderCursor {
    pub col: u16,
    pub row: u16,
    pub visible: bool,
    pub shape: TerminalCursorShape,
    pub color: Option<TerminalColor>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BackgroundRun { pub col: usize, pub cell_count: usize, pub background: TerminalColor }

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TextRun { pub col: usize, pub cell_count: usize, pub text: String, pub style: GhosttyCellStyle }
```

Implement:

```rust
pub fn background_runs(row: &GhosttyRenderRow, default_background: TerminalColor) -> Vec<BackgroundRun> { /* merge adjacent effective backgrounds */ }
pub fn text_runs(row: &GhosttyRenderRow) -> Vec<TextRun> { /* skip spacers/empty text, merge same style only for narrow cells */ }
```

Important behavior:
- Effective background is `cell.style.background.unwrap_or(default_background)`, inverted if `style.inverse`.
- `TextRun.cell_count` is `2` for `GhosttyCellWidth::Wide`, `1` for narrow.
- Do not merge a wide cell text run with neighbors in the first pass.
- Skip `SpacerTail`/`SpacerHead` for text.

Modify `src/terminal/mod.rs`:

```rust
pub mod ghostty_render;
pub use ghostty_render::*;
```

- [ ] **Step 4: Run tests and verify they pass**

Run:

```bash
cargo test ghostty_render --lib
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/terminal/ghostty_render.rs src/terminal/mod.rs
git commit -m "feat(terminal): add ghostty render frame model"
```

---

## Task 3: Build Ghostty render frames from libghostty-vt without trimming cells

**Files:**
- Modify: `src/terminal/ghostty_adapter.rs`
- Modify: `src/terminal/ghostty_render.rs` if conversion helpers belong there
- Test: `tests/terminal_render_tests.rs` or `src/terminal/ghostty_adapter.rs` unit tests

- [ ] **Step 1: Write failing test for preserving trailing background cells**

Add a test for a pure helper rather than requiring a real PTY. Extract helper like `trim_visual_cells` should not exist for Ghostty render frames.

In `src/terminal/ghostty_render.rs`, add:

```rust
#[test]
fn frame_rows_preserve_trailing_empty_styled_cells() {
    let row = GhosttyRenderRow {
        cells: vec![
            GhosttyRenderCell::narrow("x", GhosttyCellStyle::default()),
            GhosttyRenderCell::empty(GhosttyCellStyle { background: Some(TerminalColor::rgb(9, 9, 9)), ..Default::default() }),
        ],
    };

    assert_eq!(row.cells.len(), 2);
    assert_eq!(background_runs(&row, TerminalColor::rgb(0, 0, 0)).last().unwrap().col, 1);
}
```

If this already passes after Task 2, add an adapter-specific unit test around a new helper that converts a fake cell descriptor vector into `GhosttyRenderRow` and verifies no trimming.

- [ ] **Step 2: Run relevant tests and confirm failure if helper missing**

Run:

```bash
cargo test frame_rows_preserve_trailing_empty_styled_cells --lib
```

Expected: FAIL only if helper/API is missing; otherwise this is a characterization test and should pass. If it passes immediately, proceed to adapter conversion with care and use later integration tests as regression coverage.

- [ ] **Step 3: Add Ghostty conversion logic**

In `src/terminal/ghostty_adapter.rs`:

- Import `libghostty_vt::screen::CellWide`.
- In `VtState`, add a method:

```rust
fn render_frame(&mut self, viewport: TerminalViewport) -> anyhow::Result<GhosttyRenderFrame>
```

It should:

- Apply the requested viewport like `snapshot_rows` currently does.
- Call `self.render_state.update(&self.terminal)`.
- Read `snapshot.colors()` for defaults.
- Read `snapshot.cursor_viewport()` and `snapshot.cursor_visual_style()` where available.
- Iterate rows and cells.
- For each cell:
  - `let raw = cell.raw_cell()?;`
  - `let width = convert_width(raw.wide()?);`
  - `let text = cell.graphemes()?` filtering `\0`.
  - `let style = convert_ghostty_cell_style(cell)?;`
- Push every cell into row output; do not trim trailing cells.
- Restore Ghostty viewport to bottom after rendering, matching existing behavior.

Add converters:

```rust
fn convert_width(width: libghostty_vt::screen::CellWide) -> GhosttyCellWidth { ... }
fn convert_ghostty_cell_style(cell: &libghostty_vt::render::CellIteration<'_, '_>) -> anyhow::Result<GhosttyCellStyle> { ... }
```

- [ ] **Step 4: Add backend API**

Extend `TerminalBackend` with a render-frame method or add a Ghostty-specific method on `GhosttyTerminalBackend`:

```rust
pub fn render_frame(
    &mut self,
    session: TerminalBackendSession,
    viewport: TerminalViewport,
) -> anyhow::Result<GhosttyRenderFrame>
```

This method should:

- Lookup session.
- `poll_exit()`.
- `drain_output()`.
- `fail_on_read_error()`.
- Return `state.vt.render_frame(viewport)`.

Keep existing `snapshot()` until UI migration is complete.

- [ ] **Step 5: Run targeted and full tests**

Run:

```bash
cargo test ghostty_render --lib
cargo test terminal_render_tests
cargo test terminal_session_tests
```

Expected: PASS, ignored real-PTY tests remain ignored.

- [ ] **Step 6: Commit**

```bash
git add src/terminal/ghostty_adapter.rs src/terminal/ghostty_render.rs tests/terminal_render_tests.rs
git commit -m "feat(terminal): expose ghostty render frames"
```

---

## Task 4: Add canvas paint planning helpers

**Files:**
- Create: `src/ui/terminal_canvas.rs`
- Modify: `src/ui/mod.rs`
- Tests: `src/ui/terminal_canvas.rs` unit tests

- [ ] **Step 1: Write failing tests for paint command generation**

Create `src/ui/terminal_canvas.rs` with tests first:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::terminal::{GhosttyCellStyle, GhosttyRenderCell, GhosttyRenderFrame, GhosttyRenderRow, TerminalColor, TerminalCursorShape, TerminalMetrics};

    #[test]
    fn paint_plan_starts_with_full_background() {
        let frame = GhosttyRenderFrame {
            cols: 2,
            rows: 1,
            default_foreground: TerminalColor::rgb(255, 255, 255),
            default_background: TerminalColor::rgb(1, 2, 3),
            cursor: None,
            rows_data: vec![GhosttyRenderRow { cells: vec![GhosttyRenderCell::narrow("a", GhosttyCellStyle::default()), GhosttyRenderCell::empty(GhosttyCellStyle::default())] }],
        };

        let plan = terminal_paint_plan(&frame, TerminalMetrics::fallback());

        assert!(matches!(plan.commands.first(), Some(TerminalPaintCommand::FillBackground { .. })));
    }

    #[test]
    fn paint_plan_includes_cursor_overlay() {
        let mut frame = empty_frame(2, 1);
        frame.cursor = Some(crate::terminal::GhosttyRenderCursor { col: 1, row: 0, visible: true, shape: TerminalCursorShape::Block, color: None });

        let plan = terminal_paint_plan(&frame, TerminalMetrics::fallback());

        assert!(plan.commands.iter().any(|command| matches!(command, TerminalPaintCommand::Cursor { col: 1, row: 0, .. })));
    }
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
cargo test terminal_canvas --lib
```

Expected: FAIL because `terminal_canvas` module does not exist.

- [ ] **Step 3: Implement paint planning structs and helper**

Add minimal pure structs:

```rust
#[derive(Debug, Clone, PartialEq)]
pub struct TerminalPaintPlan { pub commands: Vec<TerminalPaintCommand> }

#[derive(Debug, Clone, PartialEq)]
pub enum TerminalPaintCommand {
    FillBackground { color: TerminalColor, cols: u16, rows: u16 },
    BackgroundRun { row: usize, col: usize, cell_count: usize, color: TerminalColor },
    TextRun { row: usize, col: usize, cell_count: usize, text: String, style: GhosttyCellStyle },
    Cursor { row: u16, col: u16, shape: TerminalCursorShape, color: Option<TerminalColor> },
}

pub fn terminal_paint_plan(frame: &GhosttyRenderFrame, metrics: TerminalMetrics) -> TerminalPaintPlan { ... }
```

The plan should use `background_runs` and `text_runs` from `ghostty_render.rs`.

Modify `src/ui/mod.rs`:

```rust
pub mod terminal_canvas;
```

- [ ] **Step 4: Run tests and verify they pass**

Run:

```bash
cargo test terminal_canvas --lib
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ui/terminal_canvas.rs src/ui/mod.rs
git commit -m "feat(ui): add terminal canvas paint planning"
```

---

## Task 5: Implement GPUI TerminalCanvas painting

**Files:**
- Modify: `src/ui/terminal_canvas.rs`
- Modify: `src/ui/terminal_pane.rs`

- [ ] **Step 1: Add a compile-failing skeleton test or example usage**

Add a small unit test that verifies `render_terminal_canvas` can be constructed from a frame:

```rust
#[test]
fn render_terminal_canvas_accepts_frame_and_metrics() {
    let frame = empty_frame(2, 1);
    let _element = render_terminal_canvas(frame, TerminalMetrics::fallback());
}
```

If returning `impl IntoElement` makes direct testing awkward, instead test construction of a `TerminalCanvas` struct before `IntoElement` conversion.

- [ ] **Step 2: Run test and verify failure**

Run:

```bash
cargo test render_terminal_canvas_accepts_frame_and_metrics --lib
```

Expected: FAIL because constructor does not exist.

- [ ] **Step 3: Implement `TerminalCanvas` custom element**

In `src/ui/terminal_canvas.rs`, implement:

```rust
pub fn render_terminal_canvas(frame: GhosttyRenderFrame, metrics: TerminalMetrics) -> impl IntoElement {
    TerminalCanvas { frame, metrics }
}

struct TerminalCanvas { frame: GhosttyRenderFrame, metrics: TerminalMetrics }
```

Implement `IntoElement` and `Element` similarly to `TerminalBoundsProbe` in `src/ui/terminal_view.rs`.

`request_layout`:

- Width/height relative 1.0.

`paint`:

- Build `terminal_paint_plan(&self.frame, self.metrics)`.
- Use `window.paint_layer(bounds, |window| { ... })` if clipping is needed.
- Use `window.paint_quad(fill(...))` for background rects.
- Use GPUI text shaping/painting APIs for text runs. Prefer `window.text_system().shape_line(...)` and `ShapedLine::paint(...)`; if exact API names differ, adapt to the public GPUI text-system paint path. Do not reintroduce the `div`/flex renderer for the canvas path.

Paint coordinates:

```rust
let x = bounds.origin.x + px(command.col as f32 * metrics.cell_width_px);
let y = bounds.origin.y + px(command.row as f32 * metrics.cell_height_px);
```

- [ ] **Step 4: Run compile/test**

Run:

```bash
cargo test terminal_canvas --lib
cargo build
```

Expected: PASS/build succeeds.

- [ ] **Step 5: Commit**

```bash
git add src/ui/terminal_canvas.rs src/ui/terminal_pane.rs
git commit -m "feat(ui): paint terminal frames with canvas"
```

---

## Task 6: Wire TerminalCanvas into active terminal UI

**Files:**
- Modify: `src/ui/shell.rs`
- Modify: `src/ui/terminal_pane.rs`
- Modify: `src/ui/terminal_view.rs` if old renderer is removed/legacy-only

- [ ] **Step 1: Write failing test for terminal body size using `TerminalMetrics`**

Update or add test in `src/ui/shell.rs` or `src/terminal/terminal_metrics.rs` that ensures size calculation uses `TerminalMetrics::size_from_pixels` instead of old constants.

```rust
#[test]
fn terminal_size_uses_terminal_metrics() {
    let metrics = TerminalMetrics::fallback();
    assert_eq!(metrics.size_from_pixels(900.0, 380.0), TerminalSize { cols: 100, rows: 20 });
}
```

- [ ] **Step 2: Run test and verify current code path still uses old function**

Run:

```bash
cargo test terminal_size_uses_terminal_metrics --lib
```

Expected: FAIL if not yet added/exported; otherwise use this as regression coverage before wiring.

- [ ] **Step 3: Change terminal pane API**

In `src/ui/terminal_pane.rs`:

- Replace `snapshot: Option<&TerminalGridSnapshot>` parameter with something like:

```rust
terminal_frame: Option<GhosttyRenderFrame>,
terminal_status: Option<TerminalStatus>,
terminal_metrics: TerminalMetrics,
```

- In `render_terminal_body`, call:

```rust
Some(frame) => render_terminal_canvas(frame, terminal_metrics).into_any_element()
```

- Keep exited/failure UI using status metadata rather than visual snapshot.

- [ ] **Step 4: Change shell render path**

In `src/ui/shell.rs`:

- Replace visual `terminal_snapshot()` call with a new `terminal_render_frame()` call.
- Keep a lightweight `terminal_status` update path.
- Use `TerminalMetrics::fallback()` initially, then later replace with measured metrics.
- Replace `terminal_size_from_pixels` with `TerminalMetrics::size_from_pixels`.

Add helper:

```rust
fn terminal_render_frame(&mut self) -> Option<GhosttyRenderFrame> { ... }
```

This helper should call `self.terminal_backend.render_frame(...)`.

- [ ] **Step 5: Run tests/build**

Run:

```bash
cargo test
cargo build
```

Expected: PASS.

- [ ] **Step 6: Manual smoke test**

Run:

```bash
cargo run
```

Manual checks:
- Shell prompt appears.
- `ls` output appears.
- Terminal background no longer differs accidentally from pane, or mismatch is intentionally explained by Ghostty default colors.
- No panic during resize.

- [ ] **Step 7: Commit**

```bash
git add src/ui/shell.rs src/ui/terminal_pane.rs src/ui/terminal_view.rs src/terminal/terminal_metrics.rs
git commit -m "feat(ui): wire ghostty canvas renderer"
```

---

## Task 7: Add Ghostty-first keyboard and paste encoding

**Files:**
- Create: `src/terminal/ghostty_input.rs`
- Modify: `src/terminal/ghostty_adapter.rs`
- Modify: `src/terminal/mod.rs`
- Modify: `src/ui/shell.rs`

- [ ] **Step 1: Write failing tests for paste wrapping, line normalization, and fallback text bytes**

In `src/terminal/ghostty_input.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bracketed_paste_wraps_normalized_text() {
        assert_eq!(
            paste_bytes("hello\r\nworld", PasteMode::Bracketed),
            b"\x1b[200~hello\nworld\x1b[201~".to_vec()
        );
    }

    #[test]
    fn plain_paste_writes_normalized_text_directly() {
        assert_eq!(paste_bytes("hello\r\nworld", PasteMode::Plain), b"hello\nworld".to_vec());
    }

    #[test]
    fn paste_mode_uses_terminal_bracketed_paste_mode() {
        assert_eq!(PasteMode::from_bracketed_enabled(true), PasteMode::Bracketed);
        assert_eq!(PasteMode::from_bracketed_enabled(false), PasteMode::Plain);
    }
}
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
cargo test ghostty_input --lib
```

Expected: FAIL because module/types do not exist.

- [ ] **Step 3: Implement paste helper, line normalization, and module export**

Create `src/terminal/ghostty_input.rs`:

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PasteMode {
    Plain,
    Bracketed,
}

impl PasteMode {
    pub fn from_bracketed_enabled(enabled: bool) -> Self {
        if enabled { Self::Bracketed } else { Self::Plain }
    }
}

pub fn normalize_paste_text(text: &str) -> String {
    text.replace("\r\n", "\n").replace('\r', "\n")
}

pub fn paste_bytes(text: &str, mode: PasteMode) -> Vec<u8> {
    let normalized = normalize_paste_text(text);
    match mode {
        PasteMode::Plain => normalized.into_bytes(),
        PasteMode::Bracketed => {
            let mut bytes = b"\x1b[200~".to_vec();
            bytes.extend_from_slice(normalized.as_bytes());
            bytes.extend_from_slice(b"\x1b[201~");
            bytes
        }
    }
}
```

Modify `src/terminal/mod.rs`:

```rust
pub mod ghostty_input;
pub use ghostty_input::*;
```

- [ ] **Step 4: Add Ghostty-mode-aware paste backend path**

In `src/terminal/ghostty_adapter.rs`, add a method on `GhosttyTerminalBackend`:

```rust
pub fn write_paste_input(
    &mut self,
    session: TerminalBackendSession,
    text: &str,
) -> anyhow::Result<bool>
```

Implementation requirements:

- Lookup the session state.
- Read bracketed paste mode with `state.vt.terminal.mode(libghostty_vt::terminal::Mode::BRACKETED_PASTE)?`.
- Build `PasteMode::from_bracketed_enabled(bracketed_enabled)`.
- Use `paste_bytes(text, mode)`.
- Optionally use `libghostty_vt::paste::is_safe` to reject or sanitize unsafe paste data if exposed and practical; if rejected, return a clear `anyhow` error.
- Write bytes through the same PTY writer path as normal input.
- Return `Ok(true)` after writing bytes.

In `src/ui/shell.rs`, add a paste event path if GPUI exposes a paste callback in this version. If GPUI only exposes paste through key events/clipboard, add a focused helper method that can be connected once the callback is identified, and route any existing paste action through `write_paste_input`. Do not leave paste hardcoded to always bracket or never bracket.

- [ ] **Step 5: Add Ghostty key encoding adapter**

In `ghostty_input.rs`, add functions to convert GPUI `KeyDownEvent` into `libghostty_vt::key::Event` where possible.

Implementation notes:

- Prefer a small `TerminalKeyInput` struct over passing `gpui::KeyDownEvent` deep into the backend if the backend/UI boundary gets messy.
- Use `libghostty_vt::key::Encoder::new()`.
- Call `encoder.set_options_from_terminal(&terminal)` before encoding.
- Set macOS Option-as-Alt after terminal options if desired.
- Use existing `terminal_input_bytes(event)` as fallback for unmapped keys.

In `ghostty_adapter.rs`, add method:

```rust
pub fn write_key_input(&mut self, session: TerminalBackendSession, input: TerminalKeyInput) -> anyhow::Result<bool>
```

If encoded/fallback bytes exist, write them and return `Ok(true)`. If no bytes, return `Ok(false)`.

- [ ] **Step 6: Wire shell key and paste input through new methods**

In `src/ui/shell.rs`:

- Update `write_terminal_input` to call the Ghostty-first key method.
- Keep manual fallback only inside `ghostty_input.rs`/backend, not duplicated in shell.
- Add or connect a paste handler that sends clipboard text to `write_paste_input`.
- If GPUI paste callback discovery requires a short investigation, do it in this step and document the exact GPUI API used in comments/tests.

- [ ] **Step 7: Run tests/build**

Run:

```bash
cargo test ghostty_input --lib
cargo test terminal_session_tests
cargo build
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add src/terminal/ghostty_input.rs src/terminal/ghostty_adapter.rs src/terminal/mod.rs src/ui/shell.rs
git commit -m "feat(terminal): route key and paste input through ghostty"
```

---

## Task 8: Add Ghostty-first mouse reporting and scroll fallback

**Files:**
- Modify: `src/terminal/ghostty_input.rs`
- Modify: `src/terminal/ghostty_adapter.rs`
- Modify: `src/ui/shell.rs`
- Modify: `src/ui/terminal_pane.rs`

- [ ] **Step 1: Write failing tests for pixel-to-cell mouse conversion**

In `src/terminal/ghostty_input.rs`:

```rust
#[test]
fn mouse_position_uses_metrics_to_find_cell() {
    let metrics = TerminalMetrics::fallback();
    let position = mouse_cell_position(18.0, 38.0, metrics).unwrap();
    assert_eq!(position.col, 2);
    assert_eq!(position.row, 2);
}
```

Define a small return type:

```rust
pub struct MouseCellPosition { pub col: u16, pub row: u16 }
```

- [ ] **Step 2: Run test and verify failure**

Run:

```bash
cargo test mouse_position_uses_metrics_to_find_cell --lib
```

Expected: FAIL because helper does not exist.

- [ ] **Step 3: Implement mouse position helper**

Add helper in `ghostty_input.rs` using `TerminalMetrics::cell_at`.

- [ ] **Step 4: Add Ghostty mouse encoder method**

In `ghostty_adapter.rs`, add method:

```rust
pub fn write_mouse_input(
    &mut self,
    session: TerminalBackendSession,
    input: TerminalMouseInput,
) -> anyhow::Result<bool>
```

Implementation notes:
- Use `libghostty_vt::mouse::Encoder::new()`.
- Call `encoder.set_options_from_terminal(&state.vt.terminal)`.
- Set `EncoderSize` from current rows/cols and pixel/cell metrics.
- Convert click/move/wheel action/button to `libghostty_vt::mouse::Event`.
- If encoder emits bytes, write to PTY and return `Ok(true)`.
- If mouse tracking is disabled/no report emitted, return `Ok(false)` so shell can perform app scrollback/focus behavior.

- [ ] **Step 5: Wire GPUI mouse events**

In `src/ui/terminal_pane.rs` and `src/ui/shell.rs`:

- Add mouse down/up/move callbacks to terminal body/canvas container.
- Convert event positions to terminal-local pixels using terminal body bounds.
- Call backend mouse method.
- For wheel events: first try Ghostty mouse reporting; if it returns false, keep existing scrollback behavior.

- [ ] **Step 6: Run tests/build**

Run:

```bash
cargo test ghostty_input --lib
cargo build
```

Expected: PASS.

- [ ] **Step 7: Manual smoke test**

Run:

```bash
cargo run
```

Manual checks:
- Normal scrollback still works in shell output.
- `less README.md` still scrolls or navigates as expected.
- Mouse tracking app behavior can be checked later with vim/Claude Code if available.

- [ ] **Step 8: Commit**

```bash
git add src/terminal/ghostty_input.rs src/terminal/ghostty_adapter.rs src/ui/shell.rs src/ui/terminal_pane.rs
git commit -m "feat(terminal): add ghostty mouse reporting"
```

---

## Task 9: Add measured font metrics integration

**Files:**
- Modify: `src/terminal/terminal_metrics.rs`
- Modify: `src/ui/terminal_canvas.rs`
- Modify: `src/ui/shell.rs`

- [ ] **Step 1: Write tests for metric fallback and validation policy**

Add tests in `src/terminal/terminal_metrics.rs`:

```rust
#[test]
fn metrics_reject_zero_or_negative_measurements() {
    assert_eq!(TerminalMetrics::from_measured(0.0, 19.0, 14.0), None);
    assert_eq!(TerminalMetrics::from_measured(9.0, 0.0, 14.0), None);
    assert_eq!(TerminalMetrics::from_measured(9.0, 19.0, 14.0).unwrap().cell_width_px, 9.0);
}

#[test]
fn metrics_fall_back_when_measurement_fails() {
    assert_eq!(TerminalMetrics::measured_or_fallback(None), TerminalMetrics::fallback());
    assert_eq!(
        TerminalMetrics::measured_or_fallback(TerminalMetrics::from_measured(10.0, 20.0, 14.0)).cell_width_px,
        10.0
    );
}
```

- [ ] **Step 2: Run test and verify failure**

Run:

```bash
cargo test terminal_metrics --lib
```

Expected: FAIL because `from_measured`/`measured_or_fallback` do not exist.

- [ ] **Step 3: Implement measured metrics constructors**

Add to `TerminalMetrics`:

```rust
pub fn from_measured(cell_width_px: f32, cell_height_px: f32, font_size_px: f32) -> Option<Self> {
    (cell_width_px > 0.0 && cell_height_px > 0.0 && font_size_px > 0.0).then_some(Self {
        cell_width_px,
        cell_height_px,
        font_size_px,
    })
}

pub fn measured_or_fallback(measured: Option<Self>) -> Self {
    measured.unwrap_or_else(Self::fallback)
}
```

- [ ] **Step 4: Implement GPUI font measurement helper**

Add a helper in `src/ui/terminal_canvas.rs` or a focused metrics UI module:

```rust
pub fn measure_terminal_metrics(
    window: &mut gpui::Window,
    font_family: &str,
    font_size_px: f32,
) -> TerminalMetrics
```

Implementation requirements:

- Use `window.text_system().shape_line(...)` or `layout_line(...)` with a `gpui::TextRun` using `gpui::font(font_family)` and `gpui::px(font_size_px)`.
- Measure a representative monospace string such as `"MMMMMMMMMM"`; compute `cell_width_px = shaped_line.width / 10.0`.
- Derive `cell_height_px` from the shaped line's ascent/descent plus a small line-height policy, or from the current terminal line height if it is already known. Do not use the old hardcoded constants as the primary path.
- Return `TerminalMetrics::measured_or_fallback(TerminalMetrics::from_measured(...))`.
- Keep fallback only for failed/invalid measurement.

Example shape outline, to adapt to exact GPUI APIs:

```rust
let font = gpui::font(font_family);
let run = gpui::TextRun {
    len: sample.len(),
    font,
    color: gpui::black(),
    background_color: None,
    underline: None,
    strikethrough: None,
};
let line = window.text_system().shape_line(sample.into(), gpui::px(font_size_px), &[run], None);
let width = f32::from(line.width);
let height = f32::from(line.ascent + line.descent).ceil().max(font_size_px);
```

If field visibility differs, use public `size(...)`, `ascent()`, or `layout_line(...)` accessors exposed by GPUI; do not replace measurement with a TODO.

- [ ] **Step 5: Use measured metrics in shell/canvas sizing**

In `src/ui/shell.rs`:

- Add `terminal_metrics: TerminalMetrics` state if needed.
- During render/prepaint where `Window` is available, call `measure_terminal_metrics(window, TERMINAL_FONT_FAMILY, TERMINAL_FONT_SIZE_PX)` and update cached metrics when changed.
- Replace all terminal size calculations that used hardcoded constants with `self.terminal_metrics.size_from_pixels(width, height)`.
- Ensure mouse coordinate conversion uses the same cached metrics.

In `src/ui/terminal_canvas.rs`:

- Paint using the metrics passed from shell.
- Do not call fallback directly except inside `measure_terminal_metrics` failure handling.

- [ ] **Step 6: Run tests/build**

Run:

```bash
cargo test terminal_metrics --lib
cargo test terminal_canvas --lib
cargo build
```

Expected: PASS.

- [ ] **Step 7: Manual metric smoke test**

Run:

```bash
cargo run
```

Manual checks:

- Prompt glyphs are not clipped.
- Columns remain aligned for `printf '1234567890\nabcdefghij\n'`.
- `stty size` changes consistently after resizing.

- [ ] **Step 8: Commit**

```bash
git add src/terminal/terminal_metrics.rs src/ui/terminal_canvas.rs src/ui/shell.rs
git commit -m "feat(terminal): measure terminal font metrics"
```

---

## Task 10: Update manual tests and run full verification

**Files:**
- Modify: `docs/manual-test.md`

- [ ] **Step 1: Update manual test checklist**

Add terminal rendering/input checks:

```markdown
### Ghostty-first Canvas Renderer

1. Claude Code: run `claude`; prompt area, status bars, input field, and backgrounds render without chopped bars or mismatched trailing backgrounds.
2. Vim/nvim: open editor, enter insert mode, type, move cursor, quit without saving.
3. Less alternate screen: run `less README.md`, scroll, quit, and confirm shell screen returns.
4. htop/top: run a live TUI, verify repaint stability, quit.
5. Colors: run 16/256/truecolor scripts and verify backgrounds extend through padded regions.
6. Wide text: print CJK text, emoji, and box drawing; verify columns remain aligned.
7. Mouse: verify shell scrollback still works; in mouse-aware TUIs, verify clicks/wheel are sent when supported.
8. Resize: run `stty size`, resize the window, run `stty size` again, confirm cell size changed correctly.
```

- [ ] **Step 2: Run full automated verification**

Run:

```bash
cargo fmt
cargo test
cargo build
```

Expected: all pass, ignored tests remain ignored.

- [ ] **Step 3: Manual app verification**

Run:

```bash
cargo run
```

Perform at least:
- Shell prompt + `ls`.
- Claude Code visual check if installed/authenticated.
- `less README.md`.
- Resize check with `stty size`.

Record any remaining known limitation in `docs/manual-test.md`.

- [ ] **Step 4: Commit**

```bash
git add docs/manual-test.md
git commit -m "docs: expand ghostty terminal manual tests"
```

---

## Task 11: Ghostty renderer/surface feasibility spike

**Files:**
- Create: `docs/research/ghostty-renderer-surface-spike.md`

- [ ] **Step 1: Create research questions document**

Write initial sections:

```markdown
# Ghostty Renderer Surface Feasibility Spike

## Questions

- What renderer components are accessible outside Ghostty's app?
- Does the renderer assume Ghostty-owned windows, surfaces, event loops, or GPU pipelines?
- Can a Ghostty-rendered surface live inside a GPUI element with clipping/focus/resize/input?
- What API changes or upstream work would be needed?

## Findings

## Recommendation
```

- [ ] **Step 2: Inspect available Ghostty/libghostty-vt sources**

Use local crate sources first:

```bash
rg -n "renderer|surface|metal|gpu|window" ~/.cargo/registry/src/index.crates.io-*/libghostty-vt-* ~/.cargo/registry/src/index.crates.io-*/libghostty-vt-sys-* || true
```

If a full Ghostty checkout exists or `GHOSTTY_SOURCE_DIR` is set, inspect renderer-related files there. Do not vendor Ghostty or make code changes in this task.

- [ ] **Step 3: Fill findings and recommendation**

The report must end with one of:

- `Recommendation: continue GPUI canvas renderer; revisit embedding later`
- `Recommendation: prototype Ghostty renderer embedding in a separate branch`
- `Recommendation: do not pursue embedding due to blockers`

Include concrete blockers or next steps.

- [ ] **Step 4: Commit**

```bash
git add docs/research/ghostty-renderer-surface-spike.md
git commit -m "docs: research ghostty renderer embedding feasibility"
```

---

## Final Verification

- [ ] Run:

```bash
cargo fmt
cargo test
cargo build
```

- [ ] Run `cargo run` and manually verify:
  - Claude Code rendering is substantially correct.
  - Terminal pane/terminal background mismatch is resolved or intentionally themed.
  - Shell input remains responsive.
  - Resize works.

- [ ] Check git status:

```bash
git status --short
```

Expected: clean.

- [ ] Summarize final commits and known limitations.
