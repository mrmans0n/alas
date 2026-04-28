use crate::config::AppConfig;
use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AppConfigStore {
    path: PathBuf,
}

impl AppConfigStore {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn load(&self) -> Result<AppConfig> {
        if !self.path.exists() {
            return Ok(AppConfig::default());
        }

        let contents = std::fs::read_to_string(&self.path)
            .with_context(|| format!("failed to read app config from {}", self.path.display()))?;

        toml::from_str(&contents)
            .with_context(|| format!("failed to parse app config from {}", self.path.display()))
    }

    pub fn save(&self, config: &AppConfig) -> Result<()> {
        if let Some(parent) = self
            .path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
        {
            std::fs::create_dir_all(parent).with_context(|| {
                format!("failed to create app config directory {}", parent.display())
            })?;
        }

        let contents = toml::to_string_pretty(config).context("failed to serialize app config")?;
        std::fs::write(&self.path, contents)
            .with_context(|| format!("failed to write app config to {}", self.path.display()))
    }
}
