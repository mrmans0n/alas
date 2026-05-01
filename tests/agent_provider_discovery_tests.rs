use std::{cell::Cell, fs, path::Path};

use alas::{
    agent::{
        AgentProviderConfig, AgentProviderSuggestion, ProviderDiscoveryResult,
        ProviderSettingsState, apply_provider_discovery_to_config,
        discover_agent_providers_from_path, filtered_provider_suggestions,
        ignore_discovered_provider_id, is_known_discoverable_provider_id,
        merge_discovered_agent_providers, remove_provider_and_record_discovery_ignore,
    },
    config::{AppConfig, AppConfigStore},
};
use tempfile::TempDir;

#[test]
fn opencode_on_path_is_verified_provider() {
    let dir = TempDir::new().expect("temp dir");
    create_fake_executable(dir.path(), "opencode");

    let discovery = discover_agent_providers_from_path(Some(&path_env(&[dir.path()])));

    assert_eq!(discovery.verified_providers.len(), 1);
    let provider = &discovery.verified_providers[0];
    assert_eq!(provider.id, "opencode");
    assert_eq!(provider.display_name, "OpenCode");
    assert_eq!(provider.command, "opencode");
    assert_eq!(provider.args, vec!["acp"]);
    assert!(provider.enabled);
    assert!(discovery.suggestions.is_empty());
}

#[test]
fn claude_and_codex_on_path_are_verified_with_npx_adapters() {
    let dir = TempDir::new().expect("temp dir");
    create_fake_executable(dir.path(), "claude");
    create_fake_executable(dir.path(), "codex");
    create_fake_executable(dir.path(), "npx");

    let discovery = discover_agent_providers_from_path(Some(&path_env(&[dir.path()])));

    assert!(discovery.suggestions.is_empty());
    assert_eq!(
        discovery
            .verified_providers
            .iter()
            .map(|provider| provider.id.as_str())
            .collect::<Vec<_>>(),
        vec!["claude", "codex"]
    );

    let claude = &discovery.verified_providers[0];
    assert_eq!(claude.display_name, "Claude Code");
    assert_eq!(claude.command, "npx");
    assert_eq!(
        claude.args,
        vec!["-y", "@agentclientprotocol/claude-agent-acp"]
    );

    let codex = &discovery.verified_providers[1];
    assert_eq!(codex.display_name, "Codex");
    assert_eq!(codex.command, "npx");
    assert_eq!(codex.args, vec!["-y", "@zed-industries/codex-acp"]);
}

#[test]
fn missing_or_empty_path_does_not_error() {
    let missing = discover_agent_providers_from_path(None);
    assert!(missing.verified_providers.is_empty());
    assert!(missing.suggestions.is_empty());

    let empty = discover_agent_providers_from_path(Some(""));
    assert!(empty.verified_providers.is_empty());
    assert!(empty.suggestions.is_empty());
}

#[test]
fn ignores_empty_relative_and_non_executable_path_entries() {
    let dir = TempDir::new().expect("temp dir");
    create_fake_file(dir.path(), "opencode");

    let path = format!(
        "{}relative{}{}",
        path_list_separator(),
        path_list_separator(),
        path_env(&[dir.path()])
    );

    let discovery = discover_agent_providers_from_path(Some(&path));

    assert!(discovery.verified_providers.is_empty());
    assert!(discovery.suggestions.is_empty());
}

#[test]
fn duplicate_path_matches_are_deduped() {
    let first = TempDir::new().expect("temp dir");
    let second = TempDir::new().expect("temp dir");
    create_fake_executable(first.path(), "opencode");
    create_fake_executable(second.path(), "opencode");

    let discovery =
        discover_agent_providers_from_path(Some(&path_env(&[first.path(), second.path()])));

    assert_eq!(discovery.verified_providers.len(), 1);
    assert_eq!(discovery.verified_providers[0].id, "opencode");
}

#[test]
fn claude_without_npx_is_suggestion_only() {
    let dir = TempDir::new().expect("temp dir");
    create_fake_executable(dir.path(), "claude");

    let discovery = discover_agent_providers_from_path(Some(&path_env(&[dir.path()])));

    assert!(discovery.verified_providers.is_empty());
    assert_eq!(discovery.suggestions.len(), 1);
    assert_eq!(discovery.suggestions[0].id, "claude");
    assert!(discovery.suggestions[0].message.contains("npx"));
    assert!(discovery.suggestions[0].message.contains("ACP adapter"));
}

#[test]
fn known_discoverable_provider_ids_are_reported() {
    assert!(is_known_discoverable_provider_id("opencode"));
    assert!(is_known_discoverable_provider_id("claude"));
    assert!(is_known_discoverable_provider_id("codex"));
    assert!(!is_known_discoverable_provider_id("unknown"));
}

#[test]
fn merge_appends_missing_verified_provider_and_reports_changed() {
    let mut config = AppConfig::default();
    let discovery = ProviderDiscoveryResult {
        verified_providers: vec![opencode_provider()],
        suggestions: Vec::new(),
    };

    let changed = merge_discovered_agent_providers(&mut config, &discovery);

    assert!(changed);
    assert_eq!(config.agent_providers.len(), 1);
    assert_eq!(config.agent_providers[0].id, "opencode");
}

#[test]
fn merge_preserves_existing_provider_without_overwrite_or_reenable() {
    let mut existing = AgentProviderConfig::new("opencode", "Custom OpenCode", "custom-opencode");
    existing.args = vec!["custom-acp".to_string()];
    existing.enabled = false;
    let original = existing.clone();
    let mut config = AppConfig {
        agent_providers: vec![existing],
        ..AppConfig::default()
    };
    let discovery = ProviderDiscoveryResult {
        verified_providers: vec![opencode_provider()],
        suggestions: Vec::new(),
    };

    let changed = merge_discovered_agent_providers(&mut config, &discovery);

    assert!(!changed);
    assert_eq!(config.agent_providers, vec![original]);
    assert!(!config.agent_providers[0].enabled);
}

#[test]
fn merge_skips_ignored_provider_id() {
    let mut config = AppConfig::default();
    config
        .agent_provider_discovery
        .ignored_provider_ids
        .push("opencode".to_string());
    let discovery = ProviderDiscoveryResult {
        verified_providers: vec![opencode_provider()],
        suggestions: Vec::new(),
    };

    let changed = merge_discovered_agent_providers(&mut config, &discovery);

    assert!(!changed);
    assert!(config.agent_providers.is_empty());
}

#[test]
fn suggestions_are_filtered_for_configured_and_ignored_ids() {
    let mut config = AppConfig {
        agent_providers: vec![AgentProviderConfig::new("claude", "Claude Code", "claude")],
        ..AppConfig::default()
    };
    config
        .agent_provider_discovery
        .ignored_provider_ids
        .push("codex".to_string());
    let discovery = ProviderDiscoveryResult {
        verified_providers: Vec::new(),
        suggestions: vec![suggestion("claude"), suggestion("codex")],
    };

    let filtered = filtered_provider_suggestions(&config, &discovery);

    assert!(filtered.is_empty());
}

#[test]
fn record_ignored_known_provider_id_dedupes() {
    let mut config = AppConfig::default();

    assert!(ignore_discovered_provider_id(&mut config, "opencode"));
    assert!(!ignore_discovered_provider_id(&mut config, "opencode"));
    assert!(!ignore_discovered_provider_id(&mut config, "unknown"));

    assert_eq!(
        config.agent_provider_discovery.ignored_provider_ids,
        vec!["opencode"]
    );
}

#[test]
fn removing_known_discovered_provider_records_ignored_id() {
    let mut config = AppConfig::default();
    let mut settings = ProviderSettingsState::default();
    settings.add_provider(AgentProviderConfig::new("opencode", "OpenCode", "opencode"));

    let changed =
        remove_provider_and_record_discovery_ignore(&mut config, &mut settings, "opencode");

    assert!(changed);
    assert!(settings.providers.is_empty());
    assert_eq!(
        config.agent_provider_discovery.ignored_provider_ids,
        vec!["opencode"]
    );
}

#[test]
fn removing_unknown_provider_does_not_record_ignored_id() {
    let mut config = AppConfig::default();
    let mut settings = ProviderSettingsState::default();
    settings.add_provider(AgentProviderConfig::new("custom", "Custom", "custom"));

    let changed = remove_provider_and_record_discovery_ignore(&mut config, &mut settings, "custom");

    assert!(changed);
    assert!(settings.providers.is_empty());
    assert!(
        config
            .agent_provider_discovery
            .ignored_provider_ids
            .is_empty()
    );
}

#[test]
fn saving_after_removal_persists_ignored_provider_ids() {
    let dir = TempDir::new().expect("temp dir");
    let store = AppConfigStore::new(dir.path().join("config.toml"));
    let mut config = AppConfig::default();
    let mut settings = ProviderSettingsState::default();
    settings.add_provider(AgentProviderConfig::new("opencode", "OpenCode", "opencode"));

    let changed =
        remove_provider_and_record_discovery_ignore(&mut config, &mut settings, "opencode");
    assert!(changed);
    config.agent_providers = settings.providers.clone();
    store.save(&config).expect("save config");

    let reloaded = store.load().expect("load config");
    assert_eq!(
        reloaded.agent_provider_discovery.ignored_provider_ids,
        vec!["opencode"]
    );
}

#[test]
fn startup_discovery_returns_filtered_suggestions_after_merge() {
    let mut config = AppConfig::default();
    let discovery = ProviderDiscoveryResult {
        verified_providers: vec![opencode_provider()],
        suggestions: vec![suggestion("claude")],
    };
    let save_called = Cell::new(false);

    let result = apply_provider_discovery_to_config(&mut config, &discovery, |saved_config| {
        save_called.set(true);
        assert_eq!(saved_config.agent_providers.len(), 1);
        assert_eq!(saved_config.agent_providers[0].id, "opencode");
        Ok(())
    });

    assert!(result.changed);
    assert!(result.error.is_none());
    assert!(save_called.get());
    assert_eq!(config.agent_providers.len(), 1);
    assert_eq!(config.agent_providers[0].id, "opencode");
    assert_eq!(
        result
            .suggestions
            .iter()
            .map(|suggestion| suggestion.id.as_str())
            .collect::<Vec<_>>(),
        vec!["claude"]
    );
}

#[test]
fn startup_discovery_save_failure_returns_deterministic_error_without_aborting() {
    let mut config = AppConfig::default();
    let discovery = ProviderDiscoveryResult {
        verified_providers: vec![opencode_provider()],
        suggestions: Vec::new(),
    };

    let result = apply_provider_discovery_to_config(&mut config, &discovery, |_config| {
        Err(anyhow::anyhow!("disk full"))
    });

    assert!(result.changed);
    assert_eq!(config.agent_providers.len(), 1);
    assert_eq!(config.agent_providers[0].id, "opencode");
    let error = result.error.expect("save error");
    assert!(error.starts_with("failed to persist auto-discovered providers: "));
    assert!(error.contains("disk full"));
}

#[test]
fn startup_discovery_does_not_save_when_config_unchanged() {
    let mut config = AppConfig {
        agent_providers: vec![opencode_provider()],
        ..AppConfig::default()
    };
    let discovery = ProviderDiscoveryResult {
        verified_providers: vec![opencode_provider()],
        suggestions: Vec::new(),
    };

    let result = apply_provider_discovery_to_config(&mut config, &discovery, |_config| {
        panic!("save should not be called when config is unchanged")
    });

    assert!(!result.changed);
    assert!(result.error.is_none());
    assert!(result.suggestions.is_empty());
    assert_eq!(config.agent_providers.len(), 1);
    assert_eq!(config.agent_providers[0].id, "opencode");
}

fn opencode_provider() -> AgentProviderConfig {
    let mut provider = AgentProviderConfig::new("opencode", "OpenCode", "opencode");
    provider.args = vec!["acp".to_string()];
    provider
}

fn suggestion(id: &str) -> AgentProviderSuggestion {
    AgentProviderSuggestion {
        id: id.to_string(),
        display_name: id.to_string(),
        command: id.to_string(),
        message: format!("{id} suggestion"),
    }
}

fn path_env(paths: &[&Path]) -> String {
    std::env::join_paths(paths)
        .expect("join path")
        .to_string_lossy()
        .into_owned()
}

fn path_list_separator() -> char {
    if cfg!(windows) { ';' } else { ':' }
}

fn create_fake_executable(dir: &Path, command: &str) {
    create_fake_file(dir, command);

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        let path = dir.join(command);
        let mut permissions = fs::metadata(&path).expect("metadata").permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(path, permissions).expect("set executable permissions");
    }
}

fn create_fake_file(dir: &Path, command: &str) {
    fs::write(dir.join(command), "#!/bin/sh\n").expect("write fake command");
}
