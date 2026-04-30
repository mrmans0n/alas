use crate::{
    terminal::{
        GhosttyCellStyle, GhosttyRenderFrame, TerminalColor, TerminalCursorShape, TerminalMetrics,
        background_runs_with_defaults, effective_background, text_runs,
    },
    ui::terminal_view::{TERMINAL_CANVAS_HORIZONTAL_PADDING_PX, TERMINAL_FONT_FAMILY},
};
use gpui::{
    App, Bounds, Element, ElementId, GlobalElementId, InspectorElementId, IntoElement, LayoutId,
    Pixels, SharedString, StrikethroughStyle, Style, TextRun, UnderlineStyle, Window, fill, font,
    point, px, relative, rgb, size,
};

const TERMINAL_METRICS_SAMPLE: &str = "MMMMMMMMMM";

pub fn measure_terminal_metrics(
    window: &mut gpui::Window,
    font_family: &str,
    font_size_px: f32,
) -> TerminalMetrics {
    let text_run = TextRun {
        len: TERMINAL_METRICS_SAMPLE.len(),
        font: font(font_family.to_owned()),
        color: gpui::Hsla::from(rgb(0xffffff)),
        background_color: None,
        underline: None,
        strikethrough: None,
    };
    let layout = window.text_system().layout_line(
        TERMINAL_METRICS_SAMPLE,
        px(font_size_px),
        &[text_run],
        None,
    );
    TerminalMetrics::measured_or_fallback(TerminalMetrics::from_measured(
        f32::from(layout.width) / TERMINAL_METRICS_SAMPLE.chars().count() as f32,
        f32::from(layout.ascent + layout.descent),
        font_size_px,
    ))
}

#[derive(Debug, Clone, PartialEq)]
pub struct TerminalPaintPlan {
    pub commands: Vec<TerminalPaintCommand>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum TerminalPaintCommand {
    FillBackground {
        color: TerminalColor,
        cols: u16,
        rows: u16,
    },
    BackgroundRun {
        row: usize,
        col: usize,
        cell_count: usize,
        color: TerminalColor,
    },
    TextRun {
        row: usize,
        col: usize,
        cell_count: usize,
        text: String,
        style: GhosttyCellStyle,
    },
    Cursor {
        row: u16,
        col: u16,
        shape: TerminalCursorShape,
        color: Option<TerminalColor>,
    },
}

pub fn terminal_paint_plan(
    frame: &GhosttyRenderFrame,
    _metrics: TerminalMetrics,
) -> TerminalPaintPlan {
    let mut commands = Vec::new();

    commands.push(TerminalPaintCommand::FillBackground {
        color: frame.default_background,
        cols: frame.cols,
        rows: frame.rows,
    });

    for (row_index, row) in frame.rows_data.iter().enumerate() {
        commands.extend(
            background_runs_with_defaults(row, frame.default_foreground, frame.default_background)
                .into_iter()
                .filter(|run| run.background != frame.default_background)
                .map(|run| TerminalPaintCommand::BackgroundRun {
                    row: row_index,
                    col: run.col,
                    cell_count: run.cell_count,
                    color: run.background,
                }),
        );

        commands.extend(
            text_runs(row)
                .into_iter()
                .map(|run| TerminalPaintCommand::TextRun {
                    row: row_index,
                    col: run.col,
                    cell_count: run.cell_count,
                    text: run.text,
                    style: run.style,
                }),
        );
    }

    if let Some(cursor) = frame.cursor.as_ref().filter(|cursor| cursor.visible) {
        commands.push(TerminalPaintCommand::Cursor {
            row: cursor.row,
            col: cursor.col,
            shape: cursor.shape,
            color: cursor.color,
        });
    }

    TerminalPaintPlan { commands }
}

pub fn render_terminal_canvas(
    frame: GhosttyRenderFrame,
    metrics: TerminalMetrics,
) -> impl IntoElement {
    TerminalCanvas { frame, metrics }
}

struct TerminalCanvas {
    frame: GhosttyRenderFrame,
    metrics: TerminalMetrics,
}

impl IntoElement for TerminalCanvas {
    type Element = Self;

    fn into_element(self) -> Self::Element {
        self
    }
}

impl Element for TerminalCanvas {
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
        window: &mut Window,
        cx: &mut App,
    ) {
        let plan = terminal_paint_plan(&self.frame, self.metrics);
        let metrics = self.metrics;
        let default_foreground = self.frame.default_foreground;
        let default_background = self.frame.default_background;

        window.paint_layer(bounds, |window| {
            for command in plan.commands {
                match command {
                    TerminalPaintCommand::FillBackground { color, .. } => {
                        window.paint_quad(fill(bounds, render_color(color)));
                    }
                    TerminalPaintCommand::BackgroundRun {
                        row,
                        col,
                        cell_count,
                        color,
                    } => {
                        paint_terminal_rect(
                            window,
                            bounds,
                            metrics,
                            row,
                            col,
                            cell_count,
                            1,
                            render_color(color),
                        );
                    }
                    TerminalPaintCommand::TextRun {
                        row,
                        col,
                        text,
                        style,
                        ..
                    } => {
                        paint_terminal_text_run(
                            window,
                            cx,
                            bounds,
                            metrics,
                            row,
                            col,
                            text,
                            style,
                            default_foreground,
                            default_background,
                        );
                    }
                    TerminalPaintCommand::Cursor {
                        row,
                        col,
                        shape,
                        color,
                    } => {
                        paint_terminal_cursor(
                            window,
                            cx,
                            bounds,
                            metrics,
                            &self.frame,
                            usize::from(row),
                            usize::from(col),
                            shape,
                            color.unwrap_or(default_foreground),
                        );
                    }
                }
            }
        });
    }
}

#[allow(clippy::too_many_arguments)]
fn paint_terminal_rect(
    window: &mut Window,
    bounds: Bounds<Pixels>,
    metrics: TerminalMetrics,
    row: usize,
    col: usize,
    cell_count: usize,
    row_count: usize,
    color: gpui::Rgba,
) {
    window.paint_quad(fill(
        Bounds::new(
            point(
                terminal_paint_x_origin(bounds.origin.x, col, metrics),
                bounds.origin.y + px(row as f32 * metrics.cell_height_px),
            ),
            size(
                px(cell_count as f32 * metrics.cell_width_px),
                px(row_count as f32 * metrics.cell_height_px),
            ),
        ),
        color,
    ));
}

#[allow(clippy::too_many_arguments)]
fn paint_terminal_text_run(
    window: &mut Window,
    cx: &mut App,
    bounds: Bounds<Pixels>,
    metrics: TerminalMetrics,
    row: usize,
    col: usize,
    text: String,
    style: GhosttyCellStyle,
    default_foreground: TerminalColor,
    default_background: TerminalColor,
) {
    if text.is_empty() {
        return;
    }

    let text_origin = point(
        terminal_paint_x_origin(bounds.origin.x, col, metrics),
        bounds.origin.y + px(row as f32 * metrics.cell_height_px),
    );
    let foreground = effective_foreground(&style, default_foreground, default_background);
    let color = gpui::Hsla::from(render_color(foreground));
    let mut text_font = font(TERMINAL_FONT_FAMILY);
    if style.bold {
        text_font = text_font.bold();
    }
    if style.italic {
        text_font = text_font.italic();
    }

    let text_run = TextRun {
        len: text.len(),
        font: text_font,
        color,
        background_color: None,
        underline: style.underline.then_some(UnderlineStyle {
            color: Some(color),
            thickness: px(1.0),
            wavy: false,
        }),
        strikethrough: style.strikethrough.then_some(StrikethroughStyle {
            color: Some(color),
            thickness: px(1.0),
        }),
    };
    let shaped_line = window.text_system().shape_line(
        SharedString::from(text),
        px(metrics.font_size_px),
        &[text_run],
        None,
    );
    let _ = shaped_line.paint(text_origin, px(metrics.cell_height_px), window, cx);
}

#[allow(clippy::too_many_arguments)]
fn paint_terminal_cursor(
    window: &mut Window,
    cx: &mut App,
    bounds: Bounds<Pixels>,
    metrics: TerminalMetrics,
    frame: &GhosttyRenderFrame,
    row: usize,
    col: usize,
    shape: TerminalCursorShape,
    color: TerminalColor,
) {
    let origin = point(
        terminal_paint_x_origin(bounds.origin.x, col, metrics),
        bounds.origin.y + px(row as f32 * metrics.cell_height_px),
    );
    let cell_width = px(metrics.cell_width_px);
    let cell_height = px(metrics.cell_height_px);
    let thickness = px(2.0).min(cell_width).min(cell_height);
    let (origin, rect_size) = match shape {
        TerminalCursorShape::Block => (origin, size(cell_width, cell_height)),
        TerminalCursorShape::Bar => (origin, size(thickness, cell_height)),
        TerminalCursorShape::Underline => (
            point(origin.x, origin.y + cell_height - thickness),
            size(cell_width, thickness),
        ),
    };

    window.paint_quad(fill(Bounds::new(origin, rect_size), render_color(color)));

    if shape == TerminalCursorShape::Block {
        paint_cursor_cell_text(window, cx, bounds, metrics, frame, row, col);
    }
}

fn paint_cursor_cell_text(
    window: &mut Window,
    cx: &mut App,
    bounds: Bounds<Pixels>,
    metrics: TerminalMetrics,
    frame: &GhosttyRenderFrame,
    row: usize,
    col: usize,
) {
    let Some(cell) = frame.rows_data.get(row).and_then(|row| row.cells.get(col)) else {
        return;
    };
    if cell.text.is_empty() {
        return;
    }

    let mut cursor_style = cell.style.clone();
    cursor_style.foreground = Some(effective_background(
        &cell.style,
        frame.default_foreground,
        frame.default_background,
    ));
    cursor_style.background = None;
    cursor_style.inverse = false;

    paint_terminal_text_run(
        window,
        cx,
        bounds,
        metrics,
        row,
        col,
        cell.text.clone(),
        cursor_style,
        frame.default_foreground,
        frame.default_background,
    );
}

fn terminal_paint_x_origin(origin_x: Pixels, col: usize, metrics: TerminalMetrics) -> Pixels {
    origin_x + px(col as f32 * metrics.cell_width_px + TERMINAL_CANVAS_HORIZONTAL_PADDING_PX)
}

fn effective_foreground(
    style: &GhosttyCellStyle,
    default_foreground: TerminalColor,
    default_background: TerminalColor,
) -> TerminalColor {
    if style.inverse {
        style.background.unwrap_or(default_background)
    } else {
        style.foreground.unwrap_or(default_foreground)
    }
}

fn render_color(color: TerminalColor) -> gpui::Rgba {
    rgb((u32::from(color.r) << 16) | (u32::from(color.g) << 8) | u32::from(color.b))
}

#[cfg(test)]
mod tests {
    use crate::terminal::{
        GhosttyCellStyle, GhosttyRenderCell, GhosttyRenderCursor, GhosttyRenderFrame,
        GhosttyRenderRow, TerminalColor, TerminalCursorShape, TerminalMetrics, TerminalScreenMode,
        TerminalViewport,
    };

    use super::*;

    fn empty_frame(cols: u16, rows: u16) -> GhosttyRenderFrame {
        let default_style = GhosttyCellStyle::default();
        GhosttyRenderFrame {
            cols,
            rows,
            default_foreground: TerminalColor::rgb(255, 255, 255),
            default_background: TerminalColor::rgb(0, 0, 0),
            cursor: None,
            viewport: TerminalViewport::visible(rows),
            scrollback_rows: 0,
            screen_mode: TerminalScreenMode::Main,
            rows_data: (0..rows)
                .map(|_| GhosttyRenderRow {
                    cells: (0..cols)
                        .map(|_| GhosttyRenderCell::empty(default_style.clone()))
                        .collect(),
                })
                .collect(),
        }
    }

    #[test]
    fn render_terminal_canvas_accepts_frame_and_metrics() {
        let frame = empty_frame(2, 1);
        let _element = render_terminal_canvas(frame, TerminalMetrics::fallback());
    }

    #[test]
    fn paint_plan_starts_with_full_background() {
        let frame = GhosttyRenderFrame {
            cols: 2,
            rows: 1,
            default_foreground: TerminalColor::rgb(255, 255, 255),
            default_background: TerminalColor::rgb(1, 2, 3),
            cursor: None,
            viewport: TerminalViewport::visible(1),
            scrollback_rows: 0,
            screen_mode: TerminalScreenMode::Main,
            rows_data: vec![GhosttyRenderRow {
                cells: vec![
                    GhosttyRenderCell::narrow("a", GhosttyCellStyle::default()),
                    GhosttyRenderCell::empty(GhosttyCellStyle::default()),
                ],
            }],
        };

        let plan = terminal_paint_plan(&frame, TerminalMetrics::fallback());

        assert!(matches!(
            plan.commands.first(),
            Some(TerminalPaintCommand::FillBackground {
                color,
                cols: 2,
                rows: 1,
            }) if *color == TerminalColor::rgb(1, 2, 3)
        ));
    }

    #[test]
    fn paint_plan_includes_text_runs() {
        let mut frame = empty_frame(2, 1);
        frame.rows_data[0].cells = vec![
            GhosttyRenderCell::narrow("a", GhosttyCellStyle::default()),
            GhosttyRenderCell::narrow("b", GhosttyCellStyle::default()),
        ];

        let plan = terminal_paint_plan(&frame, TerminalMetrics::fallback());

        assert!(plan.commands.iter().any(|command| matches!(
            command,
            TerminalPaintCommand::TextRun {
                row: 0,
                col: 0,
                cell_count: 2,
                text,
                ..
            } if text == "ab"
        )));
    }

    #[test]
    fn paint_plan_includes_non_default_background_runs_only() {
        let accent = TerminalColor::rgb(9, 8, 7);
        let mut frame = empty_frame(3, 1);
        frame.rows_data[0].cells[1] = GhosttyRenderCell::empty(GhosttyCellStyle {
            background: Some(accent),
            ..GhosttyCellStyle::default()
        });

        let plan = terminal_paint_plan(&frame, TerminalMetrics::fallback());

        assert_eq!(
            plan.commands
                .iter()
                .filter(|command| matches!(command, TerminalPaintCommand::BackgroundRun { .. }))
                .count(),
            1
        );
        assert!(plan.commands.iter().any(|command| matches!(
            command,
            TerminalPaintCommand::BackgroundRun {
                row: 0,
                col: 1,
                cell_count: 1,
                color
            } if *color == accent
        )));
    }

    #[test]
    fn paint_plan_includes_cursor_overlay() {
        let mut frame = empty_frame(2, 1);
        frame.cursor = Some(GhosttyRenderCursor {
            col: 1,
            row: 0,
            visible: true,
            shape: TerminalCursorShape::Block,
            color: None,
        });

        let plan = terminal_paint_plan(&frame, TerminalMetrics::fallback());

        assert!(
            plan.commands.iter().any(|command| matches!(
                command,
                TerminalPaintCommand::Cursor { col: 1, row: 0, .. }
            ))
        );
    }
}
