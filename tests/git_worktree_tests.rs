mod support;

use alas::git::{GitInspectorService, GitRunner, GitWorktreeService, WorktreeKind};

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
fn inspector_reports_changed_files_and_recent_commits() {
    let repo = support::git_repo::TestRepo::new();
    std::fs::write(repo.path().join("README.md"), "changed\n").unwrap();

    let inspector = GitInspectorService::new(GitRunner::new());
    let state = inspector.inspect(repo.path(), 5).unwrap();

    assert!(state.changed_files.iter().any(|f| f.path == "README.md"));
    assert!(
        state
            .recent_commits
            .iter()
            .any(|c| c.summary.contains("initial"))
    );
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

#[test]
fn creates_worktree_from_base_ref() {
    let repo = support::git_repo::TestRepo::new();
    let linked = repo.worktree_path("feature-b");
    let service = GitWorktreeService::new(GitRunner::new());

    service
        .create_worktree(repo.path(), "HEAD", "feature-b", &linked)
        .unwrap();

    assert!(linked.exists());
    let linked_path = linked.canonicalize().unwrap();
    let worktrees = service.list_worktrees(repo.path()).unwrap();
    assert!(
        worktrees
            .iter()
            .any(|w| w.path.canonicalize().unwrap() == linked_path)
    );
}

#[test]
fn removes_linked_worktree_but_rejects_main_worktree() {
    let repo = support::git_repo::TestRepo::new();
    let linked = repo.worktree_path("feature-c");
    let service = GitWorktreeService::new(GitRunner::new());
    service
        .create_worktree(repo.path(), "HEAD", "feature-c", &linked)
        .unwrap();

    service.remove_worktree(repo.path(), &linked).unwrap();
    assert!(!linked.exists());

    let err = service
        .remove_worktree(repo.path(), repo.path())
        .unwrap_err();
    assert!(err.to_string().contains("main worktree"));
}
