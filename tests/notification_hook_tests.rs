use std::path::{Path, PathBuf};

use alas::app::{TerminalTabKind, TerminalTabStatus, WorkspaceSession};
use alas::config::NotificationPrefs;
use alas::harness_completion::{HarnessCompletionIngestionResult, ingest_harness_completion_hook};
use alas::notifications::{
    AppFocusState, HarnessCompletionContext, HarnessCompletionEvent, HarnessCompletionOutcome,
    HarnessCompletionSource, HookProvider, NotificationController, NotificationSink,
    NotificationSound,
};
use alas::terminal::{CommandSpec, HarnessKind};
use serde_json::json;

#[derive(Debug, Default)]
struct FakeNotifier {
    completions: Vec<HarnessCompletionEvent>,
}

impl NotificationSink for FakeNotifier {
    fn notify_harness_completed(&mut self, event: HarnessCompletionEvent) -> anyhow::Result<()> {
        self.completions.push(event);
        Ok(())
    }
}

#[derive(Debug, Clone, Copy)]
struct FakeFocusState {
    active: bool,
}

impl AppFocusState for FakeFocusState {
    fn is_app_active(&self) -> bool {
        self.active
    }
}

fn controller() -> NotificationController<FakeNotifier> {
    NotificationController::new(FakeNotifier::default())
}

fn controller_with_preferences(prefs: NotificationPrefs) -> NotificationController<FakeNotifier> {
    NotificationController::new_with_preferences(FakeNotifier::default(), prefs)
}

fn controller_with_focus(active: bool) -> NotificationController<FakeNotifier, FakeFocusState> {
    NotificationController::new_with_preferences_and_focus(
        FakeNotifier::default(),
        NotificationPrefs::default(),
        FakeFocusState { active },
    )
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

fn running_terminal_tab(
    session: &mut WorkspaceSession,
    name: &str,
    command: &str,
    path: &Path,
) -> alas::app::TerminalTabId {
    let tab_id = session.create_terminal_tab(
        "repo",
        path.to_path_buf(),
        name.to_string(),
        TerminalTabKind::Command,
        CommandSpec::shell_command(command, path.to_path_buf()),
    );
    session
        .set_tab_status("repo", path, tab_id, TerminalTabStatus::Running)
        .expect("set tab running");
    tab_id
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
                "success": true,
                "terminal_tab_id": 7
            }),
        )
        .expect("handle hook");

    assert_eq!(controller.notifier().completions.len(), 1);
    let event = &controller.notifier().completions[0];
    assert_eq!(event.harness, HarnessKind::ClaudeCode);
    assert_eq!(event.source, HarnessCompletionSource::ClaudeCodeStop);
    assert_eq!(event.outcome, HarnessCompletionOutcome::Success);
    assert_eq!(event.terminal_tab_id.map(|id| id.0), Some(7));
    assert_eq!(event.title, "Claude Code completed");
    assert_eq!(event.body, "Claude Code finished successfully.");
    assert_eq!(event.sound, NotificationSound::Success);
}

#[test]
fn claude_subagent_stop_hook_notifies() {
    let mut controller = controller();

    controller
        .handle_raw_hook_payload(
            HookProvider::ClaudeCode,
            &json!({
                "hook_event_name": "SubagentStop",
                "outcome": "success"
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
                "status": "success",
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
fn focused_app_suppresses_hook_notifications() {
    let mut controller = controller_with_focus(true);

    controller
        .handle_raw_hook_payload(
            HookProvider::ClaudeCode,
            &json!({
                "hook_event_name": "Stop",
                "success": true
            }),
        )
        .expect("handle hook");

    assert!(controller.notifier().completions.is_empty());
}

#[test]
fn claude_stop_hook_ingestion_marks_running_tab_completed_and_notifies() {
    let path = cwd();
    let mut session = WorkspaceSession::default();
    let tab_id = running_terminal_tab(&mut session, "Claude", "claude", &path);
    let mut controller = controller();

    let result = ingest_harness_completion_hook(
        HookProvider::ClaudeCode,
        &json!({
            "hook_event_name": "Stop",
            "success": true,
            "terminal_tab_id": tab_id.0
        }),
        &mut session,
        &mut controller,
    )
    .expect("ingest hook");

    assert_eq!(
        result,
        HarnessCompletionIngestionResult::CompletedTab { tab_id }
    );
    assert_eq!(
        session.terminal_tab_status_by_id(tab_id),
        Some(&TerminalTabStatus::Exited(Some(0)))
    );
    assert_eq!(controller.notifier().completions.len(), 1);
    assert_eq!(
        controller.notifier().completions[0].outcome,
        HarnessCompletionOutcome::Success
    );
}

#[test]
fn codex_completion_hook_ingestion_marks_running_tab_failed_and_notifies() {
    let path = cwd();
    let mut session = WorkspaceSession::default();
    let tab_id = running_terminal_tab(&mut session, "Codex", "codex", &path);
    let mut controller = controller();

    let result = ingest_harness_completion_hook(
        HookProvider::Codex,
        &json!({
            "type": "agent-turn-complete",
            "status": "failed",
            "alas_terminal_tab_id": tab_id.0
        }),
        &mut session,
        &mut controller,
    )
    .expect("ingest hook");

    assert_eq!(
        result,
        HarnessCompletionIngestionResult::FailedTab { tab_id }
    );
    assert_eq!(
        session.terminal_tab_status_by_id(tab_id),
        Some(&TerminalTabStatus::Failed)
    );
    assert_eq!(controller.notifier().completions.len(), 1);
    assert_eq!(
        controller.notifier().completions[0].outcome,
        HarnessCompletionOutcome::Failure
    );
}

#[test]
fn hook_ingestion_correlates_inactive_terminal_tabs() {
    let path = cwd();
    let mut session = WorkspaceSession::default();
    let inactive = running_terminal_tab(&mut session, "Claude", "claude", &path);
    let active = running_terminal_tab(&mut session, "Tests", "cargo test", &path);
    session
        .set_active_tab("repo", &path, active)
        .expect("set active tab");
    let mut controller = controller();

    let result = ingest_harness_completion_hook(
        HookProvider::ClaudeCode,
        &json!({
            "hook_event_name": "Stop",
            "exit_code": 0,
            "terminal_tab_id": inactive.0
        }),
        &mut session,
        &mut controller,
    )
    .expect("ingest hook");

    assert_eq!(
        result,
        HarnessCompletionIngestionResult::CompletedTab { tab_id: inactive }
    );
    assert_eq!(
        session.terminal_tab_status_by_id(inactive),
        Some(&TerminalTabStatus::Exited(Some(0)))
    );
    assert_eq!(
        session.terminal_tab_status_by_id(active),
        Some(&TerminalTabStatus::Running)
    );
    assert_eq!(
        session.active_tab("repo", &path).map(|tab| tab.id),
        Some(active)
    );
    assert_eq!(controller.notifier().completions.len(), 1);
}

#[test]
fn duplicate_completed_tab_hook_is_suppressed() {
    let path = cwd();
    let mut session = WorkspaceSession::default();
    let tab_id = running_terminal_tab(&mut session, "Claude", "claude", &path);
    let mut controller = controller();
    let payload = json!({
        "hook_event_name": "Stop",
        "success": true,
        "terminal_tab_id": tab_id.0
    });

    let first = ingest_harness_completion_hook(
        HookProvider::ClaudeCode,
        &payload,
        &mut session,
        &mut controller,
    )
    .expect("ingest first hook");
    let second = ingest_harness_completion_hook(
        HookProvider::ClaudeCode,
        &payload,
        &mut session,
        &mut controller,
    )
    .expect("ingest duplicate hook");

    assert_eq!(
        first,
        HarnessCompletionIngestionResult::CompletedTab { tab_id }
    );
    assert_eq!(
        second,
        HarnessCompletionIngestionResult::IgnoredDuplicate { tab_id }
    );
    assert_eq!(controller.notifier().completions.len(), 1);
}

#[test]
fn first_hook_for_already_exited_tab_still_notifies() {
    let path = cwd();
    let mut session = WorkspaceSession::default();
    let tab_id = running_terminal_tab(&mut session, "Claude", "claude", &path);
    session
        .set_terminal_tab_status_by_id(tab_id, TerminalTabStatus::Exited(Some(0)))
        .expect("mark tab exited");
    let mut controller = controller();
    let payload = json!({
        "hook_event_name": "Stop",
        "success": true,
        "terminal_tab_id": tab_id.0
    });

    let first = ingest_harness_completion_hook(
        HookProvider::ClaudeCode,
        &payload,
        &mut session,
        &mut controller,
    )
    .expect("ingest first hook");
    let second = ingest_harness_completion_hook(
        HookProvider::ClaudeCode,
        &payload,
        &mut session,
        &mut controller,
    )
    .expect("ingest duplicate hook");

    assert_eq!(
        first,
        HarnessCompletionIngestionResult::NotifiedWithoutTerminalTransition { tab_id }
    );
    assert_eq!(
        second,
        HarnessCompletionIngestionResult::IgnoredDuplicate { tab_id }
    );
    assert_eq!(
        session.terminal_tab_status_by_id(tab_id),
        Some(&TerminalTabStatus::Exited(Some(0)))
    );
    assert_eq!(controller.notifier().completions.len(), 1);
}

#[test]
fn unsupported_hook_ingestion_does_not_notify_or_mutate_tab() {
    let path = cwd();
    let mut session = WorkspaceSession::default();
    let tab_id = running_terminal_tab(&mut session, "Command", "cargo test", &path);
    let mut controller = controller();

    let result = ingest_harness_completion_hook(
        HookProvider::ClaudeCode,
        &json!({
            "hook_event_name": "PreToolUse",
            "success": true,
            "terminal_tab_id": tab_id.0
        }),
        &mut session,
        &mut controller,
    )
    .expect("ingest hook");

    assert_eq!(
        result,
        HarnessCompletionIngestionResult::IgnoredUnsupportedPayload
    );
    assert_eq!(
        session.terminal_tab_status_by_id(tab_id),
        Some(&TerminalTabStatus::Running)
    );
    assert!(controller.notifier().completions.is_empty());
}

#[test]
fn unfocused_app_allows_hook_notifications() {
    let mut controller = controller_with_focus(false);

    controller
        .handle_raw_hook_payload(
            HookProvider::ClaudeCode,
            &json!({
                "hook_event_name": "Stop",
                "success": true
            }),
        )
        .expect("handle hook");

    assert_eq!(controller.notifier().completions.len(), 1);
}

#[test]
fn hook_notification_includes_resolved_tab_context() {
    let mut controller = controller();
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/alas");
    let tab_id = session.create_terminal_tab(
        "alas",
        path.clone(),
        "Tests".to_string(),
        TerminalTabKind::Command,
        CommandSpec::shell_command("cargo test", path),
    );

    controller
        .handle_raw_hook_payload_with_context(
            HookProvider::ClaudeCode,
            &json!({
                "hook_event_name": "Stop",
                "success": false,
                "terminal_tab_id": tab_id.0
            }),
            session
                .terminal_tab_context(tab_id)
                .expect("terminal tab context")
                .into(),
        )
        .expect("handle hook");

    assert_eq!(controller.notifier().completions.len(), 1);
    let event = &controller.notifier().completions[0];
    assert_eq!(event.title, "Claude Code failed");
    assert_eq!(event.body, "Claude Code failed in Tests - alas.");
    assert_eq!(event.sound, NotificationSound::Failure);
}

#[test]
fn unresolved_hook_context_does_not_invent_context() {
    let mut controller = controller();

    controller
        .handle_raw_hook_payload_with_context(
            HookProvider::ClaudeCode,
            &json!({
                "hook_event_name": "Stop",
                "success": true,
                "terminal_tab_id": 7
            }),
            HarnessCompletionContext::unresolved(Some(alas::app::TerminalTabId(7))),
        )
        .expect("handle hook");

    assert_eq!(controller.notifier().completions.len(), 1);
    assert_eq!(
        controller.notifier().completions[0].body,
        "Claude Code finished successfully."
    );
}

#[test]
fn hook_without_tab_id_notifies_without_mutating_tabs() {
    let path = cwd();
    let mut session = WorkspaceSession::default();
    let tab_id = running_terminal_tab(&mut session, "Claude", "claude", &path);
    let mut controller = controller();

    let result = ingest_harness_completion_hook(
        HookProvider::ClaudeCode,
        &json!({
            "hook_event_name": "Stop",
            "success": true
        }),
        &mut session,
        &mut controller,
    )
    .expect("ingest hook");

    assert_eq!(result, HarnessCompletionIngestionResult::NotifiedWithoutTab);
    assert_eq!(
        session.terminal_tab_status_by_id(tab_id),
        Some(&TerminalTabStatus::Running)
    );
    assert_eq!(controller.notifier().completions.len(), 1);
}

#[test]
fn non_running_tab_hook_does_not_complete_or_notify() {
    let path = cwd();
    let mut session = WorkspaceSession::default();
    let tab_id = session.create_terminal_tab(
        "repo",
        path.clone(),
        "Claude".to_string(),
        TerminalTabKind::Command,
        CommandSpec::shell_command("claude", path.clone()),
    );
    let mut controller = controller();

    let result = ingest_harness_completion_hook(
        HookProvider::ClaudeCode,
        &json!({
            "hook_event_name": "Stop",
            "success": true,
            "terminal_tab_id": tab_id.0
        }),
        &mut session,
        &mut controller,
    )
    .expect("ingest hook");

    assert_eq!(
        result,
        HarnessCompletionIngestionResult::IgnoredNonRunningTab { tab_id }
    );
    assert_eq!(
        session.terminal_tab_status_by_id(tab_id),
        Some(&TerminalTabStatus::NotStarted)
    );
    assert!(controller.notifier().completions.is_empty());
}

#[test]
fn hook_tab_id_falls_back_when_primary_id_is_not_numeric() {
    let mut controller = controller();

    controller
        .handle_raw_hook_payload(
            HookProvider::ClaudeCode,
            &json!({
                "hook_event_name": "Stop",
                "exit_code": 0,
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
fn hook_payload_without_outcome_does_not_notify() {
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

    assert!(controller.notifier().completions.is_empty());
}

#[test]
fn disabled_harness_completion_preferences_suppress_hook_notifications() {
    let mut prefs = NotificationPrefs::default();
    prefs.harness_completion.enabled = false;
    let mut controller = controller_with_preferences(prefs);

    controller
        .handle_raw_hook_payload(
            HookProvider::ClaudeCode,
            &json!({
                "hook_event_name": "Stop",
                "success": true
            }),
        )
        .expect("handle hook");

    assert!(controller.notifier().completions.is_empty());
}

#[test]
fn success_and_failure_preferences_gate_hook_notifications_independently() {
    let mut prefs = NotificationPrefs::default();
    prefs.harness_completion.success = false;
    let mut controller = controller_with_preferences(prefs);

    controller
        .handle_raw_hook_payload(
            HookProvider::ClaudeCode,
            &json!({
                "hook_event_name": "Stop",
                "success": true
            }),
        )
        .expect("handle hook");

    controller
        .handle_raw_hook_payload(
            HookProvider::ClaudeCode,
            &json!({
                "hook_event_name": "Stop",
                "success": false
            }),
        )
        .expect("handle hook");

    assert_eq!(controller.notifier().completions.len(), 1);
    assert_eq!(
        controller.notifier().completions[0].outcome,
        HarnessCompletionOutcome::Failure
    );
}

#[test]
fn controller_preferences_can_be_updated_after_construction() {
    let mut prefs = NotificationPrefs::default();
    prefs.harness_completion.success = false;
    let mut controller = controller_with_preferences(prefs);

    controller
        .handle_raw_hook_payload(
            HookProvider::ClaudeCode,
            &json!({
                "hook_event_name": "Stop",
                "success": true
            }),
        )
        .expect("handle hook");
    assert!(controller.notifier().completions.is_empty());

    let prefs = NotificationPrefs::default();
    controller.update_preferences(prefs.clone());
    assert_eq!(controller.preferences(), &prefs);

    controller
        .handle_raw_hook_payload(
            HookProvider::ClaudeCode,
            &json!({
                "hook_event_name": "Stop",
                "success": true
            }),
        )
        .expect("handle hook");

    assert_eq!(controller.notifier().completions.len(), 1);
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
