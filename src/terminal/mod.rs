pub mod ghostty_adapter;
pub mod session;

pub use session::{
    CommandSpec, TerminalHandle, TerminalSessionId, TerminalSessionRef, TerminalSessionRegistry,
};
