use std::path::PathBuf;

use crate::git::{WorktreeInfo, WorktreeKind};

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct AlasModel {
    repositories: Vec<RepositoryNode>,
    selected: Option<SelectedWorktree>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RepositoryNode {
    pub id: String,
    pub name: String,
    pub path: PathBuf,
    pub worktrees: Vec<WorktreeNode>,
    pub show_archived: bool,
    pub unavailable: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorktreeNode {
    pub path: PathBuf,
    pub branch: Option<String>,
    pub head: Option<String>,
    pub kind: WorktreeKind,
    pub archived: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SelectedWorktree {
    pub repo_id: String,
    pub path: PathBuf,
}

impl WorktreeNode {
    pub fn from_info(info: WorktreeInfo, archived: bool) -> Self {
        Self {
            path: info.path,
            branch: info.branch,
            head: info.head,
            kind: info.kind,
            archived,
        }
    }
}

impl AlasModel {
    pub fn set_repositories(&mut self, repositories: Vec<RepositoryNode>) {
        self.repositories = repositories;
    }

    pub fn repositories(&self) -> &[RepositoryNode] {
        &self.repositories
    }

    pub fn select_worktree(&mut self, repo_id: impl Into<String>, path: impl Into<PathBuf>) {
        self.selected = Some(SelectedWorktree {
            repo_id: repo_id.into(),
            path: path.into(),
        });
    }

    pub fn selected_worktree(&self) -> Option<&SelectedWorktree> {
        self.selected.as_ref()
    }

    pub fn set_show_archived(&mut self, repo_id: &str, show: bool) {
        if let Some(repository) = self
            .repositories
            .iter_mut()
            .find(|repository| repository.id == repo_id)
        {
            repository.show_archived = show;
        }
    }

    pub fn visible_worktrees(&self, repo_id: &str) -> Option<Vec<&WorktreeNode>> {
        let repository = self
            .repositories
            .iter()
            .find(|repository| repository.id == repo_id)?;

        Some(
            repository
                .worktrees
                .iter()
                .filter(|worktree| repository.show_archived || !worktree.archived)
                .collect(),
        )
    }
}
