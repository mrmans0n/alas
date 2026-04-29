use std::path::PathBuf;

use alas::app::{TerminalTabKind, WorkspaceSession};
use alas::terminal::CommandSpec;

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

    assert!(session.set_active_tab("repo", &path, shell));
    let active = session.active_tab("repo", &path).expect("active tab");
    assert_eq!(active.id, shell);
    assert_eq!(active.name, "Shell");
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

    assert!(session.set_active_tab("repo", &path_a, shell_a));

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
