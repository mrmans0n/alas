use alas::terminal::{
    CommandSpec, TerminalBackend, TerminalBackendSession, TerminalSessionId,
    TerminalSessionRegistry, default_shell_program,
};
use std::path::PathBuf;

#[derive(Default)]
struct FakeBackend {
    started: Vec<CommandSpec>,
}

impl TerminalBackend for FakeBackend {
    fn start(&mut self, command: CommandSpec) -> anyhow::Result<TerminalBackendSession> {
        self.started.push(command);
        Ok(TerminalBackendSession {
            backend_id: self.started.len() as u64,
        })
    }
}

#[derive(Default)]
struct CountingBackend {
    started: Vec<CommandSpec>,
}

impl CountingBackend {
    fn start_count(&self) -> usize {
        self.started.len()
    }
}

impl TerminalBackend for CountingBackend {
    fn start(&mut self, command: CommandSpec) -> anyhow::Result<TerminalBackendSession> {
        self.started.push(command);
        Ok(TerminalBackendSession {
            backend_id: self.started.len() as u64,
        })
    }
}

#[test]
fn backend_starts_command_in_worktree_cwd() {
    let mut backend = FakeBackend::default();
    let command = CommandSpec::shell_command("claude", PathBuf::from("/repo/wt"));

    let session = backend.start(command.clone()).unwrap();

    assert_eq!(session.backend_id, 1);
    assert_eq!(backend.started, vec![command]);
}

#[test]
fn command_spec_runs_through_shell_with_cwd() {
    let cwd = PathBuf::from("/repo/wt");
    let command = CommandSpec::shell_command("$SHELL", cwd.clone());

    assert_eq!(command.display, "$SHELL");
    assert_eq!(command.program, default_shell_program());
    assert_eq!(command.args.last().map(String::as_str), Some("$SHELL"));
    assert_eq!(command.cwd, cwd);
}

#[test]
fn session_id_is_stable_for_repo_and_worktree() {
    let a = TerminalSessionId::new("repo-1", PathBuf::from("/repo/wt"));
    let b = TerminalSessionId::new("repo-1", PathBuf::from("/repo/wt"));
    assert_eq!(a, b);
}

#[test]
fn registry_reuses_existing_session_for_worktree() {
    let mut registry = TerminalSessionRegistry::default();
    let mut backend = FakeBackend::default();
    let id = TerminalSessionId::new("repo-1", PathBuf::from("/repo/wt"));
    let command = CommandSpec::shell_command("claude", PathBuf::from("/repo/wt"));

    let first = registry
        .get_or_start(id.clone(), command.clone(), &mut backend)
        .unwrap();
    let second = registry.get_or_start(id, command, &mut backend).unwrap();

    assert_eq!(first.handle, second.handle);
    assert_eq!(first.backend_session, second.backend_session);
    assert_eq!(backend.started.len(), 1);
}

#[test]
fn counting_backend_starts_once_per_terminal_session_id() {
    let mut registry = TerminalSessionRegistry::default();
    let mut backend = CountingBackend::default();
    let first_id = TerminalSessionId::new("repo-1", PathBuf::from("/repo/wt-a"));
    let second_id = TerminalSessionId::new("repo-1", PathBuf::from("/repo/wt-b"));
    let first_command = CommandSpec::shell_command("claude", PathBuf::from("/repo/wt-a"));
    let second_command = CommandSpec::shell_command("claude", PathBuf::from("/repo/wt-b"));

    let first = registry
        .get_or_start(first_id.clone(), first_command.clone(), &mut backend)
        .unwrap();
    let first_again = registry
        .get_or_start(
            first_id,
            CommandSpec::shell_command("other", PathBuf::from("/repo/wt-a")),
            &mut backend,
        )
        .unwrap();
    let second = registry
        .get_or_start(second_id.clone(), second_command.clone(), &mut backend)
        .unwrap();
    let second_again = registry
        .get_or_start(
            second_id,
            CommandSpec::shell_command("other", PathBuf::from("/repo/wt-b")),
            &mut backend,
        )
        .unwrap();

    assert_eq!(first.backend_session, first_again.backend_session);
    assert_eq!(second.backend_session, second_again.backend_session);
    assert_ne!(first.backend_session, second.backend_session);
    assert_eq!(backend.start_count(), 2);
    assert_eq!(backend.started, vec![first_command, second_command]);
}
