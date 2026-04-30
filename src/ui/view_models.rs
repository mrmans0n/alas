use std::path::PathBuf;

use crate::app::{InspectorPaneState, RepositoryNode, SelectedWorktree, TerminalTabStatus};
use crate::git::WorktreeKind;
use crate::project::FileTreeNode;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum TreeExpansionKey {
    Repository(String),
    File(PathBuf),
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct TreeExpansionState {
    expanded: std::collections::HashSet<TreeExpansionKey>,
}

impl TreeExpansionState {
    pub fn is_expanded(&self, key: &TreeExpansionKey) -> bool {
        self.expanded.contains(key)
    }

    pub fn set_expanded(&mut self, key: TreeExpansionKey, expanded: bool) {
        if expanded {
            self.expanded.insert(key);
        } else {
            self.expanded.remove(&key);
        }
    }

    pub fn toggle(&mut self, key: TreeExpansionKey) {
        if self.expanded.contains(&key) {
            self.expanded.remove(&key);
        } else {
            self.expanded.insert(key);
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RepoTreeRow {
    Repository {
        id: String,
        name: String,
        unavailable: bool,
        expanded: bool,
    },
    Worktree {
        repo_id: String,
        path: PathBuf,
        label: String,
        selected: bool,
        archived: bool,
        kind: WorktreeKind,
    },
}

pub fn build_repo_tree_rows(
    repos: &[RepositoryNode],
    selected: Option<&SelectedWorktree>,
    expansion: &TreeExpansionState,
) -> Vec<RepoTreeRow> {
    let mut rows = Vec::new();
    for repo in repos {
        let expanded = expansion.is_expanded(&TreeExpansionKey::Repository(repo.id.clone()));
        rows.push(RepoTreeRow::Repository {
            id: repo.id.clone(),
            name: repo.name.clone(),
            unavailable: repo.unavailable,
            expanded,
        });
        if expanded {
            for worktree in &repo.worktrees {
                if !repo.show_archived && worktree.archived {
                    continue;
                }
                let is_selected =
                    selected.is_some_and(|s| s.repo_id == repo.id && s.path == worktree.path);
                let label = worktree.branch.clone().unwrap_or_else(|| {
                    worktree
                        .path
                        .file_name()
                        .and_then(|n| n.to_str())
                        .map(|s| s.to_string())
                        .unwrap_or_else(|| worktree.path.display().to_string())
                });
                rows.push(RepoTreeRow::Worktree {
                    repo_id: repo.id.clone(),
                    path: worktree.path.clone(),
                    label,
                    selected: is_selected,
                    archived: worktree.archived,
                    kind: worktree.kind.clone(),
                });
            }
        }
    }
    rows
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InspectorTreeRow {
    EmptyState,
    Context {
        branch_label: String,
        changed_count: Option<usize>,
    },
    Section {
        title: String,
    },
    Loading {
        section: &'static str,
    },
    Error {
        section: &'static str,
        message: String,
    },
    ChangedFile {
        status: String,
        path: String,
    },
    Clean {
        path: String,
    },
    File {
        depth: usize,
        name: String,
        path: PathBuf,
        is_dir: bool,
        expanded: bool,
    },
    Truncated {
        depth: usize,
    },
}

pub fn build_inspector_tree_rows(
    selected: Option<&SelectedWorktree>,
    state: &InspectorPaneState,
    file_expansion: &TreeExpansionState,
) -> Vec<InspectorTreeRow> {
    let mut rows = Vec::new();

    if selected.is_none() {
        rows.push(InspectorTreeRow::EmptyState);
        return rows;
    }

    // Changes section
    if let Some(ref changes) = state.changes {
        let branch_label = changes
            .branch
            .clone()
            .unwrap_or_else(|| "Detached HEAD".to_string());
        let changed_count = Some(changes.changed_files.len());
        rows.push(InspectorTreeRow::Context {
            branch_label,
            changed_count,
        });
        if changes.changed_files.is_empty() {
            rows.push(InspectorTreeRow::Clean {
                path: "No changes".to_string(),
            });
        } else {
            for file in &changes.changed_files {
                rows.push(InspectorTreeRow::ChangedFile {
                    status: file.status.clone(),
                    path: file.path.clone(),
                });
            }
        }
    } else if state.changes_error.is_some() {
        rows.push(InspectorTreeRow::Error {
            section: "Changes",
            message: state.changes_error.clone().unwrap(),
        });
    } else {
        rows.push(InspectorTreeRow::Loading { section: "Changes" });
    }

    // Files section
    if let Some(ref files) = state.files {
        rows.push(InspectorTreeRow::Section {
            title: "Files".to_string(),
        });
        let start = rows.len();
        flatten_file_tree(files, 0, file_expansion, &mut rows);
        if rows.len() == start {
            rows.push(InspectorTreeRow::Clean {
                path: "No files found".to_string(),
            });
        }
    } else if state.files_error.is_some() {
        rows.push(InspectorTreeRow::Error {
            section: "Files",
            message: state.files_error.clone().unwrap(),
        });
    } else {
        rows.push(InspectorTreeRow::Section {
            title: "Files".to_string(),
        });
        rows.push(InspectorTreeRow::Loading { section: "Files" });
    }

    rows
}

fn flatten_file_tree(
    node: &FileTreeNode,
    depth: usize,
    expansion: &TreeExpansionState,
    rows: &mut Vec<InspectorTreeRow>,
) {
    // Root node is not shown; its children are at depth 0.
    // If the root itself is truncated, surface that signal.
    if depth > 0 {
        let expanded =
            node.is_dir && expansion.is_expanded(&TreeExpansionKey::File(node.path.clone()));
        rows.push(InspectorTreeRow::File {
            depth: depth - 1,
            name: node.name.clone(),
            path: node.path.clone(),
            is_dir: node.is_dir,
            expanded,
        });
        if node.truncated {
            rows.push(InspectorTreeRow::Truncated { depth });
        }
        if expanded {
            for child in &node.children {
                flatten_file_tree(child, depth + 1, expansion, rows);
            }
        }
    } else {
        if node.truncated {
            rows.push(InspectorTreeRow::Truncated { depth: 0 });
        }
        for child in &node.children {
            flatten_file_tree(child, depth + 1, expansion, rows);
        }
    }
}

pub fn terminal_tab_overlay_visible(
    hovered: bool,
    terminal_focused: bool,
    tab_count: usize,
    status: Option<&TerminalTabStatus>,
    terminal_error: bool,
) -> bool {
    hovered
        || terminal_focused
        || tab_count > 1
        || terminal_error
        || status
            .is_some_and(|s| matches!(s, TerminalTabStatus::Exited(_) | TerminalTabStatus::Failed))
}
