use std::path::PathBuf;

use alas::app::{
    DetectedLanguage, FileTabLoadState, ImagePreflight, ImageZoom, MarkdownViewMode, TerminalTabId,
    TerminalTabKind, TerminalTabStatus, WorkspaceSession, WorkspaceTabContent, WorkspaceTabKind,
    is_supported_image_path, preflight_image_path,
};
use alas::terminal::{CommandSpec, TerminalBackendSession};

fn shell_command(path: &str) -> CommandSpec {
    CommandSpec::shell_command("$SHELL", PathBuf::from(path))
}

#[test]
fn selecting_worktree_creates_default_tab_once() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");
    let command = shell_command("/repo/a");

    let first = session.ensure_default_terminal_tab("repo", path.clone(), command.clone());
    let second = session.ensure_default_terminal_tab("repo", path.clone(), command);

    assert_eq!(first, second);
    assert_eq!(session.tabs_for_worktree("repo", &path).len(), 1);
    assert_eq!(
        session.active_tab("repo", &path).map(|tab| tab.id),
        Some(first)
    );
}

#[test]
fn worktree_can_have_multiple_named_terminal_tabs() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");

    let shell = session.create_terminal_tab(
        "repo",
        path.clone(),
        "Shell".to_string(),
        TerminalTabKind::Shell,
        shell_command("/repo/a"),
    );
    let tests = session.create_terminal_tab(
        "repo",
        path.clone(),
        "Tests".to_string(),
        TerminalTabKind::Command,
        CommandSpec::shell_command("cargo test", path.clone()),
    );

    assert_ne!(shell, tests);
    assert_eq!(session.tabs_for_worktree("repo", &path).len(), 2);
    assert_eq!(
        session.active_tab("repo", &path).map(|tab| tab.id),
        Some(tests)
    );

    session
        .set_active_tab("repo", &path, shell)
        .expect("set active tab");
    let active = session.active_tab("repo", &path).expect("active tab");
    assert_eq!(active.id, shell);
    assert_eq!(active.name, "Shell");

    let ensured =
        session.ensure_default_terminal_tab("repo", path.clone(), shell_command("/repo/a"));
    assert_eq!(ensured, shell);
    assert_eq!(session.tabs_for_worktree("repo", &path).len(), 2);
    assert_eq!(
        session.active_tab("repo", &path).map(|tab| tab.id),
        Some(shell)
    );
}

#[test]
fn terminal_tab_context_resolves_existing_terminal_tab() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");
    let tab_id = session.create_terminal_tab(
        "repo",
        path.clone(),
        "Tests".to_string(),
        TerminalTabKind::Command,
        CommandSpec::shell_command("cargo test", path.clone()),
    );

    let context = session
        .terminal_tab_context(tab_id)
        .expect("terminal tab context");

    assert_eq!(context.tab_id, tab_id);
    assert_eq!(context.tab_name, "Tests");
    assert_eq!(context.repo_id, "repo");
    assert_eq!(context.worktree_path, path);
}

#[test]
fn terminal_tab_context_ignores_missing_or_non_terminal_tabs() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");
    let file_tab = session.open_file_tab("repo", path.clone(), path.join("README.md"));

    assert!(session.terminal_tab_context(file_tab).is_none());
    assert!(session.terminal_tab_context(TerminalTabId(999)).is_none());
}

#[test]
fn active_tab_is_scoped_per_worktree() {
    let mut session = WorkspaceSession::default();
    let path_a = PathBuf::from("/repo/a");
    let path_b = PathBuf::from("/repo/b");

    let shell_a = session.create_terminal_tab(
        "repo",
        path_a.clone(),
        "Shell".to_string(),
        TerminalTabKind::Shell,
        shell_command("/repo/a"),
    );
    let tests_a = session.create_terminal_tab(
        "repo",
        path_a.clone(),
        "Tests".to_string(),
        TerminalTabKind::Command,
        CommandSpec::shell_command("cargo test", path_a.clone()),
    );
    let shell_b = session.create_terminal_tab(
        "repo",
        path_b.clone(),
        "Shell".to_string(),
        TerminalTabKind::Shell,
        shell_command("/repo/b"),
    );

    session
        .set_active_tab("repo", &path_a, shell_a)
        .expect("set active tab");

    assert_eq!(
        session.active_tab("repo", &path_a).map(|tab| tab.id),
        Some(shell_a)
    );
    assert_eq!(
        session.active_tab("repo", &path_b).map(|tab| tab.id),
        Some(shell_b)
    );
    assert_ne!(tests_a, shell_b);
}

#[test]
fn tab_runtime_state_can_be_updated_and_removed() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");
    let tab_id = session.create_terminal_tab(
        "repo",
        path.clone(),
        "Tests".to_string(),
        TerminalTabKind::Command,
        CommandSpec::shell_command("cargo test", path.clone()),
    );

    session
        .set_tab_backend_session(
            "repo",
            &path,
            tab_id,
            Some(TerminalBackendSession { backend_id: 42 }),
        )
        .expect("set backend session");
    session
        .set_tab_status("repo", &path, tab_id, TerminalTabStatus::Running)
        .expect("set status");
    session
        .set_tab_scroll_offset("repo", &path, tab_id, 12)
        .expect("set scroll offset");

    let active = session.active_tab("repo", &path).expect("active tab");
    let active_state = active.terminal_tab_state().expect("terminal tab state");
    assert_eq!(
        active_state.backend_session,
        Some(TerminalBackendSession { backend_id: 42 })
    );
    assert_eq!(active_state.status, TerminalTabStatus::Running);
    assert_eq!(active_state.failure_cause, None);
    assert_eq!(active_state.scroll_offset_rows, 12);

    session.remove_worktree("repo", &path);
    assert!(session.tabs_for_worktree("repo", &path).is_empty());
    assert!(session.active_tab("repo", &path).is_none());
}

#[test]
fn failed_startup_tab_preserves_failure_without_backend_session() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");
    let shell = session.create_terminal_tab(
        "repo",
        path.clone(),
        "Shell".to_string(),
        TerminalTabKind::Shell,
        shell_command("/repo/a"),
    );
    let tests = session.create_terminal_tab(
        "repo",
        path.clone(),
        "Tests".to_string(),
        TerminalTabKind::Command,
        CommandSpec::shell_command("cargo test", path.clone()),
    );

    session
        .set_tab_failure("repo", &path, shell, "backend failed to start")
        .expect("mark shell failed");
    session
        .set_active_tab("repo", &path, tests)
        .expect("select tests");
    session
        .set_active_tab("repo", &path, shell)
        .expect("select failed shell");

    let active = session.active_tab("repo", &path).expect("active tab");
    let active_state = active.terminal_tab_state().expect("terminal tab state");
    assert_eq!(active.id, shell);
    assert_eq!(active_state.status, TerminalTabStatus::Failed);
    assert_eq!(
        active_state.failure_cause.as_deref(),
        Some("backend failed to start")
    );
    assert_eq!(active_state.backend_session, None);
}

#[test]
fn terminal_failure_cause_is_scoped_per_tab() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");
    let shell = session.create_terminal_tab(
        "repo",
        path.clone(),
        "Shell".to_string(),
        TerminalTabKind::Shell,
        shell_command("/repo/a"),
    );
    let tests = session.create_terminal_tab(
        "repo",
        path.clone(),
        "Tests".to_string(),
        TerminalTabKind::Command,
        CommandSpec::shell_command("cargo test", path.clone()),
    );

    session
        .set_tab_failure("repo", &path, shell, "shell write failed")
        .expect("mark shell failed");
    session
        .set_tab_status("repo", &path, shell, TerminalTabStatus::Running)
        .expect("status update should not clear cause");
    session
        .set_active_tab("repo", &path, tests)
        .expect("set tests active");

    let shell_tab = session
        .tabs_for_worktree("repo", &path)
        .iter()
        .find(|tab| tab.id == shell)
        .expect("shell tab");
    let tests_tab = session.active_tab("repo", &path).expect("tests tab");
    let shell_state = shell_tab.terminal_tab_state().expect("shell state");
    let tests_state = tests_tab.terminal_tab_state().expect("tests state");
    assert_eq!(
        shell_state.failure_cause.as_deref(),
        Some("shell write failed")
    );
    assert_eq!(tests_state.failure_cause, None);

    session
        .set_tab_failure("repo", &path, tests, "tests resize failed")
        .expect("mark tests failed");
    session
        .clear_tab_failure("repo", &path, tests)
        .expect("clear tests failure");

    let tabs = session.tabs_for_worktree("repo", &path);
    let shell_tab = tabs.iter().find(|tab| tab.id == shell).expect("shell tab");
    let tests_tab = tabs.iter().find(|tab| tab.id == tests).expect("tests tab");
    let shell_state = shell_tab.terminal_tab_state().expect("shell state");
    let tests_state = tests_tab.terminal_tab_state().expect("tests state");
    assert_eq!(
        shell_state.failure_cause.as_deref(),
        Some("shell write failed")
    );
    assert_eq!(tests_state.failure_cause, None);
}

#[test]
fn setting_unknown_active_tab_returns_contextual_error() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");
    session.create_terminal_tab(
        "repo",
        path.clone(),
        "Shell".to_string(),
        TerminalTabKind::Shell,
        shell_command("/repo/a"),
    );

    let error = session
        .set_active_tab("repo", &path, TerminalTabId(999))
        .expect_err("unknown tab should fail")
        .to_string();

    assert!(error.contains("unknown workspace tab"));
    assert!(error.contains("repo"));
    assert!(error.contains("/repo/a"));
}

#[test]
fn worktree_can_have_mixed_terminal_and_file_tabs() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");

    let terminal = session.create_terminal_tab(
        "repo",
        path.clone(),
        "Shell".to_string(),
        TerminalTabKind::Shell,
        shell_command("/repo/a"),
    );
    let file = session.open_file_tab("repo", path.clone(), PathBuf::from("/repo/a/src/main.rs"));

    let tabs = session.tabs_for_worktree("repo", &path);
    assert_eq!(tabs.len(), 2);
    assert_eq!(tabs[0].id, terminal);
    assert_eq!(tabs[1].id, file);
    assert!(matches!(tabs[0].kind, WorkspaceTabKind::Terminal(_)));
    assert_eq!(tabs[1].kind, WorkspaceTabKind::File);
    assert_eq!(
        session.active_tab("repo", &path).map(|tab| tab.id),
        Some(file)
    );
}

#[test]
fn mixed_tab_selection_can_move_between_terminal_and_file() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");
    let terminal = session.create_terminal_tab(
        "repo",
        path.clone(),
        "Shell".to_string(),
        TerminalTabKind::Shell,
        shell_command("/repo/a"),
    );
    let file = session.open_file_tab("repo", path.clone(), PathBuf::from("/repo/a/src/lib.rs"));

    session
        .set_active_tab("repo", &path, terminal)
        .expect("select terminal");
    assert!(session.active_tab("repo", &path).unwrap().is_terminal());

    session
        .set_active_tab("repo", &path, file)
        .expect("select file");
    assert!(session.active_tab("repo", &path).unwrap().is_file());

    session
        .set_active_tab("repo", &path, terminal)
        .expect("select terminal again");
    assert!(session.active_tab("repo", &path).unwrap().is_terminal());
}

#[test]
fn opening_same_file_focuses_existing_tab() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");
    session.create_terminal_tab(
        "repo",
        path.clone(),
        "Shell".to_string(),
        TerminalTabKind::Shell,
        shell_command("/repo/a"),
    );

    let first = session.open_file_tab(
        "repo",
        path.clone(),
        PathBuf::from("/repo/a/src/../src/lib.rs"),
    );
    let second = session.open_file_tab("repo", path.clone(), PathBuf::from("/repo/a/src/lib.rs"));

    assert_eq!(first, second);
    assert_eq!(session.tabs_for_worktree("repo", &path).len(), 2);
    assert_eq!(
        session.active_tab("repo", &path).map(|tab| tab.id),
        Some(first)
    );
}

#[test]
fn closing_mixed_tabs_uses_neighbor_fallback() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");
    let first = session.create_terminal_tab(
        "repo",
        path.clone(),
        "Shell".to_string(),
        TerminalTabKind::Shell,
        shell_command("/repo/a"),
    );
    let second = session.open_file_tab("repo", path.clone(), PathBuf::from("/repo/a/README.md"));
    let third = session.create_terminal_tab(
        "repo",
        path.clone(),
        "Tests".to_string(),
        TerminalTabKind::Command,
        CommandSpec::shell_command("cargo test", path.clone()),
    );

    session
        .set_active_tab("repo", &path, third)
        .expect("select third");
    assert_eq!(session.close_tab("repo", &path, first), Some(third));
    assert_eq!(
        session.active_tab("repo", &path).map(|tab| tab.id),
        Some(third)
    );

    assert_eq!(session.close_tab("repo", &path, third), Some(second));
    assert_eq!(
        session.active_tab("repo", &path).map(|tab| tab.id),
        Some(second)
    );

    assert_eq!(session.close_tab("repo", &path, second), None);
    assert!(session.active_tab("repo", &path).is_none());
}

#[test]
fn reordering_mixed_tabs_preserves_active_tab() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");
    let first = session.create_terminal_tab(
        "repo",
        path.clone(),
        "Shell".to_string(),
        TerminalTabKind::Shell,
        shell_command("/repo/a"),
    );
    let second = session.open_file_tab("repo", path.clone(), PathBuf::from("/repo/a/README.md"));

    session
        .move_tab("repo", &path, second, 0)
        .expect("move file tab");

    let tabs = session.tabs_for_worktree("repo", &path);
    assert_eq!(tabs[0].id, second);
    assert_eq!(tabs[1].id, first);
    assert_eq!(
        session.active_tab("repo", &path).map(|tab| tab.id),
        Some(second)
    );
}

#[test]
fn terminal_specific_mutation_rejects_file_tabs() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");
    let file = session.open_file_tab("repo", path.clone(), PathBuf::from("/repo/a/README.md"));

    let error = session
        .set_tab_status("repo", &path, file, TerminalTabStatus::Running)
        .expect_err("file tab should reject terminal status")
        .to_string();

    assert!(error.contains("not a terminal tab"));
}

#[test]
fn removing_worktree_and_repository_removes_all_tab_kinds() {
    let mut session = WorkspaceSession::default();
    let path_a = PathBuf::from("/repo/a");
    let path_b = PathBuf::from("/repo/b");

    session.create_terminal_tab(
        "repo",
        path_a.clone(),
        "Shell".to_string(),
        TerminalTabKind::Shell,
        shell_command("/repo/a"),
    );
    session.open_file_tab("repo", path_a.clone(), PathBuf::from("/repo/a/README.md"));
    session.open_file_tab("repo", path_b.clone(), PathBuf::from("/repo/b/README.md"));

    session.remove_worktree("repo", &path_a);
    assert!(session.tabs_for_worktree("repo", &path_a).is_empty());
    assert_eq!(session.tabs_for_worktree("repo", &path_b).len(), 1);

    session.remove_repository("repo");
    assert!(session.tabs_for_worktree("repo", &path_b).is_empty());
}

#[test]
fn file_tab_load_state_can_be_updated() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");
    let file = session.open_file_tab("repo", path.clone(), PathBuf::from("/repo/a/notes.txt"));

    session
        .set_file_tab_load_state(
            "repo",
            &path,
            file,
            FileTabLoadState::Loaded {
                content: "hello".to_string(),
                size_bytes: 5,
                line_count: 1,
                highlight: None,
                highlight_error: None,
            },
        )
        .expect("set file state");

    let active = session.active_tab("repo", &path).expect("active file tab");
    match &active.content {
        WorkspaceTabContent::File(state) => assert!(matches!(
            &state.load_state,
            FileTabLoadState::Loaded { content, .. } if content == "hello"
        )),
        WorkspaceTabContent::Markdown(_)
        | WorkspaceTabContent::Terminal(_)
        | WorkspaceTabContent::Image(_)
        | WorkspaceTabContent::AgentChat(_) => {
            panic!("expected file tab")
        }
    }
}

#[test]
fn markdown_files_open_in_split_mode_by_default() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");
    let markdown = session.open_file_tab("repo", path.clone(), PathBuf::from("/repo/a/README.md"));

    let active = session
        .active_tab("repo", &path)
        .expect("active markdown tab");
    assert_eq!(active.id, markdown);
    assert_eq!(active.kind, WorkspaceTabKind::File);
    match &active.content {
        WorkspaceTabContent::Markdown(state) => {
            assert_eq!(state.view_mode, MarkdownViewMode::Split);
            assert_eq!(state.file.language, DetectedLanguage::Markdown);
            assert!(matches!(state.file.load_state, FileTabLoadState::Loading));
        }
        WorkspaceTabContent::File(_)
        | WorkspaceTabContent::Terminal(_)
        | WorkspaceTabContent::Image(_)
        | WorkspaceTabContent::AgentChat(_) => {
            panic!("expected markdown tab")
        }
    }
}

#[test]
fn markdown_mode_can_switch_between_code_preview_and_split() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");
    let markdown = session.open_file_tab("repo", path.clone(), PathBuf::from("/repo/a/README.md"));

    session
        .set_markdown_view_mode("repo", &path, markdown, MarkdownViewMode::Code)
        .expect("set code mode");
    session
        .set_markdown_view_mode("repo", &path, markdown, MarkdownViewMode::Preview)
        .expect("set preview mode");
    session
        .set_markdown_view_mode("repo", &path, markdown, MarkdownViewMode::Split)
        .expect("set split mode");

    let active = session
        .active_tab("repo", &path)
        .expect("active markdown tab");
    match &active.content {
        WorkspaceTabContent::Markdown(state) => {
            assert_eq!(state.view_mode, MarkdownViewMode::Split);
        }
        WorkspaceTabContent::File(_)
        | WorkspaceTabContent::Terminal(_)
        | WorkspaceTabContent::Image(_)
        | WorkspaceTabContent::AgentChat(_) => {
            panic!("expected markdown tab")
        }
    }
}

#[test]
fn opening_same_markdown_file_focuses_existing_tab() {
    let mut session = WorkspaceSession::default();
    let path = PathBuf::from("/repo/a");
    session.create_terminal_tab(
        "repo",
        path.clone(),
        "Shell".to_string(),
        TerminalTabKind::Shell,
        shell_command("/repo/a"),
    );

    let first = session.open_file_tab(
        "repo",
        path.clone(),
        PathBuf::from("/repo/a/docs/../README.md"),
    );
    let second = session.open_file_tab("repo", path.clone(), PathBuf::from("/repo/a/README.md"));

    assert_eq!(first, second);
    assert_eq!(session.tabs_for_worktree("repo", &path).len(), 2);
    assert_eq!(
        session.active_tab("repo", &path).map(|tab| tab.id),
        Some(first)
    );
}

#[test]
fn image_extension_detection_is_case_insensitive() {
    assert!(is_supported_image_path(&PathBuf::from("photo.PNG")));
    assert!(is_supported_image_path(&PathBuf::from("photo.JpEg")));
    assert!(is_supported_image_path(&PathBuf::from("vector.SVG")));
    assert!(!is_supported_image_path(&PathBuf::from("notes.txt")));
}

#[test]
fn image_preflight_reports_unsupported_extensions() {
    assert_eq!(
        preflight_image_path(&PathBuf::from("notes.txt")),
        ImagePreflight::UnsupportedExtension("txt".to_string())
    );
    assert_eq!(
        preflight_image_path(&PathBuf::from("README")),
        ImagePreflight::UnsupportedExtension(String::new())
    );
}

#[cfg(unix)]
#[test]
fn image_preflight_reports_permission_denied_when_file_cannot_be_read() {
    use std::os::unix::fs::PermissionsExt;

    let worktree = std::env::temp_dir().join(format!(
        "alas-image-permission-denied-{}",
        std::process::id()
    ));
    std::fs::create_dir_all(&worktree).expect("create temp worktree");
    let image = worktree.join("photo.png");
    std::fs::write(&image, b"not really a png").expect("write image path");
    let original_permissions = std::fs::metadata(&image)
        .expect("image metadata")
        .permissions();

    std::fs::set_permissions(&image, std::fs::Permissions::from_mode(0o000))
        .expect("remove read permission");
    let preflight = preflight_image_path(&image);
    std::fs::set_permissions(&image, original_permissions).expect("restore permissions");

    assert_eq!(preflight, ImagePreflight::PermissionDenied);

    let _ = std::fs::remove_file(image);
    let _ = std::fs::remove_dir(worktree);
}

#[test]
fn image_zoom_transitions_clamp_and_fit_resets() {
    assert_eq!(ImageZoom::Fit.zoom_in(), ImageZoom::Fixed(1.25));
    assert_eq!(ImageZoom::Fit.zoom_out(), ImageZoom::Fixed(0.75));
    assert_eq!(ImageZoom::Fixed(9.9).zoom_in(), ImageZoom::Fixed(10.0));
    assert_eq!(ImageZoom::Fixed(0.2).zoom_out(), ImageZoom::Fixed(0.1));
    assert_eq!(ImageZoom::Fit.label(), "Fit");
    assert_eq!(ImageZoom::Fixed(1.5).label(), "150%");
}

#[test]
fn opening_same_image_path_reuses_existing_tab_and_preserves_zoom() {
    let mut session = WorkspaceSession::default();
    let worktree = std::env::temp_dir().join(format!("alas-image-dedupe-{}", std::process::id()));
    std::fs::create_dir_all(&worktree).expect("create temp worktree");
    let image = worktree.join("photo.png");
    std::fs::write(&image, b"not really a png").expect("write image path");

    let first = session.open_or_focus_image_tab("repo", worktree.clone(), image.clone());
    session
        .set_image_zoom("repo", &worktree, first, ImageZoom::Fixed(2.0))
        .expect("set zoom");
    let second = session.open_or_focus_image_tab("repo", worktree.clone(), image.clone());

    assert_eq!(first, second);
    assert_eq!(session.tabs_for_worktree("repo", &worktree).len(), 1);
    let active = session.active_tab("repo", &worktree).expect("active tab");
    let image_state = active.image_tab_state().expect("image tab");
    assert_eq!(image_state.zoom, ImageZoom::Fixed(2.0));
    assert_eq!(image_state.preflight, ImagePreflight::Ready);

    let _ = std::fs::remove_file(image);
    let _ = std::fs::remove_dir(worktree);
}

#[test]
fn opening_distinct_images_creates_distinct_tabs() {
    let mut session = WorkspaceSession::default();
    let worktree = PathBuf::from("/repo/a");

    let first = session.open_or_focus_image_tab("repo", worktree.clone(), worktree.join("a.png"));
    let second = session.open_or_focus_image_tab("repo", worktree.clone(), worktree.join("b.png"));

    assert_ne!(first, second);
    assert_eq!(session.tabs_for_worktree("repo", &worktree).len(), 2);
    assert_eq!(
        session.active_tab("repo", &worktree).map(|tab| tab.kind),
        Some(WorkspaceTabKind::Image)
    );
}

#[test]
fn image_tab_does_not_expose_terminal_state() {
    let mut session = WorkspaceSession::default();
    let worktree = PathBuf::from("/repo/a");
    let tab_id = session.open_or_focus_image_tab("repo", worktree.clone(), worktree.join("a.png"));

    let active = session.active_tab("repo", &worktree).expect("active tab");
    assert_eq!(active.id, tab_id);
    assert!(active.terminal_tab_state().is_none());
    assert!(active.image_tab_state().is_some());
}
