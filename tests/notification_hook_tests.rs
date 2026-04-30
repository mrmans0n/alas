use std::path::{Path, PathBuf};

use alas::app::{TerminalTabKind, WorkspaceSession};
use alas::notifications::{
    HarnessCompletionEvent, HarnessCompletionSource, HookProvider, NotificationController,
    NotificationService,
};
use alas::terminal::{CommandSpec, HarnessKind};
use serde_json::json;

#[derive(Debug, Default)]
struct FakeNotifier {
    completions: Vec<HarnessCompletionEvent>,
}

impl NotificationService for FakeNotifier {
    fn notify_harness_completed(&mut self, event: HarnessCompletionEvent) -> anyhow::Result<()> {
        self.completions.push(event);
        Ok(())
    }
}

fn controller() -> NotificationController<FakeNotifier> {
    NotificationController::new(FakeNotifier::default())
}

fn cwd() -> PathBuf {
    PathBuf::from("/repo/a")
}

fn command_tab(command: &str) -> WorkspaceSession {
    let mut session = WorkspaceSession::default();
    let path = cwd();
    session.create_terminal_tab(
        "repo",
        path.clone(),
        command.to_string(),
        TerminalTabKind::Command,
        CommandSpec::shell_command(command, path),
    );
    session
}

fn shell_tab(path: &Path) -> WorkspaceSession {
    let mut session = WorkspaceSession::default();
    session.ensure_default_terminal_tab(
        "repo",
        path.to_path_buf(),
        CommandSpec::shell_command("$SHELL", path.to_path_buf()),
    );
    session
}

#[test]
fn claude_command_without_hook_does_not_notify() {
    let session = command_tab("claude");
    let controller = controller();

    assert_eq!(session.tabs_for_worktree("repo", &cwd()).len(), 1);
    assert!(controller.notifier().completions.is_empty());
}

#[test]
fn codex_command_without_hook_does_not_notify() {
    let session = command_tab("codex");
    let controller = controller();

    assert_eq!(session.tabs_for_worktree("repo", &cwd()).len(), 1);
    assert!(controller.notifier().completions.is_empty());
}

#[test]
fn command_v_claude_without_hook_does_not_notify() {
    let session = command_tab("command -v claude");
    let controller = controller();

    assert_eq!(session.tabs_for_worktree("repo", &cwd()).len(), 1);
    assert!(controller.notifier().completions.is_empty());
}

#[test]
fn command_v_codex_without_hook_does_not_notify() {
    let session = command_tab("command -V codex");
    let controller = controller();

    assert_eq!(session.tabs_for_worktree("repo", &cwd()).len(), 1);
    assert!(controller.notifier().completions.is_empty());
}

#[test]
fn manually_typed_harness_without_hook_does_not_notify() {
    let path = cwd();
    let session = shell_tab(&path);
    let controller = controller();

    assert_eq!(session.tabs_for_worktree("repo", &path).len(), 1);
    assert!(controller.notifier().completions.is_empty());
}

#[test]
fn non_hook_tab_does_not_notify() {
    let session = command_tab("cargo test");
    let controller = controller();

    assert_eq!(session.tabs_for_worktree("repo", &cwd()).len(), 1);
    assert!(controller.notifier().completions.is_empty());
}

#[test]
fn unsupported_harness_commands_without_hook_do_not_notify() {
    for command in ["cursor-agent", "pi"] {
        let session = command_tab(command);
        let controller = controller();

        assert_eq!(session.tabs_for_worktree("repo", &cwd()).len(), 1);
        assert!(
            controller.notifier().completions.is_empty(),
            "{command} should not notify without a validated hook"
        );
    }
}

#[test]
fn claude_stop_hook_notifies() {
    let mut controller = controller();

    controller
        .handle_raw_hook_payload(
            HookProvider::ClaudeCode,
            &json!({
                "hook_event_name": "Stop",
                "terminal_tab_id": 7
            }),
        )
        .expect("handle hook");

    assert_eq!(controller.notifier().completions.len(), 1);
    let event = &controller.notifier().completions[0];
    assert_eq!(event.harness, HarnessKind::ClaudeCode);
    assert_eq!(event.source, HarnessCompletionSource::ClaudeCodeStop);
    assert_eq!(event.terminal_tab_id.map(|id| id.0), Some(7));
}

#[test]
fn claude_subagent_stop_hook_notifies() {
    let mut controller = controller();

    controller
        .handle_raw_hook_payload(
            HookProvider::ClaudeCode,
            &json!({
                "hook_event_name": "SubagentStop"
            }),
        )
        .expect("handle hook");

    assert_eq!(controller.notifier().completions.len(), 1);
    let event = &controller.notifier().completions[0];
    assert_eq!(event.harness, HarnessKind::ClaudeCode);
    assert_eq!(
        event.source,
        HarnessCompletionSource::ClaudeCodeSubagentStop
    );
}

#[test]
fn codex_agent_turn_complete_hook_notifies() {
    let mut controller = controller();

    controller
        .handle_raw_hook_payload(
            HookProvider::Codex,
            &json!({
                "type": "agent-turn-complete",
                "alas_terminal_tab_id": 11
            }),
        )
        .expect("handle hook");

    assert_eq!(controller.notifier().completions.len(), 1);
    let event = &controller.notifier().completions[0];
    assert_eq!(event.harness, HarnessKind::Codex);
    assert_eq!(
        event.source,
        HarnessCompletionSource::CodexAgentTurnComplete
    );
    assert_eq!(event.terminal_tab_id.map(|id| id.0), Some(11));
}

#[test]
fn hook_tab_id_falls_back_when_primary_id_is_not_numeric() {
    let mut controller = controller();

    controller
        .handle_raw_hook_payload(
            HookProvider::ClaudeCode,
            &json!({
                "hook_event_name": "Stop",
                "terminal_tab_id": "7",
                "alas_terminal_tab_id": 7
            }),
        )
        .expect("handle hook");

    assert_eq!(controller.notifier().completions.len(), 1);
    let event = &controller.notifier().completions[0];
    assert_eq!(event.terminal_tab_id.map(|id| id.0), Some(7));
}

#[test]
fn unsupported_hook_payloads_do_not_notify() {
    let mut controller = controller();

    for (provider, payload) in [
        (
            HookProvider::ClaudeCode,
            json!({ "hook_event_name": "Notification" }),
        ),
        (
            HookProvider::ClaudeCode,
            json!({ "hook_event_name": "PreToolUse" }),
        ),
        (HookProvider::ClaudeCode, json!({ "unexpected": "Stop" })),
        (HookProvider::Codex, json!({ "type": "exec-command-start" })),
        (
            HookProvider::Codex,
            json!({ "unexpected": "agent-turn-complete" }),
        ),
    ] {
        controller
            .handle_raw_hook_payload(provider, &payload)
            .expect("handle hook");
    }

    assert!(controller.notifier().completions.is_empty());
}
