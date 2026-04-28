mod support;

#[test]
fn test_repo_helper_creates_valid_repo() {
    let repo = support::git_repo::TestRepo::new();
    assert!(repo.path().join(".git").exists());
}
