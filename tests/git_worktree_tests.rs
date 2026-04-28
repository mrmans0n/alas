mod support;

use alas::git::GitRunner;

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
    assert!(err.to_string().contains("not-a-real-command"));
}
