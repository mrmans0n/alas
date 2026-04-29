use std::path::PathBuf;

#[derive(Debug, Clone, Default)]
pub struct AddRepositoryDialogState {
    pub path_text: String,
    pub error: Option<String>,
}

impl AddRepositoryDialogState {
    pub fn selected_path(&self) -> Option<PathBuf> {
        let trimmed = self.path_text.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(PathBuf::from(trimmed))
        }
    }
}

#[derive(Debug, Clone)]
pub struct ConfirmRemoveRepositoryDialog {
    pub repo_id: String,
    pub repo_name: String,
}
