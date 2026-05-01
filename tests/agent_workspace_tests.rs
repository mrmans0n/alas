use std::path::PathBuf;

use alas::agent::{
    AgentConfigOption, AgentDebugEvent, AgentModeOption, AgentPermissionRequest, AgentPlanState,
    AgentResumeState, AgentSlashCommand, AgentThreadState, AgentThreadStatus, AgentToolCallState,
    AgentTranscriptEntry, AgentTranscriptRole,
};
use alas::app::{TerminalTabKind, WorkspaceSession, WorkspaceTabContent, WorkspaceTabKind};
use alas::terminal::CommandSpec;

#[test]
fn new_agent_thread_starts_disconnected_with_empty_transcript() {
    let state = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));

    assert!(!state.thread_id.is_empty());
    assert_eq!(state.provider_id, "opencode");
    assert_eq!(state.acp_session_id, None);
    assert_eq!(state.worktree_path, PathBuf::from("/repo/worktree"));
    assert_eq!(state.title, "Agent Chat");
    assert_eq!(state.status, AgentThreadStatus::Disconnected);
    assert!(state.transcript.is_empty());
    assert!(state.tool_calls.is_empty());
    assert!(state.plans.is_empty());
    assert!(state.pending_permissions.is_empty());
    assert!(state.available_commands.is_empty());
    assert!(state.available_modes.is_empty());
    assert_eq!(state.current_mode, None);
    assert!(state.config_options.is_empty());
    assert_eq!(state.draft, "");
    assert_eq!(state.resume, AgentResumeState::NotRestored);
    assert!(state.debug_log.is_empty());
}

#[test]
fn transcript_entries_keep_role_and_text() {
    let entry = AgentTranscriptEntry::user("hello");
    assert_eq!(entry.text, "hello");
}

#[test]
fn nested_agent_domain_types_match_task_contract() {
    let roles = [
        AgentTranscriptRole::User,
        AgentTranscriptRole::Agent,
        AgentTranscriptRole::Thought,
        AgentTranscriptRole::System,
        AgentTranscriptRole::Tool,
    ];
    assert_eq!(roles.len(), 5);

    let tool_call = AgentToolCallState {
        id: "tool-1".to_string(),
        title: "Read file".to_string(),
        status: "running".to_string(),
    };
    assert_eq!(tool_call.status, "running");

    let plan = AgentPlanState {
        entries: vec!["Inspect workspace".to_string()],
    };
    assert_eq!(plan.entries, ["Inspect workspace"]);

    let permission = AgentPermissionRequest {
        id: "perm-1".to_string(),
        description: "Allow command".to_string(),
    };
    assert_eq!(permission.description, "Allow command");

    let command = AgentSlashCommand {
        name: "reset".to_string(),
        description: Some("Reset conversation".to_string()),
    };
    assert_eq!(command.description.as_deref(), Some("Reset conversation"));

    let mode = AgentModeOption {
        id: "ask".to_string(),
        name: "Ask".to_string(),
    };
    assert_eq!(mode.name, "Ask");

    let config = AgentConfigOption {
        id: "model".to_string(),
        label: "Model".to_string(),
        value: Some("fast".to_string()),
        options: Vec::new(),
    };
    assert_eq!(config.value.as_deref(), Some("fast"));

    let debug_event = AgentDebugEvent {
        message: "Connected to agent".to_string(),
    };
    assert_eq!(debug_event.message, "Connected to agent");
}

#[test]
fn agent_threads_get_stable_distinct_thread_ids() {
    let first = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));
    let second = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));

    assert_ne!(first.thread_id, second.thread_id);
}

#[test]
fn worktree_can_have_agent_chat_tabs_with_other_tab_kinds() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");
    let terminal = session.create_terminal_tab(
        "repo",
        path.clone(),
        "Shell".to_string(),
        TerminalTabKind::Shell,
        CommandSpec::shell_command("$SHELL", path.clone()),
    );

    let agent = session.create_agent_chat_tab("repo", path.clone(), "opencode".to_string());

    let tabs = session.tabs_for_worktree("repo", &path);
    assert_eq!(tabs.len(), 2);
    assert_eq!(tabs[0].id, terminal);
    assert_eq!(tabs[1].id, agent);
    assert_eq!(tabs[1].kind, WorkspaceTabKind::AgentChat);
    assert!(matches!(tabs[1].content, WorkspaceTabContent::AgentChat(_)));
    assert_eq!(
        session.active_tab("repo", &path).map(|tab| tab.id),
        Some(agent)
    );
}

#[test]
fn workspace_restores_persisted_agent_tabs_once_for_matching_worktree() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");
    let other_path = PathBuf::from("/repo/b");
    let mut state = AgentThreadState::new("opencode", path.clone());
    state.thread_id = "thread-1".to_string();
    state.acp_session_id = Some("session-1".to_string());
    state.status = AgentThreadStatus::Running;
    state.resume = AgentResumeState::NotRestored;
    state.draft = "saved draft".to_string();
    let mut other = AgentThreadState::new("opencode", other_path);
    other.thread_id = "thread-2".to_string();

    let restored = session.restore_agent_chat_tabs(
        "repo",
        &path,
        &[
            alas::agent::AgentThreadRecord::from_state("thread-1".to_string(), &state),
            alas::agent::AgentThreadRecord::from_state("thread-2".to_string(), &other),
        ],
    );
    let duplicate_restore = session.restore_agent_chat_tabs(
        "repo",
        &path,
        &[alas::agent::AgentThreadRecord::from_state(
            "thread-1".to_string(),
            &state,
        )],
    );

    assert_eq!(restored.len(), 1);
    assert!(duplicate_restore.is_empty());
    let tabs = session.tabs_for_worktree("repo", &path);
    assert_eq!(tabs.len(), 1);
    let thread = tabs[0].agent_thread_state().expect("agent thread");
    assert_eq!(thread.thread_id, "thread-1");
    assert_eq!(thread.draft, "saved draft");
    assert_eq!(thread.resume, AgentResumeState::Pending);
    assert_eq!(
        thread.status,
        AgentThreadStatus::ReadOnly {
            reason: "Waiting for agent session resume".to_string()
        }
    );
}

#[test]
fn workspace_restores_persisted_agent_tabs_for_known_worktrees_without_selection() {
    let mut session = WorkspaceSession::default();
    let path_a = PathBuf::from("/repo/a");
    let path_b = PathBuf::from("/repo/b");
    let mut state_a = AgentThreadState::new("opencode", path_a.clone());
    state_a.thread_id = "thread-a".to_string();
    let mut state_b = AgentThreadState::new("codex", path_b.clone());
    state_b.thread_id = "thread-b".to_string();

    let restored = session.restore_agent_chat_tabs_for_worktrees(
        vec![
            ("repo".to_string(), path_a.clone()),
            ("repo".to_string(), path_b.clone()),
        ],
        &[
            alas::agent::AgentThreadRecord::from_state("thread-a".to_string(), &state_a),
            alas::agent::AgentThreadRecord::from_state("thread-b".to_string(), &state_b),
        ],
    );

    assert_eq!(restored.len(), 2);
    assert_eq!(session.tabs_for_worktree("repo", &path_a).len(), 1);
    assert_eq!(session.tabs_for_worktree("repo", &path_b).len(), 1);
    assert_eq!(
        session
            .active_tab("repo", &path_a)
            .and_then(|tab| tab.agent_thread_state())
            .map(|thread| thread.thread_id.as_str()),
        Some("thread-a")
    );
    assert_eq!(
        session
            .active_tab("repo", &path_b)
            .and_then(|tab| tab.agent_thread_state())
            .map(|thread| thread.thread_id.as_str()),
        Some("thread-b")
    );
}

#[test]
fn workspace_restore_for_known_worktrees_dedupes_by_thread_id() {
    let mut session = WorkspaceSession::default();
    let path_a = PathBuf::from("/repo/a");
    let path_b = PathBuf::from("/repo/b");
    let mut state_a = AgentThreadState::new("opencode", path_a.clone());
    state_a.thread_id = "thread-1".to_string();
    let mut state_b = AgentThreadState::new("opencode", path_b.clone());
    state_b.thread_id = "thread-1".to_string();

    let restored = session.restore_agent_chat_tabs_for_worktrees(
        vec![
            ("repo".to_string(), path_a.clone()),
            ("repo".to_string(), path_b.clone()),
        ],
        &[
            alas::agent::AgentThreadRecord::from_state("thread-1".to_string(), &state_a),
            alas::agent::AgentThreadRecord::from_state("thread-1".to_string(), &state_b),
        ],
    );

    assert_eq!(restored.len(), 1);
    let restored_count = session.tabs_for_worktree("repo", &path_a).len()
        + session.tabs_for_worktree("repo", &path_b).len();
    assert_eq!(restored_count, 1);
}

#[test]
fn terminal_specific_mutation_rejects_agent_chat_tabs() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");
    let agent = session.create_agent_chat_tab("repo", path.clone(), "opencode".to_string());

    let error = session
        .set_tab_scroll_offset("repo", &path, agent, 12)
        .expect_err("agent tab should reject terminal mutation")
        .to_string();

    assert!(error.contains("not a terminal tab"));
}

#[test]
fn new_workspace_tab_choice_labels_include_terminal_and_agent_chat() {
    let labels = alas::ui::workspace::new_workspace_tab_choices()
        .into_iter()
        .map(alas::ui::workspace::new_workspace_tab_choice_label)
        .collect::<Vec<_>>();

    assert!(labels.contains(&"Terminal"));
    assert!(labels.contains(&"Agent Chat"));
}

#[test]
fn agent_chat_provider_flow_uses_settings_when_no_provider_enabled() {
    let mut disabled = alas::agent::AgentProviderConfig::new("codex", "Codex", "codex-acp");
    disabled.enabled = false;

    assert_eq!(
        alas::ui::workspace::agent_chat_provider_flow(&[disabled]),
        alas::ui::workspace::AgentChatProviderFlow::ProviderSettings
    );
}

#[test]
fn agent_chat_provider_flow_opens_picker_for_one_enabled_provider() {
    let provider = alas::agent::AgentProviderConfig::new("codex", "Codex", "codex-acp");

    assert_eq!(
        alas::ui::workspace::agent_chat_provider_flow(std::slice::from_ref(&provider)),
        alas::ui::workspace::AgentChatProviderFlow::ProviderPicker(vec![provider])
    );
}

#[test]
fn agent_chat_provider_flow_opens_picker_for_multiple_enabled_providers() {
    let codex = alas::agent::AgentProviderConfig::new("codex", "Codex", "codex-acp");
    let opencode = alas::agent::AgentProviderConfig::new("opencode", "OpenCode", "opencode-acp");

    assert_eq!(
        alas::ui::workspace::agent_chat_provider_flow(&[codex.clone(), opencode.clone()]),
        alas::ui::workspace::AgentChatProviderFlow::ProviderPicker(vec![codex, opencode])
    );
}
