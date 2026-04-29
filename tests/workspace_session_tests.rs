use std::path::PathBuf;

use alas::app::{TerminalTabId, TerminalTabKind, TerminalTabStatus, WorkspaceSession};
use alas::terminal::{CommandSpec, TerminalBackendSession};

fn shell_command(path: &str) -> CommandSpec {
    CommandSpec::shell_command("$SHELL", PathBuf::from(path))
}

#[test]
fn selecting_worktree_creates_default_tab_once() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");
    let command = shell_command("/repo/a");

    let first = session.ensure_default_terminal_tab("repo", path.clone(), command.clone());
    let second = session.ensure_default_terminal_tab("repo", path.clone(), command);

    assert_eq!(first, second);
    assert_eq!(session.tabs_for_worktree("repo", &path).len(), 1);
    assert_eq!(
        session.active_tab("repo", &path).map(|tab| tab.id),
        Some(first)
    );
}

#[test]
fn worktree_can_have_multiple_named_terminal_tabs() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");

    let shell = session.create_terminal_tab(
        "repo",
        path.clone(),
        "Shell".to_string(),
        TerminalTabKind::Shell,
        shell_command("/repo/a"),
    );
    let tests = session.create_terminal_tab(
        "repo",
        path.clone(),
        "Tests".to_string(),
        TerminalTabKind::Command,
        CommandSpec::shell_command("cargo test", path.clone()),
    );

    assert_ne!(shell, tests);
    assert_eq!(session.tabs_for_worktree("repo", &path).len(), 2);
    assert_eq!(
        session.active_tab("repo", &path).map(|tab| tab.id),
        Some(tests)
    );

    session
        .set_active_tab("repo", &path, shell)
        .expect("set active tab");
    let active = session.active_tab("repo", &path).expect("active tab");
    assert_eq!(active.id, shell);
    assert_eq!(active.name, "Shell");

    let ensured =
        session.ensure_default_terminal_tab("repo", path.clone(), shell_command("/repo/a"));
    assert_eq!(ensured, shell);
    assert_eq!(session.tabs_for_worktree("repo", &path).len(), 2);
    assert_eq!(
        session.active_tab("repo", &path).map(|tab| tab.id),
        Some(shell)
    );
}

#[test]
fn active_tab_is_scoped_per_worktree() {
    let mut session = WorkspaceSession::default();
    let path_a = PathBuf::from("/repo/a");
    let path_b = PathBuf::from("/repo/b");

    let shell_a = session.create_terminal_tab(
        "repo",
        path_a.clone(),
        "Shell".to_string(),
        TerminalTabKind::Shell,
        shell_command("/repo/a"),
    );
    let tests_a = session.create_terminal_tab(
        "repo",
        path_a.clone(),
        "Tests".to_string(),
        TerminalTabKind::Command,
        CommandSpec::shell_command("cargo test", path_a.clone()),
    );
    let shell_b = session.create_terminal_tab(
        "repo",
        path_b.clone(),
        "Shell".to_string(),
        TerminalTabKind::Shell,
        shell_command("/repo/b"),
    );

    session
        .set_active_tab("repo", &path_a, shell_a)
        .expect("set active tab");

    assert_eq!(
        session.active_tab("repo", &path_a).map(|tab| tab.id),
        Some(shell_a)
    );
    assert_eq!(
        session.active_tab("repo", &path_b).map(|tab| tab.id),
        Some(shell_b)
    );
    assert_ne!(tests_a, shell_b);
}

#[test]
fn tab_runtime_state_can_be_updated_and_removed() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");
    let tab_id = session.create_terminal_tab(
        "repo",
        path.clone(),
        "Tests".to_string(),
        TerminalTabKind::Command,
        CommandSpec::shell_command("cargo test", path.clone()),
    );

    session
        .set_tab_backend_session(
            "repo",
            &path,
            tab_id,
            Some(TerminalBackendSession { backend_id: 42 }),
        )
        .expect("set backend session");
    session
        .set_tab_status("repo", &path, tab_id, TerminalTabStatus::Running)
        .expect("set status");
    session
        .set_tab_scroll_offset("repo", &path, tab_id, 12)
        .expect("set scroll offset");

    let active = session.active_tab("repo", &path).expect("active tab");
    assert_eq!(
        active.backend_session,
        Some(TerminalBackendSession { backend_id: 42 })
    );
    assert_eq!(active.status, TerminalTabStatus::Running);
    assert_eq!(active.scroll_offset_rows, 12);

    session.remove_worktree("repo", &path);
    assert!(session.tabs_for_worktree("repo", &path).is_empty());
    assert!(session.active_tab("repo", &path).is_none());
}

#[test]
fn setting_unknown_active_tab_returns_contextual_error() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");
    session.create_terminal_tab(
        "repo",
        path.clone(),
        "Shell".to_string(),
        TerminalTabKind::Shell,
        shell_command("/repo/a"),
    );

    let error = session
        .set_active_tab("repo", &path, TerminalTabId(999))
        .expect_err("unknown tab should fail")
        .to_string();

    assert!(error.contains("unknown terminal tab"));
    assert!(error.contains("repo"));
    assert!(error.contains("/repo/a"));
}
