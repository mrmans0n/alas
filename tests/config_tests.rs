use alas::config::{
    AppConfig, AppConfigStore, AppRepository, CommandConfig, CommandEntry, RepoConfigFile,
    RepoConfigStore, ResolvedRepoConfig,
};
use alas::ui::dialogs::{CommandSettingsDialogState, NotificationPreferencesDialogState};
use indexmap::IndexMap;
use std::path::PathBuf;
use std::sync::Mutex;
use tempfile::{NamedTempFile, tempdir};

static CWD_LOCK: Mutex<()> = Mutex::new(());

#[test]
fn app_config_round_trips_repositories_and_archives() {
    let temp = tempdir().unwrap();
    let config_path = temp.path().join("alas").join("config.toml");
    let store = AppConfigStore::new(config_path.clone());

    assert_eq!(store.path(), config_path.as_path());
    assert_eq!(store.load().unwrap(), AppConfig::default());

    let mut archived_worktrees = IndexMap::new();
    archived_worktrees.insert(
        "repo-1".to_string(),
        vec![
            PathBuf::from("/tmp/repo-1-worktree-a"),
            PathBuf::from("/tmp/repo-1-worktree-b"),
        ],
    );
    let config = AppConfig {
        repositories: vec![AppRepository {
            id: "repo-1".to_string(),
            path: PathBuf::from("/tmp/repo-1"),
            name: Some("Repo One".to_string()),
        }],
        archived_worktrees,
        ..AppConfig::default()
    };

    store.save(&config).unwrap();

    assert!(config_path.exists());
    assert_eq!(store.load().unwrap(), config);
}

#[test]
fn app_config_defaults_enable_harness_completion_notifications() {
    let config = AppConfig::default();
    let prefs = config.notifications.harness_completion;

    assert!(prefs.enabled);
    assert!(prefs.success);
    assert!(prefs.failure);
}

#[test]
fn app_config_loads_notification_defaults_from_existing_toml() {
    let toml = r#"
        [[repositories]]
        id = "repo-1"
        path = "/tmp/repo-1"
    "#;

    let config: AppConfig = toml::from_str(toml).unwrap();
    let prefs = config.notifications.harness_completion;

    assert!(prefs.enabled);
    assert!(prefs.success);
    assert!(prefs.failure);
}

#[test]
fn app_config_loads_partial_notification_defaults_as_enabled() {
    let toml = r#"
        [notifications.harness_completion]
        success = false
    "#;

    let config: AppConfig = toml::from_str(toml).unwrap();
    let prefs = config.notifications.harness_completion;

    assert!(prefs.enabled);
    assert!(!prefs.success);
    assert!(prefs.failure);
}

#[test]
fn app_config_round_trips_notification_preferences() {
    let temp = tempdir().unwrap();
    let store = AppConfigStore::new(temp.path().join("config.toml"));
    let mut config = AppConfig::default();
    config.notifications.harness_completion.enabled = false;
    config.notifications.harness_completion.success = false;
    config.notifications.harness_completion.failure = true;

    store.save(&config).unwrap();

    assert_eq!(store.load().unwrap(), config);
}

#[test]
fn app_config_save_supports_current_directory_file_paths() {
    let _lock = CWD_LOCK.lock().unwrap();
    let original_dir = std::env::current_dir().unwrap();
    let temp = tempdir().unwrap();
    std::env::set_current_dir(temp.path()).unwrap();

    let result = (|| {
        let config_path = PathBuf::from("config.toml");
        let store = AppConfigStore::new(config_path.clone());
        let config = AppConfig::default();

        store.save(&config)?;

        assert!(config_path.exists());
        assert_eq!(store.load()?, config);
        anyhow::Ok(())
    })();

    std::env::set_current_dir(original_dir).unwrap();
    result.unwrap();
}

#[test]
fn app_config_save_preserves_error_context_for_parent_creation() {
    let parent_file = NamedTempFile::new().unwrap();
    let store = AppConfigStore::new(parent_file.path().join("config.toml"));

    let error = store.save(&AppConfig::default()).unwrap_err();
    let message = format!("{error:#}");

    assert!(message.contains("failed to create app config directory"));
    assert!(message.contains(&parent_file.path().display().to_string()));
}

#[test]
fn repo_config_store_writes_to_dot_alas_config() {
    let temp = tempdir().unwrap();
    let store = RepoConfigStore::for_repo(temp.path());

    assert_eq!(store.path(), temp.path().join(".alas/config.toml"));
    assert_eq!(store.load().unwrap(), None);

    let mut entries = IndexMap::new();
    entries.insert(
        "claude".to_string(),
        CommandEntry {
            command: "claude".to_string(),
        },
    );
    let config = RepoConfigFile {
        default_command: None,
        commands: Some(CommandConfig {
            default: "claude".to_string(),
            entries,
        }),
    };

    store.save(&config).unwrap();

    assert_eq!(store.path(), temp.path().join(".alas").join("config.toml"));
    assert!(store.path().exists());
    assert_eq!(store.load().unwrap(), Some(config));
}

#[test]
fn repo_config_save_preserves_error_context_for_parent_creation() {
    let parent_file = NamedTempFile::new().unwrap();
    let store = RepoConfigStore::for_repo(parent_file.path());

    let error = store.save(&RepoConfigFile::default()).unwrap_err();
    let message = format!("{error:#}");

    assert!(message.contains("failed to create repository config directory"));
    assert!(message.contains(&parent_file.path().join(".alas").display().to_string()));
}

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

#[test]
fn command_settings_dialog_builds_repo_config() {
    let dialog = CommandSettingsDialogState {
        repo_id: "repo-1".to_string(),
        default_name: "claude".to_string(),
        entries: vec![
            ("claude".to_string(), "claude".to_string()),
            ("shell".to_string(), "$SHELL".to_string()),
        ],
        error: None,
    };

    let config = dialog.to_repo_config().unwrap();
    let commands = config.commands.unwrap();
    assert_eq!(config.default_command, None);
    assert_eq!(commands.default, "claude");
    assert_eq!(commands.entries["claude"].command, "claude");
}

#[test]
fn command_settings_dialog_rejects_missing_default_entry() {
    let dialog = CommandSettingsDialogState {
        repo_id: "repo-1".to_string(),
        default_name: "missing".to_string(),
        entries: vec![("claude".to_string(), "claude".to_string())],
        error: None,
    };

    assert_eq!(
        dialog.to_repo_config().unwrap_err(),
        "Default command must match a named command"
    );
}

#[test]
fn notification_preferences_dialog_initializes_from_config() {
    let mut config = AppConfig::default();
    config.notifications.harness_completion.enabled = false;
    config.notifications.harness_completion.success = true;
    config.notifications.harness_completion.failure = false;

    let dialog = NotificationPreferencesDialogState::from_config(&config);

    assert!(!dialog.harness_completion_enabled);
    assert!(dialog.harness_completion_success);
    assert!(!dialog.harness_completion_failure);
    assert_eq!(dialog.error, None);
}

#[test]
fn notification_preferences_dialog_applies_only_notification_preferences() {
    let mut config = AppConfig {
        repositories: vec![AppRepository {
            id: "repo-1".to_string(),
            path: PathBuf::from("/tmp/repo-1"),
            name: Some("Repo One".to_string()),
        }],
        ..AppConfig::default()
    };
    let dialog = NotificationPreferencesDialogState {
        harness_completion_enabled: false,
        harness_completion_success: false,
        harness_completion_failure: true,
        error: Some("ignored".to_string()),
    };

    dialog.apply_to_config(&mut config);

    assert_eq!(config.repositories.len(), 1);
    assert!(!config.notifications.harness_completion.enabled);
    assert!(!config.notifications.harness_completion.success);
    assert!(config.notifications.harness_completion.failure);
}

#[test]
fn command_settings_dialog_rejects_blank_fields() {
    let blank_default = CommandSettingsDialogState {
        repo_id: "repo-1".to_string(),
        default_name: " ".to_string(),
        entries: vec![("claude".to_string(), "claude".to_string())],
        error: None,
    };
    assert_eq!(
        blank_default.to_repo_config().unwrap_err(),
        "Default command name is required"
    );

    let blank_name = CommandSettingsDialogState {
        repo_id: "repo-1".to_string(),
        default_name: "claude".to_string(),
        entries: vec![(" ".to_string(), "claude".to_string())],
        error: None,
    };
    assert_eq!(
        blank_name.to_repo_config().unwrap_err(),
        "Command names cannot be empty"
    );

    let blank_command = CommandSettingsDialogState {
        repo_id: "repo-1".to_string(),
        default_name: "claude".to_string(),
        entries: vec![("claude".to_string(), " ".to_string())],
        error: None,
    };
    assert_eq!(
        blank_command.to_repo_config().unwrap_err(),
        "Command value for claude cannot be empty"
    );
}
