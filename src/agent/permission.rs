use std::path::{Component, Path, PathBuf};

use crate::agent::AgentTrustMode;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PermissionDecision {
    Allow,
    Ask,
    Deny,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PermissionRequestKind {
    ReadFile(PathBuf),
    WriteFile(PathBuf),
    RunTerminal { command: String },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PermissionPolicy {
    pub trust_mode: AgentTrustMode,
    pub worktree_path: PathBuf,
}

impl PermissionPolicy {
    pub fn new(trust_mode: AgentTrustMode, worktree_path: PathBuf) -> Self {
        Self {
            trust_mode,
            worktree_path,
        }
    }

    pub fn decide(&self, request: &PermissionRequestKind) -> PermissionDecision {
        match self.trust_mode {
            AgentTrustMode::AllowEverything => PermissionDecision::Allow,
            AgentTrustMode::Ask => PermissionDecision::Ask,
            AgentTrustMode::Deny => PermissionDecision::Deny,
            AgentTrustMode::WorktreeOnly => match request {
                PermissionRequestKind::ReadFile(path) | PermissionRequestKind::WriteFile(path) => {
                    if path_is_inside_worktree(path, &self.worktree_path) {
                        PermissionDecision::Allow
                    } else {
                        PermissionDecision::Deny
                    }
                }
                PermissionRequestKind::RunTerminal { .. } => PermissionDecision::Ask,
            },
        }
    }
}

fn path_is_inside_worktree(path: &Path, worktree_path: &Path) -> bool {
    let Ok(worktree_path) = canonicalize_existing_prefix(worktree_path) else {
        return false;
    };
    let Ok(path) = canonicalize_existing_prefix(path) else {
        return false;
    };

    path.starts_with(worktree_path)
}

fn canonicalize_existing_prefix(path: &Path) -> std::io::Result<PathBuf> {
    let mut missing_components = Vec::new();
    let mut current = path.to_path_buf();

    while !current.exists() {
        let Some(component) = current.components().next_back() else {
            return current.canonicalize();
        };
        missing_components.push(component.as_os_str().to_os_string());
        if !current.pop() {
            return current.canonicalize();
        }
    }

    let mut canonical = current.canonicalize()?;
    for component in missing_components.iter().rev() {
        match Path::new(component).components().next() {
            Some(Component::CurDir) => {}
            Some(Component::ParentDir) if !canonical.pop() => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "path escapes filesystem root",
                ));
            }
            Some(Component::ParentDir) => {}
            Some(Component::Normal(component)) => canonical.push(component),
            Some(Component::RootDir | Component::Prefix(_)) => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "absolute component in missing path suffix",
                ));
            }
            None => {}
        }
    }

    Ok(canonical)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonicalizes_nearest_existing_ancestor_for_missing_leaf() {
        let temp = tempfile::tempdir().expect("create tempdir");
        let dir = temp.path().join("dir");
        std::fs::create_dir(&dir).expect("create dir");

        let canonical = canonicalize_existing_prefix(&dir.join("missing.txt"))
            .expect("canonicalize missing leaf");

        assert_eq!(canonical, dir.canonicalize().unwrap().join("missing.txt"));
    }
}
