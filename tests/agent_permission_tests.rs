use alas::agent::{AgentTrustMode, PermissionDecision, PermissionPolicy, PermissionRequestKind};

#[test]
fn allow_everything_approves_file_writes_outside_worktree_and_terminal_commands() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let worktree = temp.path().join("worktree");
    std::fs::create_dir(&worktree).expect("create worktree");
    let outside = temp.path().join("outside.txt");

    let policy = PermissionPolicy::new(AgentTrustMode::AllowEverything, worktree);

    assert_eq!(
        policy.decide(&PermissionRequestKind::WriteFile(outside)),
        PermissionDecision::Allow
    );
    assert_eq!(
        policy.decide(&PermissionRequestKind::RunTerminal {
            command: "touch /tmp/outside".to_string(),
        }),
        PermissionDecision::Allow
    );
}

#[test]
fn ask_prompts_for_file_reads_file_writes_and_terminal_commands() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let worktree = temp.path().join("worktree");
    std::fs::create_dir(&worktree).expect("create worktree");

    let policy = PermissionPolicy::new(AgentTrustMode::Ask, worktree.clone());

    assert_eq!(
        policy.decide(&PermissionRequestKind::ReadFile(worktree.join("file.txt"))),
        PermissionDecision::Ask
    );
    assert_eq!(
        policy.decide(&PermissionRequestKind::WriteFile(worktree.join("file.txt"))),
        PermissionDecision::Ask
    );
    assert_eq!(
        policy.decide(&PermissionRequestKind::RunTerminal {
            command: "cargo test".to_string(),
        }),
        PermissionDecision::Ask
    );
}

#[test]
fn worktree_only_denies_write_outside_and_allows_missing_file_inside_canonical_worktree() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let worktree = temp.path().join("worktree");
    let outside_dir = temp.path().join("outside");
    std::fs::create_dir(&worktree).expect("create worktree");
    std::fs::create_dir(&outside_dir).expect("create outside dir");

    let worktree_link = temp.path().join("worktree-link");
    #[cfg(unix)]
    std::os::unix::fs::symlink(&worktree, &worktree_link).expect("create worktree symlink");
    #[cfg(windows)]
    std::os::windows::fs::symlink_dir(&worktree, &worktree_link).expect("create worktree symlink");

    let outside = outside_dir.join("outside.txt");
    let missing_inside = worktree_link.join("nested").join("missing.txt");
    std::fs::create_dir(worktree.join("nested")).expect("create nested dir");

    let policy = PermissionPolicy::new(AgentTrustMode::WorktreeOnly, worktree_link);

    assert_eq!(
        policy.decide(&PermissionRequestKind::WriteFile(outside)),
        PermissionDecision::Deny
    );
    assert_eq!(
        policy.decide(&PermissionRequestKind::WriteFile(missing_inside)),
        PermissionDecision::Allow
    );
}

#[test]
fn worktree_only_denies_missing_path_parent_traversal_outside_worktree() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let worktree = temp.path().join("worktree");
    std::fs::create_dir(&worktree).expect("create worktree");
    let path = worktree
        .join("missing")
        .join("..")
        .join("..")
        .join("outside.txt");

    let policy = PermissionPolicy::new(AgentTrustMode::WorktreeOnly, worktree);

    assert_eq!(
        policy.decide(&PermissionRequestKind::WriteFile(path)),
        PermissionDecision::Deny
    );
}

#[test]
fn worktree_only_prompts_for_terminal_commands() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let worktree = temp.path().join("worktree");
    std::fs::create_dir(&worktree).expect("create worktree");

    let policy = PermissionPolicy::new(AgentTrustMode::WorktreeOnly, worktree);

    assert_eq!(
        policy.decide(&PermissionRequestKind::RunTerminal {
            command: "cargo test".to_string(),
        }),
        PermissionDecision::Ask
    );
}

#[test]
fn worktree_only_allows_file_reads_inside_worktree() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let worktree = temp.path().join("worktree");
    std::fs::create_dir(&worktree).expect("create worktree");
    let file = worktree.join("file.txt");
    std::fs::write(&file, "contents").expect("write file");

    let policy = PermissionPolicy::new(AgentTrustMode::WorktreeOnly, worktree);

    assert_eq!(
        policy.decide(&PermissionRequestKind::ReadFile(file)),
        PermissionDecision::Allow
    );
}

#[cfg(unix)]
#[test]
fn worktree_only_denies_symlink_inside_worktree_pointing_outside() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let worktree = temp.path().join("worktree");
    std::fs::create_dir(&worktree).expect("create worktree");
    let outside = temp.path().join("outside.txt");
    std::fs::write(&outside, "outside").expect("write outside file");
    let link = worktree.join("outside-link.txt");
    std::os::unix::fs::symlink(&outside, &link).expect("create file symlink");

    let policy = PermissionPolicy::new(AgentTrustMode::WorktreeOnly, worktree);

    assert_eq!(
        policy.decide(&PermissionRequestKind::ReadFile(link)),
        PermissionDecision::Deny
    );
}

#[test]
fn worktree_only_denies_sibling_path_with_common_prefix() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let worktree = temp.path().join("worktree");
    let sibling = temp.path().join("worktree-sibling");
    std::fs::create_dir(&worktree).expect("create worktree");
    std::fs::create_dir(&sibling).expect("create sibling");
    let sibling_file = sibling.join("file.txt");
    std::fs::write(&sibling_file, "sibling").expect("write sibling file");

    let policy = PermissionPolicy::new(AgentTrustMode::WorktreeOnly, worktree);

    assert_eq!(
        policy.decide(&PermissionRequestKind::ReadFile(sibling_file)),
        PermissionDecision::Deny
    );
}

#[test]
fn deny_rejects_file_reads_file_writes_and_terminal_side_effects() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let worktree = temp.path().join("worktree");
    std::fs::create_dir(&worktree).expect("create worktree");

    let policy = PermissionPolicy::new(AgentTrustMode::Deny, worktree.clone());

    assert_eq!(
        policy.decide(&PermissionRequestKind::ReadFile(worktree.join("file.txt"))),
        PermissionDecision::Deny
    );
    assert_eq!(
        policy.decide(&PermissionRequestKind::WriteFile(worktree.join("file.txt"))),
        PermissionDecision::Deny
    );
    assert_eq!(
        policy.decide(&PermissionRequestKind::RunTerminal {
            command: "rm -rf target".to_string(),
        }),
        PermissionDecision::Deny
    );
}
