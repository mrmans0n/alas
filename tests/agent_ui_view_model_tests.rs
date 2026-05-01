use alas::{
    agent::{
        AgentAuthField, AgentAuthMethod, AgentAuthStatus, AgentConfigOption,
        AgentConfigValueOption, AgentModeOption, AgentProviderConfig, AgentProviderEnvVar,
        AgentProviderSuggestion, AgentSlashCommand, AgentThreadState, AgentThreadStatus,
        AgentTrustMode, CredentialStore, CredentialStoreKey, MemoryCredentialStore,
        ProviderSettingsState,
    },
    ui::{
        agent_pane::{agent_composer_view_model, agent_header_view_model, agent_status_label},
        provider_settings::auth_env_field_render_value,
    },
};

use std::path::PathBuf;

fn provider(id: &str) -> AgentProviderConfig {
    AgentProviderConfig::new(id, id.to_uppercase(), format!("{id}-acp"))
}

#[test]
fn agent_status_label_formats_read_only_reason() {
    let mut thread = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));
    thread.status = AgentThreadStatus::ReadOnly {
        reason: "worktree is locked".to_string(),
    };

    assert_eq!(agent_status_label(&thread), "Read-only: worktree is locked");
}

#[test]
fn agent_composer_state_maps_status_to_action_availability() {
    let mut thread = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));

    thread.status = AgentThreadStatus::Ready;
    let ready_empty = agent_composer_view_model(&thread);
    assert!(ready_empty.enabled);
    assert!(!ready_empty.action_enabled);
    assert_eq!(ready_empty.action_label, "Send");
    assert!(ready_empty.showing_placeholder);
    assert_eq!(ready_empty.display_text, "Type a prompt for the agent…");

    thread.draft = "Summarize changes".to_string();
    let ready = agent_composer_view_model(&thread);
    assert!(ready.enabled);
    assert!(ready.action_enabled);
    assert_eq!(ready.action_label, "Send");
    assert!(!ready.showing_placeholder);
    assert_eq!(ready.display_text, "Summarize changes");

    thread.status = AgentThreadStatus::Running;
    let running = agent_composer_view_model(&thread);
    assert!(!running.enabled);
    assert!(running.action_enabled);
    assert_eq!(running.action_label, "Cancel");

    thread.status = AgentThreadStatus::ReadOnly {
        reason: "locked".to_string(),
    };
    let read_only = agent_composer_view_model(&thread);
    assert!(!read_only.enabled);
    assert!(!read_only.action_enabled);
    assert_eq!(read_only.action_label, "Send");

    thread.status = AgentThreadStatus::AuthRequired;
    let auth_required = agent_composer_view_model(&thread);
    assert!(!auth_required.enabled);
    assert!(auth_required.auth_action);
}

#[test]
fn agent_header_shows_interactive_mode_and_resolved_config_labels() {
    let mut thread = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));
    thread.available_modes = vec![
        AgentModeOption {
            id: "plan".to_string(),
            name: "Plan".to_string(),
        },
        AgentModeOption {
            id: "ask".to_string(),
            name: "Ask".to_string(),
        },
    ];
    thread.current_mode = Some("plan".to_string());
    thread.config_options = vec![AgentConfigOption {
        id: "model".to_string(),
        label: "Model".to_string(),
        value: Some("gpt-5".to_string()),
        options: vec![
            AgentConfigValueOption {
                id: "gpt-5".to_string(),
                label: "GPT-5".to_string(),
            },
            AgentConfigValueOption {
                id: "sonnet".to_string(),
                label: "Claude Sonnet".to_string(),
            },
        ],
    }];

    let header = agent_header_view_model(&thread);
    assert_eq!(header.mode_label.as_deref(), Some("Mode: Plan ▾"));
    assert!(header.mode_interactive);
    assert_eq!(header.config_labels[0].label, "Model: GPT-5 ▾");
    assert!(header.config_labels[0].interactive);
}

#[test]
fn agent_header_and_composer_expose_runtime_advertisements() {
    let mut thread = AgentThreadState::new("opencode", PathBuf::from("/repo/worktree"));
    thread.available_modes = vec![AgentModeOption {
        id: "plan".to_string(),
        name: "Plan".to_string(),
    }];
    thread.current_mode = Some("plan".to_string());
    thread.config_options = vec![AgentConfigOption {
        id: "model".to_string(),
        label: "Model".to_string(),
        value: Some("gpt-5".to_string()),
        options: Vec::new(),
    }];
    thread.available_commands = vec![AgentSlashCommand {
        name: "help".to_string(),
        description: Some("Show help".to_string()),
    }];

    let header = agent_header_view_model(&thread);
    assert_eq!(header.provider_label, "Provider: opencode");
    assert_eq!(header.mode_label.as_deref(), Some("Mode: Plan"));
    assert_eq!(header.config_labels[0].label, "Model: gpt-5");
    assert!(!header.config_labels[0].interactive);

    let composer = agent_composer_view_model(&thread);
    assert_eq!(composer.slash_commands, vec!["/help"]);
}

#[test]
fn provider_settings_state_adds_updates_and_removes_provider() {
    let mut state = ProviderSettingsState::default();

    state.add_provider(AgentProviderConfig::new("codex", "Codex", "codex-acp"));

    assert_eq!(state.providers.len(), 1);
    assert_eq!(state.providers[0].display_name, "Codex");
    assert_eq!(state.providers[0].command, "codex-acp");
    assert_eq!(state.selected_provider_id.as_deref(), Some("codex"));
    assert_eq!(state.error, None);

    state.add_provider(AgentProviderConfig::new(
        "codex",
        "Codex Updated",
        "codex-acp-next",
    ));

    assert_eq!(state.providers.len(), 1);
    assert_eq!(state.providers[0].display_name, "Codex Updated");
    assert_eq!(state.providers[0].command, "codex-acp-next");
    assert_eq!(state.selected_provider_id.as_deref(), Some("codex"));

    state.remove_provider("codex");

    assert!(state.providers.is_empty());
    assert_eq!(state.selected_provider_id, None);
    assert_eq!(state.error, None);
}

#[test]
fn provider_settings_state_removing_selected_provider_selects_first_remaining_provider() {
    let mut state = ProviderSettingsState::default();
    state.add_provider(provider("codex"));
    state.add_provider(provider("claude"));
    state.add_provider(provider("gemini"));
    state.selected_provider_id = Some("claude".to_string());

    state.remove_provider("claude");

    assert_eq!(
        state
            .providers
            .iter()
            .map(|provider| provider.id.as_str())
            .collect::<Vec<_>>(),
        vec!["codex", "gemini"]
    );
    assert_eq!(state.selected_provider_id.as_deref(), Some("codex"));
    assert_eq!(state.error, None);
}

#[test]
fn provider_settings_tracks_discovery_suggestions() {
    let mut state = ProviderSettingsState::default();
    state.discovery_suggestions.push(AgentProviderSuggestion {
        id: "claude".to_string(),
        display_name: "Claude Code".to_string(),
        command: "claude".to_string(),
        message: "Claude Code found, but ACP command is not verified yet.".to_string(),
    });
    assert_eq!(state.discovery_suggestions[0].id, "claude");
}

#[test]
fn provider_settings_error_can_report_discovery_save_failure() {
    let state = ProviderSettingsState {
        error: Some("failed to persist auto-discovered providers".to_string()),
        ..ProviderSettingsState::default()
    };
    assert!(state.error.as_deref().unwrap().contains("auto-discovered"));
}

#[test]
fn provider_settings_state_removing_non_selected_provider_preserves_selection() {
    let mut state = ProviderSettingsState::default();
    state.add_provider(provider("codex"));
    state.add_provider(provider("claude"));
    state.add_provider(provider("gemini"));
    state.selected_provider_id = Some("gemini".to_string());

    state.remove_provider("claude");

    assert_eq!(
        state
            .providers
            .iter()
            .map(|provider| provider.id.as_str())
            .collect::<Vec<_>>(),
        vec!["codex", "gemini"]
    );
    assert_eq!(state.selected_provider_id.as_deref(), Some("gemini"));
    assert_eq!(state.error, None);
}

#[test]
fn provider_settings_state_updates_provider_fields_and_auth_status() {
    let mut state = ProviderSettingsState::default();
    state.add_provider(provider("codex"));

    state.update_display_name("codex", "Codex Next");
    state.update_command("codex", "codex next");
    state.update_args("codex", vec!["acp".to_string(), "--json".to_string()]);
    state.update_plain_env(
        "codex",
        vec![("CODEX_HOME".to_string(), "/tmp/codex".to_string())],
    );
    state.update_enabled("codex", false);
    state.update_trust_mode("codex", AgentTrustMode::WorktreeOnly);
    state.update_auth_status(
        "codex",
        AgentAuthStatus::Required {
            instructions: "Run codex login".to_string(),
        },
    );

    let codex = &state.providers[0];
    assert_eq!(codex.display_name, "Codex Next");
    assert_eq!(codex.command, "codex next");
    assert_eq!(codex.args, vec!["acp", "--json"]);
    assert_eq!(
        state.args_json("codex").as_deref(),
        Some("[\"acp\",\"--json\"]")
    );
    assert_eq!(codex.env[0].name, "CODEX_HOME");
    assert_eq!(codex.env[0].value.as_deref(), Some("/tmp/codex"));
    assert_eq!(codex.env[0].secure_ref, None);
    assert!(!codex.enabled);
    assert_eq!(codex.trust_mode, AgentTrustMode::WorktreeOnly);
    assert_eq!(state.auth_status_label("codex"), "Authentication required");
    assert_eq!(
        state.auth_statuses["codex"].instructions(),
        Some("Run codex login")
    );

    state.update_auth_status("codex", AgentAuthStatus::Authenticated);
    assert_eq!(state.auth_status_label("codex"), "Authenticated");

    state.update_auth_status(
        "codex",
        AgentAuthStatus::Failed {
            message: "expired".to_string(),
            instructions: "Run codex login again".to_string(),
        },
    );
    assert_eq!(state.auth_status_label("codex"), "Authentication failed");
    assert_eq!(state.auth_status_label("missing"), "Authentication unknown");
}

#[test]
fn provider_settings_state_edits_args_as_json_array() {
    let mut state = ProviderSettingsState::default();
    state.add_provider(provider("codex"));

    state
        .edit_args_json("codex", |value| {
            *value = serde_json::to_string(&vec![
                "acp".to_string(),
                "--prompt".to_string(),
                "hello world".to_string(),
                "".to_string(),
                "quoted \"value\"".to_string(),
            ])
            .unwrap();
        })
        .unwrap();

    assert_eq!(
        state.providers[0].args,
        vec!["acp", "--prompt", "hello world", "", "quoted \"value\""]
    );
    assert_eq!(state.error, None);
}

#[test]
fn provider_settings_state_rejects_invalid_args_json_without_corrupting_args() {
    let mut state = ProviderSettingsState::default();
    let mut codex = provider("codex");
    codex.args = vec!["hello world".to_string(), "".to_string()];
    state.add_provider(codex);

    let result = state.edit_args_json("codex", |value| {
        value.clear();
        value.push_str("hello world");
    });

    assert!(result.is_err());
    assert_eq!(state.providers[0].args, vec!["hello world", ""]);
    assert!(
        state
            .error
            .as_deref()
            .is_some_and(|error| error.starts_with("Args must be a JSON array of strings:"))
    );
}

#[test]
fn provider_settings_state_updates_plain_env_without_dropping_secure_refs() {
    let mut state = ProviderSettingsState::default();
    let mut provider = provider("codex");
    provider.env = vec![
        AgentProviderEnvVar {
            name: "CODEX_HOME".to_string(),
            value: Some("/old".to_string()),
            secure_ref: None,
        },
        AgentProviderEnvVar {
            name: "CODEX_TOKEN".to_string(),
            value: None,
            secure_ref: Some("codex-token".to_string()),
        },
    ];
    state.add_provider(provider);

    state.update_plain_env(
        "codex",
        vec![("CODEX_HOME".to_string(), "/new".to_string())],
    );

    let env = &state.providers[0].env;
    assert_eq!(env.len(), 2);
    assert_eq!(env[0].name, "CODEX_HOME");
    assert_eq!(env[0].value.as_deref(), Some("/new"));
    assert_eq!(env[0].secure_ref, None);
    assert_eq!(env[1].name, "CODEX_TOKEN");
    assert_eq!(env[1].value, None);
    assert_eq!(env[1].secure_ref.as_deref(), Some("codex-token"));
}

#[test]
fn provider_settings_state_removing_nonexistent_provider_leaves_state_unchanged() {
    let mut state = ProviderSettingsState::default();
    state.add_provider(provider("codex"));
    state.add_provider(provider("claude"));
    state.selected_provider_id = Some("claude".to_string());
    state.error = Some("provider missing".to_string());
    let original_state = state.clone();

    state.remove_provider("gemini");

    assert_eq!(state, original_state);
}

#[test]
fn provider_settings_env_auth_entry_saves_to_credential_store() {
    let store = MemoryCredentialStore::default();
    let mut provider = provider("opencode");
    provider.auth_methods = vec![AgentAuthMethod::EnvVar {
        fields: vec![AgentAuthField::secret("API key", "OPENCODE_API_KEY")],
        link: Some("https://example.test/key".to_string()),
    }];
    let mut state = ProviderSettingsState::default();
    state.add_provider(provider);

    state.update_auth_env_value("opencode", "OPENCODE_API_KEY", "super-secret");
    state
        .authenticate_with_available_method("opencode", &store)
        .expect("authenticate");

    assert_eq!(
        store
            .read_secret(&CredentialStoreKey::new("opencode", "OPENCODE_API_KEY"))
            .expect("read secret"),
        Some("super-secret".to_string())
    );
    assert_eq!(state.auth_status_label("opencode"), "Authenticated");
    assert_eq!(
        state.providers[0].env[0].secure_ref.as_deref(),
        Some("opencode/OPENCODE_API_KEY")
    );
    assert!(
        !serde_json::to_string(&state.providers[0])
            .expect("serialize provider")
            .contains("super-secret")
    );
}

#[test]
fn provider_settings_missing_required_env_auth_value_fails() {
    let store = MemoryCredentialStore::default();
    let mut provider = provider("opencode");
    provider.auth_methods = vec![AgentAuthMethod::EnvVar {
        fields: vec![AgentAuthField::secret("API key", "OPENCODE_API_KEY")],
        link: None,
    }];
    let mut state = ProviderSettingsState::default();
    state.add_provider(provider);

    let error = state
        .authenticate_with_available_method("opencode", &store)
        .unwrap_err();

    assert!(error.to_string().contains("OPENCODE_API_KEY"));
    assert_eq!(state.auth_status_label("opencode"), "Authentication failed");
    assert_eq!(
        store
            .read_secret(&CredentialStoreKey::new("opencode", "OPENCODE_API_KEY"))
            .expect("read secret"),
        None
    );
}

#[test]
fn provider_settings_secret_auth_env_display_is_masked() {
    let mut state = ProviderSettingsState::default();
    let field = AgentAuthField::secret("API key", "OPENCODE_API_KEY");
    state.update_auth_env_value("opencode", "OPENCODE_API_KEY", "super-secret");

    assert_eq!(state.auth_env_display_value("opencode", &field), "••••••••");
    assert_eq!(
        auth_env_field_render_value(&state, "opencode", &field, false),
        "••••••••"
    );
    assert_eq!(
        auth_env_field_render_value(&state, "opencode", &field, true),
        "••••••••"
    );
    assert!(
        !auth_env_field_render_value(&state, "opencode", &field, true).contains("super-secret")
    );
    assert_eq!(
        state.auth_env_value("opencode", "OPENCODE_API_KEY"),
        "super-secret"
    );
}

#[test]
fn provider_settings_clear_credentials_removes_env_auth_secrets() {
    let store = MemoryCredentialStore::default();
    store
        .write_secret(
            &CredentialStoreKey::new("opencode", "OPENCODE_API_KEY"),
            "super-secret",
        )
        .expect("seed secret");
    let mut provider = provider("opencode");
    provider.env = vec![
        AgentProviderEnvVar {
            name: "PLAIN".to_string(),
            value: Some("value".to_string()),
            secure_ref: None,
        },
        AgentProviderEnvVar::secure_ref("OPENCODE_API_KEY", "opencode/OPENCODE_API_KEY"),
    ];
    provider.auth_methods = vec![AgentAuthMethod::EnvVar {
        fields: vec![AgentAuthField::secret("API key", "OPENCODE_API_KEY")],
        link: None,
    }];
    let mut state = ProviderSettingsState::default();
    state.add_provider(provider);
    state.update_auth_env_value("opencode", "OPENCODE_API_KEY", "pending");

    state
        .clear_env_auth_values("opencode", &store)
        .expect("clear credentials");

    assert_eq!(
        store
            .read_secret(&CredentialStoreKey::new("opencode", "OPENCODE_API_KEY"))
            .expect("read secret"),
        None
    );
    assert_eq!(state.auth_env_value("opencode", "OPENCODE_API_KEY"), "");
    assert_eq!(state.providers[0].env.len(), 1);
    assert_eq!(state.providers[0].env[0].name, "PLAIN");
    assert!(
        state.providers[0]
            .env
            .iter()
            .all(|entry| entry.secure_ref.as_deref() != Some("opencode/OPENCODE_API_KEY"))
    );
    assert_eq!(
        state.auth_status_label("opencode"),
        "Authentication required"
    );
}

#[test]
fn provider_settings_auth_io_result_merges_only_auth_fields() {
    let mut provider = provider("opencode");
    provider.env = vec![AgentProviderEnvVar {
        name: "PLAIN".to_string(),
        value: Some("old".to_string()),
        secure_ref: None,
    }];
    provider.auth_methods = vec![AgentAuthMethod::EnvVar {
        fields: vec![AgentAuthField::secret("API key", "OPENCODE_API_KEY")],
        link: None,
    }];
    let mut current = ProviderSettingsState::default();
    current.add_provider(provider.clone());
    current.selected_provider_id = Some("other".to_string());
    current.discovery_suggestions = vec![AgentProviderSuggestion {
        id: "suggestion".to_string(),
        display_name: "Suggestion".to_string(),
        command: "suggestion".to_string(),
        message: "test".to_string(),
    }];
    current.update_auth_env_value("opencode", "OPENCODE_API_KEY", "new-draft");

    let mut result = ProviderSettingsState::default();
    provider.env.push(AgentProviderEnvVar::secure_ref(
        "OPENCODE_API_KEY",
        "opencode/OPENCODE_API_KEY",
    ));
    result.add_provider(provider);
    result.update_auth_status("opencode", AgentAuthStatus::Authenticated);

    current.apply_auth_io_result("opencode", &result);

    assert_eq!(current.selected_provider_id.as_deref(), Some("other"));
    assert_eq!(current.discovery_suggestions.len(), 1);
    assert_eq!(
        current.auth_env_value("opencode", "OPENCODE_API_KEY"),
        "new-draft"
    );
    assert_eq!(current.providers[0].env.len(), 2);
    assert!(
        current.providers[0]
            .env
            .iter()
            .any(|entry| entry.name == "PLAIN")
    );
    assert!(
        current.providers[0]
            .env
            .iter()
            .any(|entry| entry.secure_ref.as_deref() == Some("opencode/OPENCODE_API_KEY"))
    );
    assert_eq!(current.auth_status_label("opencode"), "Authenticated");
}

#[test]
fn provider_settings_clear_auth_io_result_preserves_unrelated_state() {
    let mut provider = provider("opencode");
    provider.env = vec![
        AgentProviderEnvVar {
            name: "PLAIN".to_string(),
            value: Some("value".to_string()),
            secure_ref: None,
        },
        AgentProviderEnvVar::secure_ref("OPENCODE_API_KEY", "opencode/OPENCODE_API_KEY"),
    ];
    provider.auth_methods = vec![AgentAuthMethod::EnvVar {
        fields: vec![AgentAuthField::secret("API key", "OPENCODE_API_KEY")],
        link: None,
    }];
    let mut current = ProviderSettingsState::default();
    current.add_provider(provider.clone());
    current.update_auth_env_value("opencode", "OPENCODE_API_KEY", "draft");
    current.update_auth_env_value("other", "OPENCODE_API_KEY", "other-draft");

    let store = MemoryCredentialStore::default();
    let mut result = ProviderSettingsState::default();
    result.add_provider(provider);
    result
        .clear_env_auth_values("opencode", &store)
        .expect("clear credentials");

    current.apply_clear_auth_io_result("opencode", &result);

    assert_eq!(current.auth_env_value("opencode", "OPENCODE_API_KEY"), "");
    assert_eq!(
        current.auth_env_value("other", "OPENCODE_API_KEY"),
        "other-draft"
    );
    assert_eq!(current.providers[0].env.len(), 1);
    assert_eq!(current.providers[0].env[0].name, "PLAIN");
    assert_eq!(
        current.auth_status_label("opencode"),
        "Authentication required"
    );
}

#[test]
fn provider_settings_auth_instructions_surface_advertised_text() {
    let mut provider = provider("codex");
    provider.auth_methods = vec![AgentAuthMethod::Agent {
        instructions: "Run codex login".to_string(),
    }];
    let mut state = ProviderSettingsState::default();
    state.add_provider(provider);

    state.show_auth_instructions("codex");

    assert_eq!(
        state.auth_statuses["codex"].instructions(),
        Some("Run codex login")
    );
}

#[test]
fn provider_settings_terminal_auth_command_uses_only_advertised_args_and_env() {
    let mut provider = provider("codex");
    provider.args = vec!["acp".to_string()];
    provider.auth_methods = vec![AgentAuthMethod::Terminal {
        args: vec!["login".to_string(), "--device".to_string()],
        env: vec![AgentProviderEnvVar {
            name: "CODEX_HOME".to_string(),
            value: Some("/tmp/codex".to_string()),
            secure_ref: None,
        }],
    }];
    let mut state = ProviderSettingsState::default();
    state.add_provider(provider);

    let (command, args, env) = state
        .terminal_auth_command("codex")
        .expect("terminal auth command");
    assert_eq!(command, "codex-acp");
    assert_eq!(args, vec!["acp", "login", "--device"]);
    assert_eq!(env.len(), 1);
    assert_eq!(env[0].name, "CODEX_HOME");

    state.mark_terminal_auth_unavailable("codex");
    assert_eq!(state.auth_status_label("codex"), "Authentication failed");
    assert!(
        state.auth_statuses["codex"]
            .instructions()
            .expect("instructions")
            .contains("codex-acp acp login --device")
    );
}
