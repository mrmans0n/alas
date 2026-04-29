use alas::terminal::{
    CommandSpec, GhosttyTerminalBackend, TerminalBackend, TerminalBackendSession,
    TerminalGridSnapshot, TerminalSessionId, TerminalSessionRegistry, TerminalSize,
    default_shell_program,
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

    fn write_input(
        &mut self,
        _session: TerminalBackendSession,
        _bytes: &[u8],
    ) -> anyhow::Result<()> {
        Ok(())
    }

    fn resize(
        &mut self,
        _session: TerminalBackendSession,
        _size: TerminalSize,
    ) -> anyhow::Result<()> {
        Ok(())
    }

    fn snapshot(
        &mut self,
        _session: TerminalBackendSession,
    ) -> anyhow::Result<TerminalGridSnapshot> {
        Ok(TerminalGridSnapshot {
            size: TerminalSize { cols: 80, rows: 24 },
            lines: Vec::new(),
            cursor: None,
            exited: false,
            exit_status: None,
        })
    }

    fn has_exited(&mut self, _session: TerminalBackendSession) -> anyhow::Result<bool> {
        Ok(false)
    }

    fn restart(
        &mut self,
        _session: TerminalBackendSession,
    ) -> anyhow::Result<TerminalBackendSession> {
        Ok(TerminalBackendSession {
            backend_id: self.started.len() as u64 + 1,
        })
    }
}

#[derive(Default)]
struct FakeRuntimeBackend {
    started: Vec<CommandSpec>,
    input: Vec<u8>,
    size: Option<TerminalSize>,
    exited: bool,
}

impl TerminalBackend for FakeRuntimeBackend {
    fn start(&mut self, command: CommandSpec) -> anyhow::Result<TerminalBackendSession> {
        self.started.push(command);
        Ok(TerminalBackendSession {
            backend_id: self.started.len() as u64,
        })
    }

    fn write_input(
        &mut self,
        _session: TerminalBackendSession,
        bytes: &[u8],
    ) -> anyhow::Result<()> {
        self.input.extend_from_slice(bytes);
        Ok(())
    }

    fn resize(
        &mut self,
        _session: TerminalBackendSession,
        size: TerminalSize,
    ) -> anyhow::Result<()> {
        self.size = Some(size);
        Ok(())
    }

    fn snapshot(
        &mut self,
        _session: TerminalBackendSession,
    ) -> anyhow::Result<TerminalGridSnapshot> {
        Ok(TerminalGridSnapshot {
            size: self.size.unwrap_or(TerminalSize { cols: 80, rows: 24 }),
            lines: Vec::new(),
            cursor: None,
            exited: self.exited,
            exit_status: None,
        })
    }

    fn has_exited(&mut self, _session: TerminalBackendSession) -> anyhow::Result<bool> {
        Ok(self.exited)
    }

    fn restart(
        &mut self,
        _session: TerminalBackendSession,
    ) -> anyhow::Result<TerminalBackendSession> {
        Ok(TerminalBackendSession {
            backend_id: self.started.len() as u64 + 1,
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

    fn write_input(
        &mut self,
        _session: TerminalBackendSession,
        _bytes: &[u8],
    ) -> anyhow::Result<()> {
        Ok(())
    }

    fn resize(
        &mut self,
        _session: TerminalBackendSession,
        _size: TerminalSize,
    ) -> anyhow::Result<()> {
        Ok(())
    }

    fn snapshot(
        &mut self,
        _session: TerminalBackendSession,
    ) -> anyhow::Result<TerminalGridSnapshot> {
        Ok(TerminalGridSnapshot {
            size: TerminalSize { cols: 80, rows: 24 },
            lines: Vec::new(),
            cursor: None,
            exited: false,
            exit_status: None,
        })
    }

    fn has_exited(&mut self, _session: TerminalBackendSession) -> anyhow::Result<bool> {
        Ok(false)
    }

    fn restart(
        &mut self,
        _session: TerminalBackendSession,
    ) -> anyhow::Result<TerminalBackendSession> {
        Ok(TerminalBackendSession {
            backend_id: self.started.len() as u64 + 1,
        })
    }
}

#[derive(Default)]
struct FailingOnceBackend {
    calls: usize,
}

impl TerminalBackend for FailingOnceBackend {
    fn start(&mut self, _command: CommandSpec) -> anyhow::Result<TerminalBackendSession> {
        self.calls += 1;
        if self.calls == 1 {
            anyhow::bail!("backend failed to start");
        }

        Ok(TerminalBackendSession { backend_id: 1 })
    }

    fn write_input(
        &mut self,
        _session: TerminalBackendSession,
        _bytes: &[u8],
    ) -> anyhow::Result<()> {
        Ok(())
    }

    fn resize(
        &mut self,
        _session: TerminalBackendSession,
        _size: TerminalSize,
    ) -> anyhow::Result<()> {
        Ok(())
    }

    fn snapshot(
        &mut self,
        _session: TerminalBackendSession,
    ) -> anyhow::Result<TerminalGridSnapshot> {
        Ok(TerminalGridSnapshot {
            size: TerminalSize { cols: 80, rows: 24 },
            lines: Vec::new(),
            cursor: None,
            exited: false,
            exit_status: None,
        })
    }

    fn has_exited(&mut self, _session: TerminalBackendSession) -> anyhow::Result<bool> {
        Ok(false)
    }

    fn restart(
        &mut self,
        _session: TerminalBackendSession,
    ) -> anyhow::Result<TerminalBackendSession> {
        Ok(TerminalBackendSession { backend_id: 1 })
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
fn backend_runtime_api_supports_input_resize_snapshot_and_restart() {
    let mut backend = FakeRuntimeBackend::default();
    let command = CommandSpec::shell_command("sh", PathBuf::from("/repo/wt"));

    let session = backend.start(command.clone()).unwrap();
    backend.write_input(session, b"pwd\n").unwrap();
    backend
        .resize(
            session,
            TerminalSize {
                cols: 100,
                rows: 30,
            },
        )
        .unwrap();

    let snapshot = backend.snapshot(session).unwrap();

    assert_eq!(backend.started, vec![command]);
    assert_eq!(backend.input, b"pwd\n");
    assert_eq!(
        snapshot.size,
        TerminalSize {
            cols: 100,
            rows: 30
        }
    );
    assert!(!snapshot.exited);
    assert!(!backend.has_exited(session).unwrap());

    let restarted = backend.restart(session).unwrap();
    assert_eq!(restarted.backend_id, 2);
}

#[test]
fn command_spec_runs_through_shell_with_cwd() {
    let cwd = PathBuf::from("/repo/wt");
    let command = CommandSpec::shell_command("$SHELL", cwd.clone());

    assert_eq!(command.display, "$SHELL");
    assert_eq!(command.program, default_shell_program());
    assert_eq!(command.args, vec!["-lc".to_string(), "$SHELL".to_string()]);
    assert_eq!(command.cwd, cwd);
}

#[test]
#[ignore = "requires real PTY timing; run manually during terminal integration"]
fn real_backend_starts_process_in_command_cwd() {
    let dir = tempfile::tempdir().unwrap();
    let mut backend = GhosttyTerminalBackend::new();
    let session = backend
        .start(CommandSpec::shell_command("pwd", dir.path().to_path_buf()))
        .unwrap();
    std::thread::sleep(std::time::Duration::from_millis(250));
    let snapshot = backend.snapshot(session).unwrap();
    assert!(
        snapshot
            .lines
            .join("\n")
            .contains(&dir.path().display().to_string())
    );
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
fn registry_does_not_store_session_when_backend_start_fails() {
    let mut registry = TerminalSessionRegistry::default();
    let mut backend = FailingOnceBackend::default();
    let id = TerminalSessionId::new("repo-1", PathBuf::from("/repo/wt"));
    let command = CommandSpec::shell_command("claude", PathBuf::from("/repo/wt"));

    let error = registry
        .get_or_start(id.clone(), command.clone(), &mut backend)
        .unwrap_err();
    assert_eq!(error.to_string(), "backend failed to start");

    let session = registry
        .get_or_start(id, command, &mut backend)
        .expect("retry should start a fresh session after the failed start was not stored");

    assert_eq!(backend.calls, 2);
    assert_eq!(session.handle.0, 1);
    assert_eq!(session.backend_session.backend_id, 1);
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
