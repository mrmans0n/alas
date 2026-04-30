use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::app::WorkspaceTabId;
use crate::terminal::TerminalBackendSession;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct TerminalSessionId {
    pub repo_id: String,
    pub worktree_path: PathBuf,
    pub tab_id: WorkspaceTabId,
}

impl TerminalSessionId {
    pub fn new(repo_id: impl Into<String>, worktree_path: PathBuf, tab_id: WorkspaceTabId) -> Self {
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
    pub fn get(&self, id: &TerminalSessionId) -> Option<TerminalSessionRef> {
        self.sessions.get(id).cloned()
    }

    pub fn attach_existing(
        &mut self,
        id: TerminalSessionId,
        command: CommandSpec,
        backend_session: TerminalBackendSession,
    ) -> TerminalSessionRef {
        if let Some(session) = self.sessions.get(&id) {
            return session.clone();
        }

        self.next_handle += 1;
        let session = TerminalSessionRef {
            id: id.clone(),
            handle: TerminalHandle(self.next_handle),
            command,
            backend_session,
        };
        self.sessions.insert(id, session.clone());
        session
    }

    pub fn get_or_start<B: crate::terminal::TerminalBackend>(
        &mut self,
        id: TerminalSessionId,
        command: CommandSpec,
        backend: &mut B,
    ) -> anyhow::Result<TerminalSessionRef> {
        if let Some(session) = self.get(&id) {
            return Ok(session);
        }

        let backend_session = backend.start(command.clone())?;
        Ok(self.attach_existing(id, command, backend_session))
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

    pub fn remove_sessions_for_worktree(
        &mut self,
        repo_id: &str,
        worktree_path: &Path,
    ) -> Vec<TerminalSessionRef> {
        let ids: Vec<_> = self
            .sessions
            .keys()
            .filter(|id| id.repo_id == repo_id && id.worktree_path == worktree_path)
            .cloned()
            .collect();
        ids.into_iter()
            .filter_map(|id| self.sessions.remove(&id))
            .collect()
    }

    pub fn remove(&mut self, id: &TerminalSessionId) -> Option<TerminalSessionRef> {
        self.sessions.remove(id)
    }

    pub fn remove_sessions_for_repository(&mut self, repo_id: &str) -> Vec<TerminalSessionRef> {
        let ids: Vec<_> = self
            .sessions
            .keys()
            .filter(|id| id.repo_id == repo_id)
            .cloned()
            .collect();
        ids.into_iter()
            .filter_map(|id| self.sessions.remove(&id))
            .collect()
    }

    pub fn remove_all_sessions(&mut self) -> Vec<TerminalSessionRef> {
        self.sessions.drain().map(|(_, session)| session).collect()
    }
}
