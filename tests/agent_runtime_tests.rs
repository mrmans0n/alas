use std::path::PathBuf;
use std::time::{Duration, Instant};

use alas::agent::{
    AcpProcessConnection, AgentAuthStatus, AgentConfigOption, AgentConfigValueOption,
    AgentDebugEvent, AgentModeOption, AgentProviderConfig, AgentProviderEnvVar, AgentResumeState,
    AgentRuntime, AgentRuntimeEvent, AgentSlashCommand, AgentTerminalService, AgentThreadState,
    AgentThreadStatus, AgentTranscriptEntry, AgentTranscriptRole, AgentTrustMode, CredentialStore,
    CredentialStoreKey, FakeAcpConnection, FilesystemCallbackService, MemoryCredentialStore,
    ProviderCwdPolicy, apply_agent_update, redact_debug_message, redact_debug_value,
    resolve_provider_cwd,
};

#[test]
fn process_connection_reports_missing_provider_binary_with_context() {
    let provider = AgentProviderConfig::new(
        "missing-provider",
        "Missing Provider",
        "alas-definitely-missing-acp-provider-binary",
    );

    let error = AcpProcessConnection::spawn(&provider, PathBuf::from("/")).unwrap_err();
    let message = error.to_string();

    assert!(message.contains("missing-provider"));
    assert!(message.contains("alas-definitely-missing-acp-provider-binary"));
}

#[test]
fn process_connection_dispatches_filesystem_callbacks() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("note.txt");
    let provider = AgentProviderConfig::new("dispatcher", "Dispatcher", "/bin/cat");
    let mut connection = AcpProcessConnection::spawn(&provider, temp.path().to_path_buf())
        .unwrap()
        .with_callback_services(
            FilesystemCallbackService::new(
                AgentTrustMode::AllowEverything,
                temp.path().to_path_buf(),
            ),
            AgentTerminalService::new(AgentTrustMode::AllowEverything, temp.path().to_path_buf()),
        );

    connection
        .dispatch_client_request(
            "fs/write_text_file",
            serde_json::json!({ "sessionId": "s", "path": path, "content": "hello" }),
        )
        .unwrap();
    let response = connection
        .dispatch_client_request(
            "fs/read_text_file",
            serde_json::json!({ "sessionId": "s", "path": temp.path().join("note.txt") }),
        )
        .unwrap();

    assert_eq!(response["content"], "hello");
}

#[cfg(unix)]
#[test]
fn process_connection_dispatches_terminal_callbacks() {
    let temp = tempfile::tempdir().unwrap();
    let provider = AgentProviderConfig::new("dispatcher", "Dispatcher", "/bin/cat");
    let mut connection = AcpProcessConnection::spawn(&provider, temp.path().to_path_buf())
        .unwrap()
        .with_callback_services(
            FilesystemCallbackService::new(
                AgentTrustMode::AllowEverything,
                temp.path().to_path_buf(),
            ),
            AgentTerminalService::new(AgentTrustMode::AllowEverything, temp.path().to_path_buf()),
        );

    let created = connection
        .dispatch_client_request(
            "terminal/create",
            serde_json::json!({ "sessionId": "s", "command": "printf", "args": ["hello"], "cwd": temp.path() }),
        )
        .unwrap();
    let terminal_id = created["terminalId"].as_str().unwrap();
    let exit = connection
        .dispatch_client_request(
            "terminal/wait_for_exit",
            serde_json::json!({ "sessionId": "s", "terminalId": terminal_id }),
        )
        .unwrap();
    let output = connection
        .dispatch_client_request(
            "terminal/output",
            serde_json::json!({ "sessionId": "s", "terminalId": terminal_id }),
        )
        .unwrap();
    connection
        .dispatch_client_request(
            "terminal/kill",
            serde_json::json!({ "sessionId": "s", "terminalId": terminal_id }),
        )
        .unwrap();
    connection
        .dispatch_client_request(
            "terminal/release",
            serde_json::json!({ "sessionId": "s", "terminalId": terminal_id }),
        )
        .unwrap();

    assert_eq!(exit["exitCode"], 0);
    assert_eq!(output["output"], "hello");
}

#[test]
fn process_connection_ask_permission_returns_honest_error() {
    let temp = tempfile::tempdir().unwrap();
    let provider = AgentProviderConfig::new("dispatcher", "Dispatcher", "/bin/cat");
    let mut connection = AcpProcessConnection::spawn(&provider, temp.path().to_path_buf())
        .unwrap()
        .with_callback_services(
            FilesystemCallbackService::new(AgentTrustMode::Ask, temp.path().to_path_buf()),
            AgentTerminalService::new(AgentTrustMode::Ask, temp.path().to_path_buf()),
        );

    let error = connection
        .dispatch_client_request(
            "session/request_permission",
            serde_json::json!({
                "sessionId": "s",
                "toolCall": { "toolCallId": "t", "title": "Run tool" },
                "options": [
                    { "optionId": "allow", "name": "Allow", "kind": "allow_once" },
                    { "optionId": "reject", "name": "Reject", "kind": "reject_once" }
                ]
            }),
        )
        .expect_err("Ask mode cannot silently choose an ACP permission option");

    assert!(
        error
            .to_string()
            .contains("permission request requires user approval")
    );
}

#[test]
fn process_connection_does_not_select_allow_when_permission_denied() {
    let temp = tempfile::tempdir().unwrap();
    let provider = AgentProviderConfig::new("dispatcher", "Dispatcher", "/bin/cat");
    let mut connection = AcpProcessConnection::spawn(&provider, temp.path().to_path_buf())
        .unwrap()
        .with_callback_services(
            FilesystemCallbackService::new(AgentTrustMode::Deny, temp.path().to_path_buf()),
            AgentTerminalService::new(AgentTrustMode::Deny, temp.path().to_path_buf()),
        );

    let error = connection
        .dispatch_client_request(
            "session/request_permission",
            serde_json::json!({
                "sessionId": "s",
                "toolCall": { "toolCallId": "t", "title": "Run tool" },
                "options": [
                    { "optionId": "allow", "name": "Allow", "kind": "allow_once" }
                ]
            }),
        )
        .expect_err("permission denial must not select the only allow option");

    assert!(
        error
            .to_string()
            .contains("permission request did not include a compatible option")
    );
}

#[test]
fn process_connection_ask_filesystem_returns_honest_error() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("note.txt");
    std::fs::write(&path, "hello").unwrap();
    let provider = AgentProviderConfig::new("dispatcher", "Dispatcher", "/bin/cat");
    let mut connection = AcpProcessConnection::spawn(&provider, temp.path().to_path_buf())
        .unwrap()
        .with_callback_services(
            FilesystemCallbackService::new(AgentTrustMode::Ask, temp.path().to_path_buf()),
            AgentTerminalService::new(AgentTrustMode::Ask, temp.path().to_path_buf()),
        );

    let error = connection
        .dispatch_client_request(
            "fs/read_text_file",
            serde_json::json!({ "sessionId": "s", "path": path }),
        )
        .unwrap_err()
        .to_string();

    assert!(error.contains("cannot be continued"));
}

#[cfg(unix)]
#[test]
fn acp_cancel_handle_writes_session_cancel_notification() {
    let temp = tempfile::tempdir().unwrap();
    let output = temp.path().join("cancel.json");
    let script = format!(
        "IFS= read -r line; printf '%s' \"$line\" > {}; sleep 1",
        output.display()
    );
    let mut provider = AgentProviderConfig::new("cancel-provider", "Cancel Provider", "/bin/sh");
    provider.args = vec!["-c".to_string(), script];

    let connection = AcpProcessConnection::spawn(&provider, temp.path().to_path_buf()).unwrap();
    let cancel_handle = connection.cancel_handle();
    cancel_handle.cancel("session-123".to_string()).unwrap();

    let deadline = Instant::now() + Duration::from_secs(2);
    while !output.exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }

    let value: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(output).unwrap()).unwrap();
    assert_eq!(value["jsonrpc"], "2.0");
    assert_eq!(value["method"], "session/cancel");
    assert_eq!(value["params"]["sessionId"], "session-123");
}

#[test]
fn process_connection_rejects_unresolved_secure_env_refs() {
    let mut provider = AgentProviderConfig::new("secure-provider", "Secure Provider", "unused");
    provider
        .env
        .push(AgentProviderEnvVar::secure_ref("API_TOKEN", "token-id"));

    let error = AcpProcessConnection::spawn_with_env(
        &provider,
        PathBuf::from("/"),
        &[("TOKEN".to_string(), "redacted".to_string())],
    )
    .unwrap_err();
    let message = error.to_string();

    assert!(message.contains("secure-provider"));
    assert!(message.contains("API_TOKEN"));
    assert!(!message.contains("token-id"));
    assert!(message.contains("requires credential resolution before launch"));
    assert!(!message.contains("redacted"));
}

#[cfg(unix)]
#[test]
fn process_connection_spawns_after_resolving_secure_env_refs() {
    let temp = tempfile::tempdir().unwrap();
    let output = temp.path().join("secure-spawn-output.txt");
    let script = format!("printf '%s' \"$API_TOKEN\" > {}", output.display());
    let mut provider = AgentProviderConfig::new("secure-provider", "Secure Provider", "/bin/sh");
    provider.args = vec!["-c".to_string(), script];
    provider.env.push(AgentProviderEnvVar::secure_ref(
        "API_TOKEN",
        "secure-provider/API_TOKEN",
    ));
    let store = MemoryCredentialStore::default();
    store
        .write_secret(
            &CredentialStoreKey::new("secure-provider", "API_TOKEN"),
            "resolved-secret",
        )
        .unwrap();

    let connection =
        AcpProcessConnection::spawn_with_credentials(&provider, temp.path().to_path_buf(), &store)
            .unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    while !output.exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    drop(connection);

    assert_eq!(std::fs::read_to_string(output).unwrap(), "resolved-secret");
}

#[test]
#[ignore = "requires ALAS_TEST_ACP_COMMAND pointing at a real ACP provider"]
fn real_acp_provider_can_initialize_and_create_session() {
    let command = std::env::var("ALAS_TEST_ACP_COMMAND")
        .expect("set ALAS_TEST_ACP_COMMAND to a real ACP provider command");
    let args = std::env::var("ALAS_TEST_ACP_ARGS")
        .ok()
        .map(|args| args.split_whitespace().map(str::to_string).collect())
        .unwrap_or_default();

    let temp = tempfile::tempdir().unwrap();
    let mut provider = AgentProviderConfig::new("real-acp", "Real ACP", command);
    provider.args = args;

    let connection = AcpProcessConnection::spawn(&provider, temp.path().to_path_buf()).unwrap();
    let thread = AgentThreadState::new("real-acp", temp.path().to_path_buf());
    let mut runtime = AgentRuntime::with_connection(thread, connection);

    runtime.initialize().unwrap();
    runtime.create_session().unwrap();

    assert_eq!(runtime.thread().status, AgentThreadStatus::Ready);
    assert!(runtime.thread().acp_session_id.is_some());
}

#[test]
fn fake_authenticate_updates_auth_status_and_redacted_debug_events() {
    let thread = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));
    let connection = FakeAcpConnection::new();
    let mut runtime = AgentRuntime::with_connection(thread, connection);

    runtime.authenticate("env-var").unwrap();

    assert_eq!(runtime.thread().auth_status, AgentAuthStatus::Authenticated);
    assert_eq!(runtime.thread().status, AgentThreadStatus::Ready);
    assert_eq!(runtime.connection().authenticated_methods(), &["env-var"]);
    assert!(
        runtime
            .thread()
            .debug_log
            .iter()
            .any(|event| event.message == "Authentication succeeded")
    );
}

#[test]
fn fake_authenticate_failure_preserves_required_instructions() {
    let mut thread = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));
    thread.auth_status = AgentAuthStatus::Required {
        instructions: "Run login".to_string(),
    };
    let connection = FakeAcpConnection::new().with_auth_error("denied");
    let mut runtime = AgentRuntime::with_connection(thread, connection);

    let error = runtime.authenticate("terminal").unwrap_err();

    assert_eq!(error.to_string(), "denied");
    assert_eq!(
        runtime.thread().auth_status,
        AgentAuthStatus::Failed {
            message: "denied".to_string(),
            instructions: "Run login".to_string(),
        }
    );
}

#[cfg(unix)]
#[test]
fn process_connection_spawns_with_cwd_args_and_env() {
    let temp = tempfile::tempdir().unwrap();
    let output = temp.path().join("spawn-output.txt");
    let script = format!(
        "printf '%s|%s|%s' \"$PWD\" \"$ALAS_TEST_ENV\" \"$1\" > {}",
        output.display()
    );
    let mut provider = AgentProviderConfig::new("shell-provider", "Shell Provider", "/bin/sh");
    provider.args = vec![
        "-c".to_string(),
        script,
        "alas-sh".to_string(),
        "arg-value".to_string(),
    ];
    provider.env.push(AgentProviderEnvVar {
        name: "ALAS_TEST_ENV".to_string(),
        value: Some("env-value".to_string()),
        secure_ref: None,
    });

    let connection = AcpProcessConnection::spawn(&provider, temp.path().to_path_buf()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    while !output.exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    drop(connection);

    assert_eq!(
        std::fs::read_to_string(output).unwrap(),
        format!(
            "{}|env-value|arg-value",
            temp.path().canonicalize().unwrap().display()
        )
    );
}

#[cfg(unix)]
#[test]
fn process_connection_drop_kills_and_reaps_running_child() {
    let temp = tempfile::tempdir().unwrap();
    let pid_file = temp.path().join("child.pid");
    let script = format!("echo $$ > {}; sleep 60", pid_file.display());
    let mut provider = AgentProviderConfig::new("sleep-provider", "Sleep Provider", "/bin/sh");
    provider.args = vec!["-c".to_string(), script];

    let connection = AcpProcessConnection::spawn(&provider, temp.path().to_path_buf()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    while !pid_file.exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    let pid: libc::pid_t = std::fs::read_to_string(&pid_file)
        .unwrap()
        .trim()
        .parse()
        .unwrap();

    drop(connection);

    let still_exists = unsafe { libc::kill(pid, 0) == 0 };
    assert!(!still_exists, "child process should be reaped on drop");
}

#[test]
fn provider_cwd_policy_resolves_launch_directory() {
    let selected_worktree = PathBuf::from("/repo/worktrees/feature");
    let repository_root = PathBuf::from("/repo");

    let mut provider = AgentProviderConfig::new("provider", "Provider", "agent");
    provider.cwd_policy = ProviderCwdPolicy::SelectedWorktree;
    assert_eq!(
        resolve_provider_cwd(&provider, &selected_worktree, &repository_root),
        selected_worktree
    );

    let mut provider = AgentProviderConfig::new("provider", "Provider", "agent");
    provider.cwd_policy = ProviderCwdPolicy::RepositoryRoot;
    assert_eq!(
        resolve_provider_cwd(&provider, &selected_worktree, &repository_root),
        repository_root
    );

    let fixed = PathBuf::from("/tmp/provider-cwd");
    let mut provider = AgentProviderConfig::new("provider", "Provider", "agent");
    provider.cwd_policy = ProviderCwdPolicy::Fixed(fixed.clone());
    assert_eq!(
        resolve_provider_cwd(&provider, &selected_worktree, &repository_root),
        fixed
    );
}

#[test]
fn initialize_sets_status_ready() {
    let thread = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));
    let connection = FakeAcpConnection::new();
    let mut runtime = AgentRuntime::with_connection(thread, connection);

    runtime.initialize().unwrap();

    assert_eq!(runtime.thread().status, AgentThreadStatus::Ready);
}

#[test]
fn new_session_applies_streamed_update_and_sets_status_ready() {
    let thread = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));
    let connection = FakeAcpConnection::new().with_new_session(
        "session-1",
        vec![
            AgentRuntimeEvent::AgentMessageChunk("hello from agent".to_string()),
            AgentRuntimeEvent::ToolCall {
                id: "tool-1".to_string(),
                title: "Read file".to_string(),
                status: "completed".to_string(),
            },
            AgentRuntimeEvent::Plan(vec!["Inspect files".to_string(), "Report back".to_string()]),
            AgentRuntimeEvent::Ready,
        ],
    );
    let mut runtime = AgentRuntime::with_connection(thread, connection);

    runtime.create_session().unwrap();

    let thread = runtime.thread();
    assert_eq!(thread.acp_session_id.as_deref(), Some("session-1"));
    assert_eq!(thread.status, AgentThreadStatus::Ready);
    assert_eq!(
        thread.transcript,
        vec![AgentTranscriptEntry::agent("hello from agent")]
    );
    assert_eq!(thread.tool_calls.len(), 1);
    assert_eq!(thread.tool_calls[0].id, "tool-1");
    assert_eq!(
        thread.plans[0].entries,
        vec!["Inspect files", "Report back"]
    );
}

#[test]
fn apply_agent_update_maps_message_chunk_and_plan() {
    let mut thread = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));

    apply_agent_update(
        &mut thread,
        alas::agent::AgentUpdate::AgentMessageChunk("hello".to_string()),
    );
    apply_agent_update(
        &mut thread,
        alas::agent::AgentUpdate::Plan(vec!["Inspect".to_string(), "Report".to_string()]),
    );

    assert_eq!(
        thread.transcript,
        vec![AgentTranscriptEntry::agent("hello")]
    );
    assert_eq!(thread.plans[0].entries, vec!["Inspect", "Report"]);
}

#[test]
fn apply_agent_update_preserves_tool_call_fields_on_partial_update() {
    let mut thread = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));

    apply_agent_update(
        &mut thread,
        alas::agent::AgentUpdate::ToolCall {
            id: "tool-1".to_string(),
            title: "Read file".to_string(),
            status: "Pending".to_string(),
        },
    );
    apply_agent_update(
        &mut thread,
        alas::agent::AgentUpdate::ToolCallUpdate {
            id: "tool-1".to_string(),
            title: None,
            status: Some("Completed".to_string()),
        },
    );

    assert_eq!(thread.tool_calls.len(), 1);
    assert_eq!(thread.tool_calls[0].title, "Read file");
    assert_eq!(thread.tool_calls[0].status, "Completed");
}

#[test]
fn apply_agent_update_maps_commands_modes_config_and_error() {
    let mut thread = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));

    apply_agent_update(
        &mut thread,
        alas::agent::AgentUpdate::AvailableCommands(vec![AgentSlashCommand {
            name: "plan".to_string(),
            description: Some("Create a plan".to_string()),
        }]),
    );
    apply_agent_update(
        &mut thread,
        alas::agent::AgentUpdate::AvailableModes {
            modes: vec![AgentModeOption {
                id: "default".to_string(),
                name: "Default".to_string(),
            }],
            current: Some("default".to_string()),
        },
    );
    apply_agent_update(
        &mut thread,
        alas::agent::AgentUpdate::ConfigOptions(vec![AgentConfigOption {
            id: "model".to_string(),
            label: "Model".to_string(),
            value: Some("sonnet".to_string()),
            options: Vec::new(),
        }]),
    );
    apply_agent_update(
        &mut thread,
        alas::agent::AgentUpdate::Error("provider warning".to_string()),
    );

    assert_eq!(thread.available_commands[0].name, "plan");
    assert_eq!(thread.available_modes[0].id, "default");
    assert_eq!(thread.current_mode.as_deref(), Some("default"));
    assert_eq!(thread.config_options[0].value.as_deref(), Some("sonnet"));
    assert_eq!(thread.debug_log[0].message, "provider warning");
}

#[test]
fn acp_session_update_converts_supported_updates() {
    use agent_client_protocol::schema::{
        AvailableCommand, AvailableCommandsUpdate, ConfigOptionUpdate, ContentChunk, Plan,
        PlanEntry, PlanEntryPriority, PlanEntryStatus, SessionConfigOption,
        SessionConfigSelectOption, SessionUpdate, ToolCallStatus, ToolCallUpdate,
        ToolCallUpdateFields,
    };

    let message = alas::agent::agent_update_from_acp_session_update(
        SessionUpdate::AgentMessageChunk(ContentChunk::new("hi".into())),
    );
    assert_eq!(
        message,
        Some(alas::agent::AgentUpdate::AgentMessageChunk(
            "hi".to_string()
        ))
    );

    let tool_call_update = alas::agent::agent_update_from_acp_session_update(
        SessionUpdate::ToolCallUpdate(ToolCallUpdate::new(
            "tool-1",
            ToolCallUpdateFields::new().status(ToolCallStatus::Completed),
        )),
    );
    assert_eq!(
        tool_call_update,
        Some(alas::agent::AgentUpdate::ToolCallUpdate {
            id: "tool-1".to_string(),
            title: None,
            status: Some("Completed".to_string()),
        })
    );

    let plan =
        alas::agent::agent_update_from_acp_session_update(SessionUpdate::Plan(Plan::new(vec![
            PlanEntry::new(
                "Inspect files",
                PlanEntryPriority::Medium,
                PlanEntryStatus::Pending,
            ),
        ])));
    assert_eq!(
        plan,
        Some(alas::agent::AgentUpdate::Plan(vec![
            "Inspect files".to_string()
        ]))
    );

    let commands =
        alas::agent::agent_update_from_acp_session_update(SessionUpdate::AvailableCommandsUpdate(
            AvailableCommandsUpdate::new(vec![AvailableCommand::new("plan", "Create a plan")]),
        ));
    assert_eq!(
        commands,
        Some(alas::agent::AgentUpdate::AvailableCommands(vec![
            AgentSlashCommand {
                name: "plan".to_string(),
                description: Some("Create a plan".to_string()),
            },
        ]))
    );

    let mode = alas::agent::agent_update_from_acp_session_update(SessionUpdate::CurrentModeUpdate(
        agent_client_protocol::schema::CurrentModeUpdate::new("default"),
    ));
    assert_eq!(
        mode,
        Some(alas::agent::AgentUpdate::CurrentMode("default".to_string()))
    );

    let config =
        alas::agent::agent_update_from_acp_session_update(SessionUpdate::ConfigOptionUpdate(
            ConfigOptionUpdate::new(vec![SessionConfigOption::select(
                "model",
                "Model",
                "sonnet",
                vec![
                    SessionConfigSelectOption::new("sonnet", "Claude Sonnet"),
                    SessionConfigSelectOption::new("opus", "Claude Opus"),
                ],
            )]),
        ));
    assert_eq!(
        config,
        Some(alas::agent::AgentUpdate::ConfigOptions(vec![
            AgentConfigOption {
                id: "model".to_string(),
                label: "Model".to_string(),
                value: Some("sonnet".to_string()),
                options: vec![
                    AgentConfigValueOption {
                        id: "sonnet".to_string(),
                        label: "Claude Sonnet".to_string(),
                    },
                    AgentConfigValueOption {
                        id: "opus".to_string(),
                        label: "Claude Opus".to_string(),
                    },
                ],
            },
        ]))
    );
}

#[test]
fn cancel_calls_connection_and_returns_ready() {
    let mut thread = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));
    thread.acp_session_id = Some("session-1".to_string());
    thread.status = AgentThreadStatus::Running;
    let connection = FakeAcpConnection::new();
    let mut runtime = AgentRuntime::with_connection(thread, connection);

    runtime.cancel().unwrap();

    assert_eq!(runtime.thread().status, AgentThreadStatus::Ready);
    assert_eq!(
        runtime.connection().cancelled_sessions(),
        &["session-1".to_string()]
    );
}

#[test]
fn set_mode_and_config_call_fake_connection() {
    let mut thread = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));
    thread.acp_session_id = Some("session-1".to_string());
    thread.status = AgentThreadStatus::Ready;
    thread.current_mode = Some("ask".to_string());
    thread.config_options = vec![AgentConfigOption {
        id: "model".to_string(),
        label: "Model".to_string(),
        value: Some("old".to_string()),
        options: Vec::new(),
    }];
    let connection = FakeAcpConnection::new();
    let mut runtime = AgentRuntime::with_connection(thread, connection);

    runtime.set_mode("plan").unwrap();
    runtime.set_config_option("model", "new").unwrap();

    assert_eq!(runtime.thread().current_mode.as_deref(), Some("plan"));
    assert_eq!(
        runtime.thread().config_options[0].value.as_deref(),
        Some("new")
    );
    assert_eq!(
        runtime.connection().set_modes(),
        &[("session-1".to_string(), "plan".to_string())]
    );
    assert_eq!(
        runtime.connection().set_config_options(),
        &[(
            "session-1".to_string(),
            "model".to_string(),
            "new".to_string()
        )]
    );
}

#[test]
fn failed_set_mode_keeps_previous_current_mode() {
    let mut thread = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));
    thread.acp_session_id = Some("session-1".to_string());
    thread.status = AgentThreadStatus::Ready;
    thread.current_mode = Some("ask".to_string());
    let connection = FakeAcpConnection::new().with_set_mode_error("mode failed");
    let mut runtime = AgentRuntime::with_connection(thread, connection);

    let error = runtime.set_mode("plan").unwrap_err();

    assert_eq!(error.to_string(), "mode failed");
    assert_eq!(runtime.thread().current_mode.as_deref(), Some("ask"));
    assert!(runtime.connection().set_modes().is_empty());
}

#[test]
fn failed_set_config_option_keeps_previous_value() {
    let mut thread = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));
    thread.acp_session_id = Some("session-1".to_string());
    thread.status = AgentThreadStatus::Ready;
    thread.config_options = vec![AgentConfigOption {
        id: "model".to_string(),
        label: "Model".to_string(),
        value: Some("old".to_string()),
        options: Vec::new(),
    }];
    let connection = FakeAcpConnection::new().with_set_config_option_error("config failed");
    let mut runtime = AgentRuntime::with_connection(thread, connection);

    let error = runtime.set_config_option("model", "new").unwrap_err();

    assert_eq!(error.to_string(), "config failed");
    assert_eq!(
        runtime.thread().config_options[0].value.as_deref(),
        Some("old")
    );
    assert!(runtime.connection().set_config_options().is_empty());
}

#[test]
fn failed_event_sets_failed_status() {
    let thread = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));
    let connection = FakeAcpConnection::new().with_new_session(
        "session-1",
        vec![AgentRuntimeEvent::Failed("provider crashed".to_string())],
    );
    let mut runtime = AgentRuntime::with_connection(thread, connection);

    runtime.create_session().unwrap();

    assert_eq!(
        runtime.thread().status,
        AgentThreadStatus::Failed {
            message: "provider crashed".to_string()
        }
    );
}

#[test]
fn auth_required_event_sets_status_and_debug_instructions() {
    let thread = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));
    let connection = FakeAcpConnection::new().with_new_session(
        "session-1",
        vec![AgentRuntimeEvent::AuthRequired {
            instructions: "Run auth login".to_string(),
        }],
    );
    let mut runtime = AgentRuntime::with_connection(thread, connection);

    runtime.create_session().unwrap();

    let thread = runtime.thread();
    assert_eq!(thread.status, AgentThreadStatus::AuthRequired);
    assert_eq!(thread.debug_log.len(), 1);
    assert_eq!(thread.debug_log[0].message, "Authentication required");
    assert_eq!(
        thread.transcript[0],
        AgentTranscriptEntry::agent("Run auth login")
    );
}

#[test]
fn tool_call_event_updates_existing_call_by_id() {
    let thread = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));
    let connection = FakeAcpConnection::new().with_new_session(
        "session-1",
        vec![
            AgentRuntimeEvent::ToolCall {
                id: "tool-1".to_string(),
                title: "Read file".to_string(),
                status: "running".to_string(),
            },
            AgentRuntimeEvent::ToolCall {
                id: "tool-1".to_string(),
                title: "Read src/main.rs".to_string(),
                status: "completed".to_string(),
            },
            AgentRuntimeEvent::Ready,
        ],
    );
    let mut runtime = AgentRuntime::with_connection(thread, connection);

    runtime.create_session().unwrap();

    let thread = runtime.thread();
    assert_eq!(thread.tool_calls.len(), 1);
    assert_eq!(thread.tool_calls[0].id, "tool-1");
    assert_eq!(thread.tool_calls[0].title, "Read src/main.rs");
    assert_eq!(thread.tool_calls[0].status, "completed");
}

#[test]
fn prompt_without_session_errors_and_does_not_set_running() {
    let thread = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));
    let connection = FakeAcpConnection::new();
    let mut runtime = AgentRuntime::with_connection(thread, connection);

    let error = runtime.prompt("hello").unwrap_err();

    assert!(error.to_string().contains("without an active ACP session"));
    assert_eq!(runtime.thread().status, AgentThreadStatus::Disconnected);
    assert!(runtime.thread().transcript.is_empty());
}

#[test]
fn prompt_read_only_errors_without_mutating_thread() {
    let mut thread = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));
    thread.acp_session_id = Some("session-1".to_string());
    thread.status = AgentThreadStatus::ReadOnly {
        reason: "session is unavailable".to_string(),
    };
    thread.draft = "hello".to_string();
    let connection = FakeAcpConnection::new().with_prompt_update(vec![AgentRuntimeEvent::Ready]);
    let mut runtime = AgentRuntime::with_connection(thread.clone(), connection);

    let error = runtime.prompt("hello").unwrap_err();

    assert!(error.to_string().contains("read-only"));
    assert_eq!(runtime.thread().status, thread.status);
    assert_eq!(runtime.thread().draft, "hello");
    assert!(runtime.thread().transcript.is_empty());
}

#[test]
fn prompt_connection_error_sets_failed_status() {
    let mut thread = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));
    thread.acp_session_id = Some("session-1".to_string());
    let connection = FakeAcpConnection::new().with_prompt_error("send failed");
    let mut runtime = AgentRuntime::with_connection(thread, connection);

    let error = runtime.prompt("hello").unwrap_err();

    assert_eq!(error.to_string(), "send failed");
    assert_eq!(
        runtime.thread().status,
        AgentThreadStatus::Failed {
            message: "send failed".to_string()
        }
    );
    assert_eq!(
        runtime.thread().transcript[0],
        AgentTranscriptEntry::user("hello")
    );
}

#[test]
fn prompt_with_needs_permission_produces_pending_permission() {
    let mut thread = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));
    thread.acp_session_id = Some("session-1".to_string());
    let connection = FakeAcpConnection::new().with_prompt_update(vec![
        AgentRuntimeEvent::NeedsPermission {
            id: "perm-1".to_string(),
            description: "Allow reading /repo/worktree/src/main.rs".to_string(),
        },
        AgentRuntimeEvent::Ready,
    ]);
    let mut runtime = AgentRuntime::with_connection(thread, connection);

    runtime.prompt("read the main file").unwrap();

    let thread = runtime.thread();
    assert_eq!(thread.status, AgentThreadStatus::Ready);
    assert_eq!(thread.pending_permissions.len(), 1);
    assert_eq!(thread.pending_permissions[0].id, "perm-1");
    assert_eq!(
        thread.transcript[0],
        AgentTranscriptEntry::user("read the main file")
    );
}

#[test]
fn successful_resume_with_update_marks_resumed_and_ready() {
    let thread = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));
    let connection =
        FakeAcpConnection::new().with_resume_update(vec![AgentRuntimeEvent::AgentMessageChunk(
            "restored transcript".to_string(),
        )]);
    let mut runtime = AgentRuntime::with_connection(thread, connection);

    runtime.resume_existing_session("session-1").unwrap();

    let thread = runtime.thread();
    assert_eq!(thread.acp_session_id.as_deref(), Some("session-1"));
    assert_eq!(thread.resume, AgentResumeState::Resumed);
    assert_eq!(thread.status, AgentThreadStatus::Ready);
    assert_eq!(
        thread.transcript,
        vec![AgentTranscriptEntry::agent("restored transcript")]
    );
}

#[test]
fn resume_error_marks_thread_read_only() {
    let thread = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));
    let connection = FakeAcpConnection::new().with_resume_error("session is unavailable");
    let mut runtime = AgentRuntime::with_connection(thread, connection);

    runtime.resume_existing_session("session-1").unwrap();

    assert_eq!(
        runtime.thread().acp_session_id.as_deref(),
        Some("session-1")
    );
    assert_eq!(
        runtime.thread().status,
        AgentThreadStatus::ReadOnly {
            reason: "session is unavailable".to_string()
        }
    );
}

#[test]
fn denied_filesystem_callback_records_debug_error() {
    let temp = tempfile::tempdir().unwrap();
    let thread = AgentThreadState::new("provider", temp.path().to_path_buf());
    let connection = FakeAcpConnection::new();
    let filesystem =
        FilesystemCallbackService::new(AgentTrustMode::Deny, temp.path().to_path_buf());
    let terminal = AgentTerminalService::new(AgentTrustMode::Deny, temp.path().to_path_buf());
    let mut runtime = AgentRuntime::with_connection(thread, connection)
        .with_callback_services(filesystem, terminal);

    let error = runtime
        .handle_read_text_file(&temp.path().join("file.txt"))
        .unwrap_err();

    assert!(error.to_string().contains("permission denied"));
    assert!(
        runtime
            .thread()
            .debug_log
            .iter()
            .any(|event| event.message.contains("read_text_file failed"))
    );
}

#[test]
fn terminal_callback_records_output_and_tool_entries() {
    let temp = tempfile::tempdir().unwrap();
    let thread = AgentThreadState::new("provider", temp.path().to_path_buf());
    let connection = FakeAcpConnection::new();
    let filesystem =
        FilesystemCallbackService::new(AgentTrustMode::AllowEverything, temp.path().to_path_buf());
    let terminal =
        AgentTerminalService::new(AgentTrustMode::AllowEverything, temp.path().to_path_buf());
    let mut runtime = AgentRuntime::with_connection(thread, connection)
        .with_callback_services(filesystem, terminal);

    let handle = runtime
        .handle_terminal_create("printf callback-output", temp.path())
        .unwrap();
    runtime.handle_terminal_wait_for_exit(handle).unwrap();
    let output = runtime.handle_terminal_output(handle).unwrap();

    assert_eq!(output, "callback-output");
    assert!(
        runtime
            .thread()
            .transcript
            .iter()
            .any(|entry| entry.role == AgentTranscriptRole::Tool
                && entry.text.contains("callback-output"))
    );
    assert!(
        runtime
            .thread()
            .tool_calls
            .iter()
            .any(|call| call.title == "terminal output")
    );
}

#[test]
fn ask_permission_creates_pending_request_and_resolves() {
    let temp = tempfile::tempdir().unwrap();
    let thread = AgentThreadState::new("provider", temp.path().to_path_buf());
    let connection = FakeAcpConnection::new();
    let filesystem = FilesystemCallbackService::new(AgentTrustMode::Ask, temp.path().to_path_buf());
    let terminal = AgentTerminalService::new(AgentTrustMode::Ask, temp.path().to_path_buf());
    let mut runtime = AgentRuntime::with_connection(thread, connection)
        .with_callback_services(filesystem, terminal);

    let error = runtime
        .handle_read_text_file(&temp.path().join("file.txt"))
        .unwrap_err();

    assert!(error.to_string().contains("permission request pending"));
    assert_eq!(runtime.thread().pending_permissions.len(), 1);
    let request_id = runtime.thread().pending_permissions[0].id.clone();

    assert!(
        runtime
            .resolve_permission_request(&request_id, true)
            .unwrap()
    );
    assert!(runtime.thread().pending_permissions.is_empty());
    assert!(
        runtime
            .thread()
            .debug_log
            .iter()
            .any(|event| event.message.contains("Permission allowed"))
    );
}

#[test]
fn redact_debug_value_redacts_sensitive_keys_case_insensitively() {
    assert_eq!(redact_debug_value("API_KEY", "abc123"), "[redacted]");
    assert_eq!(redact_debug_value("authToken", "abc123"), "[redacted]");
    assert_eq!(redact_debug_value("client_secret", "abc123"), "[redacted]");
    assert_eq!(redact_debug_value("password", "abc123"), "[redacted]");
    assert_eq!(redact_debug_value("PATH", "/usr/bin"), "/usr/bin");
    assert_eq!(redact_debug_value("HOME", "/home/alice"), "/home/alice");
}

#[test]
fn redact_debug_message_redacts_sensitive_key_value_patterns() {
    assert_eq!(
        redact_debug_message("provider failed: API_KEY=abc123 token: abc"),
        "provider failed: API_KEY=[redacted] token: [redacted]"
    );
    assert_eq!(
        redact_debug_message("provider warning without secrets"),
        "provider warning without secrets"
    );
}

#[test]
fn redact_debug_message_redacts_json_like_sensitive_values() {
    assert_eq!(
        redact_debug_message(r#"provider failed: {"api_key":"abc123"}"#),
        r#"provider failed: {"api_key":"[redacted]"}"#
    );
    assert_eq!(
        redact_debug_message(r#"provider failed: {"token": "abc"}"#),
        r#"provider failed: {"token": "[redacted]"}"#
    );
    assert_eq!(
        redact_debug_message("provider failed: {'password': 'pw'}"),
        "provider failed: {'password': '[redacted]'}"
    );
    assert_eq!(
        redact_debug_message(r#"provider failed: {"token":"abc\"def"}"#),
        r#"provider failed: {"token":"[redacted]"}"#
    );
    assert!(!redact_debug_message(r#"{"client_secret":"shh"}"#).contains("shh"));
}

#[test]
fn agent_update_error_redacts_debug_message_secrets() {
    let mut thread = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));

    apply_agent_update(
        &mut thread,
        alas::agent::AgentUpdate::Error("provider failed: API_KEY=abc123".to_string()),
    );
    apply_agent_update(
        &mut thread,
        alas::agent::AgentUpdate::Error("provider warning".to_string()),
    );

    assert_eq!(
        thread.debug_log[0].message,
        "provider failed: API_KEY=[redacted]"
    );
    assert!(!thread.debug_log[0].message.contains("abc123"));
    assert_eq!(thread.debug_log[1].message, "provider warning");
}

#[test]
fn push_debug_event_bounds_log_to_latest_500_entries() {
    let mut thread = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));

    for index in 0..505 {
        thread.push_debug_event(AgentDebugEvent {
            message: format!("event-{index}"),
        });
    }

    assert_eq!(thread.debug_log.len(), 500);
    assert_eq!(thread.debug_log.first().unwrap().message, "event-5");
    assert_eq!(thread.debug_log.last().unwrap().message, "event-504");
}
