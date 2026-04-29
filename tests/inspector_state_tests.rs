use alas::app::{InspectorPaneState, InspectorTab};

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
fn selected_tab_can_switch_between_files_and_changes() {
    let mut state = InspectorPaneState::default();

    assert_eq!(state.selected_tab, InspectorTab::Files);

    state.select_tab(InspectorTab::Changes);

    assert_eq!(state.selected_tab, InspectorTab::Changes);
}
