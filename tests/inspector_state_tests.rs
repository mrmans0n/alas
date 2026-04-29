use alas::{
    app::{InspectorPaneState, InspectorTab},
    git::GitInspectorState,
    project::FileTreeNode,
};
use std::path::PathBuf;

#[test]
fn files_and_changes_errors_are_independent() {
    let mut state = InspectorPaneState::default();

    state.set_files_error("failed to load files");

    assert_eq!(state.files_error.as_deref(), Some("failed to load files"));
    assert!(state.changes_error.is_none());

    state.set_changes_error("failed to load changes");

    assert_eq!(state.files_error.as_deref(), Some("failed to load files"));
    assert_eq!(
        state.changes_error.as_deref(),
        Some("failed to load changes")
    );
}

#[test]
fn successful_loads_clear_matching_errors_without_affecting_other_tab() {
    let mut state = InspectorPaneState::default();
    state.set_files_error("failed to load files");
    state.set_changes_error("failed to load changes");

    state.set_files(FileTreeNode {
        name: "repo".to_string(),
        path: PathBuf::from("/repo"),
        is_dir: true,
        children: Vec::new(),
        truncated: false,
    });

    assert!(state.files.is_some());
    assert!(state.files_error.is_none());
    assert_eq!(
        state.changes_error.as_deref(),
        Some("failed to load changes")
    );

    state.set_changes(GitInspectorState {
        branch: Some("main".to_string()),
        changed_files: Vec::new(),
        recent_commits: Vec::new(),
    });

    assert!(state.changes.is_some());
    assert!(state.changes_error.is_none());
}

#[test]
fn selected_tab_can_switch_between_files_and_changes() {
    let mut state = InspectorPaneState::default();

    assert_eq!(state.selected_tab, InspectorTab::Files);

    state.select_tab(InspectorTab::Changes);

    assert_eq!(state.selected_tab, InspectorTab::Changes);
}
