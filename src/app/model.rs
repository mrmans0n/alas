use std::path::PathBuf;

use crate::config::AppConfig;
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
    pub fn repository_nodes_from_discovery(
        config: &AppConfig,
        repo_id: &str,
        worktrees: Vec<WorktreeInfo>,
    ) -> Vec<RepositoryNode> {
        let Some(repository) = config
            .repositories
            .iter()
            .find(|repository| repository.id == repo_id)
        else {
            return Vec::new();
        };

        let archived_paths = config.archived_worktrees.get(repo_id);
        let worktrees = worktrees
            .into_iter()
            .map(|worktree| {
                let is_archived = archived_paths
                    .is_some_and(|paths| paths.iter().any(|path| path == &worktree.path));
                WorktreeNode::from_info(worktree, is_archived)
            })
            .collect();

        let name = repository.name.clone().unwrap_or_else(|| {
            repository
                .path
                .file_name()
                .and_then(|name| name.to_str())
                .filter(|name| !name.is_empty())
                .unwrap_or("repository")
                .to_string()
        });

        vec![RepositoryNode {
            id: repository.id.clone(),
            name,
            path: repository.path.clone(),
            worktrees,
            show_archived: false,
            unavailable: false,
        }]
    }

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

    pub fn clear_selection(&mut self) {
        self.selected = None;
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
