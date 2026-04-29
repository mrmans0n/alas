use std::rc::Rc;

use crate::terminal::{TerminalCell, TerminalColor, TerminalGridSnapshot, TerminalSize};
use gpui::{
    App, Bounds, Element, ElementId, GlobalElementId, InspectorElementId, IntoElement, LayoutId,
    ParentElement, Pixels, SharedString, Style, Styled, Window, div, prelude::*, px, relative, rgb,
};

const TERMINAL_BACKGROUND: u32 = 0x111827;
const TERMINAL_FOREGROUND: u32 = 0xe5e7eb;
pub const CELL_WIDTH_PX: f32 = 8.0;
pub const CELL_HEIGHT_PX: f32 = 18.0;

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
