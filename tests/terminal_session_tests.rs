use alas::app::TerminalTabId;
use alas::terminal::{
    CommandSpec, GhosttyTerminalBackend, TerminalBackend, TerminalBackendSession,
    TerminalGridSnapshot, TerminalScreenMode, TerminalSessionId, TerminalSessionRegistry,
    TerminalSize, TerminalStatus, TerminalViewport, default_shell_program, terminal_input_bytes,
};
use gpui::{KeyDownEvent, Keystroke};
use std::path::PathBuf;

fn empty_snapshot(
    size: TerminalSize,
    status: TerminalStatus,
    viewport: TerminalViewport,
) -> TerminalGridSnapshot {
    TerminalGridSnapshot {
        size,
        rows: Vec::new(),
        cursor: None,
        status,
        viewport,
        scrollback_rows: 0,
        screen_mode: TerminalScreenMode::Main,
    }
}

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
        viewport: TerminalViewport,
    ) -> anyhow::Result<TerminalGridSnapshot> {
        let size = TerminalSize { cols: 80, rows: 24 };
        Ok(empty_snapshot(size, TerminalStatus::Running, viewport))
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
        viewport: TerminalViewport,
    ) -> anyhow::Result<TerminalGridSnapshot> {
        Ok(empty_snapshot(
            self.size.unwrap_or(TerminalSize { cols: 80, rows: 24 }),
            if self.exited {
                TerminalStatus::Exited(None)
            } else {
                TerminalStatus::Running
            },
            viewport,
        ))
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
        viewport: TerminalViewport,
    ) -> anyhow::Result<TerminalGridSnapshot> {
        let size = TerminalSize { cols: 80, rows: 24 };
        Ok(empty_snapshot(size, TerminalStatus::Running, viewport))
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
        viewport: TerminalViewport,
    ) -> anyhow::Result<TerminalGridSnapshot> {
        let size = TerminalSize { cols: 80, rows: 24 };
        Ok(empty_snapshot(size, TerminalStatus::Running, viewport))
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

fn key_down(source: &str) -> KeyDownEvent {
    KeyDownEvent {
        keystroke: Keystroke::parse(source).unwrap(),
        is_held: false,
    }
}

fn printable_key_down(source: &str, text: &str) -> KeyDownEvent {
    let mut event = key_down(source);
    event.keystroke.key_char = Some(text.to_string());
    event
}

#[test]
fn terminal_input_maps_basic_control_keys() {
    assert_eq!(terminal_input_bytes(&key_down("enter")).unwrap(), b"\r");
    assert_eq!(
        terminal_input_bytes(&key_down("backspace")).unwrap(),
        vec![0x7f]
    );
    assert_eq!(
        terminal_input_bytes(&key_down("escape")).unwrap(),
        vec![0x1b]
    );
    assert_eq!(
        terminal_input_bytes(&key_down("delete")).unwrap(),
        b"\x1b[3~"
    );
    assert_eq!(
        terminal_input_bytes(&key_down("ctrl-c")).unwrap(),
        vec![0x03]
    );
}

#[test]
fn terminal_input_maps_arrow_keys_to_csi() {
    assert_eq!(terminal_input_bytes(&key_down("up")).unwrap(), b"\x1b[A");
    assert_eq!(terminal_input_bytes(&key_down("down")).unwrap(), b"\x1b[B");
    assert_eq!(terminal_input_bytes(&key_down("right")).unwrap(), b"\x1b[C");
    assert_eq!(terminal_input_bytes(&key_down("left")).unwrap(), b"\x1b[D");
}

#[test]
fn terminal_input_maps_alt_to_escape_prefix() {
    assert_eq!(terminal_input_bytes(&key_down("alt-f")).unwrap(), b"\x1bf");
    assert_eq!(
        terminal_input_bytes(&key_down("alt-backspace")).unwrap(),
        b"\x1b\x7f"
    );
}

#[test]
fn terminal_input_maps_printable_characters() {
    assert_eq!(
        terminal_input_bytes(&printable_key_down("a", "a")).unwrap(),
        b"a"
    );
    assert_eq!(
        terminal_input_bytes(&printable_key_down("shift-a", "A")).unwrap(),
        b"A"
    );
    assert_eq!(
        terminal_input_bytes(&printable_key_down("0", "0")).unwrap(),
        b"0"
    );
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

    let snapshot = backend
        .snapshot(session, TerminalViewport::visible(30))
        .unwrap();

    assert_eq!(backend.started, vec![command]);
    assert_eq!(backend.input, b"pwd\n");
    assert_eq!(
        snapshot.size,
        TerminalSize {
            cols: 100,
            rows: 30
        }
    );
    assert!(!snapshot.exited());
    assert!(!backend.has_exited(session).unwrap());

    let restarted = backend.restart(session).unwrap();
    assert_eq!(restarted.backend_id, 2);
}

#[test]
fn backend_snapshot_accepts_viewport_request() {
    let mut backend = FakeRuntimeBackend::default();
    let session = backend
        .start(CommandSpec::shell_command(
            "$SHELL",
            PathBuf::from("/repo/wt"),
        ))
        .unwrap();
    let snapshot = backend
        .snapshot(
            session,
            TerminalViewport {
                scroll_offset_rows: 10,
                visible_rows: 24,
            },
        )
        .unwrap();

    assert_eq!(snapshot.viewport.scroll_offset_rows, 10);
    assert_eq!(snapshot.viewport.visible_rows, 24);
    assert_eq!(snapshot.screen_mode, TerminalScreenMode::Main);
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
    let snapshot = wait_for_snapshot_text(&mut backend, session, &dir.path().display().to_string());
    assert!(
        snapshot
            .plain_lines()
            .join("\n")
            .contains(&dir.path().display().to_string())
    );
}

#[test]
#[ignore = "requires real PTY timing; run manually during terminal integration"]
fn real_backend_snapshots_command_output_text_grid() {
    let dir = tempfile::tempdir().unwrap();
    let mut backend = GhosttyTerminalBackend::new();
    let session = backend
        .start(CommandSpec::shell_command(
            "printf alas-terminal-ok",
            dir.path().to_path_buf(),
        ))
        .unwrap();

    let snapshot = wait_for_snapshot_text(&mut backend, session, "alas-terminal-ok");

    assert!(
        snapshot
            .plain_lines()
            .join("\n")
            .contains("alas-terminal-ok")
    );
    assert!(snapshot.exited());
}

#[test]
#[ignore = "requires real PTY timing; run manually during terminal integration"]
fn real_backend_clamps_scrollback_viewport_requests() {
    let dir = tempfile::tempdir().unwrap();
    let mut backend = GhosttyTerminalBackend::new();
    let session = backend
        .start(CommandSpec::shell_command(
            "for i in $(seq 1 60); do printf 'line-%02d\\n' \"$i\"; done",
            dir.path().to_path_buf(),
        ))
        .unwrap();

    let bottom = wait_for_snapshot_text(&mut backend, session, "line-60");
    assert!(bottom.scrollback_rows > 0);

    let scrolled = backend
        .snapshot(
            session,
            TerminalViewport {
                scroll_offset_rows: usize::MAX,
                visible_rows: 120,
            },
        )
        .unwrap();

    assert_eq!(
        scrolled.viewport.scroll_offset_rows,
        scrolled.scrollback_rows
    );
    assert_eq!(scrolled.viewport.visible_rows, scrolled.size.rows);
    assert!(scrolled.plain_lines().join("\n").contains("line-01"));
}

#[test]
#[ignore = "requires real PTY timing; run manually during terminal integration"]
fn real_backend_hides_main_scrollback_while_alternate_screen_is_active() {
    let dir = tempfile::tempdir().unwrap();
    let mut backend = GhosttyTerminalBackend::new();
    let session = backend
        .start(CommandSpec::shell_command(
            "printf 'main-before\\n'; printf '\\033[?1049h'; printf 'alt-active'; sleep 1",
            dir.path().to_path_buf(),
        ))
        .unwrap();

    let snapshot = wait_for_snapshot_matching(
        &mut backend,
        session,
        TerminalViewport {
            scroll_offset_rows: 10,
            visible_rows: 24,
        },
        |snapshot| {
            snapshot.screen_mode == TerminalScreenMode::Alternate
                && snapshot.plain_lines().join("\n").contains("alt-active")
        },
    );
    let output = snapshot.plain_lines().join("\n");

    assert_eq!(snapshot.screen_mode, TerminalScreenMode::Alternate);
    assert_eq!(snapshot.scrollback_rows, 0);
    assert_eq!(snapshot.viewport.scroll_offset_rows, 0);
    assert!(output.contains("alt-active"));
    assert!(!output.contains("main-before"));
}

fn wait_for_snapshot_text(
    backend: &mut GhosttyTerminalBackend,
    session: TerminalBackendSession,
    expected: &str,
) -> TerminalGridSnapshot {
    wait_for_snapshot_matching(
        backend,
        session,
        TerminalViewport::visible(24),
        |snapshot| snapshot.plain_lines().join("\n").contains(expected) && snapshot.exited(),
    )
}

fn wait_for_snapshot_matching(
    backend: &mut GhosttyTerminalBackend,
    session: TerminalBackendSession,
    viewport: TerminalViewport,
    mut predicate: impl FnMut(&TerminalGridSnapshot) -> bool,
) -> TerminalGridSnapshot {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
    let mut last_snapshot = None;

    while std::time::Instant::now() < deadline {
        let snapshot = backend.snapshot(session, viewport).unwrap();
        if predicate(&snapshot) {
            return snapshot;
        }
        last_snapshot = Some(snapshot);
        std::thread::sleep(std::time::Duration::from_millis(25));
    }

    last_snapshot.unwrap_or_else(|| backend.snapshot(session, viewport).unwrap())
}

#[test]
fn session_id_is_stable_for_repo_and_worktree() {
    let a = TerminalSessionId::new("repo-1", PathBuf::from("/repo/wt"), TerminalTabId(1));
    let b = TerminalSessionId::new("repo-1", PathBuf::from("/repo/wt"), TerminalTabId(1));
    assert_eq!(a, b);
}

#[test]
fn registry_reuses_existing_session_for_worktree() {
    let mut registry = TerminalSessionRegistry::default();
    let mut backend = FakeBackend::default();
    let id = TerminalSessionId::new("repo-1", PathBuf::from("/repo/wt"), TerminalTabId(1));
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
fn registry_lookup_for_missing_session_does_not_start_backend() {
    let registry = TerminalSessionRegistry::default();
    let id = TerminalSessionId::new("repo-1", PathBuf::from("/repo/wt"), TerminalTabId(1));

    assert!(registry.get(&id).is_none());
}

#[test]
fn registry_attaches_existing_backend_session_without_starting() {
    let mut registry = TerminalSessionRegistry::default();
    let mut backend = CountingBackend::default();
    let id = TerminalSessionId::new("repo-1", PathBuf::from("/repo/wt"), TerminalTabId(1));
    let command = CommandSpec::shell_command("claude", PathBuf::from("/repo/wt"));
    let backend_session = TerminalBackendSession { backend_id: 42 };

    let attached = registry.attach_existing(id.clone(), command.clone(), backend_session);
    let reused = registry
        .get_or_start(id, command, &mut backend)
        .expect("attached session should be reused without backend start");

    assert_eq!(attached.handle, reused.handle);
    assert_eq!(reused.backend_session, backend_session);
    assert_eq!(backend.start_count(), 0);
}

#[test]
fn registry_removes_sessions_by_worktree_and_repository() {
    let mut registry = TerminalSessionRegistry::default();
    let mut backend = CountingBackend::default();
    let repo = "repo";
    let worktree_a = PathBuf::from("/repo/a");
    let worktree_b = PathBuf::from("/repo/b");

    let a1 = registry
        .get_or_start(
            TerminalSessionId::new(repo, worktree_a.clone(), TerminalTabId(1)),
            CommandSpec::shell_command("$SHELL", worktree_a.clone()),
            &mut backend,
        )
        .unwrap();
    let a2 = registry
        .get_or_start(
            TerminalSessionId::new(repo, worktree_a.clone(), TerminalTabId(2)),
            CommandSpec::shell_command("cargo test", worktree_a.clone()),
            &mut backend,
        )
        .unwrap();
    let b1 = registry
        .get_or_start(
            TerminalSessionId::new(repo, worktree_b.clone(), TerminalTabId(3)),
            CommandSpec::shell_command("$SHELL", worktree_b.clone()),
            &mut backend,
        )
        .unwrap();

    let removed = registry.remove_sessions_for_worktree(repo, &worktree_a);
    let removed_handles: Vec<_> = removed.iter().map(|session| session.handle).collect();
    assert_eq!(removed.len(), 2);
    assert!(removed_handles.contains(&a1.handle));
    assert!(removed_handles.contains(&a2.handle));
    assert_eq!(
        registry
            .remove_sessions_for_worktree(repo, &worktree_a)
            .len(),
        0
    );

    let removed = registry.remove_sessions_for_repository(repo);
    assert_eq!(removed.len(), 1);
    assert_eq!(removed[0].handle, b1.handle);
}

#[test]
fn registry_does_not_store_session_when_backend_start_fails() {
    let mut registry = TerminalSessionRegistry::default();
    let mut backend = FailingOnceBackend::default();
    let id = TerminalSessionId::new("repo-1", PathBuf::from("/repo/wt"), TerminalTabId(1));
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
    let first_id = TerminalSessionId::new("repo-1", PathBuf::from("/repo/wt-a"), TerminalTabId(1));
    let second_id = TerminalSessionId::new("repo-1", PathBuf::from("/repo/wt-b"), TerminalTabId(1));
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

#[test]
fn registry_starts_one_backend_session_per_terminal_tab() {
    let mut registry = TerminalSessionRegistry::default();
    let mut backend = CountingBackend::default();
    let worktree = PathBuf::from("/repo/wt");
    let first_id = TerminalSessionId::new("repo-1", worktree.clone(), TerminalTabId(1));
    let second_id = TerminalSessionId::new("repo-1", worktree.clone(), TerminalTabId(2));

    let first = registry
        .get_or_start(
            first_id.clone(),
            CommandSpec::shell_command("$SHELL", worktree.clone()),
            &mut backend,
        )
        .unwrap();
    let second = registry
        .get_or_start(
            second_id.clone(),
            CommandSpec::shell_command("cargo test", worktree.clone()),
            &mut backend,
        )
        .unwrap();
    let first_again = registry
        .get_or_start(
            first_id,
            CommandSpec::shell_command("ignored", worktree),
            &mut backend,
        )
        .unwrap();

    assert_eq!(first.backend_session, first_again.backend_session);
    assert_ne!(first.backend_session, second.backend_session);
    assert_eq!(backend.start_count(), 2);
}

#[test]
fn remove_all_sessions_drains_registry() {
    use alas::app::TerminalTabId;
    use alas::terminal::{
        CommandSpec, TerminalBackendSession, TerminalSessionId, TerminalSessionRegistry,
    };
    use std::path::PathBuf;

    let mut registry = TerminalSessionRegistry::default();
    let id_one = TerminalSessionId::new("repo", PathBuf::from("/tmp/one"), TerminalTabId(1));
    let id_two = TerminalSessionId::new("repo", PathBuf::from("/tmp/two"), TerminalTabId(2));
    let command = CommandSpec::shell_command("echo ok", PathBuf::from("/tmp"));

    registry.attach_existing(
        id_one.clone(),
        command.clone(),
        TerminalBackendSession { backend_id: 1 },
    );
    registry.attach_existing(
        id_two.clone(),
        command,
        TerminalBackendSession { backend_id: 2 },
    );

    let removed = registry.remove_all_sessions();

    assert_eq!(removed.len(), 2);
    assert!(registry.get(&id_one).is_none());
    assert!(registry.get(&id_two).is_none());
}
