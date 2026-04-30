use std::path::PathBuf;

use alas::{
    app::{InspectorPaneState, RepositoryNode, SelectedWorktree, TerminalTabStatus, WorktreeNode},
    git::{ChangedFile, GitInspectorState, WorktreeKind},
    project::FileTreeNode,
    ui::view_models::{
        InspectorTreeRow, RepoSection, RepoTreeRow, RepoWorktreeRow, TreeExpansionKey,
        TreeExpansionState, build_inspector_tree_rows, build_repo_sections, build_repo_tree_rows,
        terminal_tab_overlay_visible,
    },
};

fn worktree(path: &str, branch: &str, archived: bool, kind: WorktreeKind) -> WorktreeNode {
    WorktreeNode {
        path: PathBuf::from(path),
        branch: Some(branch.to_string()),
        head: Some("abc123".to_string()),
        kind,
        archived,
    }
}

#[test]
fn expansion_state_tracks_repository_and_file_keys() {
    let repo_key = TreeExpansionKey::Repository("repo-1".to_string());
    let file_key = TreeExpansionKey::File(PathBuf::from("/repo/src"));
    let mut state = TreeExpansionState::default();

    assert!(!state.is_expanded(&repo_key));
    state.set_expanded(repo_key.clone(), true);
    state.toggle(file_key.clone());

    assert!(state.is_expanded(&repo_key));
    assert!(state.is_expanded(&file_key));

    state.toggle(file_key.clone());
    assert!(!state.is_expanded(&file_key));
}

#[test]
fn repo_sections_filter_archived_worktrees_and_mark_selection_without_expansion() {
    let repos = vec![RepositoryNode {
        id: "repo-1".to_string(),
        name: "alas".to_string(),
        path: PathBuf::from("/repo"),
        worktrees: vec![
            worktree("/repo", "main", false, WorktreeKind::Main),
            worktree("/repo/old", "old", true, WorktreeKind::Linked),
        ],
        show_archived: false,
        unavailable: false,
    }];
    let selected = SelectedWorktree {
        repo_id: "repo-1".to_string(),
        path: PathBuf::from("/repo"),
    };

    let sections = build_repo_sections(&repos, Some(&selected));

    assert_eq!(
        sections,
        vec![RepoSection {
            id: "repo-1".to_string(),
            name: "alas".to_string(),
            unavailable: false,
            worktrees: vec![RepoWorktreeRow {
                repo_id: "repo-1".to_string(),
                path: PathBuf::from("/repo"),
                label: "main".to_string(),
                selected: true,
                archived: false,
                kind: WorktreeKind::Main,
            }],
        }]
    );
}

#[test]
fn repo_tree_rows_filter_archived_worktrees_and_mark_selection() {
    let mut expansion = TreeExpansionState::default();
    expansion.set_expanded(TreeExpansionKey::Repository("repo-1".to_string()), true);

    let repos = vec![RepositoryNode {
        id: "repo-1".to_string(),
        name: "alas".to_string(),
        path: PathBuf::from("/repo"),
        worktrees: vec![
            worktree("/repo", "main", false, WorktreeKind::Main),
            worktree("/repo/old", "old", true, WorktreeKind::Linked),
        ],
        show_archived: false,
        unavailable: false,
    }];
    let selected = SelectedWorktree {
        repo_id: "repo-1".to_string(),
        path: PathBuf::from("/repo"),
    };

    let rows = build_repo_tree_rows(&repos, Some(&selected), &expansion);

    assert_eq!(
        rows,
        vec![
            RepoTreeRow::Repository {
                id: "repo-1".to_string(),
                name: "alas".to_string(),
                unavailable: false,
                expanded: true,
            },
            RepoTreeRow::Worktree {
                repo_id: "repo-1".to_string(),
                path: PathBuf::from("/repo"),
                label: "main".to_string(),
                selected: true,
                archived: false,
                kind: WorktreeKind::Main,
            },
        ]
    );
}

#[test]
fn grouped_inspector_rows_keep_file_and_git_errors_independent() {
    let selected = SelectedWorktree {
        repo_id: "repo-1".to_string(),
        path: PathBuf::from("/repo"),
    };
    let mut state = InspectorPaneState::default();
    state.set_files_error("files down");
    state.set_changes(GitInspectorState {
        branch: Some("main".to_string()),
        changed_files: vec![ChangedFile {
            status: "M".to_string(),
            path: "src/ui/shell.rs".to_string(),
        }],
        recent_commits: Vec::new(),
    });

    let file_expansion = TreeExpansionState::default();
    let rows = build_inspector_tree_rows(Some(&selected), &state, &file_expansion);

    assert!(rows.contains(&InspectorTreeRow::Context {
        branch_label: "main".to_string(),
        changed_count: Some(1),
    }));
    assert!(rows.contains(&InspectorTreeRow::ChangedFile {
        status: "M".to_string(),
        path: "src/ui/shell.rs".to_string(),
    }));
    assert!(rows.contains(&InspectorTreeRow::Error {
        section: "Files",
        message: "files down".to_string(),
    }));
}

#[test]
fn grouped_inspector_rows_flatten_file_tree_with_truncation() {
    let selected = SelectedWorktree {
        repo_id: "repo-1".to_string(),
        path: PathBuf::from("/repo"),
    };
    let mut state = InspectorPaneState::default();
    state.set_changes(GitInspectorState {
        branch: None,
        changed_files: Vec::new(),
        recent_commits: Vec::new(),
    });
    state.set_files(FileTreeNode {
        name: "repo".to_string(),
        path: PathBuf::from("/repo"),
        is_dir: true,
        truncated: false,
        children: vec![FileTreeNode {
            name: "src".to_string(),
            path: PathBuf::from("/repo/src"),
            is_dir: true,
            truncated: true,
            children: vec![FileTreeNode {
                name: "main.rs".to_string(),
                path: PathBuf::from("/repo/src/main.rs"),
                is_dir: false,
                children: Vec::new(),
                truncated: false,
            }],
        }],
    });

    let mut file_expansion = TreeExpansionState::default();
    file_expansion.set_expanded(TreeExpansionKey::File(PathBuf::from("/repo/src")), true);
    let rows = build_inspector_tree_rows(Some(&selected), &state, &file_expansion);

    assert!(rows.contains(&InspectorTreeRow::Context {
        branch_label: "Detached HEAD".to_string(),
        changed_count: Some(0),
    }));
    assert!(rows.contains(&InspectorTreeRow::File {
        depth: 0,
        name: "src".to_string(),
        path: PathBuf::from("/repo/src"),
        is_dir: true,
        expanded: true,
    }));
    assert!(rows.contains(&InspectorTreeRow::File {
        depth: 1,
        name: "main.rs".to_string(),
        path: PathBuf::from("/repo/src/main.rs"),
        is_dir: false,
        expanded: false,
    }));
    assert!(rows.contains(&InspectorTreeRow::Truncated { depth: 1 }));
}

#[test]
fn terminal_tab_overlay_visibility_matches_design() {
    assert!(!terminal_tab_overlay_visible(false, false, 1, None, false));
    assert!(terminal_tab_overlay_visible(true, false, 1, None, false));
    assert!(terminal_tab_overlay_visible(false, true, 1, None, false));
    assert!(terminal_tab_overlay_visible(false, false, 2, None, false));
    assert!(terminal_tab_overlay_visible(
        false,
        false,
        1,
        Some(&TerminalTabStatus::Exited(Some(1))),
        false,
    ));
    assert!(terminal_tab_overlay_visible(
        false,
        false,
        1,
        Some(&TerminalTabStatus::Failed),
        false,
    ));
    assert!(terminal_tab_overlay_visible(false, false, 1, None, true));
}

#[test]
fn grouped_inspector_rows_emit_loading_when_data_is_pending() {
    let selected = SelectedWorktree {
        repo_id: "repo-1".to_string(),
        path: PathBuf::from("/repo"),
    };
    let state = InspectorPaneState::default();
    let file_expansion = TreeExpansionState::default();
    let rows = build_inspector_tree_rows(Some(&selected), &state, &file_expansion);

    // When changes and files are still None (and no error yet),
    // loading rows should be emitted instead of blank sections.
    assert!(
        rows.contains(&InspectorTreeRow::Loading { section: "Changes" }),
        "expected Loading row for pending Changes section"
    );
    assert!(
        rows.iter()
            .any(|r| matches!(r, InspectorTreeRow::Section { title } if title == "Files")),
        "expected Section header for Files"
    );
    assert!(
        rows.contains(&InspectorTreeRow::Loading { section: "Files" }),
        "expected Loading row for pending Files section"
    );
}

#[test]
fn grouped_inspector_rows_show_empty_state_when_files_are_empty() {
    let selected = SelectedWorktree {
        repo_id: "repo-1".to_string(),
        path: PathBuf::from("/repo"),
    };
    let mut state = InspectorPaneState::default();
    state.set_changes(GitInspectorState {
        branch: Some("main".to_string()),
        changed_files: Vec::new(),
        recent_commits: Vec::new(),
    });
    state.set_files(FileTreeNode {
        name: "repo".to_string(),
        path: PathBuf::from("/repo"),
        is_dir: true,
        truncated: false,
        children: Vec::new(),
    });

    let file_expansion = TreeExpansionState::default();
    let rows = build_inspector_tree_rows(Some(&selected), &state, &file_expansion);

    // When the file tree is loaded but has no visible children,
    // an empty-state row should appear.
    assert!(
        rows.contains(&InspectorTreeRow::Clean {
            path: "No files found".to_string(),
        }),
        "expected empty-state row for files when root has no children"
    );
}

#[test]
fn grouped_inspector_rows_preserve_root_truncation() {
    let selected = SelectedWorktree {
        repo_id: "repo-1".to_string(),
        path: PathBuf::from("/repo"),
    };
    let mut state = InspectorPaneState::default();
    state.set_changes(GitInspectorState {
        branch: Some("main".to_string()),
        changed_files: Vec::new(),
        recent_commits: Vec::new(),
    });
    state.set_files(FileTreeNode {
        name: "repo".to_string(),
        path: PathBuf::from("/repo"),
        is_dir: true,
        truncated: true,
        children: vec![FileTreeNode {
            name: "src".to_string(),
            path: PathBuf::from("/repo/src"),
            is_dir: true,
            truncated: false,
            children: vec![FileTreeNode {
                name: "main.rs".to_string(),
                path: PathBuf::from("/repo/src/main.rs"),
                is_dir: false,
                truncated: false,
                children: Vec::new(),
            }],
        }],
    });

    let file_expansion = TreeExpansionState::default();
    let rows = build_inspector_tree_rows(Some(&selected), &state, &file_expansion);

    // When the root node is truncated, a Truncated row at depth 0
    // should appear even though the root itself is not displayed.
    assert!(
        rows.contains(&InspectorTreeRow::Truncated { depth: 0 }),
        "expected Truncated row for root-level truncation"
    );
}
