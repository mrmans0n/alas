mod support;

use alas::git::{GitRunner, GitWorktreeService, WorktreeKind};

#[test]
fn test_repo_helper_creates_valid_repo() {
    let repo = support::git_repo::TestRepo::new();
    assert!(repo.path().join(".git").exists());
}

#[test]
fn git_runner_captures_stdout() {
    let repo = support::git_repo::TestRepo::new();
    let runner = GitRunner::new();
    let output = runner
        .run(repo.path(), &["rev-parse", "--is-inside-work-tree"])
        .unwrap();
    assert_eq!(output.stdout.trim(), "true");
}

#[test]
fn git_runner_reports_stderr_on_failure() {
    let repo = support::git_repo::TestRepo::new();
    let runner = GitRunner::new();
    let err = runner
        .run(repo.path(), &["not-a-real-command"])
        .unwrap_err();
    let message = err.to_string();
    assert!(message.contains("not-a-real-command"));
    assert!(message.contains(&repo.path().display().to_string()));
    assert!(message.contains("stderr:"));
    assert!(message.contains("not a git command"));
}

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
    support::git_repo::run(
        repo.path(),
        &[
            "worktree",
            "add",
            "-b",
            "feature-a",
            linked.to_str().unwrap(),
            "HEAD",
        ],
    );

    let service = GitWorktreeService::new(GitRunner::new());
    let worktrees = service.list_worktrees(repo.path()).unwrap();

    let repo_path = repo.path().canonicalize().unwrap();
    let linked_path = linked.canonicalize().unwrap();

    assert!(
        worktrees
            .iter()
            .any(|w| w.path.canonicalize().unwrap() == repo_path && w.kind == WorktreeKind::Main)
    );
    assert!(worktrees.iter().any(|w| {
        w.path.canonicalize().unwrap() == linked_path && w.branch.as_deref() == Some("feature-a")
    }));
}
