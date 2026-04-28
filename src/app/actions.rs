use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AppAction {
    AddRepository(PathBuf),
    RemoveRepository(String),
    SelectWorktree {
        repo_id: String,
        path: PathBuf,
    },
    ArchiveWorktree {
        repo_id: String,
        path: PathBuf,
    },
    UnarchiveWorktree {
        repo_id: String,
        path: PathBuf,
    },
    ShowArchived {
        repo_id: String,
        show: bool,
    },
    CreateWorktree {
        repo_id: String,
        base_ref: String,
        branch_name: String,
        target_path: PathBuf,
    },
    RemoveWorktree {
        repo_id: String,
        path: PathBuf,
    },
    PruneWorktrees {
        repo_id: String,
    },
}
