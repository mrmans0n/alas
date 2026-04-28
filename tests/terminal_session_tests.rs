use alas::terminal::{
    CommandSpec, TerminalBackend, TerminalBackendSession, TerminalSessionId,
    TerminalSessionRegistry,
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

#[test]
fn backend_starts_command_in_worktree_cwd() {
    let mut backend = FakeBackend::default();
    let command = CommandSpec {
        command: "claude".to_string(),
        cwd: PathBuf::from("/repo/wt"),
    };

    let session = backend.start(command.clone()).unwrap();

    assert_eq!(session.backend_id, 1);
    assert_eq!(backend.started, vec![command]);
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
    let id = TerminalSessionId::new("repo-1", PathBuf::from("/repo/wt"));
    let command = CommandSpec {
        command: "claude".to_string(),
        cwd: PathBuf::from("/repo/wt"),
    };

    let first = registry.get_or_create(id.clone(), command.clone());
    let second = registry.get_or_create(id, command);

    assert_eq!(first.handle, second.handle);
}
