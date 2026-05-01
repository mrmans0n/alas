use std::{
    collections::HashSet,
    env,
    ffi::{OsStr, OsString},
    path::Path,
};

use crate::{
    agent::{AgentProviderConfig, ProviderSettingsState},
    config::AppConfig,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentProviderSuggestion {
    pub id: String,
    pub display_name: String,
    pub command: String,
    pub message: String,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ProviderDiscoveryResult {
    pub verified_providers: Vec<AgentProviderConfig>,
    pub suggestions: Vec<AgentProviderSuggestion>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProviderDiscoveryStartupResult {
    pub changed: bool,
    pub suggestions: Vec<AgentProviderSuggestion>,
    pub error: Option<String>,
}

struct KnownDiscoverableProvider {
    id: &'static str,
    display_name: &'static str,
    probe_commands: &'static [&'static str],
    provider_command: &'static str,
    verified_args: &'static [&'static str],
    required_commands: &'static [&'static str],
}

const KNOWN_PROVIDERS: &[KnownDiscoverableProvider] = &[
    KnownDiscoverableProvider {
        id: "opencode",
        display_name: "OpenCode",
        probe_commands: &["opencode"],
        provider_command: "opencode",
        verified_args: &["acp"],
        required_commands: &[],
    },
    KnownDiscoverableProvider {
        id: "claude",
        display_name: "Claude Code",
        probe_commands: &["claude"],
        provider_command: "npx",
        verified_args: &["-y", "@agentclientprotocol/claude-agent-acp"],
        required_commands: &["npx"],
    },
    KnownDiscoverableProvider {
        id: "codex",
        display_name: "Codex",
        probe_commands: &["codex"],
        provider_command: "npx",
        verified_args: &["-y", "@zed-industries/codex-acp"],
        required_commands: &["npx"],
    },
];

pub fn discover_agent_providers() -> ProviderDiscoveryResult {
    discover_agent_providers_from_path_os(env::var_os("PATH").as_deref())
}

pub fn discover_agent_providers_from_path(path_env: Option<&str>) -> ProviderDiscoveryResult {
    discover_agent_providers_from_path_os(path_env.map(OsStr::new))
}

fn discover_agent_providers_from_path_os(path_env: Option<&OsStr>) -> ProviderDiscoveryResult {
    let Some(path_env) = path_env else {
        return ProviderDiscoveryResult::default();
    };

    if path_env.is_empty() {
        return ProviderDiscoveryResult::default();
    }

    let available_commands = available_commands_from_path(path_env);
    let mut result = ProviderDiscoveryResult::default();

    for provider in KNOWN_PROVIDERS {
        let has_provider_binary = provider
            .probe_commands
            .iter()
            .any(|command| available_commands.contains(*command));
        if !has_provider_binary {
            continue;
        }

        let missing_required = provider
            .required_commands
            .iter()
            .find(|command| !available_commands.contains(**command));
        if let Some(missing) = missing_required {
            result.suggestions.push(AgentProviderSuggestion {
                id: provider.id.to_string(),
                display_name: provider.display_name.to_string(),
                command: provider.probe_commands[0].to_string(),
                message: format!(
                    "{} was found on PATH, but '{}' is required to launch its ACP adapter.",
                    provider.display_name, missing
                ),
            });
            continue;
        }

        let mut config = AgentProviderConfig::new(
            provider.id,
            provider.display_name,
            provider.provider_command,
        );
        config.args = provider
            .verified_args
            .iter()
            .map(|arg| (*arg).to_string())
            .collect();
        result.verified_providers.push(config);
    }

    result
}

fn available_commands_from_path(path_env: &OsStr) -> HashSet<String> {
    let mut commands = HashSet::new();

    for path_entry in env::split_paths(path_env) {
        if path_entry.as_os_str().is_empty() || path_entry.is_relative() || !path_entry.is_dir() {
            continue;
        }

        for provider in KNOWN_PROVIDERS {
            for command in provider
                .probe_commands
                .iter()
                .chain(std::iter::once(&provider.provider_command))
            {
                if command_file_candidates(command, should_use_windows_command_extensions())
                    .iter()
                    .any(|candidate| is_executable_file(&path_entry.join(candidate)))
                {
                    commands.insert((*command).to_string());
                }
            }
            for command in provider.required_commands {
                if command_file_candidates(command, should_use_windows_command_extensions())
                    .iter()
                    .any(|candidate| is_executable_file(&path_entry.join(candidate)))
                {
                    commands.insert((*command).to_string());
                }
            }
        }
    }

    commands
}

pub fn merge_discovered_agent_providers(
    config: &mut AppConfig,
    discovery: &ProviderDiscoveryResult,
) -> bool {
    let mut configured_provider_ids = config
        .agent_providers
        .iter()
        .map(|provider| provider.id.clone())
        .collect::<HashSet<_>>();
    let ignored_provider_ids = config
        .agent_provider_discovery
        .ignored_provider_ids
        .iter()
        .map(String::as_str)
        .collect::<HashSet<_>>();

    let mut providers_to_append = discovery
        .verified_providers
        .iter()
        .filter(|provider| {
            !ignored_provider_ids.contains(provider.id.as_str())
                && configured_provider_ids.insert(provider.id.clone())
        })
        .cloned()
        .collect::<Vec<_>>();

    if providers_to_append.is_empty() {
        return false;
    }

    config.agent_providers.append(&mut providers_to_append);
    true
}

pub fn apply_provider_discovery_to_config(
    config: &mut AppConfig,
    discovery: &ProviderDiscoveryResult,
    save: impl FnOnce(&AppConfig) -> anyhow::Result<()>,
) -> ProviderDiscoveryStartupResult {
    let changed = merge_discovered_agent_providers(config, discovery);
    let error = if changed {
        save(config)
            .err()
            .map(|error| format!("failed to persist auto-discovered providers: {error}"))
    } else {
        None
    };

    ProviderDiscoveryStartupResult {
        changed,
        suggestions: filtered_provider_suggestions(config, discovery),
        error,
    }
}

pub fn filtered_provider_suggestions(
    config: &AppConfig,
    discovery: &ProviderDiscoveryResult,
) -> Vec<AgentProviderSuggestion> {
    let configured_provider_ids = config
        .agent_providers
        .iter()
        .map(|provider| provider.id.as_str())
        .collect::<HashSet<_>>();
    let ignored_provider_ids = config
        .agent_provider_discovery
        .ignored_provider_ids
        .iter()
        .map(String::as_str)
        .collect::<HashSet<_>>();

    discovery
        .suggestions
        .iter()
        .filter(|suggestion| {
            !configured_provider_ids.contains(suggestion.id.as_str())
                && !ignored_provider_ids.contains(suggestion.id.as_str())
        })
        .cloned()
        .collect()
}

pub fn ignore_discovered_provider_id(config: &mut AppConfig, provider_id: &str) -> bool {
    if !is_known_discoverable_provider_id(provider_id) {
        return false;
    }

    if config
        .agent_provider_discovery
        .ignored_provider_ids
        .iter()
        .any(|ignored_provider_id| ignored_provider_id == provider_id)
    {
        return false;
    }

    config
        .agent_provider_discovery
        .ignored_provider_ids
        .push(provider_id.to_string());
    true
}

pub fn remove_provider_and_record_discovery_ignore(
    config: &mut AppConfig,
    settings: &mut ProviderSettingsState,
    provider_id: &str,
) -> bool {
    let provider_was_present = settings
        .providers
        .iter()
        .any(|provider| provider.id == provider_id);
    let suggestion_count = settings.discovery_suggestions.len();

    settings.remove_provider(provider_id);
    settings
        .discovery_suggestions
        .retain(|suggestion| suggestion.id != provider_id);

    let ignored_changed = if provider_was_present {
        ignore_discovered_provider_id(config, provider_id)
    } else {
        false
    };

    provider_was_present
        || ignored_changed
        || settings.discovery_suggestions.len() != suggestion_count
}

pub fn is_known_discoverable_provider_id(provider_id: &str) -> bool {
    KNOWN_PROVIDERS
        .iter()
        .any(|provider| provider.id == provider_id)
}

fn should_use_windows_command_extensions() -> bool {
    cfg!(windows)
}

fn command_file_candidates(command: &str, include_windows_extensions: bool) -> Vec<OsString> {
    let mut candidates = Vec::new();
    let mut seen = HashSet::new();

    push_command_candidate(&mut candidates, &mut seen, OsString::from(command));

    if include_windows_extensions && Path::new(command).extension().is_none() {
        for extension in windows_command_extensions(env::var_os("PATHEXT").as_deref()) {
            let mut candidate = OsString::from(command);
            candidate.push(extension);
            push_command_candidate(&mut candidates, &mut seen, candidate);
        }
    }

    candidates
}

fn push_command_candidate(
    candidates: &mut Vec<OsString>,
    seen: &mut HashSet<OsString>,
    candidate: OsString,
) {
    if seen.insert(candidate.clone()) {
        candidates.push(candidate);
    }
}

fn windows_command_extensions(path_ext: Option<&OsStr>) -> Vec<OsString> {
    let mut extensions = Vec::new();
    let mut seen = HashSet::new();

    if let Some(path_ext) = path_ext {
        for extension in path_ext.to_string_lossy().split(';') {
            if !extension.is_empty() {
                push_command_candidate(&mut extensions, &mut seen, OsString::from(extension));
            }
        }
    }

    for extension in [".exe", ".cmd", ".bat"] {
        push_command_candidate(&mut extensions, &mut seen, OsString::from(extension));
    }

    extensions
}

#[cfg(unix)]
fn is_executable_file(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;

    path.metadata()
        .map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

#[cfg(not(unix))]
fn is_executable_file(path: &Path) -> bool {
    path.is_file()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_file_candidates_include_windows_suffixes_when_requested() {
        let candidates = command_file_candidates("opencode", true);

        assert!(candidates.contains(&OsString::from("opencode")));
        assert!(candidates.contains(&OsString::from("opencode.exe")));
        assert!(candidates.contains(&OsString::from("opencode.cmd")));
        assert!(candidates.contains(&OsString::from("opencode.bat")));
    }

    #[test]
    fn command_file_candidates_do_not_append_suffixes_to_explicit_extension() {
        let candidates = command_file_candidates("opencode.exe", true);

        assert_eq!(candidates, vec![OsString::from("opencode.exe")]);
    }

    #[test]
    fn windows_command_extensions_use_pathext_before_defaults() {
        let extensions = windows_command_extensions(Some(OsStr::new(".COM;.EXE;.CMD")));

        assert_eq!(extensions[0], OsString::from(".COM"));
        assert_eq!(extensions[1], OsString::from(".EXE"));
        assert_eq!(extensions[2], OsString::from(".CMD"));
        assert!(extensions.contains(&OsString::from(".exe")));
        assert!(extensions.contains(&OsString::from(".cmd")));
        assert!(extensions.contains(&OsString::from(".bat")));
    }
}
