//! Ghostty terminal adapter boundary.
//!
//! The GPUI application model should depend on [`TerminalBackend`] and
//! [`TerminalBackendSession`] instead of libghostty-specific types. The real
//! libghostty-rs integration belongs behind this module boundary.

use std::collections::HashMap;

use super::CommandSpec;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalBackendSession {
    pub backend_id: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalSize {
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalGridSnapshot {
    pub size: TerminalSize,
    pub lines: Vec<String>,
    pub cursor: Option<(u16, u16)>,
    pub exited: bool,
    pub exit_status: Option<i32>,
}

pub trait TerminalBackend {
    fn start(&mut self, command: CommandSpec) -> anyhow::Result<TerminalBackendSession>;
    fn write_input(&mut self, session: TerminalBackendSession, bytes: &[u8]) -> anyhow::Result<()>;
    fn resize(&mut self, session: TerminalBackendSession, size: TerminalSize)
    -> anyhow::Result<()>;
    fn snapshot(&mut self, session: TerminalBackendSession)
    -> anyhow::Result<TerminalGridSnapshot>;
    fn has_exited(&mut self, session: TerminalBackendSession) -> anyhow::Result<bool>;
    fn restart(
        &mut self,
        session: TerminalBackendSession,
    ) -> anyhow::Result<TerminalBackendSession>;
}

#[derive(Debug, Clone)]
struct GhosttySessionState {
    command: CommandSpec,
    size: TerminalSize,
    input: Vec<u8>,
    exited: bool,
    exit_status: Option<i32>,
}

#[derive(Debug, Default)]
pub struct GhosttyTerminalBackend {
    next_id: u64,
    sessions: HashMap<u64, GhosttySessionState>,
}

impl GhosttyTerminalBackend {
    pub fn new() -> Self {
        Self::default()
    }
}

impl TerminalBackend for GhosttyTerminalBackend {
    fn start(&mut self, command: CommandSpec) -> anyhow::Result<TerminalBackendSession> {
        // Placeholder until real libghostty-rs process/PTY integration is added.
        // Keep libghostty types contained in this adapter so the GPUI/app model
        // depends only on the TerminalBackend contract.
        self.next_id += 1;
        let session = TerminalBackendSession {
            backend_id: self.next_id,
        };
        self.sessions.insert(
            session.backend_id,
            GhosttySessionState {
                command,
                size: TerminalSize { cols: 80, rows: 24 },
                input: Vec::new(),
                exited: false,
                exit_status: None,
            },
        );
        Ok(session)
    }

    fn write_input(&mut self, session: TerminalBackendSession, bytes: &[u8]) -> anyhow::Result<()> {
        let state = self.sessions.get_mut(&session.backend_id).ok_or_else(|| {
            anyhow::anyhow!("unknown terminal backend session {}", session.backend_id)
        })?;
        state.input.extend_from_slice(bytes);
        Ok(())
    }

    fn resize(
        &mut self,
        session: TerminalBackendSession,
        size: TerminalSize,
    ) -> anyhow::Result<()> {
        let state = self.sessions.get_mut(&session.backend_id).ok_or_else(|| {
            anyhow::anyhow!("unknown terminal backend session {}", session.backend_id)
        })?;
        state.size = size;
        Ok(())
    }

    fn snapshot(
        &mut self,
        session: TerminalBackendSession,
    ) -> anyhow::Result<TerminalGridSnapshot> {
        let state = self.sessions.get(&session.backend_id).ok_or_else(|| {
            anyhow::anyhow!("unknown terminal backend session {}", session.backend_id)
        })?;
        Ok(TerminalGridSnapshot {
            size: state.size,
            lines: Vec::new(),
            cursor: None,
            exited: state.exited,
            exit_status: state.exit_status,
        })
    }

    fn has_exited(&mut self, session: TerminalBackendSession) -> anyhow::Result<bool> {
        let state = self.sessions.get(&session.backend_id).ok_or_else(|| {
            anyhow::anyhow!("unknown terminal backend session {}", session.backend_id)
        })?;
        Ok(state.exited)
    }

    fn restart(
        &mut self,
        session: TerminalBackendSession,
    ) -> anyhow::Result<TerminalBackendSession> {
        let command = self
            .sessions
            .get(&session.backend_id)
            .ok_or_else(|| {
                anyhow::anyhow!("unknown terminal backend session {}", session.backend_id)
            })?
            .command
            .clone();
        self.start(command)
    }
}
