use std::path::{Path, PathBuf};

use anyhow::{Context, bail};

use super::GitRunner;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WorktreeKind {
    Main,
    Linked,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorktreeInfo {
    pub path: PathBuf,
    pub branch: Option<String>,
    pub head: Option<String>,
    pub kind: WorktreeKind,
}

pub struct GitWorktreeService {
    runner: GitRunner,
}

impl GitWorktreeService {
    pub fn new(runner: GitRunner) -> Self {
        Self { runner }
    }

    pub fn validate_repository(&self, repo_path: &Path) -> anyhow::Result<()> {
        self.runner
            .run(repo_path, &["rev-parse", "--show-toplevel"])
            .with_context(|| format!("{} is not a Git repository", repo_path.display()))?;

        Ok(())
    }

    pub fn list_worktrees(&self, repo_path: &Path) -> anyhow::Result<Vec<WorktreeInfo>> {
        let output = self
            .runner
            .run(repo_path, &["worktree", "list", "--porcelain"])
            .with_context(|| format!("failed to list Git worktrees for {}", repo_path.display()))?;

        Ok(parse_worktrees(&output.stdout))
    }

    pub fn create_worktree(
        &self,
        repo_path: &Path,
        base_ref: &str,
        branch_name: &str,
        target_path: &Path,
    ) -> anyhow::Result<()> {
        let target_path = target_path.to_str().with_context(|| {
            format!(
                "worktree path is not valid UTF-8: {}",
                target_path.display()
            )
        })?;

        self.runner
            .run(
                repo_path,
                &["worktree", "add", "-b", branch_name, target_path, base_ref],
            )
            .with_context(|| format!("failed to create Git worktree at {target_path}"))?;

        Ok(())
    }

    pub fn remove_worktree(&self, repo_path: &Path, worktree_path: &Path) -> anyhow::Result<()> {
        let worktrees = self.list_worktrees(repo_path)?;
        let worktree = worktrees
            .iter()
            .find(|worktree| paths_match(&worktree.path, worktree_path))
            .with_context(|| format!("Git worktree not found: {}", worktree_path.display()))?;

        if worktree.kind == WorktreeKind::Main {
            bail!("cannot remove main worktree: {}", worktree_path.display());
        }

        let worktree_path = worktree_path.to_str().with_context(|| {
            format!(
                "worktree path is not valid UTF-8: {}",
                worktree_path.display()
            )
        })?;

        self.runner
            .run(repo_path, &["worktree", "remove", worktree_path])
            .with_context(|| format!("failed to remove Git worktree at {worktree_path}"))?;

        Ok(())
    }

    pub fn prune_worktrees(&self, repo_path: &Path) -> anyhow::Result<()> {
        self.runner
            .run(repo_path, &["worktree", "prune"])
            .with_context(|| {
                format!("failed to prune Git worktrees for {}", repo_path.display())
            })?;

        Ok(())
    }
}

fn paths_match(left: &Path, right: &Path) -> bool {
    match (left.canonicalize(), right.canonicalize()) {
        (Ok(left), Ok(right)) => left == right,
        _ => left == right,
    }
}

fn parse_worktrees(output: &str) -> Vec<WorktreeInfo> {
    let mut worktrees = Vec::new();
    let mut current = PartialWorktree::default();

    for line in output.lines() {
        if line.is_empty() {
            push_worktree(&mut worktrees, &mut current);
            continue;
        }

        if let Some(path) = line.strip_prefix("worktree ") {
            push_worktree(&mut worktrees, &mut current);
            current.path = Some(PathBuf::from(path));
        } else if let Some(head) = line.strip_prefix("HEAD ") {
            current.head = Some(head.to_string());
        } else if let Some(branch) = line.strip_prefix("branch ") {
            current.branch = Some(strip_heads_prefix(branch).to_string());
        }
    }

    push_worktree(&mut worktrees, &mut current);
    worktrees
}

fn strip_heads_prefix(branch: &str) -> &str {
    branch.strip_prefix("refs/heads/").unwrap_or(branch)
}

fn push_worktree(worktrees: &mut Vec<WorktreeInfo>, current: &mut PartialWorktree) {
    let path = current.path.take();
    let branch = current.branch.take();
    let head = current.head.take();
    let Some(path) = path else {
        return;
    };

    let kind = if worktrees.is_empty() {
        WorktreeKind::Main
    } else {
        WorktreeKind::Linked
    };

    worktrees.push(WorktreeInfo {
        path,
        branch,
        head,
        kind,
    });
}

#[derive(Default)]
struct PartialWorktree {
    path: Option<PathBuf>,
    branch: Option<String>,
    head: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_blank_terminated_and_final_records_with_optional_fields() {
        let worktrees = parse_worktrees(
            "worktree /repo\nHEAD abc123\nbranch refs/heads/main\n\nworktree /linked\ndetached\nHEAD def456\n",
        );

        assert_eq!(worktrees.len(), 2);
        assert_eq!(worktrees[0].path, PathBuf::from("/repo"));
        assert_eq!(worktrees[0].branch.as_deref(), Some("main"));
        assert_eq!(worktrees[0].head.as_deref(), Some("abc123"));
        assert_eq!(worktrees[0].kind, WorktreeKind::Main);
        assert_eq!(worktrees[1].path, PathBuf::from("/linked"));
        assert_eq!(worktrees[1].branch, None);
        assert_eq!(worktrees[1].head.as_deref(), Some("def456"));
        assert_eq!(worktrees[1].kind, WorktreeKind::Linked);
    }

    #[test]
    fn ignores_empty_records_without_leaking_fields() {
        let worktrees = parse_worktrees(
            "branch refs/heads/ignored\n\nworktree /repo\nHEAD abc123\nbranch refs/heads/main\n\n\n",
        );

        assert_eq!(worktrees.len(), 1);
        assert_eq!(worktrees[0].branch.as_deref(), Some("main"));
    }
}
