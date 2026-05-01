use std::path::{Path, PathBuf};

use anyhow::{Context, bail};

use crate::agent::{AgentTrustMode, PermissionDecision, PermissionPolicy, PermissionRequestKind};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FilesystemCallbackService {
    pub policy: PermissionPolicy,
}

impl FilesystemCallbackService {
    pub fn new(trust_mode: AgentTrustMode, worktree_path: PathBuf) -> Self {
        Self {
            policy: PermissionPolicy::new(trust_mode, worktree_path),
        }
    }

    pub fn read_text_file(&self, path: &Path) -> anyhow::Result<String> {
        match self
            .policy
            .decide(&PermissionRequestKind::ReadFile(path.to_path_buf()))
        {
            PermissionDecision::Allow => std::fs::read_to_string(path)
                .with_context(|| format!("read text file {}", path.display())),
            PermissionDecision::Ask => bail!("permission required to read file {}", path.display()),
            PermissionDecision::Deny => bail!("permission denied to read file {}", path.display()),
        }
    }

    pub fn write_text_file(&self, path: &Path, content: &str) -> anyhow::Result<()> {
        match self
            .policy
            .decide(&PermissionRequestKind::WriteFile(path.to_path_buf()))
        {
            PermissionDecision::Allow => {
                if let Some(parent) = path.parent() {
                    std::fs::create_dir_all(parent).with_context(|| {
                        format!("create parent directories for {}", path.display())
                    })?;
                }
                std::fs::write(path, content)
                    .with_context(|| format!("write text file {}", path.display()))
            }
            PermissionDecision::Ask => {
                bail!("permission required to write file {}", path.display())
            }
            PermissionDecision::Deny => bail!("permission denied to write file {}", path.display()),
        }
    }
}
