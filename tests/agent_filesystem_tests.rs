use alas::agent::{AgentTrustMode, FilesystemCallbackService};

#[test]
fn allowed_service_reads_and_writes_text_file() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let worktree = temp.path().join("worktree");
    std::fs::create_dir(&worktree).expect("create worktree");
    let path = worktree.join("nested").join("file.txt");

    let service = FilesystemCallbackService::new(AgentTrustMode::AllowEverything, worktree);

    service
        .write_text_file(&path, "hello from agent")
        .expect("write text file");

    let contents = service.read_text_file(&path).expect("read text file");
    assert_eq!(contents, "hello from agent");
}

#[test]
fn worktree_only_service_denies_write_outside_via_missing_path_traversal() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let worktree = temp.path().join("worktree");
    std::fs::create_dir(&worktree).expect("create worktree");
    let traversal_path = worktree
        .join("missing")
        .join("..")
        .join("..")
        .join("outside.txt");
    let outside = temp.path().join("outside.txt");

    let service = FilesystemCallbackService::new(AgentTrustMode::WorktreeOnly, worktree);

    let error = service
        .write_text_file(&traversal_path, "should not be written")
        .expect_err("write should be denied");

    assert!(
        error.to_string().contains("permission denied"),
        "unexpected error: {error:#}"
    );
    assert!(!outside.exists());
}

#[test]
fn worktree_only_service_allows_write_and_read_inside_worktree() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let worktree = temp.path().join("worktree");
    std::fs::create_dir(&worktree).expect("create worktree");
    let path = worktree.join("nested").join("file.txt");

    let service = FilesystemCallbackService::new(AgentTrustMode::WorktreeOnly, worktree);

    service
        .write_text_file(&path, "inside worktree")
        .expect("write inside worktree");
    let contents = service.read_text_file(&path).expect("read inside worktree");

    assert_eq!(contents, "inside worktree");
}

#[test]
fn ask_service_requires_permission_for_read_and_write() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let worktree = temp.path().join("worktree");
    std::fs::create_dir(&worktree).expect("create worktree");
    let path = worktree.join("file.txt");
    std::fs::write(&path, "contents").expect("write fixture");

    let service = FilesystemCallbackService::new(AgentTrustMode::Ask, worktree);

    let read_error = service
        .read_text_file(&path)
        .expect_err("read should require permission");
    assert!(
        read_error.to_string().contains("permission required"),
        "unexpected error: {read_error:#}"
    );
    let write_error = service
        .write_text_file(&path, "new contents")
        .expect_err("write should require permission");
    assert!(
        write_error.to_string().contains("permission required"),
        "unexpected error: {write_error:#}"
    );
}

#[test]
fn denied_service_denies_write_and_does_not_create_file() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let worktree = temp.path().join("worktree");
    std::fs::create_dir(&worktree).expect("create worktree");
    let path = worktree.join("file.txt");

    let service = FilesystemCallbackService::new(AgentTrustMode::Deny, worktree);

    let error = service
        .write_text_file(&path, "should not be written")
        .expect_err("write should be denied");

    assert!(
        error.to_string().contains("permission denied"),
        "unexpected error: {error:#}"
    );
    assert!(!path.exists());
}

#[test]
fn denied_service_denies_read() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let worktree = temp.path().join("worktree");
    std::fs::create_dir(&worktree).expect("create worktree");
    let path = worktree.join("file.txt");
    std::fs::write(&path, "contents").expect("write fixture");

    let service = FilesystemCallbackService::new(AgentTrustMode::Deny, worktree);

    let error = service
        .read_text_file(&path)
        .expect_err("read should be denied");

    assert!(
        error.to_string().contains("permission denied"),
        "unexpected error: {error:#}"
    );
}
