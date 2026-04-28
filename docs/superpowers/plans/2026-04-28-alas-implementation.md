# Alas Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Alas v1: a GPUI Rust desktop app that manages configured Git repositories, discovers and creates worktrees, and opens a persistent embedded Ghostty terminal per selected worktree.

**Architecture:** Use a GPUI app shell over testable domain services. Keep config, Git/worktree operations, app model state, and terminal session management behind clear interfaces so GPUI components do not contain Git command logic or raw `libghostty-rs` details.

**Tech Stack:** Rust stable, Cargo, GPUI, the `libghostty-rs` project crates (`libghostty-vt` for Ghostty VT emulation, plus a PTY/process owner inside Alas if the crate does not provide one), `serde`, `toml`, `directories`, `anyhow`, `thiserror`, `tempfile`, Git CLI.

---

## Scope Notes

This plan implements a vertical v1 in small, testable slices:

1. Project scaffold and service boundaries.
2. Config model and persistence.
3. Git/worktree service.
4. App model behavior.
5. Terminal session registry and adapter boundary.
6. GPUI shell/sidebar/inspector/dialog wiring.
7. Real terminal embedding integration.
8. End-to-end smoke checks.

If GPUI APIs differ from expected current examples, keep the public Alas UI boundaries intact and adapt only `src/ui/*`. If the `libghostty-rs` project exposes only `libghostty-vt`, Alas' `ghostty_adapter` must own the missing PTY/process bridge while still using Ghostty's VT/rendering API behind the internal `TerminalBackend` trait.

## File Structure

Create a single Rust binary crate first. Split by responsibility, not by technical layer inside large files.

```text
Cargo.toml
README.md
.gitignore
src/main.rs
src/lib.rs
src/app/mod.rs
src/app/model.rs
src/app/actions.rs
src/config/mod.rs
src/config/types.rs
src/config/app_config.rs
src/config/repo_config.rs
src/git/mod.rs
src/git/runner.rs
src/git/worktree.rs
src/git/inspector.rs
src/terminal/mod.rs
src/terminal/session.rs
src/terminal/ghostty_adapter.rs
src/ui/mod.rs
src/ui/shell.rs
src/ui/sidebar.rs
src/ui/terminal_pane.rs
src/ui/inspector.rs
src/ui/dialogs.rs
tests/support/mod.rs
tests/support/git_repo.rs
tests/config_tests.rs
tests/git_worktree_tests.rs
tests/app_model_tests.rs
tests/terminal_session_tests.rs
```

Responsibilities:

- `src/main.rs`: call the library UI entry point.
- `src/lib.rs`: export Alas modules for the binary and integration tests.
- `src/app/model.rs`: pure app state and state transitions.
- `src/app/actions.rs`: typed user/app actions.
- `src/config/*`: config structs, app config file IO, `.alas/config.toml` IO, precedence resolution.
- `src/git/runner.rs`: command execution abstraction for Git CLI.
- `src/git/worktree.rs`: repository validation, worktree discovery/create/remove/prune.
- `src/git/inspector.rs`: changed files, recent commits, branch summary.
- `src/terminal/session.rs`: persistent per-worktree session registry and command resolution.
- `src/terminal/ghostty_adapter.rs`: the only module that directly imports `libghostty-rs`.
- `src/ui/*`: GPUI rendering and event wiring only.
- `tests/support/git_repo.rs`: temp Git repository helpers.

---

## Task 1: Scaffold Rust Project

**Files:**
- Create: `Cargo.toml`
- Create: `.gitignore`
- Create: `README.md`
- Create: `src/main.rs`
- Create: `src/lib.rs`
- Create: module placeholder files listed in File Structure

- [ ] **Step 1: Create crate files**

Create `Cargo.toml`:

```toml
[package]
name = "alas"
version = "0.1.0"
edition = "2024"

[dependencies]
anyhow = "1"
thiserror = "2"
serde = { version = "1", features = ["derive"] }
toml = "0.8"
directories = "6"
indexmap = { version = "2", features = ["serde"] }

# GPUI is the Rust UI framework used by Zed. If crates.io does not have the
# needed version, switch this dependency to Zed's Git repository during this task.
gpui = "0.2"

# libghostty-rs currently exposes Ghostty VT bindings through libghostty-vt.
# Alas keeps this behind src/terminal/ghostty_adapter.rs. If the project adds
# higher-level PTY/process crates, add them here without changing TerminalBackend.
libghostty-vt = "0.1"

[dev-dependencies]
tempfile = "3"
pretty_assertions = "1"
```

Create `.gitignore`:

```gitignore
/target/
/.superpowers/
.DS_Store
```

Create `README.md`:

```markdown
# Alas

Alas is a native Rust desktop app for managing Git repositories, their worktrees,
and persistent embedded terminals.
```

Create `src/main.rs`:

```rust
fn main() -> anyhow::Result<()> {
    alas::ui::run()
}
```

Create `src/lib.rs` so `src/main.rs` and integration tests can import the `alas` library crate:

```rust
pub mod app;
pub mod config;
pub mod git;
pub mod terminal;
pub mod ui;
```

- [ ] **Step 2: Create placeholder modules**

Create each module file with minimal compiling placeholders, for example `src/app/mod.rs`:

```rust
pub mod actions;
pub mod model;
```

Create `src/ui/mod.rs`:

```rust
pub mod dialogs;
pub mod inspector;
pub mod shell;
pub mod sidebar;
pub mod terminal_pane;

pub fn run() -> anyhow::Result<()> {
    Ok(())
}
```

- [ ] **Step 3: Run compile check**

Run:

```bash
cargo check
```

Expected: PASS. If GPUI/libghostty dependency resolution fails, adjust dependency source but do not change internal file boundaries.

- [ ] **Step 4: Commit**

```bash
git add Cargo.toml README.md .gitignore src
git commit -m "chore: scaffold Alas Rust crate"
```

---

## Task 2: Define Config Types

**Files:**
- Create/Modify: `src/config/types.rs`
- Modify: `src/config/mod.rs`
- Test: `tests/config_tests.rs`

- [ ] **Step 1: Write failing tests for config parsing and precedence**

Create `tests/config_tests.rs`:

```rust
use alas::config::{AppConfig, CommandConfig, RepoConfigFile, ResolvedRepoConfig};
use std::path::PathBuf;

#[test]
fn repo_config_supports_named_commands() {
    let toml = r#"
        [commands]
        default = "claude"

        [commands.entries.claude]
        command = "claude"

        [commands.entries.shell]
        command = "$SHELL"
    "#;

    let repo: RepoConfigFile = toml::from_str(toml).unwrap();
    assert_eq!(repo.commands.unwrap().default, "claude");
}

#[test]
fn repo_config_supports_default_command_shorthand() {
    let toml = r#"default_command = "codex""#;
    let repo: RepoConfigFile = toml::from_str(toml).unwrap();
    assert_eq!(repo.default_command.as_deref(), Some("codex"));
}

#[test]
fn resolved_config_prefers_repo_command_over_shell_fallback() {
    let app = AppConfig::default();
    let repo_file = RepoConfigFile {
        default_command: Some("claude".to_string()),
        commands: None,
    };

    let resolved = ResolvedRepoConfig::resolve(
        "repo-1".to_string(),
        PathBuf::from("/tmp/repo"),
        Some("repo".to_string()),
        &app,
        Some(repo_file),
    );

    assert_eq!(resolved.default_command().command, "claude");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cargo test --test config_tests
```

Expected: FAIL with unresolved config types.

- [ ] **Step 3: Implement config types**

Create `src/config/types.rs`:

```rust
use indexmap::IndexMap;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct AppConfig {
    #[serde(default)]
    pub repositories: Vec<AppRepository>,
    #[serde(default)]
    pub archived_worktrees: IndexMap<String, Vec<PathBuf>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AppRepository {
    pub id: String,
    pub path: PathBuf,
    pub name: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct RepoConfigFile {
    pub default_command: Option<String>,
    pub commands: Option<CommandConfig>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CommandConfig {
    pub default: String,
    #[serde(default)]
    pub entries: IndexMap<String, CommandEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CommandEntry {
    pub command: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedRepoConfig {
    pub id: String,
    pub path: PathBuf,
    pub name: String,
    pub commands: IndexMap<String, CommandEntry>,
    pub default_command_name: String,
}

impl ResolvedRepoConfig {
    pub fn resolve(
        id: String,
        path: PathBuf,
        name: Option<String>,
        _app: &AppConfig,
        repo_file: Option<RepoConfigFile>,
    ) -> Self {
        let mut commands = IndexMap::new();
        let mut default_command_name = "shell".to_string();

        if let Some(repo_file) = repo_file {
            if let Some(command_config) = repo_file.commands {
                default_command_name = command_config.default;
                commands = command_config.entries;
            } else if let Some(default_command) = repo_file.default_command {
                default_command_name = "default".to_string();
                commands.insert("default".to_string(), CommandEntry { command: default_command });
            }
        }

        if commands.is_empty() {
            commands.insert("shell".to_string(), CommandEntry { command: "$SHELL".to_string() });
        }

        let fallback_name = commands.keys().next().cloned().unwrap_or_else(|| "shell".to_string());
        if !commands.contains_key(&default_command_name) {
            default_command_name = fallback_name;
        }

        let inferred_name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("repository")
            .to_string();

        Self {
            id,
            path,
            name: name.unwrap_or(inferred_name),
            commands,
            default_command_name,
        }
    }

    pub fn default_command(&self) -> &CommandEntry {
        &self.commands[&self.default_command_name]
    }
}
```

Modify `src/config/mod.rs`:

```rust
pub mod app_config;
pub mod repo_config;
pub mod types;

pub use types::{
    AppConfig, AppRepository, CommandConfig, CommandEntry, RepoConfigFile, ResolvedRepoConfig,
};
```

- [ ] **Step 4: Run tests**

Run:

```bash
cargo test --test config_tests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/config tests/config_tests.rs
git commit -m "feat: define Alas configuration model"
```

---

## Task 3: Implement Config File IO

**Files:**
- Modify: `src/config/app_config.rs`
- Modify: `src/config/repo_config.rs`
- Modify: `src/config/mod.rs`
- Test: `tests/config_tests.rs`

- [ ] **Step 1: Add failing tests for app and repo config IO**

Append to `tests/config_tests.rs`:

```rust
use alas::config::{AppConfigStore, RepoConfigStore};
use tempfile::tempdir;

#[test]
fn app_config_round_trips_repositories_and_archives() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("config.toml");
    let store = AppConfigStore::new(path.clone());

    let mut config = AppConfig::default();
    config.repositories.push(alas::config::AppRepository {
        id: "repo-1".to_string(),
        path: PathBuf::from("/repo"),
        name: Some("repo".to_string()),
    });
    config.archived_worktrees.insert("repo-1".to_string(), vec![PathBuf::from("/repo/wt")]);

    store.save(&config).unwrap();
    assert_eq!(store.load().unwrap(), config);
}

#[test]
fn repo_config_store_writes_to_dot_alas_config() {
    let dir = tempdir().unwrap();
    let store = RepoConfigStore::for_repo(dir.path());
    let config = RepoConfigFile { default_command: Some("claude".to_string()), commands: None };

    store.save(&config).unwrap();

    assert!(dir.path().join(".alas/config.toml").exists());
    assert_eq!(store.load().unwrap().unwrap(), config);
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
cargo test --test config_tests
```

Expected: FAIL with missing store types.

- [ ] **Step 3: Implement app config store**

Create `src/config/app_config.rs`:

```rust
use crate::config::AppConfig;
use anyhow::Context;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
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

    pub fn load(&self) -> anyhow::Result<AppConfig> {
        if !self.path.exists() {
            return Ok(AppConfig::default());
        }
        let text = fs::read_to_string(&self.path)
            .with_context(|| format!("failed to read app config {}", self.path.display()))?;
        toml::from_str(&text).context("failed to parse app config")
    }

    pub fn save(&self, config: &AppConfig) -> anyhow::Result<()> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("failed to create config directory {}", parent.display()))?;
        }
        let text = toml::to_string_pretty(config).context("failed to serialize app config")?;
        fs::write(&self.path, text)
            .with_context(|| format!("failed to write app config {}", self.path.display()))
    }
}
```

- [ ] **Step 4: Implement repo config store**

Create `src/config/repo_config.rs`:

```rust
use crate::config::RepoConfigFile;
use anyhow::Context;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct RepoConfigStore {
    path: PathBuf,
}

impl RepoConfigStore {
    pub fn for_repo(repo_path: impl AsRef<Path>) -> Self {
        Self { path: repo_path.as_ref().join(".alas/config.toml") }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn load(&self) -> anyhow::Result<Option<RepoConfigFile>> {
        if !self.path.exists() {
            return Ok(None);
        }
        let text = fs::read_to_string(&self.path)
            .with_context(|| format!("failed to read repo config {}", self.path.display()))?;
        toml::from_str(&text).map(Some).context("failed to parse repo config")
    }

    pub fn save(&self, config: &RepoConfigFile) -> anyhow::Result<()> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("failed to create repo config directory {}", parent.display()))?;
        }
        let text = toml::to_string_pretty(config).context("failed to serialize repo config")?;
        fs::write(&self.path, text)
            .with_context(|| format!("failed to write repo config {}", self.path.display()))
    }
}
```

Modify `src/config/mod.rs` to export stores:

```rust
pub use app_config::AppConfigStore;
pub use repo_config::RepoConfigStore;
```

- [ ] **Step 5: Run tests**

Run:

```bash
cargo test --test config_tests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/config tests/config_tests.rs
git commit -m "feat: persist Alas configuration files"
```

---

## Task 4: Add Git Test Support

**Files:**
- Create: `tests/support/mod.rs`
- Create: `tests/support/git_repo.rs`
- Test: `tests/git_worktree_tests.rs`

- [ ] **Step 1: Write support helper and a failing smoke test**

Create `tests/support/mod.rs`:

```rust
pub mod git_repo;
```

Create `tests/support/git_repo.rs`:

```rust
use std::path::{Path, PathBuf};
use std::process::Command;
use tempfile::TempDir;

pub struct TestRepo {
    _temp: TempDir,
    path: PathBuf,
}

impl TestRepo {
    pub fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("repo");
        std::fs::create_dir(&path).unwrap();
        run(&path, &["init"]);
        run(&path, &["config", "user.email", "test@example.com"]);
        run(&path, &["config", "user.name", "Test User"]);
        std::fs::write(path.join("README.md"), "test\n").unwrap();
        run(&path, &["add", "README.md"]);
        run(&path, &["commit", "-m", "initial"]);
        Self { _temp: temp, path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn worktree_path(&self, name: &str) -> PathBuf {
        self.path.parent().unwrap().join(name)
    }
}

pub fn run(cwd: &Path, args: &[&str]) {
    let output = Command::new("git").args(args).current_dir(cwd).output().unwrap();
    assert!(output.status.success(), "git {:?} failed: {}", args, String::from_utf8_lossy(&output.stderr));
}
```

Create `tests/git_worktree_tests.rs`:

```rust
mod support;

#[test]
fn test_repo_helper_creates_valid_repo() {
    let repo = support::git_repo::TestRepo::new();
    assert!(repo.path().join(".git").exists());
}
```

- [ ] **Step 2: Run support smoke test**

Run:

```bash
cargo test --test git_worktree_tests test_repo_helper_creates_valid_repo -- --nocapture
```

Expected: PASS if Git is installed and available.

- [ ] **Step 3: Commit**

```bash
git add tests/support tests/git_worktree_tests.rs
git commit -m "test: add temporary Git repository support"
```

---

## Task 5: Implement Git Command Runner

**Files:**
- Create/Modify: `src/git/runner.rs`
- Modify: `src/git/mod.rs`
- Test: `tests/git_worktree_tests.rs`

- [ ] **Step 1: Add failing tests for command runner**

Append to `tests/git_worktree_tests.rs`:

```rust
use alas::git::GitRunner;

#[test]
fn git_runner_captures_stdout() {
    let repo = support::git_repo::TestRepo::new();
    let runner = GitRunner::new();

    let output = runner.run(repo.path(), &["rev-parse", "--is-inside-work-tree"]).unwrap();

    assert_eq!(output.stdout.trim(), "true");
}

#[test]
fn git_runner_reports_stderr_on_failure() {
    let repo = support::git_repo::TestRepo::new();
    let runner = GitRunner::new();

    let err = runner.run(repo.path(), &["not-a-real-command"]).unwrap_err();

    assert!(err.to_string().contains("not-a-real-command"));
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
cargo test --test git_worktree_tests git_runner -- --nocapture
```

Expected: FAIL with missing `GitRunner`.

- [ ] **Step 3: Implement runner**

Create `src/git/runner.rs`:

```rust
use anyhow::{anyhow, Context};
use std::path::Path;
use std::process::Command;

#[derive(Debug, Clone, Default)]
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
            .with_context(|| format!("failed to run git {:?} in {}", args, cwd.display()))?;

        let stdout = String::from_utf8_lossy(&output.stdout).to_string();
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();

        if !output.status.success() {
            return Err(anyhow!("git {:?} failed in {}: {}", args, cwd.display(), stderr.trim()));
        }

        Ok(GitOutput { stdout, stderr })
    }
}
```

Modify `src/git/mod.rs`:

```rust
pub mod inspector;
pub mod runner;
pub mod worktree;

pub use runner::{GitOutput, GitRunner};
```

- [ ] **Step 4: Run tests**

Run:

```bash
cargo test --test git_worktree_tests git_runner -- --nocapture
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/git tests/git_worktree_tests.rs
git commit -m "feat: add Git command runner"
```

---

## Task 6: Discover Git Worktrees

**Files:**
- Modify: `src/git/worktree.rs`
- Modify: `src/git/mod.rs`
- Test: `tests/git_worktree_tests.rs`

- [ ] **Step 1: Add failing tests for validation and discovery**

Append to `tests/git_worktree_tests.rs`:

```rust
use alas::git::{GitWorktreeService, WorktreeKind};

#[test]
fn validates_git_repository() {
    let repo = support::git_repo::TestRepo::new();
    let service = GitWorktreeService::new(GitRunner::new());

    service.validate_repository(repo.path()).unwrap();
}

#[test]
fn discovers_main_and_linked_worktrees() {
    let repo = support::git_repo::TestRepo::new();
    let linked = repo.worktree_path("feature-a");
    support::git_repo::run(repo.path(), &["worktree", "add", "-b", "feature-a", linked.to_str().unwrap(), "HEAD"]);

    let service = GitWorktreeService::new(GitRunner::new());
    let worktrees = service.list_worktrees(repo.path()).unwrap();

    assert!(worktrees.iter().any(|w| w.path == repo.path() && w.kind == WorktreeKind::Main));
    assert!(worktrees.iter().any(|w| w.path == linked && w.branch.as_deref() == Some("feature-a")));
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
cargo test --test git_worktree_tests discovers_main_and_linked_worktrees -- --nocapture
```

Expected: FAIL with missing service/types.

- [ ] **Step 3: Implement worktree discovery**

Create `src/git/worktree.rs`:

```rust
use crate::git::GitRunner;
use anyhow::Context;
use std::path::{Path, PathBuf};

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

#[derive(Debug, Clone)]
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
            .map(|_| ())
            .with_context(|| format!("{} is not a Git repository", repo_path.display()))
    }

    pub fn list_worktrees(&self, repo_path: &Path) -> anyhow::Result<Vec<WorktreeInfo>> {
        let output = self.runner.run(repo_path, &["worktree", "list", "--porcelain"])?;
        Ok(parse_worktree_porcelain(&output.stdout))
    }
}

fn parse_worktree_porcelain(input: &str) -> Vec<WorktreeInfo> {
    let mut result = Vec::new();
    let mut current_path: Option<PathBuf> = None;
    let mut current_head: Option<String> = None;
    let mut current_branch: Option<String> = None;
    let mut first = true;

    let mut flush = |result: &mut Vec<WorktreeInfo>, first: &mut bool, path: &mut Option<PathBuf>, head: &mut Option<String>, branch: &mut Option<String>| {
        if let Some(path) = path.take() {
            result.push(WorktreeInfo {
                path,
                branch: branch.take().map(|b| b.trim_start_matches("refs/heads/").to_string()),
                head: head.take(),
                kind: if *first { WorktreeKind::Main } else { WorktreeKind::Linked },
            });
            *first = false;
        }
    };

    for line in input.lines() {
        if line.is_empty() {
            flush(&mut result, &mut first, &mut current_path, &mut current_head, &mut current_branch);
            continue;
        }
        if let Some(path) = line.strip_prefix("worktree ") {
            current_path = Some(PathBuf::from(path));
        } else if let Some(head) = line.strip_prefix("HEAD ") {
            current_head = Some(head.to_string());
        } else if let Some(branch) = line.strip_prefix("branch ") {
            current_branch = Some(branch.to_string());
        }
    }
    flush(&mut result, &mut first, &mut current_path, &mut current_head, &mut current_branch);

    result
}
```

Modify `src/git/mod.rs`:

```rust
pub use worktree::{GitWorktreeService, WorktreeInfo, WorktreeKind};
```

- [ ] **Step 4: Run tests**

Run:

```bash
cargo test --test git_worktree_tests discovers_main_and_linked_worktrees -- --nocapture
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/git tests/git_worktree_tests.rs
git commit -m "feat: discover Git worktrees"
```

---

## Task 7: Create, Remove, and Prune Worktrees

**Files:**
- Modify: `src/git/worktree.rs`
- Test: `tests/git_worktree_tests.rs`

- [ ] **Step 1: Add failing tests**

Append to `tests/git_worktree_tests.rs`:

```rust
#[test]
fn creates_worktree_from_base_ref() {
    let repo = support::git_repo::TestRepo::new();
    let linked = repo.worktree_path("feature-b");
    let service = GitWorktreeService::new(GitRunner::new());

    service.create_worktree(repo.path(), "HEAD", "feature-b", &linked).unwrap();

    assert!(linked.exists());
    let worktrees = service.list_worktrees(repo.path()).unwrap();
    assert!(worktrees.iter().any(|w| w.path == linked));
}

#[test]
fn removes_linked_worktree_but_rejects_main_worktree() {
    let repo = support::git_repo::TestRepo::new();
    let linked = repo.worktree_path("feature-c");
    let service = GitWorktreeService::new(GitRunner::new());
    service.create_worktree(repo.path(), "HEAD", "feature-c", &linked).unwrap();

    service.remove_worktree(repo.path(), &linked).unwrap();
    assert!(!linked.exists());

    let err = service.remove_worktree(repo.path(), repo.path()).unwrap_err();
    assert!(err.to_string().contains("main worktree"));
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
cargo test --test git_worktree_tests worktree -- --nocapture
```

Expected: FAIL with missing methods.

- [ ] **Step 3: Implement operations**

Modify `src/git/worktree.rs`:

```rust
impl GitWorktreeService {
    pub fn create_worktree(
        &self,
        repo_path: &Path,
        base_ref: &str,
        branch_name: &str,
        target_path: &Path,
    ) -> anyhow::Result<()> {
        let target = target_path
            .to_str()
            .context("worktree target path must be valid UTF-8 for git CLI")?;
        self.runner.run(repo_path, &["worktree", "add", "-b", branch_name, target, base_ref])?;
        Ok(())
    }

    pub fn remove_worktree(&self, repo_path: &Path, worktree_path: &Path) -> anyhow::Result<()> {
        let worktrees = self.list_worktrees(repo_path)?;
        let info = worktrees
            .iter()
            .find(|w| w.path == worktree_path)
            .context("worktree not found")?;
        if info.kind == WorktreeKind::Main {
            anyhow::bail!("cannot remove main worktree from Alas");
        }
        let target = worktree_path
            .to_str()
            .context("worktree path must be valid UTF-8 for git CLI")?;
        self.runner.run(repo_path, &["worktree", "remove", target])?;
        Ok(())
    }

    pub fn prune_worktrees(&self, repo_path: &Path) -> anyhow::Result<()> {
        self.runner.run(repo_path, &["worktree", "prune"])?;
        Ok(())
    }
}
```

- [ ] **Step 4: Run tests**

Run:

```bash
cargo test --test git_worktree_tests -- --nocapture
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/git/worktree.rs tests/git_worktree_tests.rs
git commit -m "feat: manage Git worktrees"
```

---

## Task 8: Implement Git Inspector Service

**Files:**
- Modify: `src/git/inspector.rs`
- Modify: `src/git/mod.rs`
- Test: `tests/git_worktree_tests.rs`

- [ ] **Step 1: Add failing tests for changed files and commits**

Append to `tests/git_worktree_tests.rs`:

```rust
use alas::git::GitInspectorService;

#[test]
fn inspector_reports_changed_files_and_recent_commits() {
    let repo = support::git_repo::TestRepo::new();
    std::fs::write(repo.path().join("README.md"), "changed\n").unwrap();

    let inspector = GitInspectorService::new(GitRunner::new());
    let state = inspector.inspect(repo.path(), 5).unwrap();

    assert!(state.changed_files.iter().any(|f| f.path == "README.md"));
    assert!(state.recent_commits.iter().any(|c| c.summary.contains("initial")));
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
cargo test --test git_worktree_tests inspector_reports -- --nocapture
```

Expected: FAIL with missing inspector service.

- [ ] **Step 3: Implement inspector**

Create `src/git/inspector.rs`:

```rust
use crate::git::GitRunner;
use std::path::Path;

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

#[derive(Debug, Clone)]
pub struct GitInspectorService {
    runner: GitRunner,
}

impl GitInspectorService {
    pub fn new(runner: GitRunner) -> Self {
        Self { runner }
    }

    pub fn inspect(&self, worktree_path: &Path, commit_limit: usize) -> anyhow::Result<GitInspectorState> {
        let branch = self
            .runner
            .run(worktree_path, &["branch", "--show-current"])?
            .stdout
            .trim()
            .to_string();

        let status = self.runner.run(worktree_path, &["status", "--short"])?;
        let changed_files = status
            .stdout
            .lines()
            .filter_map(|line| {
                if line.len() < 4 {
                    return None;
                }
                Some(ChangedFile {
                    status: line[..2].trim().to_string(),
                    path: line[3..].to_string(),
                })
            })
            .collect();

        let limit_arg = format!("-n{}", commit_limit);
        let log = self.runner.run(worktree_path, &["log", "--oneline", &limit_arg])?;
        let recent_commits = log
            .stdout
            .lines()
            .filter_map(|line| {
                let (hash, summary) = line.split_once(' ')?;
                Some(RecentCommit { hash: hash.to_string(), summary: summary.to_string() })
            })
            .collect();

        Ok(GitInspectorState {
            branch: if branch.is_empty() { None } else { Some(branch) },
            changed_files,
            recent_commits,
        })
    }
}
```

Modify `src/git/mod.rs`:

```rust
pub use inspector::{ChangedFile, GitInspectorService, GitInspectorState, RecentCommit};
```

- [ ] **Step 4: Run tests**

Run:

```bash
cargo test --test git_worktree_tests inspector_reports -- --nocapture
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/git tests/git_worktree_tests.rs
git commit -m "feat: inspect selected worktree Git state"
```

---

## Task 9: Implement App Model State Transitions

**Files:**
- Create/Modify: `src/app/actions.rs`
- Create/Modify: `src/app/model.rs`
- Modify: `src/app/mod.rs`
- Test: `tests/app_model_tests.rs`

- [ ] **Step 1: Write failing app model tests**

Create `tests/app_model_tests.rs`:

```rust
use alas::app::{AlasModel, RepositoryNode, WorktreeNode};
use alas::git::{WorktreeInfo, WorktreeKind};
use std::path::PathBuf;

fn worktree(path: &str, kind: WorktreeKind) -> WorktreeInfo {
    WorktreeInfo {
        path: PathBuf::from(path),
        branch: Some("main".to_string()),
        head: Some("abc".to_string()),
        kind,
    }
}

#[test]
fn selecting_worktree_updates_selection() {
    let mut model = AlasModel::default();
    model.set_repositories(vec![RepositoryNode {
        id: "repo-1".to_string(),
        name: "repo".to_string(),
        path: PathBuf::from("/repo"),
        worktrees: vec![WorktreeNode::from_info(worktree("/repo", WorktreeKind::Main), false)],
        show_archived: false,
        unavailable: false,
    }]);

    model.select_worktree("repo-1", PathBuf::from("/repo"));

    assert_eq!(model.selected_worktree().unwrap().repo_id, "repo-1");
}

#[test]
fn archived_worktrees_are_hidden_until_repo_shows_archived() {
    let mut model = AlasModel::default();
    let archived = WorktreeNode::from_info(worktree("/repo/old", WorktreeKind::Linked), true);
    model.set_repositories(vec![RepositoryNode {
        id: "repo-1".to_string(),
        name: "repo".to_string(),
        path: PathBuf::from("/repo"),
        worktrees: vec![archived],
        show_archived: false,
        unavailable: false,
    }]);

    assert!(model.visible_worktrees("repo-1").unwrap().is_empty());
    model.set_show_archived("repo-1", true);
    assert_eq!(model.visible_worktrees("repo-1").unwrap().len(), 1);
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
cargo test --test app_model_tests
```

Expected: FAIL with missing app model types.

- [ ] **Step 3: Implement app model**

Create `src/app/model.rs`:

```rust
use crate::git::{WorktreeInfo, WorktreeKind};
use std::path::PathBuf;

#[derive(Debug, Clone, Default)]
pub struct AlasModel {
    repositories: Vec<RepositoryNode>,
    selected: Option<SelectedWorktree>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RepositoryNode {
    pub id: String,
    pub name: String,
    pub path: PathBuf,
    pub worktrees: Vec<WorktreeNode>,
    pub show_archived: bool,
    pub unavailable: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorktreeNode {
    pub path: PathBuf,
    pub branch: Option<String>,
    pub head: Option<String>,
    pub kind: WorktreeKind,
    pub archived: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SelectedWorktree {
    pub repo_id: String,
    pub path: PathBuf,
}

impl WorktreeNode {
    pub fn from_info(info: WorktreeInfo, archived: bool) -> Self {
        Self {
            path: info.path,
            branch: info.branch,
            head: info.head,
            kind: info.kind,
            archived,
        }
    }
}

impl AlasModel {
    pub fn set_repositories(&mut self, repositories: Vec<RepositoryNode>) {
        self.repositories = repositories;
    }

    pub fn repositories(&self) -> &[RepositoryNode] {
        &self.repositories
    }

    pub fn select_worktree(&mut self, repo_id: impl Into<String>, path: PathBuf) {
        self.selected = Some(SelectedWorktree { repo_id: repo_id.into(), path });
    }

    pub fn selected_worktree(&self) -> Option<&SelectedWorktree> {
        self.selected.as_ref()
    }

    pub fn set_show_archived(&mut self, repo_id: &str, show: bool) {
        if let Some(repo) = self.repositories.iter_mut().find(|repo| repo.id == repo_id) {
            repo.show_archived = show;
        }
    }

    pub fn visible_worktrees(&self, repo_id: &str) -> Option<Vec<&WorktreeNode>> {
        let repo = self.repositories.iter().find(|repo| repo.id == repo_id)?;
        Some(repo.worktrees.iter().filter(|wt| repo.show_archived || !wt.archived).collect())
    }
}
```

Create `src/app/actions.rs`:

```rust
use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AppAction {
    AddRepository(PathBuf),
    RemoveRepository(String),
    SelectWorktree { repo_id: String, path: PathBuf },
    ArchiveWorktree { repo_id: String, path: PathBuf },
    UnarchiveWorktree { repo_id: String, path: PathBuf },
    ShowArchived { repo_id: String, show: bool },
    CreateWorktree { repo_id: String, base_ref: String, branch_name: String, target_path: PathBuf },
    RemoveWorktree { repo_id: String, path: PathBuf },
    PruneWorktrees { repo_id: String },
}
```

Modify `src/app/mod.rs`:

```rust
pub mod actions;
pub mod model;

pub use actions::AppAction;
pub use model::{AlasModel, RepositoryNode, SelectedWorktree, WorktreeNode};
```

- [ ] **Step 4: Run tests**

Run:

```bash
cargo test --test app_model_tests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/app tests/app_model_tests.rs
git commit -m "feat: add Alas app model"
```

---

## Task 10: Implement Terminal Session Registry

**Files:**
- Create/Modify: `src/terminal/session.rs`
- Modify: `src/terminal/mod.rs`
- Test: `tests/terminal_session_tests.rs`

- [ ] **Step 1: Write failing terminal registry tests**

Create `tests/terminal_session_tests.rs`:

```rust
use alas::terminal::{CommandSpec, TerminalSessionId, TerminalSessionRegistry};
use std::path::PathBuf;

#[test]
fn session_id_is_stable_for_repo_and_worktree() {
    let a = TerminalSessionId::new("repo-1", PathBuf::from("/repo/wt"));
    let b = TerminalSessionId::new("repo-1", PathBuf::from("/repo/wt"));
    assert_eq!(a, b);
}

#[test]
fn registry_reuses_existing_session_for_worktree() {
    let mut registry = TerminalSessionRegistry::default();
    let id = TerminalSessionId::new("repo-1", PathBuf::from("/repo/wt"));
    let command = CommandSpec { command: "claude".to_string(), cwd: PathBuf::from("/repo/wt") };

    let first = registry.get_or_create(id.clone(), command.clone());
    let second = registry.get_or_create(id, command);

    assert_eq!(first.handle, second.handle);
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
cargo test --test terminal_session_tests
```

Expected: FAIL with missing terminal types.

- [ ] **Step 3: Implement terminal registry**

Create `src/terminal/session.rs`:

```rust
use std::collections::HashMap;
use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct TerminalSessionId {
    repo_id: String,
    worktree_path: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandSpec {
    pub command: String,
    pub cwd: PathBuf,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TerminalHandle(pub u64);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalSessionRef {
    pub id: TerminalSessionId,
    pub handle: TerminalHandle,
    pub command: CommandSpec,
}

#[derive(Debug, Default)]
pub struct TerminalSessionRegistry {
    next_handle: u64,
    sessions: HashMap<TerminalSessionId, TerminalSessionRef>,
}

impl TerminalSessionId {
    pub fn new(repo_id: impl Into<String>, worktree_path: PathBuf) -> Self {
        Self { repo_id: repo_id.into(), worktree_path }
    }
}

impl TerminalSessionRegistry {
    pub fn get_or_create(&mut self, id: TerminalSessionId, command: CommandSpec) -> TerminalSessionRef {
        if let Some(existing) = self.sessions.get(&id) {
            return existing.clone();
        }
        self.next_handle += 1;
        let session = TerminalSessionRef { id: id.clone(), handle: TerminalHandle(self.next_handle), command };
        self.sessions.insert(id, session.clone());
        session
    }
}
```

Modify `src/terminal/mod.rs`:

```rust
pub mod ghostty_adapter;
pub mod session;

pub use session::{CommandSpec, TerminalHandle, TerminalSessionId, TerminalSessionRef, TerminalSessionRegistry};
```

- [ ] **Step 4: Run tests**

Run:

```bash
cargo test --test terminal_session_tests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/terminal tests/terminal_session_tests.rs
git commit -m "feat: track persistent terminal sessions"
```

---

## Task 11: Add Terminal Backend Trait and Ghostty Adapter Boundary

**Files:**
- Modify: `src/terminal/ghostty_adapter.rs`
- Modify: `src/terminal/mod.rs`
- Test: `tests/terminal_session_tests.rs`

- [ ] **Step 1: Add failing backend contract test with fake backend**

Append to `tests/terminal_session_tests.rs`:

```rust
use alas::terminal::{TerminalBackend, TerminalBackendSession};

#[derive(Default)]
struct FakeBackend {
    started: Vec<CommandSpec>,
}

impl TerminalBackend for FakeBackend {
    fn start(&mut self, command: CommandSpec) -> anyhow::Result<TerminalBackendSession> {
        self.started.push(command);
        Ok(TerminalBackendSession { backend_id: self.started.len() as u64 })
    }
}

#[test]
fn backend_starts_command_in_worktree_cwd() {
    let mut backend = FakeBackend::default();
    let command = CommandSpec { command: "claude".to_string(), cwd: PathBuf::from("/repo/wt") };

    let session = backend.start(command.clone()).unwrap();

    assert_eq!(session.backend_id, 1);
    assert_eq!(backend.started, vec![command]);
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
cargo test --test terminal_session_tests backend_starts -- --nocapture
```

Expected: FAIL with missing trait/types.

- [ ] **Step 3: Implement backend boundary**

Create `src/terminal/ghostty_adapter.rs`:

```rust
use crate::terminal::CommandSpec;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalBackendSession {
    pub backend_id: u64,
}

pub trait TerminalBackend {
    fn start(&mut self, command: CommandSpec) -> anyhow::Result<TerminalBackendSession>;
}

#[derive(Debug, Default)]
pub struct GhosttyTerminalBackend {
    next_id: u64,
}

impl GhosttyTerminalBackend {
    pub fn new() -> Self {
        Self::default()
    }
}

impl TerminalBackend for GhosttyTerminalBackend {
    fn start(&mut self, _command: CommandSpec) -> anyhow::Result<TerminalBackendSession> {
        // Placeholder for the real libghostty-rs integration. Keep this boundary stable:
        // GPUI and app model code must depend on TerminalBackend, not on libghostty types.
        self.next_id += 1;
        Ok(TerminalBackendSession { backend_id: self.next_id })
    }
}
```

Modify `src/terminal/mod.rs`:

```rust
pub use ghostty_adapter::{GhosttyTerminalBackend, TerminalBackend, TerminalBackendSession};
```

- [ ] **Step 4: Run tests**

Run:

```bash
cargo test --test terminal_session_tests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/terminal tests/terminal_session_tests.rs
git commit -m "feat: isolate terminal backend integration"
```

---

## Task 11A: Connect Terminal Registry to Backend Sessions and Command Resolution

**Files:**
- Modify: `src/terminal/session.rs`
- Modify: `src/terminal/ghostty_adapter.rs`
- Modify: `src/terminal/mod.rs`
- Test: `tests/terminal_session_tests.rs`

- [ ] **Step 1: Add failing tests for one backend start per worktree**

Append to `tests/terminal_session_tests.rs`:

```rust
#[derive(Default)]
struct CountingBackend {
    starts: usize,
}

impl TerminalBackend for CountingBackend {
    fn start(&mut self, command: CommandSpec) -> anyhow::Result<TerminalBackendSession> {
        self.starts += 1;
        assert_eq!(command.cwd, PathBuf::from("/repo/wt"));
        Ok(TerminalBackendSession { backend_id: self.starts as u64 })
    }
}

#[test]
fn registry_starts_backend_once_per_session_id() {
    let mut registry = TerminalSessionRegistry::default();
    let mut backend = CountingBackend::default();
    let id = TerminalSessionId::new("repo-1", PathBuf::from("/repo/wt"));
    let command = CommandSpec::shell_command("claude", PathBuf::from("/repo/wt"));

    let first = registry.get_or_start(id.clone(), command.clone(), &mut backend).unwrap();
    let second = registry.get_or_start(id, command, &mut backend).unwrap();

    assert_eq!(first.backend_session.backend_id, second.backend_session.backend_id);
    assert_eq!(backend.starts, 1);
}

#[test]
fn command_spec_runs_through_shell_with_cwd() {
    let command = CommandSpec::shell_command("$SHELL", PathBuf::from("/repo/wt"));
    assert_eq!(command.display, "$SHELL");
    assert_eq!(command.program, default_shell_program());
    assert_eq!(command.args.last().unwrap(), "$SHELL");
    assert_eq!(command.cwd, PathBuf::from("/repo/wt"));
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
cargo test --test terminal_session_tests registry_starts_backend_once -- --nocapture
```

Expected: FAIL with missing `get_or_start`, `backend_session`, and command-resolution helpers.

- [ ] **Step 3: Extend command specs**

Modify `CommandSpec` in `src/terminal/session.rs` so terminal commands have explicit process execution details:

```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandSpec {
    pub display: String,
    pub program: String,
    pub args: Vec<String>,
    pub cwd: PathBuf,
}

pub fn default_shell_program() -> String {
    std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string())
}

impl CommandSpec {
    pub fn shell_command(command: impl Into<String>, cwd: PathBuf) -> Self {
        let command = command.into();
        let shell = default_shell_program();
        Self {
            display: command.clone(),
            program: shell,
            args: vec!["-lc".to_string(), command],
            cwd,
        }
    }
}
```

V1 intentionally executes configured command strings through the user's shell (`$SHELL -lc <command>`) rather than implementing custom argv parsing. This supports `$SHELL`, `claude`, `codex --flag`, aliases/functions provided by the shell, and cwd isolation. The terminal backend owns the child process/PTY lifecycle.

Update earlier tests and call sites that constructed `CommandSpec { command, cwd }` to use `CommandSpec::shell_command(command, cwd)` and assert against `display`, `program`, `args`, and `cwd`. Also update the earlier `registry_reuses_existing_session_for_worktree` test to use `get_or_start` with a fake backend; remove `get_or_create` from production code rather than keeping two registry creation paths.

Export the shell helper from `src/terminal/mod.rs` so tests can import it:

```rust
pub use session::{default_shell_program, CommandSpec, TerminalHandle, TerminalSessionId, TerminalSessionRef, TerminalSessionRegistry};
```

Update the test import to:

```rust
use alas::terminal::{default_shell_program, CommandSpec, TerminalSessionId, TerminalSessionRegistry};
```

- [ ] **Step 4: Store backend sessions in registry**

Modify `TerminalSessionRef` and `TerminalSessionRegistry`. Add this import at the top of `src/terminal/session.rs`:

```rust
use crate::terminal::TerminalBackendSession;
```

Then replace the old `get_or_create` implementation with `get_or_start`:

```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalSessionRef {
    pub id: TerminalSessionId,
    pub handle: TerminalHandle,
    pub command: CommandSpec,
    pub backend_session: TerminalBackendSession,
}

impl TerminalSessionRegistry {
    pub fn get_or_start<B: crate::terminal::TerminalBackend>(
        &mut self,
        id: TerminalSessionId,
        command: CommandSpec,
        backend: &mut B,
    ) -> anyhow::Result<TerminalSessionRef> {
        if let Some(existing) = self.sessions.get(&id) {
            return Ok(existing.clone());
        }
        self.next_handle += 1;
        let backend_session = backend.start(command.clone())?;
        let session = TerminalSessionRef {
            id: id.clone(),
            handle: TerminalHandle(self.next_handle),
            command,
            backend_session,
        };
        self.sessions.insert(id, session.clone());
        Ok(session)
    }
}
```

Do not keep the old `get_or_create` implementation after this change. A terminal session is valid only when it has a matching `TerminalBackendSession`, so all tests and production code should use `get_or_start`.

- [ ] **Step 5: Run tests**

Run:

```bash
cargo test --test terminal_session_tests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/terminal tests/terminal_session_tests.rs
git commit -m "feat: start one terminal backend per worktree session"
```

---

## Task 12: Build Repository Refresh Orchestration

**Files:**
- Modify: `src/app/model.rs`
- Modify: `src/config/types.rs`
- Test: `tests/app_model_tests.rs`

- [ ] **Step 1: Add failing test for mapping app config + Git discovery into sidebar nodes**

Append to `tests/app_model_tests.rs`:

```rust
use alas::config::{AppConfig, AppRepository};

#[test]
fn model_builds_repository_nodes_with_archived_flags() {
    let mut config = AppConfig::default();
    config.repositories.push(AppRepository {
        id: "repo-1".to_string(),
        path: PathBuf::from("/repo"),
        name: Some("repo".to_string()),
    });
    config.archived_worktrees.insert("repo-1".to_string(), vec![PathBuf::from("/repo/old")]);

    let nodes = AlasModel::repository_nodes_from_discovery(
        &config,
        "repo-1",
        vec![
            worktree("/repo", WorktreeKind::Main),
            worktree("/repo/old", WorktreeKind::Linked),
        ],
    );

    assert_eq!(nodes.len(), 1);
    assert!(!nodes[0].worktrees[0].archived);
    assert!(nodes[0].worktrees[1].archived);
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
cargo test --test app_model_tests model_builds -- --nocapture
```

Expected: FAIL with missing method.

- [ ] **Step 3: Implement mapping helper**

Add to `impl AlasModel` in `src/app/model.rs`:

```rust
pub fn repository_nodes_from_discovery(
    config: &crate::config::AppConfig,
    repo_id: &str,
    worktrees: Vec<crate::git::WorktreeInfo>,
) -> Vec<RepositoryNode> {
    let Some(repo) = config.repositories.iter().find(|repo| repo.id == repo_id) else {
        return Vec::new();
    };
    let archived = config.archived_worktrees.get(repo_id).cloned().unwrap_or_default();
    let worktrees = worktrees
        .into_iter()
        .map(|info| {
            let is_archived = archived.iter().any(|path| path == &info.path);
            WorktreeNode::from_info(info, is_archived)
        })
        .collect();

    vec![RepositoryNode {
        id: repo.id.clone(),
        name: repo.name.clone().unwrap_or_else(|| repo.path.file_name().and_then(|n| n.to_str()).unwrap_or("repository").to_string()),
        path: repo.path.clone(),
        worktrees,
        show_archived: false,
        unavailable: false,
    }]
}
```

- [ ] **Step 4: Run tests**

Run:

```bash
cargo test --test app_model_tests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/app tests/app_model_tests.rs
git commit -m "feat: map repository discovery into app state"
```

---

## Task 13: Create GPUI Main Window Skeleton

**Files:**
- Modify: `src/ui/mod.rs`
- Modify: `src/ui/shell.rs`
- Modify: `src/main.rs`

- [ ] **Step 1: Replace placeholder UI run function with GPUI app startup**

Implement `src/ui/shell.rs` with a minimal renderable root component. Adapt imports to the installed GPUI version if needed:

```rust
use gpui::{div, prelude::*, App, Application, Context, IntoElement, Render, WindowOptions};

pub struct AlasShell;

impl Render for AlasShell {
    fn render(&mut self, _window: &mut gpui::Window, _cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .flex()
            .size_full()
            .child("Alas")
    }
}

pub fn run() -> anyhow::Result<()> {
    Application::new().run(|cx: &mut App| {
        cx.open_window(WindowOptions::default(), |_, cx| cx.new(|_| AlasShell))
            .expect("failed to open Alas window");
    });
    Ok(())
}
```

Modify `src/ui/mod.rs`:

```rust
pub mod dialogs;
pub mod inspector;
pub mod shell;
pub mod sidebar;
pub mod terminal_pane;

pub use shell::run;
```

- [ ] **Step 2: Run compile check**

Run:

```bash
cargo check
```

Expected: PASS. If it fails due to GPUI API drift, consult `crates/gpui/README.md` and examples from Zed, then adapt only `src/ui/shell.rs` and dependency declarations.

- [ ] **Step 3: Run app manually**

Run:

```bash
cargo run
```

Expected: a native window opens with text `Alas`.

- [ ] **Step 4: Commit**

```bash
git add src/ui src/main.rs Cargo.toml
git commit -m "feat: open GPUI main window"
```

---

## Task 14: Render Three-Pane Layout with Static Data

**Files:**
- Modify: `src/ui/shell.rs`
- Modify: `src/ui/sidebar.rs`
- Modify: `src/ui/terminal_pane.rs`
- Modify: `src/ui/inspector.rs`

- [ ] **Step 1: Implement static sidebar renderer**

Create `src/ui/sidebar.rs`:

```rust
use crate::app::RepositoryNode;
use gpui::{div, prelude::*, IntoElement};

pub fn render_sidebar(repositories: &[RepositoryNode]) -> impl IntoElement {
    let mut root = div().w(px(280.0)).h_full().p_3().border_r_1().child("Repositories");
    for repo in repositories {
        root = root.child(div().mt_3().font_weight(gpui::FontWeight::BOLD).child(repo.name.clone()));
        root = root.child(div().text_sm().child("+ Worktree"));
        for worktree in &repo.worktrees {
            if repo.show_archived || !worktree.archived {
                let label = worktree.branch.clone().unwrap_or_else(|| worktree.path.display().to_string());
                root = root.child(div().ml_3().mt_1().child(label));
            }
        }
    }
    root
}
```

- [ ] **Step 2: Implement static terminal and inspector renderers**

Create `src/ui/terminal_pane.rs`:

```rust
use gpui::{div, prelude::*, IntoElement};

pub fn render_terminal_placeholder() -> impl IntoElement {
    div()
        .flex_1()
        .h_full()
        .p_3()
        .child("Terminal will render here")
}
```

Create `src/ui/inspector.rs`:

```rust
use gpui::{div, prelude::*, IntoElement};

pub fn render_inspector_placeholder() -> impl IntoElement {
    div()
        .w(px(320.0))
        .h_full()
        .p_3()
        .border_l_1()
        .child("Git Inspector")
}
```

- [ ] **Step 3: Wire shell to use the panes**

Modify `src/ui/shell.rs` to create a small static `AlasModel` in `AlasShell` and render:

```rust
div()
    .flex()
    .size_full()
    .child(crate::ui::sidebar::render_sidebar(self.model.repositories()))
    .child(crate::ui::terminal_pane::render_terminal_placeholder())
    .child(crate::ui::inspector::render_inspector_placeholder())
```

- [ ] **Step 4: Run compile and manual check**

Run:

```bash
cargo check
cargo run
```

Expected: window shows left sidebar, center placeholder, right inspector placeholder.

- [ ] **Step 5: Commit**

```bash
git add src/ui
git commit -m "feat: render Alas three-pane shell"
```

---

## Task 15: Wire App Config Loading into UI Startup

**Files:**
- Modify: `src/ui/shell.rs`
- Modify: `src/config/app_config.rs`
- Modify: `src/ui/sidebar.rs`

- [ ] **Step 1: Add default app config path helper**

Modify `src/config/app_config.rs`:

```rust
impl AppConfigStore {
    pub fn default_path() -> anyhow::Result<std::path::PathBuf> {
        let dirs = directories::ProjectDirs::from("dev", "alas", "Alas")
            .ok_or_else(|| anyhow::anyhow!("failed to resolve app config directory"))?;
        Ok(dirs.config_dir().join("config.toml"))
    }

    pub fn default_store() -> anyhow::Result<Self> {
        Ok(Self::new(Self::default_path()?))
    }
}
```

- [ ] **Step 2: Load config in shell startup**

In `src/ui/shell.rs`, initialize `AlasShell` with loaded `AppConfig`. For repositories, show configured repositories even before worktree refresh is wired:

```rust
let config = crate::config::AppConfigStore::default_store()
    .and_then(|store| store.load())
    .unwrap_or_default();
```

Map `config.repositories` into `RepositoryNode` values with empty `worktrees`.

- [ ] **Step 3: Run compile check**

Run:

```bash
cargo check
```

Expected: PASS.

- [ ] **Step 4: Manual config check**

Create a temporary config at the default app config path with one repository path, run `cargo run`, and verify it appears in sidebar. Remove or restore the temp config after checking.

- [ ] **Step 5: Commit**

```bash
git add src/config src/ui
git commit -m "feat: load configured repositories in UI"
```

---

## Task 16: Implement Add/Remove Repository UI Flow

**Files:**
- Modify: `src/ui/dialogs.rs`
- Modify: `src/app/actions.rs`
- Modify: `src/ui/sidebar.rs`
- Modify: `src/ui/shell.rs`

- [ ] **Step 1: Create dialog state types**

In `src/ui/dialogs.rs`:

```rust
use std::path::PathBuf;

#[derive(Debug, Clone, Default)]
pub struct AddRepositoryDialogState {
    pub path_text: String,
    pub error: Option<String>,
}

impl AddRepositoryDialogState {
    pub fn selected_path(&self) -> Option<PathBuf> {
        let trimmed = self.path_text.trim();
        if trimmed.is_empty() { None } else { Some(PathBuf::from(trimmed)) }
    }
}

#[derive(Debug, Clone)]
pub struct ConfirmRemoveRepositoryDialog {
    pub repo_id: String,
    pub repo_name: String,
}
```

- [ ] **Step 2: Add repository id helper**

Add a helper in `src/config/types.rs` or `src/ui/shell.rs` to create stable local repository ids from canonical paths:

```rust
fn repository_id_for_path(path: &std::path::Path) -> String {
    path.canonicalize()
        .unwrap_or_else(|_| path.to_path_buf())
        .to_string_lossy()
        .replace(['/', '\\', ':'], "_")
}
```

- [ ] **Step 3: Wire Add Repository flow**

In `src/ui/shell.rs`, implement a submit handler for `AddRepositoryDialogState`:

```rust
fn add_repository_from_dialog(&mut self) {
    let Some(path) = self.add_repository_dialog.as_ref().and_then(|dialog| dialog.selected_path()) else {
        self.set_add_repository_error("Repository path is required");
        return;
    };

    let runner = crate::git::GitRunner::new();
    let service = crate::git::GitWorktreeService::new(runner);
    if let Err(error) = service.validate_repository(&path) {
        self.set_add_repository_error(&error.to_string());
        return;
    }

    let id = repository_id_for_path(&path);
    if !self.config.repositories.iter().any(|repo| repo.id == id) {
        self.config.repositories.push(crate::config::AppRepository {
            id,
            path: path.clone(),
            name: path.file_name().and_then(|name| name.to_str()).map(str::to_string),
        });
    }

    if let Err(error) = self.app_config_store.save(&self.config) {
        self.set_add_repository_error(&error.to_string());
        return;
    }

    self.add_repository_dialog = None;
    self.refresh_repositories();
}
```

If a native folder picker is not available in the current GPUI version, keep the path text field for v1 and isolate folder-picker work to `src/ui/dialogs.rs` later.

- [ ] **Step 4: Wire Remove Repository flow**

In `src/ui/shell.rs`, implement confirmed repository removal:

```rust
fn remove_repository_from_alas(&mut self, repo_id: &str) -> anyhow::Result<()> {
    self.config.repositories.retain(|repo| repo.id != repo_id);
    self.config.archived_worktrees.shift_remove(repo_id);
    if self.model.selected_worktree().is_some_and(|selected| selected.repo_id == repo_id) {
        self.clear_selection_and_active_terminal();
    }
    self.app_config_store.save(&self.config)?;
    self.refresh_repositories();
    Ok(())
}
```

Define `clear_selection_and_active_terminal` in `src/ui/shell.rs` before using it:

```rust
fn clear_selection_and_active_terminal(&mut self) {
    self.model.clear_selection();
    self.active_terminal = None;
    self.git_inspector = None;
    self.git_inspector_error = None;
}
```

Add the matching model method in `src/app/model.rs`:

```rust
pub fn clear_selection(&mut self) {
    self.selected = None;
}
```

The confirmation copy must say: "This removes the repository from Alas only. It does not delete repository files or worktrees."

- [ ] **Step 5: Run compile/manual check**

Run:

```bash
cargo check
cargo run
```

Expected: user can add a valid Git repo, invalid paths show an error, removing a repo updates app config and does not delete files.

- [ ] **Step 6: Commit**

```bash
git add src/ui src/app/actions.rs src/config
git commit -m "feat: manage repositories from the UI"
```

---

## Task 17: Wire Worktree Discovery Refresh

**Files:**
- Modify: `src/ui/shell.rs`
- Modify: `src/app/model.rs`
- Modify: `src/git/worktree.rs`

- [ ] **Step 1: Add synchronous refresh method for v1**

In `src/ui/shell.rs`, add a method on `AlasShell`:

```rust
fn refresh_repositories(&mut self) {
    let runner = crate::git::GitRunner::new();
    let service = crate::git::GitWorktreeService::new(runner);
    let mut nodes = Vec::new();

    for repo in &self.config.repositories {
        match service.list_worktrees(&repo.path) {
            Ok(worktrees) => {
                nodes.extend(crate::app::AlasModel::repository_nodes_from_discovery(&self.config, &repo.id, worktrees));
            }
            Err(_) => {
                nodes.push(crate::app::RepositoryNode {
                    id: repo.id.clone(),
                    name: repo.name.clone().unwrap_or_else(|| repo.path.display().to_string()),
                    path: repo.path.clone(),
                    worktrees: Vec::new(),
                    show_archived: false,
                    unavailable: true,
                });
            }
        }
    }

    self.model.set_repositories(nodes);
}
```

Call it during shell initialization.

- [ ] **Step 2: Update sidebar to show unavailable repositories**

In `src/ui/sidebar.rs`, render unavailable repositories with an `Unavailable` label and do not show `+ Worktree` for them.

- [ ] **Step 3: Run compile/manual check**

Run:

```bash
cargo check
cargo run
```

Expected: configured repositories show their discovered worktrees.

- [ ] **Step 4: Commit**

```bash
git add src/ui src/app
git commit -m "feat: refresh worktrees from Git discovery"
```

---

## Task 18: Implement Archive/Unarchive State Persistence

**Files:**
- Modify: `src/ui/sidebar.rs`
- Modify: `src/ui/shell.rs`
- Modify: `src/config/types.rs`
- Test: `tests/app_model_tests.rs`

- [ ] **Step 1: Add model test for archive mutation**

Append to `tests/app_model_tests.rs`:

```rust
#[test]
fn archiving_and_unarchiving_updates_app_config_paths() {
    let mut config = AppConfig::default();

    config.archive_worktree("repo-1", PathBuf::from("/repo/old"));
    assert_eq!(config.archived_worktrees["repo-1"], vec![PathBuf::from("/repo/old")]);

    config.unarchive_worktree("repo-1", &PathBuf::from("/repo/old"));
    assert!(config.archived_worktrees.get("repo-1").unwrap().is_empty());
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
cargo test --test app_model_tests archiving_and_unarchiving -- --nocapture
```

Expected: FAIL with missing methods.

- [ ] **Step 3: Implement archive helpers**

Add to `impl AppConfig` in `src/config/types.rs`:

```rust
impl AppConfig {
    pub fn archive_worktree(&mut self, repo_id: &str, path: PathBuf) {
        let paths = self.archived_worktrees.entry(repo_id.to_string()).or_default();
        if !paths.iter().any(|existing| existing == &path) {
            paths.push(path);
        }
    }

    pub fn unarchive_worktree(&mut self, repo_id: &str, path: &PathBuf) {
        if let Some(paths) = self.archived_worktrees.get_mut(repo_id) {
            paths.retain(|existing| existing != path);
        }
    }
}
```

- [ ] **Step 4: Wire sidebar actions**

Add context-menu or temporary visible action buttons for archive/unarchive. On action:

1. Mutate `self.config`.
2. Save via `AppConfigStore`.
3. Refresh repositories.

If GPUI context menus require extra API work, use visible `Archive`/`Unarchive` buttons first and leave context-menu polish to Task 25.

- [ ] **Step 5: Run tests and manual check**

Run:

```bash
cargo test --test app_model_tests
cargo check
cargo run
```

Expected: archive state persists and hidden worktrees are filtered.

- [ ] **Step 6: Commit**

```bash
git add src/config src/ui tests/app_model_tests.rs
git commit -m "feat: archive worktrees locally"
```

---

## Task 19: Add Create Worktree Dialog and Flow

**Files:**
- Modify: `src/ui/dialogs.rs`
- Modify: `src/ui/sidebar.rs`
- Modify: `src/ui/shell.rs`
- Modify: `src/git/worktree.rs`

- [ ] **Step 1: Add create dialog state**

In `src/ui/dialogs.rs`:

```rust
#[derive(Debug, Clone, Default)]
pub struct CreateWorktreeDialogState {
    pub repo_id: String,
    pub base_ref: String,
    pub branch_name: String,
    pub target_path_text: String,
    pub error: Option<String>,
}

impl CreateWorktreeDialogState {
    pub fn target_path(&self) -> Option<PathBuf> {
        let trimmed = self.target_path_text.trim();
        if trimmed.is_empty() { None } else { Some(PathBuf::from(trimmed)) }
    }

    pub fn validate(&self) -> Result<PathBuf, String> {
        if self.base_ref.trim().is_empty() {
            return Err("Base branch or commit is required".to_string());
        }
        if self.branch_name.trim().is_empty() {
            return Err("New branch name is required".to_string());
        }
        self.target_path().ok_or_else(|| "Target path is required".to_string())
    }
}
```

- [ ] **Step 2: Wire `+ Worktree` per repository**

In `src/ui/sidebar.rs`, make each available repository render a `+ Worktree` control. In `src/ui/shell.rs`, open `CreateWorktreeDialogState` scoped to that repo.

- [ ] **Step 3: Submit create action**

On submit:

1. Validate dialog.
2. Call `GitWorktreeService::create_worktree(repo_path, base_ref, branch_name, target_path)`.
3. Refresh repositories.
4. Select the new worktree.
5. Ask terminal registry/backend for a session using repo default command.

- [ ] **Step 4: Run tests and manual check**

Run:

```bash
cargo test --test git_worktree_tests creates_worktree_from_base_ref -- --nocapture
cargo check
cargo run
```

Expected: creating a worktree from UI adds it to the sidebar and selects it.

- [ ] **Step 5: Commit**

```bash
git add src/ui src/git
git commit -m "feat: create worktrees from repository sidebar"
```

---

## Task 20: Select Worktree and Start Persistent Terminal Session

**Files:**
- Modify: `src/ui/sidebar.rs`
- Modify: `src/ui/shell.rs`
- Modify: `src/ui/terminal_pane.rs`
- Modify: `src/terminal/session.rs`

- [ ] **Step 1: Add shell method to resolve command and session**

In `src/ui/shell.rs`, implement:

```rust
fn select_worktree(&mut self, repo_id: String, path: std::path::PathBuf) {
    self.model.select_worktree(repo_id.clone(), path.clone());
    let command = self.resolve_default_command(&repo_id, path.clone());
    let id = crate::terminal::TerminalSessionId::new(repo_id, path);
    match self.terminal_registry.get_or_start(id, command, &mut self.terminal_backend) {
        Ok(session) => {
            self.active_terminal = Some(session);
            self.terminal_error = None;
        }
        Err(error) => {
            self.active_terminal = None;
            self.terminal_error = Some(error.to_string());
        }
    }
}
```

Implement `resolve_default_command` using `RepoConfigStore::for_repo(repo.path).load()`, `ResolvedRepoConfig::resolve`, and fallback shell. It must return `CommandSpec::shell_command(resolved.default_command().command.clone(), worktree_path)` so all configured strings execute through `$SHELL -lc` in the selected worktree cwd.

- [ ] **Step 2: Wire sidebar click**

Make worktree rows selectable. On click, call `select_worktree`.

- [ ] **Step 3: Render active terminal session placeholder**

In `src/ui/terminal_pane.rs`, render:

- selected worktree path.
- command.
- session handle.
- message that real Ghostty rendering is wired later.

- [ ] **Step 4: Manual check**

Run:

```bash
cargo run
```

Expected: selecting two worktrees creates two session/backend handles; switching back reuses the first backend session and does not call `TerminalBackend::start` again. If backend startup fails, the center pane renders a retryable terminal error and the sidebar remains usable.

- [ ] **Step 5: Commit**

```bash
git add src/ui src/terminal
git commit -m "feat: select worktrees and keep terminal sessions alive"
```

---

## Task 21: Persist Repo Command Settings to `.alas/config.toml`

**Files:**
- Modify: `src/ui/dialogs.rs`
- Modify: `src/ui/sidebar.rs`
- Modify: `src/ui/shell.rs`
- Test: `tests/config_tests.rs`

- [ ] **Step 1: Add command settings dialog state**

In `src/ui/dialogs.rs`:

```rust
#[derive(Debug, Clone, Default)]
pub struct CommandSettingsDialogState {
    pub repo_id: String,
    pub default_name: String,
    pub entries: Vec<(String, String)>,
    pub error: Option<String>,
}
```

- [ ] **Step 2: Implement save conversion**

Add method:

```rust
impl CommandSettingsDialogState {
    pub fn to_repo_config(&self) -> Result<crate::config::RepoConfigFile, String> {
        let mut entries = indexmap::IndexMap::new();
        for (name, command) in &self.entries {
            if name.trim().is_empty() || command.trim().is_empty() {
                return Err("Command names and values are required".to_string());
            }
            entries.insert(name.trim().to_string(), crate::config::CommandEntry { command: command.trim().to_string() });
        }
        if !entries.contains_key(self.default_name.trim()) {
            return Err("Default command must match a named command".to_string());
        }
        Ok(crate::config::RepoConfigFile {
            default_command: None,
            commands: Some(crate::config::CommandConfig { default: self.default_name.trim().to_string(), entries }),
        })
    }
}
```

- [ ] **Step 3: Wire repository command settings action**

From repository options, open settings. On save:

1. Convert dialog to `RepoConfigFile`.
2. Save through `RepoConfigStore::for_repo(repo.path)`.
3. If selected worktree has no running session yet, future selection uses new default.
4. Existing sessions keep their original command in v1.

- [ ] **Step 4: Run config tests and manual check**

Run:

```bash
cargo test --test config_tests
cargo check
cargo run
```

Expected: editing repo command settings creates/updates `.alas/config.toml`.

- [ ] **Step 5: Commit**

```bash
git add src/ui src/config tests/config_tests.rs
git commit -m "feat: edit repository command settings"
```

---

## Task 22: Wire Git Inspector Panel

**Files:**
- Modify: `src/ui/inspector.rs`
- Modify: `src/ui/shell.rs`
- Modify: `src/app/model.rs`

- [ ] **Step 1: Add inspector state to shell/model**

Store latest `GitInspectorState` and optional error for the selected worktree.

- [ ] **Step 2: Refresh inspector on selection**

After selecting a worktree, call:

```rust
let inspector = crate::git::GitInspectorService::new(crate::git::GitRunner::new());
self.git_inspector = match inspector.inspect(&path, 8) {
    Ok(state) => Some(state),
    Err(error) => {
        self.git_inspector_error = Some(error.to_string());
        None
    }
};
```

- [ ] **Step 3: Render inspector details**

In `src/ui/inspector.rs`, show:

- branch name.
- changed files list.
- recent commits list.
- non-blocking warning when refresh fails.

- [ ] **Step 4: Manual check**

Run:

```bash
cargo run
```

Expected: selecting a dirty worktree shows changed files and recent commits on the right.

- [ ] **Step 5: Commit**

```bash
git add src/ui src/app
git commit -m "feat: show selected worktree Git inspector"
```

---

## Task 23: Add Remove and Prune Confirmation Flows

**Files:**
- Modify: `src/ui/dialogs.rs`
- Modify: `src/ui/sidebar.rs`
- Modify: `src/ui/shell.rs`

- [ ] **Step 1: Add confirmation dialog states**

In `src/ui/dialogs.rs`:

```rust
#[derive(Debug, Clone)]
pub struct ConfirmRemoveWorktreeDialog {
    pub repo_id: String,
    pub path: PathBuf,
    pub is_main: bool,
}

#[derive(Debug, Clone)]
pub struct ConfirmPruneWorktreesDialog {
    pub repo_id: String,
    pub repo_name: String,
}
```

- [ ] **Step 2: Disable remove for main worktree**

In sidebar worktree actions, show remove disabled or omitted when `WorktreeKind::Main`.

- [ ] **Step 3: Implement confirmed actions**

On confirmed remove:

1. Call `GitWorktreeService::remove_worktree`.
2. If the removed worktree is selected, call `clear_selection_and_active_terminal()` from Task 16 so selected state, active terminal, inspector state, and terminal/inspector errors are cleared together.
3. Refresh repositories.

On confirmed prune:

1. Call `GitWorktreeService::prune_worktrees`.
2. Refresh repositories.

- [ ] **Step 4: Manual safety check**

Run:

```bash
cargo run
```

Expected:

- Remove confirmation shows exact path.
- Main worktree cannot be removed.
- Prune confirmation explains it prunes stale worktree metadata.

- [ ] **Step 5: Commit**

```bash
git add src/ui
git commit -m "feat: confirm worktree remove and prune actions"
```

---

## Task 24A: Define Terminal Backend Runtime API

**Files:**
- Modify: `src/terminal/ghostty_adapter.rs`
- Modify: `src/terminal/mod.rs`
- Test: `tests/terminal_session_tests.rs`

- [ ] **Step 1: Add failing backend API tests with fake backend**

Append to `tests/terminal_session_tests.rs`:

```rust
use alas::terminal::{TerminalGridSnapshot, TerminalSize};

#[derive(Default)]
struct FakeRuntimeBackend {
    size: Option<TerminalSize>,
    input: Vec<u8>,
}

impl TerminalBackend for FakeRuntimeBackend {
    fn start(&mut self, _command: CommandSpec) -> anyhow::Result<TerminalBackendSession> {
        Ok(TerminalBackendSession { backend_id: 1 })
    }

    fn write_input(&mut self, _session: TerminalBackendSession, bytes: &[u8]) -> anyhow::Result<()> {
        self.input.extend_from_slice(bytes);
        Ok(())
    }

    fn resize(&mut self, _session: TerminalBackendSession, size: TerminalSize) -> anyhow::Result<()> {
        self.size = Some(size);
        Ok(())
    }

    fn snapshot(&mut self, _session: TerminalBackendSession) -> anyhow::Result<TerminalGridSnapshot> {
        Ok(TerminalGridSnapshot {
            size: self.size.unwrap_or(TerminalSize { cols: 80, rows: 24 }),
            lines: vec![String::from("fake")],
            cursor: Some((0, 0)),
            exited: false,
            exit_status: None,
        })
    }

    fn has_exited(&mut self, _session: TerminalBackendSession) -> anyhow::Result<bool> {
        Ok(false)
    }

    fn restart(&mut self, _session: TerminalBackendSession) -> anyhow::Result<TerminalBackendSession> {
        Ok(TerminalBackendSession { backend_id: 2 })
    }
}

#[test]
fn backend_runtime_api_supports_input_resize_snapshot_and_restart() {
    let mut backend = FakeRuntimeBackend::default();
    let session = backend.start(CommandSpec::shell_command("sh", PathBuf::from("/repo/wt"))).unwrap();

    backend.write_input(session, b"pwd\n").unwrap();
    backend.resize(session, TerminalSize { cols: 100, rows: 30 }).unwrap();
    let snapshot = backend.snapshot(session).unwrap();
    assert_eq!(snapshot.size, TerminalSize { cols: 100, rows: 30 });
    assert!(!backend.has_exited(session).unwrap());
}
```

- [ ] **Step 2: Extend `TerminalBackend` trait**

Update `src/terminal/ghostty_adapter.rs`:

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalSize {
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalGridSnapshot {
    pub size: TerminalSize,
    pub lines: Vec<String>,
    pub cursor: Option<(u16, u16)>,
    pub exited: bool,
    pub exit_status: Option<i32>,
}

pub trait TerminalBackend {
    fn start(&mut self, command: CommandSpec) -> anyhow::Result<TerminalBackendSession>;
    fn write_input(&mut self, session: TerminalBackendSession, bytes: &[u8]) -> anyhow::Result<()>;
    fn resize(&mut self, session: TerminalBackendSession, size: TerminalSize) -> anyhow::Result<()>;
    fn snapshot(&mut self, session: TerminalBackendSession) -> anyhow::Result<TerminalGridSnapshot>;
    fn has_exited(&mut self, session: TerminalBackendSession) -> anyhow::Result<bool>;
    fn restart(&mut self, session: TerminalBackendSession) -> anyhow::Result<TerminalBackendSession>;
}
```

Export these types from `src/terminal/mod.rs`.

- [ ] **Step 3: Update fake/default backend implementations**

Update all fake backends in tests and the placeholder `GhosttyTerminalBackend` implementation to satisfy the extended trait.

- [ ] **Step 4: Run tests and commit**

Run:

```bash
cargo test --test terminal_session_tests
```

Expected: PASS.

```bash
git add src/terminal tests/terminal_session_tests.rs
git commit -m "feat: define terminal runtime backend API"
```

---

## Task 24B: Implement PTY Process Ownership in Terminal Adapter

**Files:**
- Modify: `Cargo.toml`
- Modify: `src/terminal/ghostty_adapter.rs`
- Test: `tests/terminal_session_tests.rs`

- [ ] **Step 1: Inspect installed `libghostty-rs` API and choose PTY crate**

Run:

```bash
cargo doc -p libghostty-vt --no-deps --open
```

Expected: identify current Ghostty VT types. If the `libghostty-rs` project does not provide PTY/process ownership, add:

```toml
portable-pty = "0.8"
```

Keep PTY crate usage private to `src/terminal/ghostty_adapter.rs`.

- [ ] **Step 2: Add failing integration-style test for process cwd**

Append to `tests/terminal_session_tests.rs` behind a non-flaky helper or `#[ignore]` if platform timing makes it unreliable:

```rust
#[test]
#[ignore = "requires real PTY timing; run manually during terminal integration"]
fn real_backend_starts_process_in_command_cwd() {
    let dir = tempfile::tempdir().unwrap();
    let mut backend = alas::terminal::GhosttyTerminalBackend::new();
    let session = backend.start(CommandSpec::shell_command("pwd", dir.path().to_path_buf())).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(250));
    let snapshot = backend.snapshot(session).unwrap();
    assert!(snapshot.lines.join("\n").contains(&dir.path().display().to_string()));
}
```

- [ ] **Step 3: Implement backend session state**

In `src/terminal/ghostty_adapter.rs`, add private state:

```rust
struct BackendSessionState {
    command: CommandSpec,
    size: TerminalSize,
    // PTY master/reader/writer/child handles live here.
    // Ghostty VT Terminal/RenderState live here.
    exited: bool,
    exit_status: Option<i32>,
}
```

`GhosttyTerminalBackend` should own `HashMap<u64, BackendSessionState>` and spawn `CommandSpec.program` with `CommandSpec.args` in `CommandSpec.cwd`.

- [ ] **Step 4: Run manual ignored test**

Run:

```bash
cargo test --test terminal_session_tests real_backend_starts_process_in_command_cwd -- --ignored --nocapture
```

Expected: PASS or a clear platform-specific PTY error to fix before continuing.

- [ ] **Step 5: Commit**

```bash
git add Cargo.toml src/terminal tests/terminal_session_tests.rs
git commit -m "feat: spawn terminal commands through PTY"
```

---

## Task 24C: Feed PTY Output into Ghostty VT and Snapshot Text Grid

**Files:**
- Modify: `src/terminal/ghostty_adapter.rs`
- Test: `tests/terminal_session_tests.rs`

- [ ] **Step 1: Add/enable snapshot test**

Use the real backend test from Task 24B and assert `TerminalGridSnapshot.lines` contains command output from `printf alas-terminal-ok`.

- [ ] **Step 2: Implement PTY read pump and VT feed**

Inside the adapter only:

1. Read available PTY bytes for each backend session.
2. Feed bytes into the Ghostty VT terminal type.
3. Convert Ghostty render state into `TerminalGridSnapshot` lines.
4. Mark process exit status when the child exits.

- [ ] **Step 3: Run test**

Run:

```bash
cargo test --test terminal_session_tests real_backend_starts_process_in_command_cwd -- --ignored --nocapture
```

Expected: PASS with visible command output in the snapshot.

- [ ] **Step 4: Commit**

```bash
git add src/terminal tests/terminal_session_tests.rs
git commit -m "feat: snapshot Ghostty terminal output"
```

---

## Task 24D: Wire Terminal Rendering, Input, Resize, and Restart in GPUI

**Files:**
- Modify: `src/ui/terminal_pane.rs`
- Modify: `src/ui/shell.rs`
- Modify: `src/terminal/ghostty_adapter.rs`

- [ ] **Step 1: Render terminal snapshot**

Update `src/ui/terminal_pane.rs` to render `TerminalGridSnapshot.lines` for the active session. If no session exists, render the no-worktree-selected state. If `terminal_error` is set, render a retry button.

- [ ] **Step 2: Forward keyboard input**

Map GPUI key events to bytes and call `terminal_backend.write_input(active.backend_session, bytes)`. Verify normal typing, Enter, Backspace, and Ctrl-C.

- [ ] **Step 3: Forward resize**

Compute terminal rows/cols from pane size and font metrics, then call `terminal_backend.resize(active.backend_session, TerminalSize { cols, rows })` when size changes.

- [ ] **Step 4: Implement restart on exit/error**

If `terminal_backend.has_exited(active.backend_session)` is true, render exit status and a restart action. Restart calls `terminal_backend.restart(active.backend_session)` and updates the active `TerminalSessionRef.backend_session`.

- [ ] **Step 5: Manual terminal acceptance check**

Run:

```bash
cargo run
```

Expected:

- Selecting a worktree starts the repo default command in that worktree.
- `$ pwd` reports the worktree path when using shell command.
- Switching away and back preserves terminal output/process.
- Typing, Enter, Backspace, Ctrl-C, resize, process exit, and restart work.

- [ ] **Step 6: Commit**

```bash
git add src/terminal src/ui
git commit -m "feat: render and control embedded Ghostty terminals"
```

---

## Task 25: Add Context Menus and UI Polish

**Files:**
- Modify: `src/ui/sidebar.rs`
- Modify: `src/ui/shell.rs`
- Modify: `src/ui/dialogs.rs`

- [ ] **Step 1: Convert temporary action buttons to context menus**

Use GPUI menu/context-menu APIs to expose right-click worktree actions:

- Open/select.
- Archive or unarchive.
- Remove linked worktree.

Repository options should include:

- Show archived worktrees.
- Prune stale worktrees.
- Edit command settings.
- Remove repository from Alas.

- [ ] **Step 2: Add empty states**

Render clear messages for:

- No repositories configured.
- Repository unavailable/moved.
- No worktree selected.
- No changed files.
- Terminal process exited.

- [ ] **Step 3: Run manual UX pass**

Run:

```bash
cargo run
```

Expected: primary workflows are discoverable without visual clutter.

- [ ] **Step 4: Commit**

```bash
git add src/ui
git commit -m "feat: polish sidebar and empty states"
```

---

## Task 26: End-to-End Verification

**Files:**
- Modify: `README.md`
- Create: `docs/manual-test.md`

- [ ] **Step 1: Document manual test script**

Create `docs/manual-test.md`:

```markdown
# Alas Manual Test Script

1. Start Alas with `cargo run`.
2. Add an existing Git repository.
3. Confirm its main worktree appears in the sidebar.
4. Create a new worktree from `HEAD` with branch `alas-manual-test`.
5. Confirm the new worktree is selected automatically.
6. Confirm the terminal command starts in the new worktree directory.
7. Switch back to the main worktree, then back to the new worktree.
8. Confirm terminal session output is preserved.
9. Modify a file and confirm the right Git inspector shows it.
10. Archive the linked worktree and confirm it disappears.
11. Enable show archived for the repository and unarchive it.
12. Remove the linked worktree with confirmation.
13. Prune stale worktrees with confirmation.
```

Update `README.md` with build/run instructions:

```markdown
## Development

```bash
cargo test
cargo run
```
```

- [ ] **Step 2: Run automated tests**

Run:

```bash
cargo test
```

Expected: PASS.

- [ ] **Step 3: Run compile check**

Run:

```bash
cargo check
```

Expected: PASS.

- [ ] **Step 4: Run manual smoke test**

Run:

```bash
cargo run
```

Follow `docs/manual-test.md`.

Expected: all manual steps pass on the current platform.

- [ ] **Step 5: Commit**

```bash
git add README.md docs/manual-test.md
git commit -m "docs: add Alas manual verification steps"
```

---

## Final Acceptance Criteria

- `cargo test` passes.
- `cargo check` passes.
- App opens a GPUI native window on macOS/Linux.
- Repositories can be configured from UI.
- Sidebar shows repositories and Git-discovered worktrees.
- Each repository has its own `+ Worktree` action.
- Creating a worktree is branch-aware and auto-selects/launches the new worktree.
- Selecting a worktree opens/reuses a persistent terminal session in that worktree.
- Repo command settings are saved to `.alas/config.toml`.
- Worktree archive/unarchive is local app state and does not delete files.
- Linked worktree remove and prune require confirmations.
- Main worktree removal is disabled.
- Right inspector shows changed files and recent commits.
