use std::rc::Rc;

use crate::terminal::{TerminalCellStyle, TerminalColor, TerminalGridSnapshot, TerminalSize};
use gpui::{
    App, Bounds, Element, ElementId, GlobalElementId, InspectorElementId, IntoElement, LayoutId,
    ParentElement, Pixels, SharedString, Style, Styled, Window, div, prelude::*, px, relative, rgb,
};

const TERMINAL_BACKGROUND: u32 = 0x111827;
const TERMINAL_FOREGROUND: u32 = 0xe5e7eb;
pub const TERMINAL_FONT_FAMILY: &str = "Hack Nerd Font";
pub const TERMINAL_FONT_SIZE_PX: f32 = 14.0;
pub const CELL_WIDTH_PX: f32 = 9.0;
pub const CELL_HEIGHT_PX: f32 = 19.0;

pub fn terminal_size_from_pixels(width_px: f32, height_px: f32) -> TerminalSize {
    TerminalSize {
        cols: (width_px / CELL_WIDTH_PX).floor().max(20.0) as u16,
        rows: (height_px / CELL_HEIGHT_PX).floor().max(4.0) as u16,
    }
}

pub fn render_terminal_bounds_probe(
    on_bounds: impl Fn(Bounds<Pixels>, &mut App) + 'static,
) -> impl IntoElement {
    TerminalBoundsProbe {
        on_bounds: Rc::new(on_bounds),
    }
}

struct TerminalBoundsProbe {
    on_bounds: Rc<dyn Fn(Bounds<Pixels>, &mut App)>,
}

impl IntoElement for TerminalBoundsProbe {
    type Element = Self;

    fn into_element(self) -> Self::Element {
        self
    }
}

impl Element for TerminalBoundsProbe {
    type RequestLayoutState = ();
    type PrepaintState = ();

    fn id(&self) -> Option<ElementId> {
        None
    }

    fn source_location(&self) -> Option<&'static core::panic::Location<'static>> {
        None
    }

    fn request_layout(
        &mut self,
        _id: Option<&GlobalElementId>,
        _inspector_id: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, Self::RequestLayoutState) {
        let mut style = Style::default();
        style.size.width = relative(1.0).into();
        style.size.height = relative(1.0).into();
        (window.request_layout(style, [], cx), ())
    }

    fn prepaint(
        &mut self,
        _id: Option<&GlobalElementId>,
        _inspector_id: Option<&InspectorElementId>,
        _bounds: Bounds<Pixels>,
        _request_layout: &mut Self::RequestLayoutState,
        _window: &mut Window,
        _cx: &mut App,
    ) -> Self::PrepaintState {
    }

    fn paint(
        &mut self,
        _id: Option<&GlobalElementId>,
        _inspector_id: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        _request_layout: &mut Self::RequestLayoutState,
        _prepaint: &mut Self::PrepaintState,
        _window: &mut Window,
        cx: &mut App,
    ) {
        (self.on_bounds)(bounds, cx);
    }
}

pub fn render_terminal_grid(snapshot: &TerminalGridSnapshot) -> impl IntoElement {
    let cursor = snapshot
        .cursor
        .filter(|cursor| cursor.visible)
        .map(|cursor| (usize::from(cursor.row), usize::from(cursor.col)));

    div()
        .id("terminal-grid")
        .flex()
        .flex_col()
        .overflow_hidden()
        .font_family(TERMINAL_FONT_FAMILY)
        .text_size(px(TERMINAL_FONT_SIZE_PX))
        .line_height(px(CELL_HEIGHT_PX))
        .children(
            snapshot
                .rows
                .iter()
                .enumerate()
                .map(move |(row_index, row)| render_terminal_row(row_index, row, cursor)),
        )
}

fn render_terminal_row(
    row_index: usize,
    row: &crate::terminal::TerminalRow,
    cursor: Option<(usize, usize)>,
) -> impl IntoElement {
    let cursor_col =
        cursor.and_then(|(cursor_row, cursor_col)| (cursor_row == row_index).then_some(cursor_col));

    div()
        .flex()
        .flex_row()
        .flex_none()
        .h(px(CELL_HEIGHT_PX))
        .whitespace_nowrap()
        .children(
            terminal_row_runs(row, cursor_col)
                .into_iter()
                .map(render_terminal_run),
        )
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct TerminalRun {
    text: String,
    style: TerminalCellStyle,
    is_cursor: bool,
    cell_count: usize,
}

fn terminal_row_runs(
    row: &crate::terminal::TerminalRow,
    cursor_col: Option<usize>,
) -> Vec<TerminalRun> {
    let cells_to_render = cursor_col
        .map(|cursor_col| row.cells.len().max(cursor_col.saturating_add(1)))
        .unwrap_or(row.cells.len());
    let mut runs: Vec<TerminalRun> = Vec::new();

    for col_index in 0..cells_to_render {
        let is_cursor = cursor_col == Some(col_index);
        let cell = row.cells.get(col_index);
        let style = cell.map(|cell| cell.style.clone()).unwrap_or_default();
        let text = cell
            .map(|cell| cell.text.as_str())
            .filter(|text| !text.is_empty())
            .unwrap_or(" ");

        if let Some(run) = runs.last_mut()
            && !is_cursor
            && !run.is_cursor
            && run.style == style
        {
            run.text.push_str(text);
            run.cell_count += 1;
            continue;
        }

        runs.push(TerminalRun {
            text: text.to_string(),
            style,
            is_cursor,
            cell_count: 1,
        });
    }

    runs
}

fn render_terminal_run(run: TerminalRun) -> impl IntoElement {
    let mut foreground = run
        .style
        .foreground
        .map(render_color)
        .unwrap_or_else(|| rgb(TERMINAL_FOREGROUND));
    let mut background = run
        .style
        .background
        .map(render_color)
        .unwrap_or_else(|| rgb(TERMINAL_BACKGROUND));

    if run.style.inverse {
        std::mem::swap(&mut foreground, &mut background);
    }

    if run.is_cursor {
        std::mem::swap(&mut foreground, &mut background);
    }

    div()
        .flex_none()
        .w(px(CELL_WIDTH_PX * run.cell_count as f32))
        .h(px(CELL_HEIGHT_PX))
        .overflow_hidden()
        .text_color(foreground)
        .bg(background)
        .when(run.style.bold, |element| {
            element.font_weight(gpui::FontWeight::BOLD)
        })
        .when(run.style.italic, |element| element.italic())
        .when(run.style.underline, |element| element.underline())
        .when(run.style.strikethrough, |element| element.line_through())
        .child(SharedString::from(run.text))
}

fn render_color(color: TerminalColor) -> gpui::Rgba {
    rgb((u32::from(color.r) << 16) | (u32::from(color.g) << 8) | u32::from(color.b))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::terminal::{TerminalCell, TerminalCellStyle, TerminalRow};

    #[test]
    fn terminal_row_runs_coalesce_adjacent_cells_with_same_style() {
        let normal = TerminalCellStyle::default();
        let red = TerminalCellStyle {
            foreground: Some(TerminalColor::rgb(255, 0, 0)),
            ..TerminalCellStyle::default()
        };
        let row = TerminalRow {
            cells: vec![
                TerminalCell {
                    text: "a".to_string(),
                    style: normal.clone(),
                },
                TerminalCell {
                    text: "b".to_string(),
                    style: normal,
                },
                TerminalCell {
                    text: "c".to_string(),
                    style: red.clone(),
                },
                TerminalCell {
                    text: "d".to_string(),
                    style: red,
                },
            ],
        };

        let runs = terminal_row_runs(&row, None);

        assert_eq!(runs.len(), 2);
        assert_eq!(runs[0].text, "ab");
        assert_eq!(runs[0].cell_count, 2);
        assert_eq!(runs[1].text, "cd");
        assert_eq!(runs[1].cell_count, 2);
    }

    #[test]
    fn terminal_row_runs_keep_cursor_in_own_run() {
        let row = TerminalRow {
            cells: vec![
                TerminalCell::new("a"),
                TerminalCell::new("b"),
                TerminalCell::new("c"),
            ],
        };

        let runs = terminal_row_runs(&row, Some(1));

        assert_eq!(runs.len(), 3);
        assert_eq!(runs[0].text, "a");
        assert!(!runs[0].is_cursor);
        assert_eq!(runs[1].text, "b");
        assert!(runs[1].is_cursor);
        assert_eq!(runs[2].text, "c");
        assert!(!runs[2].is_cursor);
    }
}
