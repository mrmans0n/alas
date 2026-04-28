use alas::config::{AppConfig, CommandConfig, CommandEntry, RepoConfigFile, ResolvedRepoConfig};
use indexmap::IndexMap;
use std::path::PathBuf;

#[test]
fn repo_config_supports_named_commands() {
    let toml = r#"
        [commands]
        default = "claude"

        [commands.entries.claude]
        command = "claude"

        [commands.entries.shell]
        command = "$SHELL"
    "#;

    let repo: RepoConfigFile = toml::from_str(toml).unwrap();
    assert_eq!(repo.commands.unwrap().default, "claude");
}

#[test]
fn repo_config_supports_default_command_shorthand() {
    let toml = r#"default_command = "codex""#;
    let repo: RepoConfigFile = toml::from_str(toml).unwrap();
    assert_eq!(repo.default_command.as_deref(), Some("codex"));
}

#[test]
fn resolved_config_prefers_repo_command_over_shell_fallback() {
    let app = AppConfig::default();
    let repo_file = RepoConfigFile {
        default_command: Some("claude".to_string()),
        commands: None,
    };

    let resolved = ResolvedRepoConfig::resolve(
        "repo-1".to_string(),
        PathBuf::from("/tmp/repo"),
        Some("repo".to_string()),
        &app,
        Some(repo_file),
    );

    assert_eq!(resolved.default_command().command, "claude");
}

#[test]
fn resolved_config_falls_back_to_first_named_command_when_default_is_missing() {
    let app = AppConfig::default();
    let mut entries = IndexMap::new();
    entries.insert(
        "first".to_string(),
        CommandEntry {
            command: "first-command".to_string(),
        },
    );
    entries.insert(
        "second".to_string(),
        CommandEntry {
            command: "second-command".to_string(),
        },
    );

    let resolved = ResolvedRepoConfig::resolve(
        "repo-1".to_string(),
        PathBuf::from("/tmp/repo"),
        None,
        &app,
        Some(RepoConfigFile {
            default_command: None,
            commands: Some(CommandConfig {
                default: "missing".to_string(),
                entries,
            }),
        }),
    );

    assert_eq!(resolved.default_command_name(), "first");
    assert_eq!(resolved.default_command().command, "first-command");
}

#[test]
fn command_config_type_is_exported() {
    let commands = CommandConfig::default();
    assert!(commands.entries.is_empty());
}
