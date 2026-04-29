use std::path::PathBuf;

use crate::config::{CommandConfig, CommandEntry, RepoConfigFile};
use indexmap::IndexMap;

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

#[derive(Debug, Clone, Default)]
pub struct CommandSettingsDialogState {
    pub repo_id: String,
    pub default_name: String,
    pub entries: Vec<(String, String)>,
    pub error: Option<String>,
}

impl CommandSettingsDialogState {
    pub fn to_repo_config(&self) -> Result<RepoConfigFile, String> {
        let default = self.default_name.trim().to_string();
        if default.is_empty() {
            return Err("Default command name is required".to_string());
        }

        let mut entries = IndexMap::new();
        for (name, command) in &self.entries {
            let name = name.trim();
            let command = command.trim();
            if name.is_empty() {
                return Err("Command names cannot be empty".to_string());
            }
            if command.is_empty() {
                return Err(format!("Command value for {name} cannot be empty"));
            }
            entries.insert(
                name.to_string(),
                CommandEntry {
                    command: command.to_string(),
                },
            );
        }

        if !entries.contains_key(&default) {
            return Err("Default command must match a named command".to_string());
        }

        Ok(RepoConfigFile {
            default_command: None,
            commands: Some(CommandConfig { default, entries }),
        })
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
