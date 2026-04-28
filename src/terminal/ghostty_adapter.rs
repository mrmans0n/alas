//! Ghostty terminal adapter boundary.
//!
//! The GPUI application model should depend on [`TerminalBackend`] and
//! [`TerminalBackendSession`] instead of libghostty-specific types. The real
//! libghostty-rs integration belongs behind this module boundary.

use super::CommandSpec;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalBackendSession {
    pub backend_id: u64,
}

pub trait TerminalBackend {
    fn start(&mut self, command: CommandSpec) -> anyhow::Result<TerminalBackendSession>;
}

#[derive(Debug, Default)]
pub struct GhosttyTerminalBackend {
    next_id: u64,
}

impl GhosttyTerminalBackend {
    pub fn new() -> Self {
        Self::default()
    }
}

impl TerminalBackend for GhosttyTerminalBackend {
    fn start(&mut self, _command: CommandSpec) -> anyhow::Result<TerminalBackendSession> {
        // Placeholder until real libghostty-rs process/PTY integration is added.
        // Keep libghostty types contained in this adapter so the GPUI/app model
        // depends only on the TerminalBackend contract.
        self.next_id += 1;
        Ok(TerminalBackendSession {
            backend_id: self.next_id,
        })
    }
}
