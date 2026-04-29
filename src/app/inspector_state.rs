use crate::{git::GitInspectorState, project::FileTreeNode};

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub enum InspectorTab {
    #[default]
    Files,
    Changes,
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct InspectorPaneState {
    pub selected_tab: InspectorTab,
    pub files: Option<FileTreeNode>,
    pub files_error: Option<String>,
    pub changes: Option<GitInspectorState>,
    pub changes_error: Option<String>,
}

impl InspectorPaneState {
    pub fn select_tab(&mut self, tab: InspectorTab) {
        self.selected_tab = tab;
    }

    pub fn clear_for_new_worktree(&mut self) {
        self.files = None;
        self.files_error = None;
        self.changes = None;
        self.changes_error = None;
    }

    pub fn set_files_error(&mut self, error: impl Into<String>) {
        self.files = None;
        self.files_error = Some(error.into());
    }

    pub fn set_changes_error(&mut self, error: impl Into<String>) {
        self.changes = None;
        self.changes_error = Some(error.into());
    }
}
