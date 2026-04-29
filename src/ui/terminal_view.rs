use crate::terminal::{TerminalCell, TerminalColor, TerminalGridSnapshot};
use gpui::{IntoElement, ParentElement, SharedString, Styled, div, prelude::*, px, rgb};

const TERMINAL_BACKGROUND: u32 = 0x111827;
const TERMINAL_FOREGROUND: u32 = 0xe5e7eb;
const CELL_WIDTH_PX: f32 = 8.0;
const CELL_HEIGHT_PX: f32 = 18.0;

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
        .font_family("monospace")
        .text_sm()
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
    let cells_to_render = cursor
        .filter(|(cursor_row, _)| *cursor_row == row_index)
        .map(|(_, cursor_col)| row.cells.len().max(cursor_col.saturating_add(1)))
        .unwrap_or(row.cells.len());

    div()
        .flex()
        .flex_row()
        .flex_none()
        .h(px(CELL_HEIGHT_PX))
        .whitespace_nowrap()
        .children((0..cells_to_render).map(move |col_index| {
            render_terminal_cell(
                row.cells.get(col_index),
                cursor.is_some_and(|(cursor_row, cursor_col)| {
                    cursor_row == row_index && cursor_col == col_index
                }),
            )
        }))
}

fn render_terminal_cell(cell: Option<&TerminalCell>, is_cursor: bool) -> impl IntoElement {
    let style = cell.map(|cell| &cell.style);
    let mut foreground = style
        .and_then(|style| style.foreground)
        .map(render_color)
        .unwrap_or_else(|| rgb(TERMINAL_FOREGROUND));
    let mut background = style
        .and_then(|style| style.background)
        .map(render_color)
        .unwrap_or_else(|| rgb(TERMINAL_BACKGROUND));

    if style.is_some_and(|style| style.inverse) {
        std::mem::swap(&mut foreground, &mut background);
    }

    if is_cursor {
        std::mem::swap(&mut foreground, &mut background);
    }

    let text = cell
        .map(|cell| cell.text.as_str())
        .filter(|text| !text.is_empty())
        .unwrap_or(" ");

    div()
        .flex_none()
        .w(px(CELL_WIDTH_PX))
        .h(px(CELL_HEIGHT_PX))
        .overflow_hidden()
        .text_color(foreground)
        .bg(background)
        .when(style.is_some_and(|style| style.bold), |element| {
            element.font_weight(gpui::FontWeight::BOLD)
        })
        .when(style.is_some_and(|style| style.italic), |element| {
            element.italic()
        })
        .when(style.is_some_and(|style| style.underline), |element| {
            element.underline()
        })
        .when(style.is_some_and(|style| style.strikethrough), |element| {
            element.line_through()
        })
        .child(SharedString::from(text.to_string()))
}

fn render_color(color: TerminalColor) -> gpui::Rgba {
    rgb((u32::from(color.r) << 16) | (u32::from(color.g) << 8) | u32::from(color.b))
}
