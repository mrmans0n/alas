use std::path::Path;

use anyhow::Context;

use super::GitRunner;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitInspectorState {
    pub branch: Option<String>,
    pub changed_files: Vec<ChangedFile>,
    pub recent_commits: Vec<RecentCommit>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChangedFile {
    pub status: String,
    pub path: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecentCommit {
    pub hash: String,
    pub summary: String,
}

pub struct GitInspectorService {
    runner: GitRunner,
}

impl GitInspectorService {
    pub fn new(runner: GitRunner) -> Self {
        Self { runner }
    }

    pub fn inspect(
        &self,
        worktree_path: &Path,
        commit_limit: usize,
    ) -> anyhow::Result<GitInspectorState> {
        let mut state = self.inspect_changes(worktree_path)?;

        let limit_arg = format!("-n{commit_limit}");
        let log_output = self
            .runner
            .run(worktree_path, &["log", "--oneline", &limit_arg])
            .with_context(|| {
                format!("failed to inspect Git log for {}", worktree_path.display())
            })?;
        state.recent_commits = parse_recent_commits(&log_output.stdout);

        Ok(state)
    }

    pub fn inspect_changes(&self, worktree_path: &Path) -> anyhow::Result<GitInspectorState> {
        let branch_output = self
            .runner
            .run(worktree_path, &["branch", "--show-current"])
            .with_context(|| {
                format!(
                    "failed to inspect Git branch for {}",
                    worktree_path.display()
                )
            })?;
        let branch = match branch_output.stdout.trim() {
            "" => None,
            branch => Some(branch.to_string()),
        };

        let status_output = self
            .runner
            .run(worktree_path, &["status", "--short"])
            .with_context(|| {
                format!(
                    "failed to inspect Git status for {}",
                    worktree_path.display()
                )
            })?;
        let changed_files = parse_changed_files(&status_output.stdout);

        Ok(GitInspectorState {
            branch,
            changed_files,
            recent_commits: Vec::new(),
        })
    }
}

fn parse_changed_files(output: &str) -> Vec<ChangedFile> {
    output
        .lines()
        .filter_map(|line| {
            let status = line.get(..2)?.trim().to_string();
            let path = line.get(3..)?.trim().to_string();

            if status.is_empty() || path.is_empty() {
                return None;
            }

            Some(ChangedFile { status, path })
        })
        .collect()
}

fn parse_recent_commits(output: &str) -> Vec<RecentCommit> {
    output
        .lines()
        .filter_map(|line| {
            let (hash, summary) = line.split_once(' ')?;
            Some(RecentCommit {
                hash: hash.to_string(),
                summary: summary.to_string(),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_changed_files_from_short_status() {
        let changed_files = parse_changed_files(" M README.md\n?? src/main.rs\n");

        assert_eq!(
            changed_files,
            vec![
                ChangedFile {
                    status: "M".to_string(),
                    path: "README.md".to_string(),
                },
                ChangedFile {
                    status: "??".to_string(),
                    path: "src/main.rs".to_string(),
                },
            ]
        );
    }

    #[test]
    fn parses_recent_commits_from_oneline_log() {
        let commits = parse_recent_commits("abc123 initial commit\ndef456 follow-up\n");

        assert_eq!(
            commits,
            vec![
                RecentCommit {
                    hash: "abc123".to_string(),
                    summary: "initial commit".to_string(),
                },
                RecentCommit {
                    hash: "def456".to_string(),
                    summary: "follow-up".to_string(),
                },
            ]
        );
    }
}
