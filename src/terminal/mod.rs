pub mod ghostty_adapter;
pub mod ghostty_input;
pub mod ghostty_render;
pub mod grid;
pub mod harness;
pub mod input;
pub mod session;
pub mod terminal_metrics;

pub use ghostty_adapter::{
    GhosttyTerminalBackend, TerminalBackend, TerminalBackendSession, TerminalSize,
};
pub use ghostty_input::{PasteMode, TerminalKeyInput, paste_bytes};
pub use ghostty_render::*;
pub use grid::{
    TerminalCell, TerminalCellStyle, TerminalColor, TerminalCursor, TerminalCursorShape,
    TerminalGridSnapshot, TerminalRow, TerminalScreenMode, TerminalStatus, TerminalViewport,
};
pub use harness::{HarnessKind, HarnessState};
pub use input::terminal_input_bytes;
pub use session::{
    CommandSpec, TerminalHandle, TerminalSessionId, TerminalSessionRef, TerminalSessionRegistry,
    default_shell_program,
};
pub use terminal_metrics::TerminalMetrics;
