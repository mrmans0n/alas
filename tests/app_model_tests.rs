use std::path::PathBuf;

use alas::app::{AlasModel, RepositoryNode, WorktreeNode};
use alas::config::{AppConfig, AppRepository};
use alas::git::{WorktreeInfo, WorktreeKind};

fn worktree(path: &str, kind: WorktreeKind) -> WorktreeInfo {
    WorktreeInfo {
        path: PathBuf::from(path),
        branch: Some(format!("branch-{path}")),
        head: Some("abc123".to_string()),
        kind,
    }
}

#[test]
fn selecting_worktree_updates_selection() {
    let mut model = AlasModel::default();
    let path = PathBuf::from("/repo/feature");

    model.select_worktree("repo-1", path.clone());

    let selected = model.selected_worktree().expect("selected worktree");
    assert_eq!(selected.repo_id, "repo-1");
    assert_eq!(selected.path, path);
}

#[test]
fn model_builds_repository_nodes_with_archived_flags() {
    let mut config = AppConfig::default();
    config.repositories.push(AppRepository {
        id: "repo-1".to_string(),
        path: PathBuf::from("/repo"),
        name: Some("repo".to_string()),
    });
    config
        .archived_worktrees
        .insert("repo-1".to_string(), vec![PathBuf::from("/repo/old")]);

    let nodes = AlasModel::repository_nodes_from_discovery(
        &config,
        "repo-1",
        vec![
            worktree("/repo", WorktreeKind::Main),
            worktree("/repo/old", WorktreeKind::Linked),
        ],
    );

    assert_eq!(nodes.len(), 1);
    assert!(!nodes[0].worktrees[0].archived);
    assert!(nodes[0].worktrees[1].archived);
}

#[test]
fn archived_worktrees_are_hidden_until_repo_shows_archived() {
    let main = WorktreeNode::from_info(worktree("/repo", WorktreeKind::Main), false);
    let archived = WorktreeNode::from_info(worktree("/repo/archived", WorktreeKind::Linked), true);
    let mut model = AlasModel::default();

    model.set_repositories(vec![RepositoryNode {
        id: "repo-1".to_string(),
        name: "Repo One".to_string(),
        path: PathBuf::from("/repo"),
        worktrees: vec![main.clone(), archived.clone()],
        show_archived: false,
        unavailable: false,
    }]);

    let visible = model
        .visible_worktrees("repo-1")
        .expect("repository visible worktrees");
    assert_eq!(visible, vec![&main]);

    model.set_show_archived("repo-1", true);

    let visible = model
        .visible_worktrees("repo-1")
        .expect("repository visible worktrees");
    assert_eq!(visible, vec![&main, &archived]);
}
