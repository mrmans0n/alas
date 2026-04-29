use super::TerminalSize;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalColor {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl TerminalColor {
    pub fn rgb(r: u8, g: u8, b: u8) -> Self {
        Self { r, g, b }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TerminalCellStyle {
    pub foreground: Option<TerminalColor>,
    pub background: Option<TerminalColor>,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub inverse: bool,
    pub strikethrough: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalCell {
    pub text: String,
    pub style: TerminalCellStyle,
}

impl TerminalCell {
    pub fn new(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            style: TerminalCellStyle::default(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalRow {
    pub cells: Vec<TerminalCell>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalCursorShape {
    Block,
    Bar,
    Underline,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalCursor {
    pub col: u16,
    pub row: u16,
    pub visible: bool,
    pub shape: TerminalCursorShape,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalStatus {
    Running,
    Exited(Option<i32>),
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalViewport {
    pub scroll_offset_rows: usize,
    pub visible_rows: u16,
}

impl TerminalViewport {
    pub fn visible(visible_rows: u16) -> Self {
        Self {
            scroll_offset_rows: 0,
            visible_rows,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalScreenMode {
    Main,
    Alternate,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalGridSnapshot {
    pub size: TerminalSize,
    pub rows: Vec<TerminalRow>,
    pub cursor: Option<TerminalCursor>,
    pub status: TerminalStatus,
    pub viewport: TerminalViewport,
    pub scrollback_rows: usize,
    pub screen_mode: TerminalScreenMode,
}

impl TerminalGridSnapshot {
    pub fn plain_lines(&self) -> Vec<String> {
        self.rows
            .iter()
            .map(|row| row.cells.iter().map(|cell| cell.text.as_str()).collect())
            .collect()
    }

    pub fn exited(&self) -> bool {
        matches!(self.status, TerminalStatus::Exited(_))
    }

    pub fn exit_status(&self) -> Option<i32> {
        match self.status {
            TerminalStatus::Exited(status) => status,
            TerminalStatus::Running | TerminalStatus::Failed => None,
        }
    }
}
