use std::path::Path;
use std::process::Command;

use anyhow::{Context, bail};

pub struct GitRunner;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitOutput {
    pub stdout: String,
    pub stderr: String,
}

impl GitRunner {
    pub fn new() -> Self {
        Self
    }

    pub fn run(&self, cwd: &Path, args: &[&str]) -> anyhow::Result<GitOutput> {
        let output = Command::new("git")
            .args(args)
            .current_dir(cwd)
            .output()
            .with_context(|| format!("failed to run git {args:?} in {}", cwd.display()))?;

        let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
        let stderr = String::from_utf8_lossy(&output.stderr).into_owned();

        if !output.status.success() {
            bail!(
                "git {:?} failed in {} with status {}\nstderr:\n{}",
                args,
                cwd.display(),
                output.status,
                stderr
            );
        }

        Ok(GitOutput { stdout, stderr })
    }
}

impl Default for GitRunner {
    fn default() -> Self {
        Self::new()
    }
}
