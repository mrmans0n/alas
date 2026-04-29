use std::collections::HashMap;
use std::path::PathBuf;

use crate::app::TerminalTabId;
use crate::terminal::TerminalBackendSession;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct TerminalSessionId {
    pub repo_id: String,
    pub worktree_path: PathBuf,
    pub tab_id: TerminalTabId,
}

impl TerminalSessionId {
    pub fn new(repo_id: impl Into<String>, worktree_path: PathBuf, tab_id: TerminalTabId) -> Self {
        Self {
            repo_id: repo_id.into(),
            worktree_path,
            tab_id,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandSpec {
    pub display: String,
    pub program: String,
    pub args: Vec<String>,
    pub cwd: PathBuf,
}

pub fn default_shell_program() -> String {
    std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string())
}

impl CommandSpec {
    pub fn shell_command(command: impl Into<String>, cwd: PathBuf) -> Self {
        let command = command.into();
        let shell = default_shell_program();
        Self {
            display: command.clone(),
            program: shell,
            args: vec!["-lc".to_string(), command],
            cwd,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TerminalHandle(pub u64);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalSessionRef {
    pub id: TerminalSessionId,
    pub handle: TerminalHandle,
    pub command: CommandSpec,
    pub backend_session: TerminalBackendSession,
}

#[derive(Debug, Default)]
pub struct TerminalSessionRegistry {
    next_handle: u64,
    sessions: HashMap<TerminalSessionId, TerminalSessionRef>,
}

impl TerminalSessionRegistry {
    pub fn get_or_start<B: crate::terminal::TerminalBackend>(
        &mut self,
        id: TerminalSessionId,
        command: CommandSpec,
        backend: &mut B,
    ) -> anyhow::Result<TerminalSessionRef> {
        if let Some(session) = self.sessions.get(&id) {
            return Ok(session.clone());
        }

        let backend_session = backend.start(command.clone())?;
        self.next_handle += 1;
        let session = TerminalSessionRef {
            id: id.clone(),
            handle: TerminalHandle(self.next_handle),
            command,
            backend_session,
        };
        self.sessions.insert(id, session.clone());
        Ok(session)
    }

    pub fn replace_backend_session(
        &mut self,
        id: &TerminalSessionId,
        backend_session: TerminalBackendSession,
    ) {
        if let Some(session) = self.sessions.get_mut(id) {
            session.backend_session = backend_session;
        }
    }
}
