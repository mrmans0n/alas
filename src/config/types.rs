use indexmap::IndexMap;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct AppConfig {
    #[serde(default)]
    pub repositories: Vec<AppRepository>,
    #[serde(default)]
    pub archived_worktrees: IndexMap<String, Vec<PathBuf>>,
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
