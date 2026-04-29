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

#[derive(Debug, Clone, Copy, Default, Eq, PartialEq)]
pub enum CreateWorktreeField {
    #[default]
    BaseRef,
    BranchName,
    TargetPath,
}

#[derive(Debug, Clone, Default)]
pub struct CreateWorktreeDialogState {
    pub repo_id: String,
    pub base_ref: String,
    pub branch_name: String,
    pub target_path_text: String,
    pub error: Option<String>,
    pub active_field: CreateWorktreeField,
}

impl CreateWorktreeDialogState {
    pub fn target_path(&self) -> Option<PathBuf> {
        let trimmed = self.target_path_text.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(PathBuf::from(trimmed))
        }
    }

    pub fn validate(&self) -> Result<PathBuf, String> {
        if self.base_ref.trim().is_empty() {
            return Err("Base ref is required".to_string());
        }
        if self.branch_name.trim().is_empty() {
            return Err("Branch name is required".to_string());
        }

        self.target_path()
            .ok_or_else(|| "Target path is required".to_string())
    }
}

#[derive(Debug, Clone)]
pub struct ConfirmRemoveRepositoryDialog {
    pub repo_id: String,
    pub repo_name: String,
}
