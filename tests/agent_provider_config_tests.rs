use alas::agent::{
    AgentAuthField, AgentAuthMethod, AgentProviderConfig, AgentProviderEnvVar, AgentTrustMode,
    CredentialStore, CredentialStoreKey, MemoryCredentialStore, ProviderCwdPolicy,
    resolve_secure_env_values,
};
use alas::config::AppConfig;

#[test]
fn app_config_serializes_global_agent_providers_without_secret_values() {
    let mut config = AppConfig::default();
    config.agent_providers.push(AgentProviderConfig {
        id: "opencode".to_string(),
        display_name: "OpenCode".to_string(),
        command: "opencode".to_string(),
        args: vec!["acp".to_string()],
        env: vec![AgentProviderEnvVar::secure_ref(
            "OPENCODE_API_KEY",
            "opencode/api-key",
        )],
        auth_methods: Vec::new(),
        cwd_policy: ProviderCwdPolicy::SelectedWorktree,
        trust_mode: AgentTrustMode::AllowEverything,
        enabled: true,
    });

    let toml = toml::to_string(&config).expect("serialize config");
    assert!(toml.contains("agent_providers"));
    assert!(toml.contains("opencode/api-key"));
    assert!(!toml.contains("value ="));

    let loaded: AppConfig = toml::from_str(&toml).expect("deserialize config");
    assert_eq!(
        loaded.agent_providers[0].trust_mode,
        AgentTrustMode::AllowEverything
    );
}

#[test]
fn provider_defaults_to_allow_everything_and_selected_worktree() {
    let provider = AgentProviderConfig::new("codex", "Codex", "codex-acp");
    assert_eq!(provider.trust_mode, AgentTrustMode::AllowEverything);
    assert_eq!(provider.cwd_policy, ProviderCwdPolicy::SelectedWorktree);
    assert!(provider.enabled);
}

#[test]
fn env_var_auth_method_builds_secure_env_refs() {
    let method = AgentAuthMethod::EnvVar {
        fields: vec![AgentAuthField::secret("API token", "OPENCODE_API_KEY")],
        link: Some("https://example.test/token".to_string()),
    };

    assert_eq!(
        method.secure_env_refs("opencode"),
        vec![AgentProviderEnvVar::secure_ref(
            "OPENCODE_API_KEY",
            "opencode/OPENCODE_API_KEY"
        )]
    );
    assert_eq!(method.instructions(), Some("https://example.test/token"));
}

#[test]
fn terminal_auth_method_preserves_setup_args_and_env() {
    let env = vec![AgentProviderEnvVar {
        name: "AUTH_MODE".to_string(),
        value: Some("browser".to_string()),
        secure_ref: None,
    }];
    let method = AgentAuthMethod::Terminal {
        args: vec!["auth".to_string(), "login".to_string()],
        env: env.clone(),
    };

    let (args, method_env) = method.terminal_args_env().expect("terminal auth");
    assert_eq!(args, &["auth".to_string(), "login".to_string()]);
    assert_eq!(method_env, env.as_slice());
}

#[test]
fn secure_env_values_resolve_from_credential_store_without_serializing_secret() {
    let store = MemoryCredentialStore::default();
    store
        .write_secret(
            &CredentialStoreKey::new("opencode", "OPENCODE_API_KEY"),
            "super-secret",
        )
        .unwrap();
    let env = vec![AgentProviderEnvVar::secure_ref(
        "OPENCODE_API_KEY",
        "opencode/OPENCODE_API_KEY",
    )];

    assert_eq!(
        resolve_secure_env_values("opencode", &env, &store).unwrap(),
        vec![("OPENCODE_API_KEY".to_string(), "super-secret".to_string())]
    );
    assert!(
        !serde_json::to_string(&env)
            .unwrap()
            .contains("super-secret")
    );
}

#[test]
fn memory_credential_store_round_trips_secret_by_provider_and_field() {
    let store = MemoryCredentialStore::default();
    let key = CredentialStoreKey::new("opencode", "OPENCODE_API_KEY");

    store
        .write_secret(&key, "super-secret")
        .expect("write secret");
    assert_eq!(
        store.read_secret(&key).expect("read secret"),
        Some("super-secret".to_string())
    );
    store.delete_secret(&key).expect("delete secret");
    assert_eq!(store.read_secret(&key).expect("read after delete"), None);
}
