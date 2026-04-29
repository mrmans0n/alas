use std::{
    path::{Path, PathBuf},
    time::Duration,
};

use crate::{
    app::{
        ActionId, AlasModel, InspectorPaneState, InspectorTab, RepositoryNode, TerminalTabId,
        TerminalTabKind, TerminalTabStatus, WorkspaceSession,
    },
    config::{
        AppConfig, AppConfigStore, AppRepository, CommandEntry, RepoConfigStore,
        ResolvedRepoConfig, repository_id_for_path,
    },
    git::{GitInspectorService, GitRunner, GitWorktreeService},
    project::FileTreeService,
    terminal::{
        CommandSpec, GhosttyTerminalBackend, TerminalBackend, TerminalGridSnapshot,
        TerminalScreenMode, TerminalSessionId, TerminalSessionRef, TerminalSessionRegistry,
        TerminalSize, TerminalStatus, TerminalViewport,
    },
    ui::{
        command_picker::render_command_picker,
        dialogs::{
            AddRepositoryDialogState, CommandSettingsDialogState, ConfirmPruneWorktreesDialog,
            ConfirmRemoveRepositoryDialog, ConfirmRemoveWorktreeDialog, CreateWorktreeDialogState,
            CreateWorktreeField,
        },
        inspector::render_project_inspector,
        sidebar::{SidebarMenuState, render_sidebar},
        terminal_pane::render_terminal_pane,
        theme::{APP_BG, DANGER, PANEL_BG, PANEL_BORDER, SUCCESS, TEXT, TEXT_MUTED},
        workspace::render_workspace,
    },
};
use gpui::{
    App, Application, ClipboardItem, Context, FocusHandle, IntoElement, KeyDownEvent,
    PathPromptOptions, PromptLevel, Render, ScrollDelta, ScrollWheelEvent, SharedString, Window,
    WindowOptions, div, prelude::*, px, rgb,
};
use indexmap::IndexMap;
use std::borrow::BorrowMut;

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
enum CommandSettingsField {
    DefaultName,
    EntryName(usize),
    EntryCommand(usize),
}

#[derive(Debug, Clone)]
struct CommandPickerState {
    repo_id: String,
    worktree_path: PathBuf,
    commands: IndexMap<String, CommandEntry>,
}

const INSPECTOR_FILE_TREE_MAX_DEPTH: usize = 3;

pub struct AlasShell {
    model: AlasModel,
    config: AppConfig,
    app_config_store: AppConfigStore,
    add_repository_dialog: Option<AddRepositoryDialogState>,
    create_worktree_dialog: Option<CreateWorktreeDialogState>,
    create_worktree_focus: FocusHandle,
    command_settings_dialog: Option<CommandSettingsDialogState>,
    command_settings_focus: FocusHandle,
    command_settings_active_field: CommandSettingsField,
    command_picker: Option<CommandPickerState>,
    sidebar_menu: Option<SidebarMenuState>,
    confirm_remove_repository_dialog: Option<ConfirmRemoveRepositoryDialog>,
    confirm_remove_worktree_dialog: Option<ConfirmRemoveWorktreeDialog>,
    confirm_prune_worktrees_dialog: Option<ConfirmPruneWorktreesDialog>,
    terminal_registry: TerminalSessionRegistry,
    terminal_backend: GhosttyTerminalBackend,
    workspace_session: WorkspaceSession,
    active_terminal_tab: Option<TerminalTabId>,
    active_terminal: Option<TerminalSessionRef>,
    terminal_error: Option<String>,
    terminal_focus: FocusHandle,
    terminal_size: Option<TerminalSize>,
    terminal_scroll_offset_rows: usize,
    inspector_state: InspectorPaneState,
    inspector_request_generation: u64,
}

impl AlasShell {
    fn new(cx: &mut Context<Self>) -> Self {
        let app_config_store =
            AppConfigStore::default_store().expect("failed to resolve app config store");
        let config = app_config_store.load().unwrap_or_default();

        let mut shell = Self {
            model: AlasModel::default(),
            config,
            app_config_store,
            add_repository_dialog: None,
            create_worktree_dialog: None,
            create_worktree_focus: cx.focus_handle(),
            command_settings_dialog: None,
            command_settings_focus: cx.focus_handle(),
            command_settings_active_field: CommandSettingsField::DefaultName,
            command_picker: None,
            sidebar_menu: None,
            confirm_remove_repository_dialog: None,
            confirm_remove_worktree_dialog: None,
            confirm_prune_worktrees_dialog: None,
            terminal_registry: TerminalSessionRegistry::default(),
            terminal_backend: GhosttyTerminalBackend::new(),
            workspace_session: WorkspaceSession::default(),
            active_terminal_tab: None,
            active_terminal: None,
            terminal_error: None,
            terminal_focus: cx.focus_handle(),
            terminal_size: None,
            terminal_scroll_offset_rows: 0,
            inspector_state: InspectorPaneState::default(),
            inspector_request_generation: 0,
        };
        shell.refresh_repositories();
        shell.start_terminal_refresh(cx);
        shell
    }

    fn start_terminal_refresh(&self, cx: &mut Context<Self>) {
        cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(100))
                    .await;
                if this
                    .update(cx, |shell, cx| {
                        if shell.active_terminal.is_some() {
                            cx.notify();
                        }
                    })
                    .is_err()
                {
                    break;
                }
            }
        })
        .detach();
    }

    fn terminal_snapshot(&mut self) -> Option<TerminalGridSnapshot> {
        let session = self.active_terminal.as_ref()?.clone();
        let rows = self.terminal_size.map_or(24, |size| size.rows);
        let viewport = TerminalViewport {
            scroll_offset_rows: self.terminal_scroll_offset_rows,
            visible_rows: rows,
        };

        match self
            .terminal_backend
            .snapshot(session.backend_session, viewport)
        {
            Ok(snapshot) => {
                self.terminal_scroll_offset_rows = match snapshot.screen_mode {
                    TerminalScreenMode::Main => snapshot.viewport.scroll_offset_rows,
                    TerminalScreenMode::Alternate => 0,
                };
                let _ = self.workspace_session.set_tab_scroll_offset(
                    &session.id.repo_id,
                    &session.id.worktree_path,
                    session.id.tab_id,
                    self.terminal_scroll_offset_rows,
                );
                let _ = self.workspace_session.set_tab_status(
                    &session.id.repo_id,
                    &session.id.worktree_path,
                    session.id.tab_id,
                    terminal_tab_status(snapshot.status),
                );
                self.terminal_error = None;
                Some(snapshot)
            }
            Err(error) => {
                let _ = self.workspace_session.set_tab_status(
                    &session.id.repo_id,
                    &session.id.worktree_path,
                    session.id.tab_id,
                    TerminalTabStatus::Failed,
                );
                self.terminal_error = Some(error.to_string());
                None
            }
        }
    }

    fn resize_active_terminal(&mut self, size: TerminalSize) {
        if self.terminal_size == Some(size) {
            return;
        }
        self.terminal_size = Some(size);
        if let Some(session) = self.active_terminal.as_ref() {
            if let Err(error) = self.terminal_backend.resize(session.backend_session, size) {
                self.terminal_error = Some(error.to_string());
            }
        }
    }

    fn retry_active_terminal(&mut self, cx: &mut Context<Self>) {
        let Some(selected) = self.model.selected_worktree().cloned() else {
            return;
        };
        self.select_worktree(selected.repo_id, selected.path, cx);
    }

    fn restart_active_terminal(&mut self) {
        self.terminal_scroll_offset_rows = 0;
        let Some(active) = self.active_terminal.as_mut() else {
            return;
        };
        match self.terminal_backend.restart(active.backend_session) {
            Ok(session) => {
                if let Some(size) = self.terminal_size {
                    if let Err(error) = self.terminal_backend.resize(session, size) {
                        self.terminal_error = Some(error.to_string());
                        return;
                    }
                }
                active.backend_session = session;
                self.terminal_registry
                    .replace_backend_session(&active.id, session);
                let _ = self.workspace_session.set_tab_backend_session(
                    &active.id.repo_id,
                    &active.id.worktree_path,
                    active.id.tab_id,
                    Some(session),
                );
                let _ = self.workspace_session.set_tab_status(
                    &active.id.repo_id,
                    &active.id.worktree_path,
                    active.id.tab_id,
                    TerminalTabStatus::Running,
                );
                self.terminal_error = None;
            }
            Err(error) => {
                if let Some(active) = self.active_terminal.as_ref() {
                    let _ = self.workspace_session.set_tab_status(
                        &active.id.repo_id,
                        &active.id.worktree_path,
                        active.id.tab_id,
                        TerminalTabStatus::Failed,
                    );
                }
                self.terminal_error = Some(error.to_string());
            }
        }
    }

    fn write_terminal_input(&mut self, event: &KeyDownEvent) -> bool {
        let Some(session) = self.active_terminal.as_ref() else {
            return false;
        };
        let Some(bytes) = terminal_input_bytes(event) else {
            return false;
        };

        match self
            .terminal_backend
            .write_input(session.backend_session, &bytes)
        {
            Ok(()) => true,
            Err(error) => {
                self.terminal_error = Some(error.to_string());
                true
            }
        }
    }

    fn scroll_terminal(
        &mut self,
        event: &ScrollWheelEvent,
        screen_mode: TerminalScreenMode,
        scrollback_rows: usize,
    ) -> bool {
        if self.active_terminal.is_none() {
            return false;
        }

        if screen_mode == TerminalScreenMode::Alternate {
            // Alternate-screen apps often expect wheel input as terminal mouse
            // events. Alas does not translate GPUI wheel events into PTY mouse
            // reports yet, so keep the main-screen scrollback offset pinned.
            let changed = self.terminal_scroll_offset_rows != 0;
            self.terminal_scroll_offset_rows = 0;
            return changed;
        }

        let rows = terminal_scroll_rows(event);
        if rows == 0 {
            return false;
        }

        let next_offset = if rows > 0 {
            self.terminal_scroll_offset_rows
                .saturating_add(rows.unsigned_abs())
        } else {
            self.terminal_scroll_offset_rows
                .saturating_sub(rows.unsigned_abs())
        }
        .min(scrollback_rows);

        if next_offset == self.terminal_scroll_offset_rows {
            return false;
        }

        self.terminal_scroll_offset_rows = next_offset;
        true
    }

    fn open_add_repository_dialog(&mut self, cx: &mut Context<Self>) {
        self.add_repository_dialog = Some(AddRepositoryDialogState::default());
        let receiver = cx.prompt_for_paths(PathPromptOptions {
            files: false,
            directories: true,
            multiple: false,
            prompt: Some("Select a Git repository".into()),
        });

        cx.spawn(async move |this, cx| match receiver.await {
            Ok(Ok(Some(paths))) => {
                if let Some(path) = paths.into_iter().next() {
                    this.update(cx, |shell, cx| {
                        shell.set_add_repository_path(path);
                        shell.add_repository_from_dialog();
                        cx.notify();
                    })
                    .ok();
                }
            }
            Ok(Ok(None)) => {
                this.update(cx, |shell, cx| {
                    shell.add_repository_dialog = None;
                    cx.notify();
                })
                .ok();
            }
            Ok(Err(error)) => {
                this.update(cx, |shell, cx| {
                    shell.set_add_repository_error(error.to_string());
                    cx.notify();
                })
                .ok();
            }
            Err(error) => {
                this.update(cx, |shell, cx| {
                    shell.set_add_repository_error(error.to_string());
                    cx.notify();
                })
                .ok();
            }
        })
        .detach();

        cx.notify();
    }

    fn set_add_repository_path(&mut self, path: PathBuf) {
        let dialog = self
            .add_repository_dialog
            .get_or_insert_with(AddRepositoryDialogState::default);
        dialog.path_text = path.display().to_string();
        dialog.error = None;
    }

    fn add_repository_from_dialog(&mut self) {
        let Some(path) = self
            .add_repository_dialog
            .as_ref()
            .and_then(AddRepositoryDialogState::selected_path)
        else {
            self.set_add_repository_error("Repository path is required");
            return;
        };

        let service = GitWorktreeService::new(GitRunner::new());
        if let Err(error) = service.validate_repository(&path) {
            self.set_add_repository_error(error.to_string());
            return;
        }

        let id = repository_id_for_path(&path);
        let mut next_config = self.config.clone();
        if !next_config
            .repositories
            .iter()
            .any(|repository| repository.id == id)
        {
            next_config.repositories.push(AppRepository {
                id,
                path: path.clone(),
                name: path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .map(str::to_string),
            });
        }

        if let Err(error) = self.app_config_store.save(&next_config) {
            self.set_add_repository_error(error.to_string());
            return;
        }

        self.config = next_config;
        self.add_repository_dialog = None;
        self.refresh_repositories();
    }

    fn set_add_repository_error(&mut self, error: impl Into<String>) {
        let dialog = self
            .add_repository_dialog
            .get_or_insert_with(AddRepositoryDialogState::default);
        dialog.error = Some(error.into());
    }

    fn open_create_worktree_dialog(&mut self, repo_id: String, cx: &mut Context<Self>) {
        let Some(repo_path) = self.repository_path(&repo_id) else {
            self.create_worktree_dialog = Some(CreateWorktreeDialogState {
                repo_id,
                base_ref: "HEAD".to_string(),
                branch_name: "new-worktree".to_string(),
                target_path_text: String::new(),
                error: Some("Repository not found".to_string()),
                active_field: CreateWorktreeField::BaseRef,
            });
            cx.notify();
            return;
        };

        let suggested_name = "new-worktree";
        let target_path_text = repo_path
            .parent()
            .map(|parent| parent.join(suggested_name).display().to_string())
            .unwrap_or_else(|| suggested_name.to_string());
        self.create_worktree_dialog = Some(CreateWorktreeDialogState {
            repo_id,
            base_ref: "HEAD".to_string(),
            branch_name: suggested_name.to_string(),
            target_path_text,
            error: None,
            active_field: CreateWorktreeField::BaseRef,
        });
        cx.notify();
    }

    fn set_create_worktree_field(&mut self, field: CreateWorktreeField) {
        if let Some(dialog) = self.create_worktree_dialog.as_mut() {
            dialog.active_field = field;
            dialog.error = None;
        }
    }

    fn edit_create_worktree_field(&mut self, event: &KeyDownEvent, cx: &mut Context<Self>) -> bool {
        if self.create_worktree_dialog.is_none() {
            return false;
        }

        match event.keystroke.key.as_str() {
            "escape" => {
                self.create_worktree_dialog = None;
                return true;
            }
            "enter" => {
                self.create_worktree_from_dialog(cx);
                return true;
            }
            "tab" => {
                if let Some(dialog) = self.create_worktree_dialog.as_mut() {
                    dialog.active_field = match dialog.active_field {
                        CreateWorktreeField::BaseRef => CreateWorktreeField::BranchName,
                        CreateWorktreeField::BranchName => CreateWorktreeField::TargetPath,
                        CreateWorktreeField::TargetPath => CreateWorktreeField::BaseRef,
                    };
                    dialog.error = None;
                }
                return true;
            }
            "backspace" => {
                if let Some(text) = self.active_create_worktree_text_mut() {
                    text.pop();
                }
                if let Some(dialog) = self.create_worktree_dialog.as_mut() {
                    dialog.error = None;
                }
                return true;
            }
            _ => {}
        }

        if event.keystroke.modifiers.control || event.keystroke.modifiers.platform {
            return false;
        }
        if let Some(text) = event.keystroke.key_char.as_deref() {
            if let Some(active_text) = self.active_create_worktree_text_mut() {
                active_text.push_str(text);
            }
            if let Some(dialog) = self.create_worktree_dialog.as_mut() {
                dialog.error = None;
            }
            return true;
        }

        false
    }

    fn active_create_worktree_text_mut(&mut self) -> Option<&mut String> {
        let dialog = self.create_worktree_dialog.as_mut()?;
        Some(match dialog.active_field {
            CreateWorktreeField::BaseRef => &mut dialog.base_ref,
            CreateWorktreeField::BranchName => &mut dialog.branch_name,
            CreateWorktreeField::TargetPath => &mut dialog.target_path_text,
        })
    }

    fn close_create_worktree_dialog(&mut self) {
        self.create_worktree_dialog = None;
    }

    fn open_command_settings_dialog(&mut self, repo_id: String, cx: &mut Context<Self>) {
        let Some(repo) = self
            .config
            .repositories
            .iter()
            .find(|repository| repository.id == repo_id)
        else {
            self.command_settings_dialog = Some(CommandSettingsDialogState {
                repo_id,
                default_name: "shell".to_string(),
                entries: vec![("shell".to_string(), "$SHELL".to_string())],
                error: Some("Repository not found".to_string()),
            });
            cx.notify();
            return;
        };

        let repo_file = RepoConfigStore::for_repo(&repo.path).load().ok().flatten();
        let resolved = ResolvedRepoConfig::resolve(
            repo.id.clone(),
            repo.path.clone(),
            repo.name.clone(),
            &self.config,
            repo_file,
        );
        self.command_settings_dialog = Some(CommandSettingsDialogState {
            repo_id,
            default_name: resolved.default_command_name().to_string(),
            entries: resolved
                .commands()
                .iter()
                .map(|(name, entry)| (name.clone(), entry.command.clone()))
                .collect(),
            error: None,
        });
        self.command_settings_active_field = CommandSettingsField::DefaultName;
        cx.notify();
    }

    fn set_command_settings_field(&mut self, field: CommandSettingsField) {
        self.command_settings_active_field = field;
        if let Some(dialog) = self.command_settings_dialog.as_mut() {
            dialog.error = None;
        }
    }

    fn edit_command_settings_field(&mut self, event: &KeyDownEvent) -> bool {
        if self.command_settings_dialog.is_none() {
            return false;
        }

        match event.keystroke.key.as_str() {
            "escape" => {
                self.command_settings_dialog = None;
                return true;
            }
            "enter" => {
                self.save_command_settings_from_dialog();
                return true;
            }
            "tab" => {
                self.advance_command_settings_field();
                return true;
            }
            "backspace" => {
                if let Some(text) = self.active_command_settings_text_mut() {
                    text.pop();
                }
                if let Some(dialog) = self.command_settings_dialog.as_mut() {
                    dialog.error = None;
                }
                return true;
            }
            _ => {}
        }

        if event.keystroke.modifiers.control || event.keystroke.modifiers.platform {
            return false;
        }
        if let Some(text) = event.keystroke.key_char.as_deref() {
            if let Some(active_text) = self.active_command_settings_text_mut() {
                active_text.push_str(text);
            }
            if let Some(dialog) = self.command_settings_dialog.as_mut() {
                dialog.error = None;
            }
            return true;
        }

        false
    }

    fn active_command_settings_text_mut(&mut self) -> Option<&mut String> {
        let dialog = self.command_settings_dialog.as_mut()?;
        match self.command_settings_active_field {
            CommandSettingsField::DefaultName => Some(&mut dialog.default_name),
            CommandSettingsField::EntryName(index) => {
                dialog.entries.get_mut(index).map(|entry| &mut entry.0)
            }
            CommandSettingsField::EntryCommand(index) => {
                dialog.entries.get_mut(index).map(|entry| &mut entry.1)
            }
        }
    }

    fn advance_command_settings_field(&mut self) {
        let entry_count = self
            .command_settings_dialog
            .as_ref()
            .map(|dialog| dialog.entries.len())
            .unwrap_or_default();
        self.command_settings_active_field = match self.command_settings_active_field {
            CommandSettingsField::DefaultName if entry_count > 0 => {
                CommandSettingsField::EntryName(0)
            }
            CommandSettingsField::EntryName(index) => CommandSettingsField::EntryCommand(index),
            CommandSettingsField::EntryCommand(index) if index + 1 < entry_count => {
                CommandSettingsField::EntryName(index + 1)
            }
            _ => CommandSettingsField::DefaultName,
        };
        if let Some(dialog) = self.command_settings_dialog.as_mut() {
            dialog.error = None;
        }
    }

    fn add_command_settings_entry(&mut self) {
        if let Some(dialog) = self.command_settings_dialog.as_mut() {
            dialog.entries.push(("new".to_string(), String::new()));
            self.command_settings_active_field =
                CommandSettingsField::EntryName(dialog.entries.len() - 1);
            dialog.error = None;
        }
    }

    fn remove_command_settings_entry(&mut self, index: usize) {
        if let Some(dialog) = self.command_settings_dialog.as_mut() {
            if dialog.entries.len() > 1 && index < dialog.entries.len() {
                dialog.entries.remove(index);
                self.command_settings_active_field = CommandSettingsField::DefaultName;
                dialog.error = None;
            }
        }
    }

    fn close_command_settings_dialog(&mut self) {
        self.command_settings_dialog = None;
    }

    fn save_command_settings_from_dialog(&mut self) {
        let Some(dialog) = self.command_settings_dialog.clone() else {
            return;
        };
        let Some(repo_path) = self.repository_path(&dialog.repo_id) else {
            self.set_command_settings_error("Repository not found");
            return;
        };
        let repo_config = match dialog.to_repo_config() {
            Ok(config) => config,
            Err(error) => {
                self.set_command_settings_error(error);
                return;
            }
        };
        if let Err(error) = RepoConfigStore::for_repo(repo_path).save(&repo_config) {
            self.set_command_settings_error(error.to_string());
            return;
        }
        self.command_settings_dialog = None;
    }

    fn set_command_settings_error(&mut self, error: impl Into<String>) {
        if let Some(dialog) = self.command_settings_dialog.as_mut() {
            dialog.error = Some(error.into());
        }
    }

    fn create_worktree_from_dialog(&mut self, cx: &mut Context<Self>) {
        let Some(dialog) = self.create_worktree_dialog.clone() else {
            return;
        };
        let target_path = match dialog.validate() {
            Ok(path) => path,
            Err(error) => {
                self.set_create_worktree_error(error);
                return;
            }
        };
        let Some(repo_path) = self.repository_path(&dialog.repo_id) else {
            self.set_create_worktree_error("Repository not found");
            return;
        };

        let target_path = if target_path.is_absolute() {
            target_path
        } else {
            repo_path.join(target_path)
        };

        let service = GitWorktreeService::new(GitRunner::new());
        if let Err(error) = service.create_worktree(
            &repo_path,
            dialog.base_ref.trim(),
            dialog.branch_name.trim(),
            &target_path,
        ) {
            self.set_create_worktree_error(error.to_string());
            return;
        }

        self.refresh_repositories();
        self.create_worktree_dialog = None;
        self.select_worktree(dialog.repo_id.clone(), target_path, cx);
    }

    fn select_worktree(&mut self, repo_id: String, path: PathBuf, cx: &mut Context<Self>) {
        self.model.select_worktree(repo_id.clone(), path.clone());
        self.command_picker = None;
        self.sidebar_menu = None;
        self.terminal_scroll_offset_rows = 0;
        self.inspector_state.clear_for_new_worktree();
        self.inspector_request_generation = self.inspector_request_generation.wrapping_add(1);
        let inspector_request_generation = self.inspector_request_generation;
        self.refresh_git_inspector(
            repo_id.clone(),
            path.clone(),
            inspector_request_generation,
            cx,
        );
        self.refresh_file_tree(
            repo_id.clone(),
            path.clone(),
            inspector_request_generation,
            cx,
        );

        let default_command = self.resolve_default_command(&repo_id, path.clone());
        let tab_id = self.workspace_session.ensure_default_terminal_tab(
            &repo_id,
            path.clone(),
            default_command,
        );
        self.start_or_reuse_terminal_tab(repo_id, path, tab_id);
    }

    fn select_terminal_tab(&mut self, tab_id: TerminalTabId) {
        let Some(selected) = self.model.selected_worktree().cloned() else {
            return;
        };

        if let Err(error) =
            self.workspace_session
                .set_active_tab(&selected.repo_id, &selected.path, tab_id)
        {
            self.terminal_error = Some(error.to_string());
            return;
        }

        self.start_or_reuse_terminal_tab(selected.repo_id, selected.path, tab_id);
    }

    fn start_or_reuse_terminal_tab(
        &mut self,
        repo_id: String,
        path: PathBuf,
        tab_id: TerminalTabId,
    ) {
        let Some(tab) = self.workspace_session.active_tab(&repo_id, &path).cloned() else {
            self.active_terminal = None;
            self.active_terminal_tab = None;
            self.terminal_error = Some("No active terminal tab for selected worktree".to_string());
            return;
        };

        let id = TerminalSessionId::new(repo_id, path, tab_id);
        self.active_terminal_tab = Some(tab_id);
        self.terminal_scroll_offset_rows = tab.scroll_offset_rows;

        match self.terminal_registry.get_or_start(
            id.clone(),
            tab.command.clone(),
            &mut self.terminal_backend,
        ) {
            Ok(session) => {
                if let Some(size) = self.terminal_size {
                    if let Err(error) = self.terminal_backend.resize(session.backend_session, size)
                    {
                        self.active_terminal = None;
                        let _ = self.workspace_session.set_tab_status(
                            &session.id.repo_id,
                            &session.id.worktree_path,
                            session.id.tab_id,
                            TerminalTabStatus::Failed,
                        );
                        self.terminal_error = Some(error.to_string());
                        return;
                    }
                }
                let _ = self.workspace_session.set_tab_backend_session(
                    &session.id.repo_id,
                    &session.id.worktree_path,
                    session.id.tab_id,
                    Some(session.backend_session),
                );
                let _ = self.workspace_session.set_tab_status(
                    &session.id.repo_id,
                    &session.id.worktree_path,
                    session.id.tab_id,
                    TerminalTabStatus::Running,
                );
                self.active_terminal = Some(session);
                self.terminal_error = None;
            }
            Err(error) => {
                self.active_terminal = None;
                let _ = self.workspace_session.set_tab_status(
                    &id.repo_id,
                    &id.worktree_path,
                    id.tab_id,
                    TerminalTabStatus::Failed,
                );
                self.terminal_error = Some(error.to_string());
            }
        }
    }

    fn open_command_picker(&mut self, cx: &mut Context<Self>) {
        let Some(selected) = self.model.selected_worktree().cloned() else {
            return;
        };
        let Some(resolved) = self.resolved_repo_config(&selected.repo_id) else {
            self.terminal_error = Some("Repository not found".to_string());
            return;
        };

        self.command_picker = Some(CommandPickerState {
            repo_id: selected.repo_id,
            worktree_path: selected.path,
            commands: resolved.commands().clone(),
        });
        cx.notify();
    }

    fn close_command_picker(&mut self) {
        self.command_picker = None;
    }

    fn open_sidebar_menu(&mut self, menu: SidebarMenuState) {
        if self.sidebar_menu.as_ref() == Some(&menu) {
            self.sidebar_menu = None;
        } else {
            self.sidebar_menu = Some(menu);
        }
    }

    fn close_sidebar_menu(&mut self) {
        self.sidebar_menu = None;
    }

    fn handle_sidebar_menu_action(
        &mut self,
        action_id: ActionId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(menu) = self.sidebar_menu.take() else {
            return;
        };

        match action_id {
            ActionId::RemoveRepository => {
                let repo_name = self.repository_name(&menu.repo_id);
                self.confirm_remove_repository(menu.repo_id, repo_name, window, cx);
            }
            ActionId::CreateWorktree => self.open_create_worktree_dialog(menu.repo_id, cx),
            ActionId::CommandSettings => self.open_command_settings_dialog(menu.repo_id, cx),
            ActionId::PruneWorktrees => {
                let repo_name = self.repository_name(&menu.repo_id);
                self.confirm_prune_worktrees(menu.repo_id, repo_name, window, cx);
            }
            ActionId::ToggleArchivedWorktrees => {
                let show_archived = !self.repository_show_archived(&menu.repo_id);
                self.set_show_archived(&menu.repo_id, show_archived);
            }
            ActionId::ArchiveWorktree => {
                if let Some(path) = menu.worktree_path {
                    if let Err(error) = self.archive_worktree(&menu.repo_id, path) {
                        self.set_add_repository_error(error.to_string());
                    }
                }
            }
            ActionId::UnarchiveWorktree => {
                if let Some(path) = menu.worktree_path {
                    if let Err(error) = self.unarchive_worktree(&menu.repo_id, &path) {
                        self.set_add_repository_error(error.to_string());
                    }
                }
            }
            ActionId::RemoveWorktree => {
                if let Some(path) = menu.worktree_path {
                    let is_main = self.worktree_is_main(&menu.repo_id, &path);
                    self.confirm_remove_worktree(menu.repo_id, path, is_main, window, cx);
                }
            }
            ActionId::SelectWorktree => {
                if let Some(path) = menu.worktree_path {
                    self.select_worktree(menu.repo_id, path, cx);
                }
            }
            ActionId::OpenPath => {
                if let Some(path) = menu.worktree_path {
                    let app: &mut App = BorrowMut::borrow_mut(cx);
                    app.open_with_system(&path);
                }
            }
            ActionId::CopyPath => {
                if let Some(path) = menu.worktree_path {
                    let app: &mut App = BorrowMut::borrow_mut(cx);
                    app.write_to_clipboard(ClipboardItem::new_string(path.display().to_string()));
                }
            }
            ActionId::AddRepository => self.open_add_repository_dialog(cx),
        }

        cx.notify();
    }

    fn handle_command_picker_key_down(&mut self, event: &KeyDownEvent) -> bool {
        if self.command_picker.is_none() {
            return false;
        }

        if event.keystroke.key == "escape" {
            self.close_command_picker();
        }
        true
    }

    fn create_command_tab_from_picker(&mut self, name: String, command: String) {
        let Some(picker) = self.command_picker.take() else {
            return;
        };

        let command = CommandSpec::shell_command(command, picker.worktree_path.clone());
        let tab_id = self.workspace_session.create_terminal_tab(
            &picker.repo_id,
            picker.worktree_path.clone(),
            name,
            TerminalTabKind::Command,
            command,
        );
        self.start_or_reuse_terminal_tab(picker.repo_id, picker.worktree_path, tab_id);
    }

    fn refresh_git_inspector(
        &mut self,
        repo_id: String,
        path: PathBuf,
        request_generation: u64,
        cx: &mut Context<Self>,
    ) {
        let selected_repo_id = repo_id;
        let selected_path = path.clone();
        let task = cx.background_executor().spawn(async move {
            GitInspectorService::new(GitRunner::new())
                .inspect_changes(&path)
                .map_err(|error| error.to_string())
        });

        cx.spawn(async move |this, cx| {
            let result = task.await;
            this.update(cx, |shell, cx| {
                let is_current_selection =
                    shell.model.selected_worktree().is_some_and(|selected| {
                        selected.repo_id == selected_repo_id && selected.path == selected_path
                    });
                if !is_current_selection || shell.inspector_request_generation != request_generation
                {
                    return;
                }

                match result {
                    Ok(state) => {
                        shell.inspector_state.set_changes(state);
                    }
                    Err(error) => {
                        shell.inspector_state.set_changes_error(error);
                    }
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    fn refresh_file_tree(
        &mut self,
        repo_id: String,
        path: PathBuf,
        request_generation: u64,
        cx: &mut Context<Self>,
    ) {
        let selected_repo_id = repo_id;
        let selected_path = path.clone();
        let task = cx.background_executor().spawn(async move {
            FileTreeService::new()
                .load(&path, INSPECTOR_FILE_TREE_MAX_DEPTH)
                .map_err(|error| error.to_string())
        });

        cx.spawn(async move |this, cx| {
            let result = task.await;
            this.update(cx, |shell, cx| {
                let is_current_selection =
                    shell.model.selected_worktree().is_some_and(|selected| {
                        selected.repo_id == selected_repo_id && selected.path == selected_path
                    });
                if !is_current_selection || shell.inspector_request_generation != request_generation
                {
                    return;
                }

                match result {
                    Ok(files) => {
                        shell.inspector_state.set_files(files);
                    }
                    Err(error) => {
                        shell.inspector_state.set_files_error(error);
                    }
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    fn resolve_default_command(&self, repo_id: &str, worktree_path: PathBuf) -> CommandSpec {
        let Some(resolved) = self.resolved_repo_config(repo_id) else {
            return CommandSpec::shell_command("$SHELL", worktree_path);
        };

        CommandSpec::shell_command(resolved.default_command().command.clone(), worktree_path)
    }

    fn resolved_repo_config(&self, repo_id: &str) -> Option<ResolvedRepoConfig> {
        let repo = self
            .config
            .repositories
            .iter()
            .find(|repository| repository.id == repo_id)?;

        let repo_file = RepoConfigStore::for_repo(&repo.path).load().ok().flatten();
        Some(ResolvedRepoConfig::resolve(
            repo.id.clone(),
            repo.path.clone(),
            repo.name.clone(),
            &self.config,
            repo_file,
        ))
    }

    fn set_create_worktree_error(&mut self, error: impl Into<String>) {
        if let Some(dialog) = self.create_worktree_dialog.as_mut() {
            dialog.error = Some(error.into());
        }
    }

    fn repository_path(&self, repo_id: &str) -> Option<PathBuf> {
        self.config
            .repositories
            .iter()
            .find(|repository| repository.id == repo_id)
            .map(|repository| repository.path.clone())
    }

    fn repository_name(&self, repo_id: &str) -> String {
        self.model
            .repositories()
            .iter()
            .find(|repository| repository.id == repo_id)
            .map(|repository| repository.name.clone())
            .unwrap_or_else(|| repo_id.to_string())
    }

    fn repository_show_archived(&self, repo_id: &str) -> bool {
        self.model
            .repositories()
            .iter()
            .find(|repository| repository.id == repo_id)
            .is_some_and(|repository| repository.show_archived)
    }

    fn worktree_is_main(&self, repo_id: &str, path: &Path) -> bool {
        self.model
            .repositories()
            .iter()
            .find(|repository| repository.id == repo_id)
            .and_then(|repository| {
                repository
                    .worktrees
                    .iter()
                    .find(|worktree| worktree.path == path)
            })
            .is_some_and(|worktree| worktree.kind == crate::git::WorktreeKind::Main)
    }

    fn confirm_remove_repository(
        &mut self,
        repo_id: String,
        repo_name: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.confirm_remove_repository_dialog = Some(ConfirmRemoveRepositoryDialog {
            repo_id: repo_id.clone(),
            repo_name: repo_name.clone(),
        });

        let answer = window.prompt(
            PromptLevel::Warning,
            &format!("Remove {repo_name} from Alas?"),
            Some("This removes the repository from Alas only. It does not delete repository files or worktrees."),
            &["Remove", "Cancel"],
            cx,
        );

        cx.spawn(async move |this, cx| {
            let should_remove = answer.await.unwrap_or(1) == 0;
            this.update(cx, |shell, cx| {
                if should_remove {
                    if let Err(error) = shell.remove_repository_from_alas(&repo_id) {
                        shell.set_add_repository_error(error.to_string());
                    }
                }
                shell.confirm_remove_repository_dialog = None;
                cx.notify();
            })
            .ok();
        })
        .detach();

        cx.notify();
    }

    fn remove_repository_from_alas(&mut self, repo_id: &str) -> anyhow::Result<()> {
        let mut next_config = self.config.clone();
        next_config
            .repositories
            .retain(|repository| repository.id != repo_id);
        next_config.archived_worktrees.shift_remove(repo_id);

        self.app_config_store.save(&next_config)?;
        self.config = next_config;
        self.cleanup_repository_sessions(repo_id);
        self.workspace_session.remove_repository(repo_id);

        if self
            .model
            .selected_worktree()
            .is_some_and(|selected| selected.repo_id == repo_id)
        {
            self.clear_selection_and_active_terminal();
        }

        self.refresh_repositories();
        Ok(())
    }

    fn confirm_remove_worktree(
        &mut self,
        repo_id: String,
        path: PathBuf,
        is_main: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.confirm_remove_worktree_dialog = Some(ConfirmRemoveWorktreeDialog {
            repo_id: repo_id.clone(),
            path: path.clone(),
            is_main,
        });

        if is_main {
            self.set_add_repository_error(format!(
                "Cannot remove main worktree: {}",
                path.display()
            ));
            self.confirm_remove_worktree_dialog = None;
            cx.notify();
            return;
        }

        let path_label = path.display().to_string();
        let answer = window.prompt(
            PromptLevel::Warning,
            "Remove Git worktree?",
            Some(&format!(
                "This will run git worktree remove for the exact path:\n{path_label}"
            )),
            &["Remove", "Cancel"],
            cx,
        );

        cx.spawn(async move |this, cx| {
            let should_remove = answer.await.unwrap_or(1) == 0;
            this.update(cx, |shell, cx| {
                if should_remove {
                    if let Err(error) = shell.remove_worktree(&repo_id, &path) {
                        shell.set_add_repository_error(error.to_string());
                    }
                }
                shell.confirm_remove_worktree_dialog = None;
                cx.notify();
            })
            .ok();
        })
        .detach();

        cx.notify();
    }

    fn remove_worktree(&mut self, repo_id: &str, path: &Path) -> anyhow::Result<()> {
        let repo_path = self
            .repository_path(repo_id)
            .ok_or_else(|| anyhow::anyhow!("Repository not found"))?;

        GitWorktreeService::new(GitRunner::new()).remove_worktree(&repo_path, path)?;
        self.cleanup_worktree_sessions(repo_id, path);
        self.workspace_session.remove_worktree(repo_id, path);

        if self
            .model
            .selected_worktree()
            .is_some_and(|selected| selected.repo_id == repo_id && selected.path == path)
        {
            self.clear_selection_and_active_terminal();
        }

        self.refresh_repositories();
        Ok(())
    }

    fn confirm_prune_worktrees(
        &mut self,
        repo_id: String,
        repo_name: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.confirm_prune_worktrees_dialog = Some(ConfirmPruneWorktreesDialog {
            repo_id: repo_id.clone(),
            repo_name: repo_name.clone(),
        });

        let answer = window.prompt(
            PromptLevel::Warning,
            &format!("Prune stale worktree metadata for {repo_name}?"),
            Some("This runs git worktree prune. It only prunes stale worktree metadata for worktrees that no longer exist."),
            &["Prune", "Cancel"],
            cx,
        );

        cx.spawn(async move |this, cx| {
            let should_prune = answer.await.unwrap_or(1) == 0;
            this.update(cx, |shell, cx| {
                if should_prune {
                    if let Err(error) = shell.prune_worktrees(&repo_id) {
                        shell.set_add_repository_error(error.to_string());
                    }
                }
                shell.confirm_prune_worktrees_dialog = None;
                cx.notify();
            })
            .ok();
        })
        .detach();

        cx.notify();
    }

    fn prune_worktrees(&mut self, repo_id: &str) -> anyhow::Result<()> {
        let repo_path = self
            .repository_path(repo_id)
            .ok_or_else(|| anyhow::anyhow!("Repository not found"))?;

        GitWorktreeService::new(GitRunner::new()).prune_worktrees(&repo_path)?;
        self.refresh_repositories();
        Ok(())
    }

    fn set_show_archived(&mut self, repo_id: &str, show: bool) {
        self.model.set_show_archived(repo_id, show);
    }

    fn archive_worktree(&mut self, repo_id: &str, path: PathBuf) -> anyhow::Result<()> {
        let mut next_config = self.config.clone();
        next_config.archive_worktree(repo_id.to_string(), path);
        self.app_config_store.save(&next_config)?;
        self.config = next_config;
        self.refresh_repositories();
        Ok(())
    }

    fn unarchive_worktree(&mut self, repo_id: &str, path: &Path) -> anyhow::Result<()> {
        let mut next_config = self.config.clone();
        next_config.unarchive_worktree(repo_id, path);
        self.app_config_store.save(&next_config)?;
        self.config = next_config;
        self.refresh_repositories();
        Ok(())
    }

    fn cleanup_repository_sessions(&mut self, repo_id: &str) {
        let sessions = self
            .terminal_registry
            .remove_sessions_for_repository(repo_id);
        self.stop_terminal_sessions(sessions);
    }

    fn cleanup_worktree_sessions(&mut self, repo_id: &str, path: &Path) {
        let sessions = self
            .terminal_registry
            .remove_sessions_for_worktree(repo_id, path);
        self.stop_terminal_sessions(sessions);
    }

    fn stop_terminal_sessions(&mut self, sessions: Vec<TerminalSessionRef>) {
        let active_backend_session = self
            .active_terminal
            .as_ref()
            .map(|session| session.backend_session);
        let removed_active_session = sessions
            .iter()
            .any(|session| Some(session.backend_session) == active_backend_session);

        for session in sessions {
            if let Err(error) = self.terminal_backend.stop(session.backend_session) {
                self.terminal_error = Some(error.to_string());
            }
        }

        if removed_active_session {
            self.active_terminal = None;
            self.active_terminal_tab = None;
            self.terminal_scroll_offset_rows = 0;
        }
    }

    fn clear_selection_and_active_terminal(&mut self) {
        self.model.clear_selection();
        self.command_picker = None;
        self.sidebar_menu = None;
        self.active_terminal_tab = None;
        self.active_terminal = None;
        self.terminal_error = None;
        self.terminal_scroll_offset_rows = 0;
        self.inspector_state.clear_for_new_worktree();
    }

    fn refresh_repositories(&mut self) {
        let runner = GitRunner::new();
        let service = GitWorktreeService::new(runner);
        let mut nodes = Vec::new();

        for repository in &self.config.repositories {
            match service.list_worktrees(&repository.path) {
                Ok(worktrees) => nodes.extend(AlasModel::repository_nodes_from_discovery(
                    &self.config,
                    &repository.id,
                    worktrees,
                )),
                Err(_) => nodes.push(RepositoryNode {
                    id: repository.id.clone(),
                    name: repository
                        .name
                        .clone()
                        .unwrap_or_else(|| infer_repository_name(&repository.path)),
                    path: repository.path.clone(),
                    worktrees: Vec::new(),
                    show_archived: false,
                    unavailable: true,
                }),
            }
        }

        self.model.set_repositories(nodes);
    }

    fn add_repository_error(&self) -> Option<&str> {
        self.add_repository_dialog
            .as_ref()
            .and_then(|dialog| dialog.error.as_deref())
    }
}

fn terminal_tab_status(status: TerminalStatus) -> TerminalTabStatus {
    match status {
        TerminalStatus::Running => TerminalTabStatus::Running,
        TerminalStatus::Exited(status) => TerminalTabStatus::Exited(status),
        TerminalStatus::Failed => TerminalTabStatus::Failed,
    }
}

fn terminal_scroll_rows(event: &ScrollWheelEvent) -> isize {
    let rows = match &event.delta {
        ScrollDelta::Lines(delta) => f64::from(delta.y),
        ScrollDelta::Pixels(delta) => delta.y.to_f64() / 18.0,
    };

    if rows == 0.0 {
        return 0;
    }

    let rounded = rows.round() as isize;
    if rounded == 0 {
        rows.signum() as isize
    } else {
        rounded
    }
}

fn terminal_input_bytes(event: &KeyDownEvent) -> Option<Vec<u8>> {
    let keystroke = &event.keystroke;

    if keystroke.modifiers.platform || keystroke.modifiers.alt {
        return None;
    }

    if keystroke.modifiers.control {
        let key = keystroke.key.to_ascii_lowercase();
        if key.len() == 1 {
            let byte = key.as_bytes()[0];
            if byte.is_ascii_lowercase() {
                return Some(vec![byte - b'a' + 1]);
            }
        }
        return None;
    }

    // GPUI 0.2 only exposes key-down events here. This covers common terminal
    // input; IME/composition and full function-key handling need a richer input
    // handler if Alas adopts one later.
    match keystroke.key.as_str() {
        "enter" => Some(b"\r".to_vec()),
        "backspace" => Some(vec![0x7f]),
        "tab" => Some(b"\t".to_vec()),
        "escape" => Some(vec![0x1b]),
        "up" => Some(b"\x1b[A".to_vec()),
        "down" => Some(b"\x1b[B".to_vec()),
        "right" => Some(b"\x1b[C".to_vec()),
        "left" => Some(b"\x1b[D".to_vec()),
        _ => keystroke
            .key_char
            .as_ref()
            .map(|text| text.as_bytes().to_vec()),
    }
}

fn render_command_settings_field(
    id: String,
    label: String,
    value: &str,
    field: CommandSettingsField,
    active_field: CommandSettingsField,
    on_select_field: impl Fn(CommandSettingsField, &gpui::ClickEvent, &mut Window, &mut App)
    + Clone
    + 'static,
) -> impl IntoElement {
    let is_active = field == active_field;
    div()
        .flex()
        .flex_col()
        .gap_1()
        .child(
            div()
                .text_xs()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .text_color(rgb(0x374151))
                .child(label),
        )
        .child(
            div()
                .id(SharedString::from(id))
                .px_2()
                .py_1()
                .min_h(px(28.0))
                .rounded_md()
                .border_1()
                .border_color(if is_active {
                    rgb(0x2563eb)
                } else {
                    rgb(0xd1d5db)
                })
                .bg(rgb(0xffffff))
                .text_sm()
                .child(if value.is_empty() {
                    SharedString::from(" ")
                } else {
                    SharedString::from(value.to_string())
                })
                .on_click(move |event, window, cx| {
                    on_select_field(field, event, window, cx);
                }),
        )
}

fn render_create_worktree_field(
    label: &'static str,
    value: &str,
    field: CreateWorktreeField,
    active_field: CreateWorktreeField,
    on_select_field: impl Fn(CreateWorktreeField, &gpui::ClickEvent, &mut Window, &mut App)
    + Clone
    + 'static,
) -> impl IntoElement {
    let is_active = field == active_field;
    div()
        .flex()
        .flex_col()
        .gap_1()
        .child(
            div()
                .text_xs()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .text_color(rgb(0x374151))
                .child(label),
        )
        .child(
            div()
                .id(SharedString::from(format!("create-worktree-{field:?}")))
                .px_2()
                .py_1()
                .min_h(px(28.0))
                .rounded_md()
                .border_1()
                .border_color(if is_active {
                    rgb(0x2563eb)
                } else {
                    rgb(0xd1d5db)
                })
                .bg(rgb(0xffffff))
                .text_sm()
                .child(if value.is_empty() {
                    SharedString::from(" ")
                } else {
                    SharedString::from(value.to_string())
                })
                .on_click(move |event, window, cx| {
                    on_select_field(field, event, window, cx);
                }),
        )
}

fn render_status_bar(
    repo_summary: String,
    tab_summary: String,
    terminal_status: Option<&TerminalTabStatus>,
) -> impl IntoElement {
    let (status_label, status_color) = match terminal_status {
        Some(TerminalTabStatus::Running) => ("running".to_string(), SUCCESS),
        Some(TerminalTabStatus::Exited(Some(code))) => (
            format!("exited {code}"),
            if *code == 0 { SUCCESS } else { DANGER },
        ),
        Some(TerminalTabStatus::Exited(None)) => ("exited".to_string(), TEXT_MUTED),
        Some(TerminalTabStatus::Failed) => ("failed".to_string(), DANGER),
        Some(TerminalTabStatus::NotStarted) => ("not started".to_string(), TEXT_MUTED),
        None => ("no terminal".to_string(), TEXT_MUTED),
    };

    div()
        .flex()
        .items_center()
        .justify_between()
        .gap_3()
        .px_4()
        .py_2()
        .border_t_1()
        .border_color(PANEL_BORDER)
        .bg(PANEL_BG)
        .text_xs()
        .text_color(TEXT_MUTED)
        .child(
            div()
                .flex()
                .items_center()
                .gap_2()
                .overflow_hidden()
                .child(div().text_color(TEXT).child("Workspace"))
                .child(div().child("•"))
                .child(div().truncate().child(repo_summary)),
        )
        .child(
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(div().text_color(TEXT).child(tab_summary))
                .child(div().child("•"))
                .child(div().text_color(status_color).child(status_label)),
        )
}

impl Render for AlasShell {
    fn render(&mut self, window: &mut gpui::Window, cx: &mut Context<Self>) -> impl IntoElement {
        let window_bounds = window.bounds();
        let terminal_width = (f32::from(window_bounds.size.width) - 640.0).max(160.0);
        let terminal_height = (f32::from(window_bounds.size.height) - 88.0).max(80.0);
        let terminal_size = TerminalSize {
            cols: (terminal_width / 8.0).floor().max(20.0) as u16,
            rows: (terminal_height / 18.0).floor().max(4.0) as u16,
        };
        self.resize_active_terminal(terminal_size);
        let terminal_snapshot = self.terminal_snapshot();

        let view = cx.entity().downgrade();
        let on_select_worktree = move |repo_id: String,
                                       path: PathBuf,
                                       _event: &gpui::ClickEvent,
                                       _window: &mut Window,
                                       app: &mut App| {
            view.update(app, |shell, cx| {
                shell.select_worktree(repo_id, path, cx);
                cx.notify();
            })
            .ok();
        };
        let view = cx.entity().downgrade();
        let on_select_create_worktree_field =
            move |field: CreateWorktreeField,
                  _event: &gpui::ClickEvent,
                  window: &mut Window,
                  app: &mut App| {
                view.update(app, |shell, cx| {
                    shell.set_create_worktree_field(field);
                    window.focus(&shell.create_worktree_focus);
                    cx.notify();
                })
                .ok();
            };
        let view = cx.entity().downgrade();
        let on_select_inspector_tab = move |tab: InspectorTab,
                                            _event: &gpui::ClickEvent,
                                            _window: &mut Window,
                                            app: &mut App| {
            view.update(app, |shell, cx| {
                shell.inspector_state.select_tab(tab);
                cx.notify();
            })
            .ok();
        };
        let on_submit_create_worktree = cx.listener(|shell, _event, _window, cx| {
            shell.create_worktree_from_dialog(cx);
            cx.notify();
        });
        let on_cancel_create_worktree = cx.listener(|shell, _event, _window, cx| {
            shell.close_create_worktree_dialog();
            cx.notify();
        });
        let on_create_worktree_key_down =
            cx.listener(|shell, event: &KeyDownEvent, _window, cx| {
                if shell.edit_create_worktree_field(event, cx) {
                    cx.stop_propagation();
                    cx.notify();
                }
            });
        let view = cx.entity().downgrade();
        let on_select_command_settings_field =
            move |field: CommandSettingsField,
                  _event: &gpui::ClickEvent,
                  window: &mut Window,
                  app: &mut App| {
                view.update(app, |shell, cx| {
                    shell.set_command_settings_field(field);
                    window.focus(&shell.command_settings_focus);
                    cx.notify();
                })
                .ok();
            };
        let on_submit_command_settings = cx.listener(|shell, _event, _window, cx| {
            shell.save_command_settings_from_dialog();
            cx.notify();
        });
        let on_cancel_command_settings = cx.listener(|shell, _event, _window, cx| {
            shell.close_command_settings_dialog();
            cx.notify();
        });
        let on_add_command_entry = cx.listener(|shell, _event, _window, cx| {
            shell.add_command_settings_entry();
            cx.notify();
        });
        let on_command_settings_key_down =
            cx.listener(|shell, event: &KeyDownEvent, _window, cx| {
                if shell.edit_command_settings_field(event) {
                    cx.stop_propagation();
                    cx.notify();
                }
            });
        let on_terminal_key_down = cx.listener(|shell, event: &KeyDownEvent, _window, cx| {
            if shell.handle_command_picker_key_down(event) {
                cx.stop_propagation();
                cx.notify();
                return;
            }

            if shell.write_terminal_input(event) {
                cx.stop_propagation();
                cx.notify();
            }
        });
        let on_retry_terminal = cx.listener(|shell, _event, _window, cx| {
            shell.retry_active_terminal(cx);
            cx.notify();
        });
        let on_restart_terminal = cx.listener(|shell, _event, _window, cx| {
            shell.restart_active_terminal();
            cx.notify();
        });
        let on_focus_terminal = cx.listener(|shell, _event, window, cx| {
            window.focus(&shell.terminal_focus);
            cx.notify();
        });
        let terminal_screen_mode = terminal_snapshot
            .as_ref()
            .map(|snapshot| snapshot.screen_mode)
            .unwrap_or(TerminalScreenMode::Main);
        let terminal_scrollback_rows = terminal_snapshot
            .as_ref()
            .map_or(0, |snapshot| snapshot.scrollback_rows);
        let on_terminal_scroll =
            cx.listener(move |shell, event: &ScrollWheelEvent, _window, cx| {
                if shell.scroll_terminal(event, terminal_screen_mode, terminal_scrollback_rows) {
                    cx.stop_propagation();
                    cx.notify();
                }
            });
        let view = cx.entity().downgrade();
        let on_select_terminal_tab = move |tab_id: TerminalTabId,
                                           _event: &gpui::ClickEvent,
                                           _window: &mut Window,
                                           app: &mut App| {
            view.update(app, |shell, cx| {
                shell.select_terminal_tab(tab_id);
                cx.notify();
            })
            .ok();
        };
        let on_new_terminal_tab = cx.listener(|shell, _event, _window, cx| {
            shell.open_command_picker(cx);
        });
        let view = cx.entity().downgrade();
        let on_select_command = move |name: String,
                                      command: String,
                                      _event: &gpui::ClickEvent,
                                      _window: &mut Window,
                                      app: &mut App| {
            view.update(app, |shell, cx| {
                shell.create_command_tab_from_picker(name, command);
                cx.notify();
            })
            .ok();
        };
        let on_cancel_command_picker = cx.listener(|shell, _event, _window, cx| {
            shell.close_command_picker();
            cx.notify();
        });
        let view = cx.entity().downgrade();
        let on_open_sidebar_menu =
            move |menu: SidebarMenuState, _window: &mut Window, app: &mut App| {
                view.update(app, |shell, cx| {
                    shell.open_sidebar_menu(menu);
                    cx.notify();
                })
                .ok();
            };
        let view = cx.entity().downgrade();
        let on_sidebar_menu_action = move |action_id: ActionId,
                                           _event: &gpui::ClickEvent,
                                           window: &mut Window,
                                           app: &mut App| {
            view.update(app, |shell, cx| {
                shell.handle_sidebar_menu_action(action_id, window, cx);
            })
            .ok();
        };
        let view = cx.entity().downgrade();
        let on_close_sidebar_menu =
            move |_event: &gpui::ClickEvent, _window: &mut Window, app: &mut App| {
                view.update(app, |shell, cx| {
                    shell.close_sidebar_menu();
                    cx.notify();
                })
                .ok();
            };
        let workspace_tabs = self
            .model
            .selected_worktree()
            .map(|selected| {
                self.workspace_session
                    .tabs_for_worktree(&selected.repo_id, &selected.path)
            })
            .unwrap_or(&[]);
        let active_workspace_tab = self.model.selected_worktree().and_then(|selected| {
            self.workspace_session
                .active_tab(&selected.repo_id, &selected.path)
                .map(|tab| tab.id)
        });
        let active_tab = workspace_tabs
            .iter()
            .find(|tab| Some(tab.id) == active_workspace_tab);
        let status_bar_repo = self
            .model
            .selected_worktree()
            .map(|selected| {
                let repository = self
                    .model
                    .repositories()
                    .iter()
                    .find(|repository| repository.id == selected.repo_id);
                let worktree = repository.and_then(|repository| {
                    repository
                        .worktrees
                        .iter()
                        .find(|worktree| worktree.path == selected.path)
                });
                let repo_name = repository
                    .map(|repository| repository.name.as_str())
                    .unwrap_or(selected.repo_id.as_str());
                let branch = worktree
                    .and_then(|worktree| worktree.branch.as_deref())
                    .unwrap_or("detached");
                let path = selected
                    .path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .unwrap_or_else(|| selected.path.to_str().unwrap_or("worktree"));
                format!("{repo_name} • {branch} • {path}")
            })
            .unwrap_or_else(|| "No worktree selected".to_string());
        let status_bar_tab = active_tab
            .map(|tab| tab.name.clone())
            .unwrap_or_else(|| "No terminal tab".to_string());
        let status_bar_terminal_status = if self.terminal_error.is_some() {
            Some(TerminalTabStatus::Failed)
        } else {
            active_tab.map(|tab| tab.status.clone())
        };

        div()
            .flex()
            .flex_col()
            .size_full()
            .bg(APP_BG)
            .text_color(TEXT)
            .child(
                div()
                    .flex()
                    .flex_1()
                    .overflow_hidden()
                    .child(render_sidebar(
                        self.model.repositories(),
                        self.model.selected_worktree(),
                        self.sidebar_menu.as_ref(),
                        cx.listener(|shell, _event, _window, cx| shell.open_add_repository_dialog(cx)),
                        on_select_worktree,
                        on_open_sidebar_menu,
                        on_sidebar_menu_action,
                        on_close_sidebar_menu,
                        self.add_repository_error(),
                    ))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .when(self.command_picker.is_some(), |element| {
                        let picker = self.command_picker.as_ref().unwrap();
                        element.child(render_command_picker(
                            &picker.commands,
                            on_select_command,
                            on_cancel_command_picker,
                        ))
                    })
                    .when(self.command_settings_dialog.is_some(), |element| {
                        let dialog = self.command_settings_dialog.as_ref().unwrap();
                        element.child(
                            div()
                                .m_3()
                                .p_3()
                                .rounded_md()
                                .border_1()
                                .border_color(rgb(0xbfdbfe))
                                .bg(rgb(0xeff6ff))
                                .flex()
                                .flex_col()
                                .gap_2()
                                .track_focus(&self.command_settings_focus)
                                .on_key_down(on_command_settings_key_down)
                                .child(
                                    div()
                                        .text_sm()
                                        .font_weight(gpui::FontWeight::SEMIBOLD)
                                        .child("Repository Commands"),
                                )
                                .child(
                                    div()
                                        .text_xs()
                                        .text_color(rgb(0x4b5563))
                                        .child(format!("Repository: {}", dialog.repo_id)),
                                )
                                .child(render_command_settings_field(
                                    "command-settings-default".to_string(),
                                    "Default command name".to_string(),
                                    &dialog.default_name,
                                    CommandSettingsField::DefaultName,
                                    self.command_settings_active_field,
                                    on_select_command_settings_field.clone(),
                                ))
                                .children(dialog.entries.iter().enumerate().map(|(index, entry)| {
                                    let view = cx.entity().downgrade();
                                    let on_remove_entry = move |_: &gpui::ClickEvent,
                                                                _window: &mut Window,
                                                                app: &mut App| {
                                        view.update(app, |shell, cx| {
                                            shell.remove_command_settings_entry(index);
                                            cx.notify();
                                        })
                                        .ok();
                                    };
                                    div()
                                        .flex()
                                        .flex_col()
                                        .gap_1()
                                        .child(
                                            div()
                                                .flex()
                                                .items_center()
                                                .justify_between()
                                                .child(
                                                    div()
                                                        .text_xs()
                                                        .font_weight(gpui::FontWeight::SEMIBOLD)
                                                        .child(format!("Command {}", index + 1)),
                                                )
                                                .child(
                                                    div()
                                                        .id(SharedString::from(format!(
                                                            "remove-command-entry-{index}"
                                                        )))
                                                        .text_xs()
                                                        .text_color(rgb(0xdc2626))
                                                        .child("Remove")
                                                        .on_click(on_remove_entry),
                                                ),
                                        )
                                        .child(render_command_settings_field(
                                            format!("command-settings-name-{index}"),
                                            "Name".to_string(),
                                            &entry.0,
                                            CommandSettingsField::EntryName(index),
                                            self.command_settings_active_field,
                                            on_select_command_settings_field.clone(),
                                        ))
                                        .child(render_command_settings_field(
                                            format!("command-settings-command-{index}"),
                                            "Command".to_string(),
                                            &entry.1,
                                            CommandSettingsField::EntryCommand(index),
                                            self.command_settings_active_field,
                                            on_select_command_settings_field.clone(),
                                        ))
                                }))
                                .child(
                                    div()
                                        .text_xs()
                                        .text_color(rgb(0x6b7280))
                                        .child("Click a field, type to edit, Tab switches fields, Enter saves, Esc cancels."),
                                )
                                .when(dialog.error.is_some(), |element| {
                                    element.child(
                                        div()
                                            .text_sm()
                                            .text_color(rgb(0xdc2626))
                                            .child(SharedString::from(
                                                dialog.error.clone().unwrap_or_default(),
                                            )),
                                    )
                                })
                                .child(
                                    div()
                                        .flex()
                                        .gap_2()
                                        .child(
                                            div()
                                                .id("add-command-entry")
                                                .px_3()
                                                .py_2()
                                                .rounded_md()
                                                .text_sm()
                                                .font_weight(gpui::FontWeight::SEMIBOLD)
                                                .text_color(rgb(0x374151))
                                                .bg(rgb(0xe5e7eb))
                                                .child("Add Command")
                                                .on_click(on_add_command_entry),
                                        )
                                        .child(
                                            div()
                                                .id("submit-command-settings")
                                                .px_3()
                                                .py_2()
                                                .rounded_md()
                                                .text_sm()
                                                .font_weight(gpui::FontWeight::SEMIBOLD)
                                                .text_color(rgb(0xffffff))
                                                .bg(rgb(0x2563eb))
                                                .child("Save")
                                                .on_click(on_submit_command_settings),
                                        )
                                        .child(
                                            div()
                                                .id("cancel-command-settings")
                                                .px_3()
                                                .py_2()
                                                .rounded_md()
                                                .text_sm()
                                                .font_weight(gpui::FontWeight::SEMIBOLD)
                                                .text_color(rgb(0x374151))
                                                .bg(rgb(0xe5e7eb))
                                                .child("Cancel")
                                                .on_click(on_cancel_command_settings),
                                        ),
                                ),
                        )
                    })
                    .when(self.create_worktree_dialog.is_some(), |element| {
                        let dialog = self.create_worktree_dialog.as_ref().unwrap();
                        element.child(
                            div()
                                .m_3()
                                .p_3()
                                .rounded_md()
                                .border_1()
                                .border_color(rgb(0xbfdbfe))
                                .bg(rgb(0xeff6ff))
                                .flex()
                                .flex_col()
                                .gap_2()
                                .track_focus(&self.create_worktree_focus)
                                .on_key_down(on_create_worktree_key_down)
                                .child(
                                    div()
                                        .text_sm()
                                        .font_weight(gpui::FontWeight::SEMIBOLD)
                                        .child("Create Worktree"),
                                )
                                .child(
                                    div()
                                        .text_xs()
                                        .text_color(rgb(0x4b5563))
                                        .child(format!("Repository: {}", dialog.repo_id)),
                                )
                                .child(render_create_worktree_field(
                                    "Base ref",
                                    &dialog.base_ref,
                                    CreateWorktreeField::BaseRef,
                                    dialog.active_field,
                                    on_select_create_worktree_field.clone(),
                                ))
                                .child(render_create_worktree_field(
                                    "Branch name",
                                    &dialog.branch_name,
                                    CreateWorktreeField::BranchName,
                                    dialog.active_field,
                                    on_select_create_worktree_field.clone(),
                                ))
                                .child(render_create_worktree_field(
                                    "Target path",
                                    &dialog.target_path_text,
                                    CreateWorktreeField::TargetPath,
                                    dialog.active_field,
                                    on_select_create_worktree_field.clone(),
                                ))
                                .child(
                                    div()
                                        .text_xs()
                                        .text_color(rgb(0x6b7280))
                                        .child("Click a field, type to edit, Tab switches fields, Enter submits, Esc cancels."),
                                )
                                .when(dialog.error.is_some(), |element| {
                                    element.child(
                                        div()
                                            .text_sm()
                                            .text_color(rgb(0xdc2626))
                                            .child(SharedString::from(
                                                dialog.error.clone().unwrap_or_default(),
                                            )),
                                    )
                                })
                                .child(
                                    div()
                                        .flex()
                                        .gap_2()
                                        .child(
                                            div()
                                                .id("submit-create-worktree")
                                                .px_3()
                                                .py_2()
                                                .rounded_md()
                                                .text_sm()
                                                .font_weight(gpui::FontWeight::SEMIBOLD)
                                                .text_color(rgb(0xffffff))
                                                .bg(rgb(0x2563eb))
                                                .child("Create")
                                                .on_click(on_submit_create_worktree),
                                        )
                                        .child(
                                            div()
                                                .id("cancel-create-worktree")
                                                .px_3()
                                                .py_2()
                                                .rounded_md()
                                                .text_sm()
                                                .font_weight(gpui::FontWeight::SEMIBOLD)
                                                .text_color(rgb(0x374151))
                                                .bg(rgb(0xe5e7eb))
                                                .child("Cancel")
                                                .on_click(on_cancel_create_worktree),
                                        ),
                                ),
                        )
                    })
                    .child(
                        div()
                            .flex()
                            .flex_1()
                            .track_focus(&self.terminal_focus)
                            .on_key_down(on_terminal_key_down)
                            .child(render_workspace(
                                workspace_tabs,
                                active_workspace_tab,
                                on_select_terminal_tab,
                                on_new_terminal_tab,
                                render_terminal_pane(
                                    self.model.selected_worktree(),
                                    terminal_snapshot.as_ref(),
                                    self.terminal_error.as_deref(),
                                    on_retry_terminal,
                                    on_restart_terminal,
                                    on_focus_terminal,
                                    on_terminal_scroll,
                                ),
                            )),
                    ),
            )
            .child(render_project_inspector(
                self.model.selected_worktree(),
                &self.inspector_state,
                on_select_inspector_tab,
            )),
            )
            .child(render_status_bar(
                status_bar_repo,
                status_bar_tab,
                status_bar_terminal_status.as_ref(),
            ))
    }
}

pub fn run() -> anyhow::Result<()> {
    Application::new().run(|cx: &mut App| {
        cx.open_window(WindowOptions::default(), |_, cx| {
            cx.new(|cx| AlasShell::new(cx))
        })
        .expect("failed to open Alas window");
    });

    Ok(())
}

fn infer_repository_name(path: &Path) -> String {
    path.file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .map(ToString::to_string)
        .unwrap_or_else(|| path.display().to_string())
}
