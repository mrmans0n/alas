use indexmap::IndexMap;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct AppConfig {
    #[serde(default)]
    pub repositories: Vec<AppRepository>,
    #[serde(default)]
    pub archived_worktrees: IndexMap<String, Vec<PathBuf>>,
    #[serde(default)]
    pub notifications: NotificationPrefs,
}

impl AppConfig {
    pub fn archive_worktree(&mut self, repo_id: impl Into<String>, path: PathBuf) {
        let paths = self.archived_worktrees.entry(repo_id.into()).or_default();
        if !paths.iter().any(|archived_path| archived_path == &path) {
            paths.push(path);
        }
    }

    pub fn unarchive_worktree(&mut self, repo_id: &str, path: &Path) {
        if let Some(paths) = self.archived_worktrees.get_mut(repo_id) {
            paths.retain(|archived_path| archived_path != path);
        }
    }
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct NotificationPrefs {
    #[serde(default)]
    pub harness_completion: HarnessCompletionNotificationPrefs,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct HarnessCompletionNotificationPrefs {
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default = "default_true")]
    pub success: bool,
    #[serde(default = "default_true")]
    pub failure: bool,
}

impl Default for HarnessCompletionNotificationPrefs {
    fn default() -> Self {
        Self {
            enabled: true,
            success: true,
            failure: true,
        }
    }
}

const fn default_true() -> bool {
    true
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AppRepository {
    pub id: String,
    pub path: PathBuf,
    #[serde(default)]
    pub name: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct RepoConfigFile {
    #[serde(default)]
    pub default_command: Option<String>,
    #[serde(default)]
    pub commands: Option<CommandConfig>,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct CommandConfig {
    pub default: String,
    #[serde(default)]
    pub entries: IndexMap<String, CommandEntry>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct CommandEntry {
    pub command: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResolvedRepoConfig {
    pub id: String,
    pub path: PathBuf,
    pub name: String,
    commands: IndexMap<String, CommandEntry>,
    default_command_name: String,
}

impl ResolvedRepoConfig {
    pub fn resolve(
        id: String,
        path: PathBuf,
        name: Option<String>,
        _app: &AppConfig,
        repo_file: Option<RepoConfigFile>,
    ) -> Self {
        let repo_name = name.unwrap_or_else(|| infer_repo_name(&path));
        let mut commands = IndexMap::new();
        let mut configured_default = None;

        if let Some(repo_file) = repo_file {
            if let Some(command_config) = repo_file.commands {
                configured_default = Some(command_config.default);
                commands = command_config.entries;
            } else if let Some(default_command) = repo_file.default_command {
                configured_default = Some("default".to_string());
                commands.insert(
                    "default".to_string(),
                    CommandEntry {
                        command: default_command,
                    },
                );
            }
        }

        ensure_fallback_command(&mut commands);

        let default_command_name = configured_default
            .filter(|default| commands.contains_key(default))
            .or_else(|| commands.keys().next().cloned())
            .expect("resolved repository config must contain at least one command");

        Self {
            id,
            path,
            name: repo_name,
            commands,
            default_command_name,
        }
    }

    pub fn commands(&self) -> &IndexMap<String, CommandEntry> {
        &self.commands
    }

    pub fn default_command_name(&self) -> &str {
        &self.default_command_name
    }

    pub fn default_command(&self) -> &CommandEntry {
        self.commands
            .get(&self.default_command_name)
            .expect("default command name must reference an available command")
    }
}

pub fn repository_id_for_path(path: &Path) -> String {
    path.canonicalize()
        .unwrap_or_else(|_| path.to_path_buf())
        .to_string_lossy()
        .replace(['/', '\\', ':'], "_")
}

fn ensure_fallback_command(commands: &mut IndexMap<String, CommandEntry>) {
    if commands.is_empty() {
        commands.insert(
            "shell".to_string(),
            CommandEntry {
                command: "$SHELL".to_string(),
            },
        );
    }
}

fn infer_repo_name(path: &std::path::Path) -> String {
    path.file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .unwrap_or("repository")
        .to_string()
}
