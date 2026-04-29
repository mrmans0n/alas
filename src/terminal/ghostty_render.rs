use super::grid::{TerminalColor, TerminalCursorShape, TerminalScreenMode, TerminalViewport};

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
    pub fn narrow(text: impl Into<String>, style: GhosttyCellStyle) -> Self {
        Self {
            text: text.into(),
            style,
            width: GhosttyCellWidth::Narrow,
        }
    }

    pub fn wide(text: impl Into<String>, style: GhosttyCellStyle) -> Self {
        Self {
            text: text.into(),
            style,
            width: GhosttyCellWidth::Wide,
        }
    }

    pub fn spacer_tail(style: GhosttyCellStyle) -> Self {
        Self {
            text: String::new(),
            style,
            width: GhosttyCellWidth::SpacerTail,
        }
    }

    pub fn empty(style: GhosttyCellStyle) -> Self {
        Self {
            text: String::new(),
            style,
            width: GhosttyCellWidth::Narrow,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GhosttyRenderRow {
    pub cells: Vec<GhosttyRenderCell>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GhosttyRenderFrame {
    pub cols: u16,
    pub rows: u16,
    pub default_foreground: TerminalColor,
    pub default_background: TerminalColor,
    pub cursor: Option<GhosttyRenderCursor>,
    pub rows_data: Vec<GhosttyRenderRow>,
    pub viewport: TerminalViewport,
    pub scrollback_rows: usize,
    pub screen_mode: TerminalScreenMode,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GhosttyRenderCursor {
    pub col: u16,
    pub row: u16,
    pub visible: bool,
    pub shape: TerminalCursorShape,
    pub color: Option<TerminalColor>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BackgroundRun {
    pub col: usize,
    pub cell_count: usize,
    pub background: TerminalColor,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TextRun {
    pub col: usize,
    pub cell_count: usize,
    pub text: String,
    pub style: GhosttyCellStyle,
}

pub fn background_runs(
    row: &GhosttyRenderRow,
    default_background: TerminalColor,
) -> Vec<BackgroundRun> {
    background_runs_with_defaults(row, default_background, default_background)
}

pub fn background_runs_with_defaults(
    row: &GhosttyRenderRow,
    default_foreground: TerminalColor,
    default_background: TerminalColor,
) -> Vec<BackgroundRun> {
    let mut runs: Vec<BackgroundRun> = Vec::new();

    for (col, cell) in row.cells.iter().enumerate() {
        let background = effective_background(&cell.style, default_foreground, default_background);
        if let Some(last) = runs.last_mut() {
            if last.background == background {
                last.cell_count += 1;
                continue;
            }
        }

        runs.push(BackgroundRun {
            col,
            cell_count: 1,
            background,
        });
    }

    runs
}

pub fn text_runs(row: &GhosttyRenderRow) -> Vec<TextRun> {
    let mut runs: Vec<TextRun> = Vec::new();
    let mut last_run_mergeable = false;

    for (col, cell) in row.cells.iter().enumerate() {
        match cell.width {
            GhosttyCellWidth::Narrow if !cell.text.is_empty() => {
                if last_run_mergeable {
                    if let Some(last) = runs.last_mut() {
                        if last.style == cell.style && last.col + last.cell_count == col {
                            last.cell_count += 1;
                            last.text.push_str(&cell.text);
                            continue;
                        }
                    }
                }

                runs.push(TextRun {
                    col,
                    cell_count: 1,
                    text: cell.text.clone(),
                    style: cell.style.clone(),
                });
                last_run_mergeable = true;
            }
            GhosttyCellWidth::Wide if !cell.text.is_empty() => {
                runs.push(TextRun {
                    col,
                    cell_count: 2,
                    text: cell.text.clone(),
                    style: cell.style.clone(),
                });
                last_run_mergeable = false;
            }
            _ => {
                last_run_mergeable = false;
            }
        }
    }

    runs
}

pub fn effective_background(
    style: &GhosttyCellStyle,
    default_foreground: TerminalColor,
    default_background: TerminalColor,
) -> TerminalColor {
    if style.inverse {
        style.foreground.unwrap_or(default_foreground)
    } else {
        style.background.unwrap_or(default_background)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn style_with_background(background: TerminalColor) -> GhosttyCellStyle {
        GhosttyCellStyle {
            background: Some(background),
            ..GhosttyCellStyle::default()
        }
    }

    #[test]
    fn cell_constructors_preserve_styles() {
        let styled = style_with_background(TerminalColor::rgb(1, 2, 3));

        assert_eq!(
            GhosttyRenderCell::narrow("a", styled.clone()),
            GhosttyRenderCell {
                text: "a".to_string(),
                style: styled.clone(),
                width: GhosttyCellWidth::Narrow,
            }
        );
        assert_eq!(
            GhosttyRenderCell::wide("表", styled.clone()),
            GhosttyRenderCell {
                text: "表".to_string(),
                style: styled.clone(),
                width: GhosttyCellWidth::Wide,
            }
        );
        assert_eq!(
            GhosttyRenderCell::spacer_tail(styled.clone()),
            GhosttyRenderCell {
                text: String::new(),
                style: styled.clone(),
                width: GhosttyCellWidth::SpacerTail,
            }
        );
        assert_eq!(
            GhosttyRenderCell::empty(styled.clone()),
            GhosttyRenderCell {
                text: String::new(),
                style: styled,
                width: GhosttyCellWidth::Narrow,
            }
        );
    }

    #[test]
    fn render_frame_cursor_is_optional() {
        let frame = GhosttyRenderFrame {
            cols: 2,
            rows: 1,
            default_foreground: TerminalColor::rgb(255, 255, 255),
            default_background: TerminalColor::rgb(0, 0, 0),
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

        assert_eq!(frame.cursor, None);
    }

    #[test]
    fn frame_rows_preserve_trailing_empty_styled_cells() {
        let row = GhosttyRenderRow {
            cells: vec![
                GhosttyRenderCell::narrow("x", GhosttyCellStyle::default()),
                GhosttyRenderCell::empty(GhosttyCellStyle {
                    background: Some(TerminalColor::rgb(9, 9, 9)),
                    ..Default::default()
                }),
            ],
        };
        assert_eq!(row.cells.len(), 2);
        assert_eq!(
            background_runs(&row, TerminalColor::rgb(0, 0, 0))
                .last()
                .unwrap()
                .col,
            1
        );
    }

    #[test]
    fn background_runs_cover_trailing_empty_cells() {
        let highlighted = TerminalColor::rgb(1, 2, 3);
        let row = GhosttyRenderRow {
            cells: vec![
                GhosttyRenderCell::narrow("a", GhosttyCellStyle::default()),
                GhosttyRenderCell::empty(style_with_background(highlighted)),
                GhosttyRenderCell::empty(style_with_background(highlighted)),
            ],
        };

        assert_eq!(
            background_runs(&row, TerminalColor::rgb(0, 0, 0)),
            vec![
                BackgroundRun {
                    col: 0,
                    cell_count: 1,
                    background: TerminalColor::rgb(0, 0, 0),
                },
                BackgroundRun {
                    col: 1,
                    cell_count: 2,
                    background: highlighted,
                },
            ]
        );
    }

    #[test]
    fn inverse_background_uses_default_foreground_when_foreground_is_unset() {
        let row = GhosttyRenderRow {
            cells: vec![GhosttyRenderCell::narrow(
                "x",
                GhosttyCellStyle {
                    inverse: true,
                    ..GhosttyCellStyle::default()
                },
            )],
        };

        let runs = background_runs_with_defaults(
            &row,
            TerminalColor::rgb(10, 20, 30),
            TerminalColor::rgb(0, 0, 0),
        );

        assert_eq!(runs[0].background, TerminalColor::rgb(10, 20, 30));
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

        assert_eq!(
            text_runs(&row),
            vec![
                TextRun {
                    col: 0,
                    cell_count: 2,
                    text: "表".to_string(),
                    style: GhosttyCellStyle::default(),
                },
                TextRun {
                    col: 2,
                    cell_count: 1,
                    text: "x".to_string(),
                    style: GhosttyCellStyle::default(),
                },
            ]
        );
    }
}
