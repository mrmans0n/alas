use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::terminal::{CommandSpec, TerminalBackendSession};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TerminalTabId(pub u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TerminalTabKind {
    Shell,
    Command,
    Agent,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TerminalTabStatus {
    NotStarted,
    Running,
    Exited(Option<i32>),
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct WorktreeKey {
    pub repo_id: String,
    pub path: PathBuf,
}

impl WorktreeKey {
    pub fn new(repo_id: impl Into<String>, path: PathBuf) -> Self {
        Self {
            repo_id: repo_id.into(),
            path,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalTab {
    pub id: TerminalTabId,
    pub name: String,
    pub kind: TerminalTabKind,
    pub command: CommandSpec,
    pub backend_session: Option<TerminalBackendSession>,
    pub status: TerminalTabStatus,
    pub scroll_offset_rows: usize,
}

#[derive(Debug, Default)]
pub struct WorkspaceSession {
    next_tab_id: u64,
    tabs: HashMap<WorktreeKey, Vec<TerminalTab>>,
    active_tabs: HashMap<WorktreeKey, TerminalTabId>,
}

impl WorkspaceSession {
    pub fn ensure_default_terminal_tab(
        &mut self,
        repo_id: impl Into<String>,
        path: PathBuf,
        command: CommandSpec,
    ) -> TerminalTabId {
        let key = WorktreeKey::new(repo_id, path);
        if let Some(active) = self.active_tabs.get(&key).copied() {
            return active;
        }
        if let Some(existing) = self.tabs.get(&key).and_then(|tabs| tabs.first()) {
            self.active_tabs.insert(key, existing.id);
            return existing.id;
        }

        self.create_terminal_tab_for_key(key, "Shell".to_string(), TerminalTabKind::Shell, command)
    }

    pub fn create_terminal_tab(
        &mut self,
        repo_id: impl Into<String>,
        path: PathBuf,
        name: String,
        kind: TerminalTabKind,
        command: CommandSpec,
    ) -> TerminalTabId {
        let key = WorktreeKey::new(repo_id, path);
        self.create_terminal_tab_for_key(key, name, kind, command)
    }

    fn create_terminal_tab_for_key(
        &mut self,
        key: WorktreeKey,
        name: String,
        kind: TerminalTabKind,
        command: CommandSpec,
    ) -> TerminalTabId {
        self.next_tab_id += 1;
        let id = TerminalTabId(self.next_tab_id);
        let tab = TerminalTab {
            id,
            name,
            kind,
            command,
            backend_session: None,
            status: TerminalTabStatus::NotStarted,
            scroll_offset_rows: 0,
        };

        self.tabs.entry(key.clone()).or_default().push(tab);
        self.active_tabs.insert(key, id);
        id
    }

    pub fn tabs_for_worktree(&self, repo_id: impl Into<String>, path: &Path) -> &[TerminalTab] {
        let key = WorktreeKey::new(repo_id, path.to_path_buf());
        self.tabs.get(&key).map_or(&[], Vec::as_slice)
    }

    pub fn active_tab(&self, repo_id: impl Into<String>, path: &Path) -> Option<&TerminalTab> {
        let key = WorktreeKey::new(repo_id, path.to_path_buf());
        let active_id = self.active_tabs.get(&key)?;
        self.tabs.get(&key)?.iter().find(|tab| tab.id == *active_id)
    }

    pub fn set_active_tab(
        &mut self,
        repo_id: impl Into<String>,
        path: &Path,
        tab_id: TerminalTabId,
    ) -> anyhow::Result<()> {
        let key = WorktreeKey::new(repo_id, path.to_path_buf());
        let has_tab = self
            .tabs
            .get(&key)
            .is_some_and(|tabs| tabs.iter().any(|tab| tab.id == tab_id));

        if !has_tab {
            anyhow::bail!(
                "unknown terminal tab {:?} for repo '{}' worktree {}",
                tab_id,
                key.repo_id,
                key.path.display()
            );
        }

        self.active_tabs.insert(key, tab_id);
        Ok(())
    }
}
