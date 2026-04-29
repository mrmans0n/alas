use crate::terminal::{
    GhosttyCellStyle, GhosttyRenderFrame, TerminalColor, TerminalCursorShape, TerminalMetrics,
    background_runs, text_runs,
};

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
            background_runs(row, frame.default_background)
                .into_iter()
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

#[cfg(test)]
mod tests {
    use crate::terminal::{
        GhosttyCellStyle, GhosttyRenderCell, GhosttyRenderCursor, GhosttyRenderFrame,
        GhosttyRenderRow, TerminalColor, TerminalCursorShape, TerminalMetrics,
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
    fn paint_plan_starts_with_full_background() {
        let frame = GhosttyRenderFrame {
            cols: 2,
            rows: 1,
            default_foreground: TerminalColor::rgb(255, 255, 255),
            default_background: TerminalColor::rgb(1, 2, 3),
            cursor: None,
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
            Some(TerminalPaintCommand::FillBackground { .. })
        ));
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
