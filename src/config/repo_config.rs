use crate::config::RepoConfigFile;
use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RepoConfigStore {
    path: PathBuf,
}

impl RepoConfigStore {
    pub fn for_repo(repo_path: impl AsRef<Path>) -> Self {
        Self {
            path: repo_path.as_ref().join(".alas").join("config.toml"),
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn load(&self) -> Result<Option<RepoConfigFile>> {
        if !self.path.exists() {
            return Ok(None);
        }

        let contents = std::fs::read_to_string(&self.path).with_context(|| {
            format!(
                "failed to read repository config from {}",
                self.path.display()
            )
        })?;

        toml::from_str(&contents).map(Some).with_context(|| {
            format!(
                "failed to parse repository config from {}",
                self.path.display()
            )
        })
    }

    pub fn save(&self, config: &RepoConfigFile) -> Result<()> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent).with_context(|| {
                format!(
                    "failed to create repository config directory {}",
                    parent.display()
                )
            })?;
        }

        let contents =
            toml::to_string_pretty(config).context("failed to serialize repository config")?;
        std::fs::write(&self.path, contents).with_context(|| {
            format!(
                "failed to write repository config to {}",
                self.path.display()
            )
        })
    }
}
