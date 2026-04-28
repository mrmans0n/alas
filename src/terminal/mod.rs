pub mod ghostty_adapter;
pub mod session;

pub use ghostty_adapter::{GhosttyTerminalBackend, TerminalBackend, TerminalBackendSession};
pub use session::{
    CommandSpec, TerminalHandle, TerminalSessionId, TerminalSessionRef, TerminalSessionRegistry,
    default_shell_program,
};
