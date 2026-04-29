pub mod ghostty_adapter;
pub mod grid;
pub mod input;
pub mod session;
pub mod terminal_metrics;

pub use ghostty_adapter::{
    GhosttyTerminalBackend, TerminalBackend, TerminalBackendSession, TerminalSize,
};
pub use grid::{
    TerminalCell, TerminalCellStyle, TerminalColor, TerminalCursor, TerminalCursorShape,
    TerminalGridSnapshot, TerminalRow, TerminalScreenMode, TerminalStatus, TerminalViewport,
};
pub use input::terminal_input_bytes;
pub use session::{
    CommandSpec, TerminalHandle, TerminalSessionId, TerminalSessionRef, TerminalSessionRegistry,
    default_shell_program,
};
pub use terminal_metrics::TerminalMetrics;
