use std::path::{Path, PathBuf};
use std::process::Command;

use tempfile::TempDir;

pub struct TestRepo {
    _tempdir: TempDir,
    path: PathBuf,
}

impl TestRepo {
    pub fn new() -> Self {
        let tempdir = TempDir::new().expect("create temporary directory");
        let path = tempdir.path().join("repo");
        std::fs::create_dir(&path).expect("create repository directory");

        run(&path, &["init", "--initial-branch", "main"]);
        run(&path, &["config", "user.email", "test@example.com"]);
        run(&path, &["config", "user.name", "Test User"]);
        run(&path, &["config", "commit.gpgsign", "false"]);

        std::fs::write(path.join("README.md"), "# Test Repo\n").expect("write README.md");
        run(&path, &["add", "README.md"]);
        run(&path, &["commit", "-m", "initial"]);

        Self {
            _tempdir: tempdir,
            path,
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    #[allow(dead_code)]
    pub fn worktree_path(&self, name: &str) -> PathBuf {
        self._tempdir.path().join(name)
    }
}

pub fn run(cwd: &Path, args: &[&str]) {
    let output = Command::new("git")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .args(args)
        .current_dir(cwd)
        .output()
        .unwrap_or_else(|err| panic!("failed to run git {:?} in {}: {err}", args, cwd.display()));

    assert!(
        output.status.success(),
        "git {:?} failed in {} with status {}\nstdout:\n{}\nstderr:\n{}",
        args,
        cwd.display(),
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}
