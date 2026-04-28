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
    let command = CommandSpec {
        command: "claude".to_string(),
        cwd: PathBuf::from("/repo/wt"),
    };

    let first = registry.get_or_create(id.clone(), command.clone());
    let second = registry.get_or_create(id, command);

    assert_eq!(first.handle, second.handle);
}
