use std::collections::HashMap;
use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct TerminalSessionId {
    pub repo_id: String,
    pub worktree_path: PathBuf,
}

impl TerminalSessionId {
    pub fn new(repo_id: impl Into<String>, worktree_path: PathBuf) -> Self {
        Self {
            repo_id: repo_id.into(),
            worktree_path,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandSpec {
    pub command: String,
    pub cwd: PathBuf,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TerminalHandle(pub u64);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalSessionRef {
    pub id: TerminalSessionId,
    pub handle: TerminalHandle,
    pub command: CommandSpec,
}

#[derive(Debug, Default)]
pub struct TerminalSessionRegistry {
    next_handle: u64,
    sessions: HashMap<TerminalSessionId, TerminalSessionRef>,
}

impl TerminalSessionRegistry {
    pub fn get_or_create(
        &mut self,
        id: TerminalSessionId,
        command: CommandSpec,
    ) -> TerminalSessionRef {
        if let Some(session) = self.sessions.get(&id) {
            return session.clone();
        }

        self.next_handle += 1;
        let session = TerminalSessionRef {
            id: id.clone(),
            handle: TerminalHandle(self.next_handle),
            command,
        };
        self.sessions.insert(id, session.clone());
        session
    }
}
