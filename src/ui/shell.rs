use std::{
    path::{Path, PathBuf},
    time::Duration,
};

use crate::{
    app::{
        ActionId, AlasModel, FILE_TAB_MAX_BYTES, FileTabLoadState, InspectorPaneState,
        RepositoryNode, TerminalTabKind, TerminalTabStatus, WorkspaceSession, WorkspaceTabContent,
        WorkspaceTabId, WorkspaceTabKind,
    },
    config::{
        AppConfig, AppConfigStore, AppRepository, CommandEntry, RepoConfigStore,
        ResolvedRepoConfig, repository_id_for_path,
    },
    git::{GitInspectorService, GitRunner, GitWorktreeService},
    project::FileTreeService,
    terminal::{
        CommandSpec, GhosttyRenderFrame, GhosttyTerminalBackend, TerminalBackend, TerminalKeyInput,
        TerminalMetrics, TerminalScreenMode, TerminalSessionId, TerminalSessionRef,
        TerminalSessionRegistry, TerminalSize, TerminalStatus, TerminalViewport,
        ghostty_input::{
            TerminalKeyModifiers, TerminalMouseAction, TerminalMouseButton, TerminalMouseInput,
            mouse_cell_position,
        },
    },
    ui::{
        chrome::{alas_window_options, apply_window_background_appearance},
        command_picker::render_command_picker,
        dialogs::{
            AddRepositoryDialogState, CommandSettingsDialogState, ConfirmPruneWorktreesDialog,
            ConfirmRemoveRepositoryDialog, ConfirmRemoveWorktreeDialog, CreateWorktreeDialogState,
            CreateWorktreeField,
        },
        file_pane::render_file_pane,
        inspector::render_project_inspector,
        sidebar::{SidebarMenuState, render_sidebar},
        terminal_canvas::measure_terminal_metrics,
        terminal_pane::render_terminal_pane,
        terminal_view::{
            TERMINAL_CANVAS_HORIZONTAL_PADDING_PX, TERMINAL_FONT_FAMILY, TERMINAL_FONT_SIZE_PX,
        },
        theme::{DANGER, PANEL_BG, PANEL_BORDER, SUCCESS, TEXT, TEXT_MUTED, root_background},
        view_models::TreeExpansionState,
        workspace::render_workspace,
    },
};
use gpui::{
    App, Application, Bounds, ClipboardItem, Context, FocusHandle, IntoElement, KeyDownEvent,
    MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent, PathPromptOptions, Pixels,
    PromptLevel, Render, ScrollDelta, ScrollWheelEvent, SharedString, Window, div, prelude::*, px,
    rgb,
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

fn terminal_refresh_interval() -> Duration {
    Duration::from_millis(16)
}

fn terminal_should_intercept_key(terminal_focused: bool) -> bool {
    terminal_focused
}

fn is_terminal_paste_key(event: &KeyDownEvent) -> bool {
    if !event.keystroke.key.eq_ignore_ascii_case("v") {
        return false;
    }

    let modifiers = &event.keystroke.modifiers;
    let platform_paste = modifiers.platform
        && !modifiers.control
        && !modifiers.alt
        && !modifiers.shift
        && !modifiers.function;
    let secondary_paste = modifiers.secondary()
        && !modifiers.platform
        && !modifiers.alt
        && !modifiers.shift
        && !modifiers.function;

    platform_paste || secondary_paste
}

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
    active_terminal_tab: Option<WorkspaceTabId>,
    active_terminal: Option<TerminalSessionRef>,
    terminal_error: Option<String>,
    terminal_focus: FocusHandle,
    terminal_metrics: TerminalMetrics,
    terminal_size: Option<TerminalSize>,
    terminal_body_size_px: Option<(f32, f32)>,
    terminal_body_bounds: Option<Bounds<Pixels>>,
    terminal_scroll_offset_rows: usize,
    inspector_state: InspectorPaneState,
    inspector_request_generation: u64,
    file_tree_expansion: TreeExpansionState,
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
            terminal_metrics: TerminalMetrics::fallback(),
            terminal_size: None,
            terminal_body_size_px: None,
            terminal_body_bounds: None,
            terminal_scroll_offset_rows: 0,
            inspector_state: InspectorPaneState::default(),
            inspector_request_generation: 0,
            file_tree_expansion: TreeExpansionState::default(),
        };
        shell.refresh_repositories();
        shell.start_terminal_refresh(cx);
        shell.register_app_quit_cleanup(cx);
        shell
    }

    fn start_terminal_refresh(&self, cx: &mut Context<Self>) {
        cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(terminal_refresh_interval())
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

    fn terminal_render_frame(&mut self) -> Option<GhosttyRenderFrame> {
        if !self.active_tab_is_terminal() {
            return None;
        }

        let session = self.active_terminal.as_ref()?.clone();
        let rows = self.terminal_size.map_or(24, |size| size.rows);
        let viewport = TerminalViewport {
            scroll_offset_rows: self.terminal_scroll_offset_rows,
            visible_rows: rows,
        };

        match self
            .terminal_backend
            .render_frame(session.backend_session, viewport)
        {
            Ok(frame) => {
                self.terminal_scroll_offset_rows = match frame.screen_mode {
                    TerminalScreenMode::Main => frame.viewport.scroll_offset_rows,
                    TerminalScreenMode::Alternate => 0,
                };
                self.persist_terminal_scroll_offset(&session.id);
                Some(frame)
            }
            Err(error) => {
                self.mark_terminal_tab_failed(&session.id, error.to_string());
                None
            }
        }
    }

    fn refresh_active_terminal_status(&mut self) {
        if !self.active_tab_is_terminal() {
            return;
        }
        let Some(session) = self.active_terminal.as_ref().cloned() else {
            return;
        };
        if self.terminal_tab_has_failure(&session.id) {
            return;
        }

        match self.terminal_backend.status(session.backend_session) {
            Ok(TerminalStatus::Exited(exit_status)) => {
                let _ = self.workspace_session.set_tab_status(
                    &session.id.repo_id,
                    &session.id.worktree_path,
                    session.id.tab_id,
                    TerminalTabStatus::Exited(exit_status),
                );
            }
            Ok(TerminalStatus::Running) => {
                let _ = self.workspace_session.set_tab_status(
                    &session.id.repo_id,
                    &session.id.worktree_path,
                    session.id.tab_id,
                    TerminalTabStatus::Running,
                );
            }
            Ok(TerminalStatus::Failed) => self.mark_terminal_tab_failed(
                &session.id,
                "terminal backend reported failure".to_string(),
            ),
            Err(error) => self.mark_terminal_tab_failed(&session.id, error.to_string()),
        }
    }

    fn resize_active_terminal(&mut self, size: TerminalSize) {
        if !self.active_tab_is_terminal() {
            return;
        }
        if self.terminal_size == Some(size) {
            return;
        }
        if let Some(session) = self.active_terminal.as_ref()
            && let Err(error) = self.terminal_backend.resize(session.backend_session, size)
        {
            let id = session.id.clone();
            self.mark_terminal_tab_failed(&id, error.to_string());
            return;
        }
        self.terminal_size = Some(size);
    }

    fn update_terminal_body_bounds(&mut self, bounds: Bounds<Pixels>) -> bool {
        if !self.active_tab_is_terminal() {
            return false;
        }

        let width_px = f32::from(bounds.size.width);
        let height_px = f32::from(bounds.size.height);
        if width_px <= 0.0 || height_px <= 0.0 {
            return false;
        }

        let next_size = (width_px.floor(), height_px.floor());
        if self.terminal_body_size_px == Some(next_size)
            && self.terminal_body_bounds == Some(bounds)
        {
            return false;
        }
        self.terminal_body_size_px = Some(next_size);
        self.terminal_body_bounds = Some(bounds);
        true
    }

    fn current_terminal_size(&self) -> TerminalSize {
        self.terminal_body_size_px
            .map(|(width, height)| {
                let width = (width - (2.0 * TERMINAL_CANVAS_HORIZONTAL_PADDING_PX)).max(0.0);
                self.terminal_metrics.size_from_pixels(width, height)
            })
            .or(self.terminal_size)
            .unwrap_or(TerminalSize { cols: 80, rows: 24 })
    }

    fn terminal_tab_has_failure(&self, id: &TerminalSessionId) -> bool {
        self.workspace_session
            .terminal_tab_state(&id.repo_id, &id.worktree_path, id.tab_id)
            .is_some_and(|state| state.failure_cause.is_some())
    }

    fn mark_terminal_tab_failed(&mut self, id: &TerminalSessionId, cause: String) {
        if self
            .workspace_session
            .set_tab_failure(&id.repo_id, &id.worktree_path, id.tab_id, cause.clone())
            .is_err()
        {
            self.terminal_error = Some(cause);
        }
    }

    fn clear_terminal_tab_failure(&mut self, id: &TerminalSessionId) {
        let _ = self
            .workspace_session
            .clear_tab_failure(&id.repo_id, &id.worktree_path, id.tab_id);
    }

    fn retry_active_terminal(&mut self) {
        if self.active_terminal.is_some() {
            self.restart_active_terminal();
            return;
        }

        let Some(selected) = self.model.selected_worktree().cloned() else {
            return;
        };
        let tab_id = self
            .workspace_session
            .active_tab(&selected.repo_id, &selected.path)
            .map(|tab| tab.id)
            .unwrap_or_else(|| {
                let default_command =
                    self.resolve_default_command(&selected.repo_id, selected.path.clone());
                self.workspace_session.ensure_default_terminal_tab(
                    &selected.repo_id,
                    selected.path.clone(),
                    default_command,
                )
            });
        self.start_or_reuse_terminal_tab_for_retry(selected.repo_id, selected.path, tab_id);
    }

    fn restart_active_terminal(&mut self) {
        self.terminal_scroll_offset_rows = 0;
        let Some(active) = self.active_terminal.clone() else {
            return;
        };
        match self.terminal_backend.restart(active.backend_session) {
            Ok(session) => {
                if let Some(active_terminal) = self.active_terminal.as_mut()
                    && active_terminal.id == active.id
                {
                    active_terminal.backend_session = session;
                }
                self.terminal_registry
                    .replace_backend_session(&active.id, session);
                let _ = self.workspace_session.set_tab_backend_session(
                    &active.id.repo_id,
                    &active.id.worktree_path,
                    active.id.tab_id,
                    Some(session),
                );

                if let Some(size) = self.terminal_size
                    && let Err(error) = self.terminal_backend.resize(session, size)
                {
                    self.mark_terminal_tab_failed(&active.id, error.to_string());
                    return;
                }

                let _ = self.workspace_session.set_tab_status(
                    &active.id.repo_id,
                    &active.id.worktree_path,
                    active.id.tab_id,
                    TerminalTabStatus::Running,
                );
                self.clear_terminal_tab_failure(&active.id);
                self.terminal_error = None;
            }
            Err(error) => {
                self.mark_terminal_tab_failed(&active.id, error.to_string());
            }
        }
    }

    fn handle_terminal_key_down(&mut self, event: &KeyDownEvent, cx: &mut Context<Self>) -> bool {
        if self.handle_command_picker_key_down(event) {
            cx.notify();
            return true;
        }

        if is_terminal_paste_key(event)
            && let Some(text) = cx.read_from_clipboard().and_then(|item| item.text())
            && self.write_terminal_paste(&text)
        {
            cx.notify();
            return true;
        }

        if self.write_terminal_input(event) {
            cx.notify();
        }

        true
    }

    fn write_terminal_input(&mut self, event: &KeyDownEvent) -> bool {
        if !self.should_route_terminal_input() {
            return false;
        }

        let Some(session) = self.active_terminal.as_ref() else {
            return false;
        };
        let input = TerminalKeyInput::from(event);

        match self
            .terminal_backend
            .write_key_input(session.backend_session, input)
        {
            Ok(handled) => handled,
            Err(error) => {
                let id = session.id.clone();
                self.mark_terminal_tab_failed(&id, error.to_string());
                true
            }
        }
    }

    fn write_terminal_paste(&mut self, text: &str) -> bool {
        if !self.should_route_terminal_input() {
            return false;
        }

        let Some(session) = self.active_terminal.as_ref() else {
            return false;
        };

        match self
            .terminal_backend
            .write_paste_input(session.backend_session, text)
        {
            Ok(handled) => handled,
            Err(error) => {
                let id = session.id.clone();
                self.mark_terminal_tab_failed(&id, error.to_string());
                true
            }
        }
    }

    fn write_terminal_mouse_input(&mut self, input: TerminalMouseInput) -> bool {
        if !self.should_route_terminal_input() {
            return false;
        }

        let Some(session) = self.active_terminal.as_ref() else {
            return false;
        };

        match self
            .terminal_backend
            .write_mouse_input(session.backend_session, input)
        {
            Ok(handled) => handled,
            Err(error) => {
                let id = session.id.clone();
                self.mark_terminal_tab_failed(&id, error.to_string());
                true
            }
        }
    }

    fn write_terminal_mouse_event(
        &mut self,
        action: TerminalMouseAction,
        button: TerminalMouseButton,
        position: gpui::Point<Pixels>,
        modifiers: gpui::Modifiers,
    ) -> bool {
        let Some(input) = self.terminal_mouse_input(action, button, position, modifiers) else {
            return false;
        };
        self.write_terminal_mouse_input(input)
    }

    fn write_terminal_wheel_input(&mut self, event: &ScrollWheelEvent) -> bool {
        let rows = terminal_scroll_rows(event);
        if rows == 0 {
            return false;
        }

        let action = if rows > 0 {
            TerminalMouseAction::WheelUp
        } else {
            TerminalMouseAction::WheelDown
        };
        self.write_terminal_mouse_event(
            action,
            TerminalMouseButton::None,
            event.position,
            event.modifiers,
        )
    }

    fn terminal_mouse_input(
        &self,
        action: TerminalMouseAction,
        button: TerminalMouseButton,
        position: gpui::Point<Pixels>,
        modifiers: gpui::Modifiers,
    ) -> Option<TerminalMouseInput> {
        let bounds = self.terminal_body_bounds?;
        let mut x_px = f32::from(position.x) - f32::from(bounds.origin.x);
        let y_px = f32::from(position.y) - f32::from(bounds.origin.y);

        let horizontal_padding = TERMINAL_CANVAS_HORIZONTAL_PADDING_PX;
        x_px -= horizontal_padding;

        let content_width = (f32::from(bounds.size.width) - (2.0 * horizontal_padding)).max(0.0);
        if x_px < 0.0 || x_px >= content_width {
            return None;
        }

        let cell = mouse_cell_position(x_px, y_px, self.terminal_metrics)?;

        Some(TerminalMouseInput {
            action,
            button,
            col: cell.col,
            row: cell.row,
            x_px,
            y_px,
            metrics: self.terminal_metrics,
            modifiers: terminal_mouse_modifiers(modifiers),
        })
    }

    fn scroll_terminal(
        &mut self,
        event: &ScrollWheelEvent,
        screen_mode: TerminalScreenMode,
        scrollback_rows: usize,
    ) -> bool {
        if !self.active_tab_is_terminal() {
            return false;
        }

        let Some(session) = self.active_terminal.as_ref().cloned() else {
            return false;
        };

        if screen_mode == TerminalScreenMode::Alternate {
            // If Ghostty mouse reporting did not consume the wheel event, keep
            // alternate-screen scrollback pinned rather than scrolling the main
            // screen behind the TUI.
            let changed = self.terminal_scroll_offset_rows != 0;
            self.terminal_scroll_offset_rows = 0;
            if changed {
                self.persist_terminal_scroll_offset(&session.id);
            }
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
        self.persist_terminal_scroll_offset(&session.id);
        true
    }

    fn persist_terminal_scroll_offset(&mut self, id: &TerminalSessionId) {
        let _ = self.workspace_session.set_tab_scroll_offset(
            &id.repo_id,
            &id.worktree_path,
            id.tab_id,
            self.terminal_scroll_offset_rows,
        );
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
        if let Some(dialog) = self.command_settings_dialog.as_mut()
            && dialog.entries.len() > 1
            && index < dialog.entries.len()
        {
            dialog.entries.remove(index);
            self.command_settings_active_field = CommandSettingsField::DefaultName;
            dialog.error = None;
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
        self.file_tree_expansion = TreeExpansionState::default();
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

    fn select_workspace_tab(&mut self, tab_id: WorkspaceTabId) {
        let Some(selected) = self.model.selected_worktree().cloned() else {
            return;
        };

        let is_terminal = self
            .workspace_session
            .tab(&selected.repo_id, &selected.path, tab_id)
            .is_some_and(|t| t.is_terminal());

        if let Err(error) =
            self.workspace_session
                .set_active_tab(&selected.repo_id, &selected.path, tab_id)
        {
            self.terminal_error = Some(error.to_string());
            return;
        }

        if is_terminal {
            self.start_or_reuse_terminal_tab(selected.repo_id, selected.path, tab_id);
        } else {
            self.active_terminal_tab = Some(tab_id);
            self.active_terminal = None;
            self.terminal_scroll_offset_rows = 0;
            self.terminal_error = None;
        }
    }

    fn active_workspace_tab_kind(&self) -> Option<WorkspaceTabKind> {
        let selected = self.model.selected_worktree()?;
        self.workspace_session
            .active_tab(&selected.repo_id, &selected.path)
            .map(|tab| tab.kind)
    }

    fn active_tab_is_terminal(&self) -> bool {
        self.active_workspace_tab_kind()
            .is_some_and(|kind| matches!(kind, WorkspaceTabKind::Terminal(_)))
    }

    fn should_route_terminal_input(&self) -> bool {
        Self::should_route_terminal_input_for(
            self.active_workspace_tab_kind(),
            self.active_terminal.is_some(),
        )
    }

    fn should_route_terminal_input_for(
        active_tab_kind: Option<WorkspaceTabKind>,
        has_active_terminal: bool,
    ) -> bool {
        active_tab_kind.is_some_and(|kind| matches!(kind, WorkspaceTabKind::Terminal(_)))
            && has_active_terminal
    }

    fn start_or_reuse_terminal_tab(
        &mut self,
        repo_id: String,
        path: PathBuf,
        tab_id: WorkspaceTabId,
    ) {
        self.start_or_reuse_terminal_tab_inner(repo_id, path, tab_id, false);
    }

    fn start_or_reuse_terminal_tab_for_retry(
        &mut self,
        repo_id: String,
        path: PathBuf,
        tab_id: WorkspaceTabId,
    ) {
        self.start_or_reuse_terminal_tab_inner(repo_id, path, tab_id, true);
    }

    fn start_or_reuse_terminal_tab_inner(
        &mut self,
        repo_id: String,
        path: PathBuf,
        tab_id: WorkspaceTabId,
        clear_existing_failure: bool,
    ) {
        let terminal_state = self
            .workspace_session
            .terminal_tab_state(&repo_id, &path, tab_id)
            .cloned();

        let Some(terminal_state) = terminal_state else {
            self.active_terminal = None;
            self.active_terminal_tab = None;
            self.terminal_error = Some("No active terminal tab for selected worktree".to_string());
            return;
        };

        let id = TerminalSessionId::new(repo_id, path, tab_id);
        let preserve_failure = terminal_state.failure_cause.is_some() && !clear_existing_failure;
        self.active_terminal_tab = Some(tab_id);
        self.terminal_scroll_offset_rows = terminal_state.scroll_offset_rows;
        self.terminal_error = None;

        if preserve_failure {
            let session = self.terminal_registry.get(&id).or_else(|| {
                terminal_state.backend_session.map(|backend_session| {
                    self.terminal_registry.attach_existing(
                        id.clone(),
                        terminal_state.command.clone(),
                        backend_session,
                    )
                })
            });

            let Some(session) = session else {
                self.active_terminal = None;
                return;
            };

            self.active_terminal = Some(session.clone());
            if let Some(size) = self.terminal_size
                && let Err(error) = self.terminal_backend.resize(session.backend_session, size)
            {
                self.mark_terminal_tab_failed(&session.id, error.to_string());
            }
            return;
        }

        match self.terminal_registry.get_or_start(
            id.clone(),
            terminal_state.command.clone(),
            &mut self.terminal_backend,
        ) {
            Ok(session) => {
                self.active_terminal = Some(session.clone());
                let _ = self.workspace_session.set_tab_backend_session(
                    &session.id.repo_id,
                    &session.id.worktree_path,
                    session.id.tab_id,
                    Some(session.backend_session),
                );

                if let Some(size) = self.terminal_size
                    && let Err(error) = self.terminal_backend.resize(session.backend_session, size)
                {
                    self.mark_terminal_tab_failed(&session.id, error.to_string());
                    return;
                }

                let _ = self.workspace_session.set_tab_status(
                    &session.id.repo_id,
                    &session.id.worktree_path,
                    session.id.tab_id,
                    TerminalTabStatus::Running,
                );
                self.clear_terminal_tab_failure(&session.id);
            }
            Err(error) => {
                self.active_terminal = None;
                self.mark_terminal_tab_failed(&id, error.to_string());
            }
        }
    }

    fn close_workspace_tab(&mut self, tab_id: WorkspaceTabId) {
        let Some(selected) = self.model.selected_worktree().cloned() else {
            return;
        };

        let is_terminal = self
            .workspace_session
            .tab(&selected.repo_id, &selected.path, tab_id)
            .is_some_and(|t| t.is_terminal());

        if is_terminal {
            let session_id =
                TerminalSessionId::new(&selected.repo_id, selected.path.clone(), tab_id);
            if let Some(session) = self.terminal_registry.remove(&session_id) {
                if Some(session.backend_session)
                    == self.active_terminal.as_ref().map(|a| a.backend_session)
                {
                    self.active_terminal = None;
                    self.active_terminal_tab = None;
                    self.terminal_scroll_offset_rows = 0;
                }
                let _ = self.terminal_backend.stop(session.backend_session);
            }
        }

        if let Some(fallback_id) =
            self.workspace_session
                .close_tab(&selected.repo_id, &selected.path, tab_id)
        {
            let is_terminal_fallback = self
                .workspace_session
                .tab(&selected.repo_id, &selected.path, fallback_id)
                .is_some_and(|t| t.is_terminal());

            if is_terminal_fallback {
                self.start_or_reuse_terminal_tab(selected.repo_id, selected.path, fallback_id);
            } else {
                self.active_terminal_tab = Some(fallback_id);
                self.active_terminal = None;
                self.terminal_error = None;
            }
        } else {
            self.active_terminal_tab = None;
            self.active_terminal = None;
            self.terminal_error = None;
        }
    }

    fn open_file_from_inspector(&mut self, file_path: PathBuf, cx: &mut Context<Self>) {
        let Some(selected) = self.model.selected_worktree().cloned() else {
            return;
        };

        let file_path = if file_path.is_absolute() {
            file_path
        } else {
            selected.path.join(file_path)
        };

        let tab_id = self.workspace_session.open_file_tab(
            &selected.repo_id,
            selected.path.clone(),
            file_path.clone(),
        );
        self.select_workspace_tab(tab_id);
        self.load_file_tab_if_needed(
            selected.repo_id.clone(),
            selected.path.clone(),
            tab_id,
            file_path,
            cx,
        );
    }

    fn load_file_tab_if_needed(
        &mut self,
        repo_id: String,
        path: PathBuf,
        tab_id: WorkspaceTabId,
        file_path: PathBuf,
        cx: &mut Context<Self>,
    ) {
        let already_loaded = self
            .workspace_session
            .tab(&repo_id, &path, tab_id)
            .and_then(|tab| match &tab.content {
                WorkspaceTabContent::File(state) => Some(state.load_state.clone()),
                WorkspaceTabContent::Terminal(_) => None,
            })
            .is_some_and(|state| matches!(state, FileTabLoadState::Loaded { .. }));

        if already_loaded {
            return;
        }

        let worktree_path = path.clone();
        let task = cx.background_executor().spawn(async move {
            if !file_path.starts_with(&worktree_path) {
                return Err("file is outside the selected worktree".to_string());
            }

            let metadata = std::fs::metadata(&file_path)
                .map_err(|error| format!("failed to read file metadata: {error}"))?;

            if !metadata.is_file() {
                return Err("path is not a regular file".to_string());
            }
            if metadata.len() > FILE_TAB_MAX_BYTES {
                return Err(format!(
                    "file is too large ({} bytes, max {FILE_TAB_MAX_BYTES})",
                    metadata.len()
                ));
            }

            let content = std::fs::read_to_string(&file_path)
                .map_err(|error| format!("failed to read file: {error}"))?;

            Ok(content)
        });

        cx.spawn(async move |this, cx| {
            let result = task.await;
            this.update(cx, |shell, cx| {
                let load_state = match result {
                    Ok(content) => FileTabLoadState::Loaded { content },
                    Err(message) => FileTabLoadState::Error { message },
                };
                let _ = shell
                    .workspace_session
                    .set_file_tab_load_state(&repo_id, &path, tab_id, load_state);
                cx.notify();
            })
            .ok();
        })
        .detach();
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
                if let Some(path) = menu.worktree_path
                    && let Err(error) = self.archive_worktree(&menu.repo_id, path)
                {
                    self.set_add_repository_error(error.to_string());
                }
            }
            ActionId::UnarchiveWorktree => {
                if let Some(path) = menu.worktree_path
                    && let Err(error) = self.unarchive_worktree(&menu.repo_id, &path)
                {
                    self.set_add_repository_error(error.to_string());
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

    fn handle_sidebar_menu_action_from_target(
        &mut self,
        menu: SidebarMenuState,
        action_id: ActionId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.sidebar_menu = Some(menu);
        self.handle_sidebar_menu_action(action_id, window, cx);
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
                if should_remove && let Err(error) = shell.remove_repository_from_alas(&repo_id) {
                    shell.set_add_repository_error(error.to_string());
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
                if should_remove && let Err(error) = shell.remove_worktree(&repo_id, &path) {
                    shell.set_add_repository_error(error.to_string());
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
                if should_prune && let Err(error) = shell.prune_worktrees(&repo_id) {
                    shell.set_add_repository_error(error.to_string());
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

    fn shutdown(&mut self) {
        let sessions = self.terminal_registry.remove_all_sessions();
        self.stop_terminal_sessions(sessions);
        self.active_terminal = None;
        self.active_terminal_tab = None;
        self.terminal_scroll_offset_rows = 0;
    }

    fn register_app_quit_cleanup(&self, cx: &mut Context<Self>) {
        cx.on_app_quit(|shell, _cx| {
            shell.shutdown();
            async {}
        })
        .detach();
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

fn terminal_status_from_tab_status(status: &TerminalTabStatus) -> Option<TerminalStatus> {
    match status {
        TerminalTabStatus::NotStarted => None,
        TerminalTabStatus::Running => Some(TerminalStatus::Running),
        TerminalTabStatus::Exited(status) => Some(TerminalStatus::Exited(*status)),
        TerminalTabStatus::Failed => Some(TerminalStatus::Failed),
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

fn terminal_mouse_modifiers(modifiers: gpui::Modifiers) -> TerminalKeyModifiers {
    TerminalKeyModifiers {
        control: modifiers.control,
        alt: modifiers.alt,
        shift: modifiers.shift,
        platform: modifiers.platform,
        function: modifiers.function,
    }
}

fn terminal_mouse_button(button: MouseButton) -> Option<TerminalMouseButton> {
    match button {
        MouseButton::Left => Some(TerminalMouseButton::Left),
        MouseButton::Right => Some(TerminalMouseButton::Right),
        MouseButton::Middle => Some(TerminalMouseButton::Middle),
        MouseButton::Navigate(_) => None,
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
    active_tab_kind: Option<WorkspaceTabKind>,
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
        None if matches!(active_tab_kind, Some(WorkspaceTabKind::File)) => {
            ("file".to_string(), TEXT_MUTED)
        }
        None if active_tab_kind.is_none() => ("no tab".to_string(), TEXT_MUTED),
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
        let measured_metrics =
            measure_terminal_metrics(window, TERMINAL_FONT_FAMILY, TERMINAL_FONT_SIZE_PX);
        if self.terminal_metrics != measured_metrics {
            self.terminal_metrics = measured_metrics;
        }

        let terminal_size = self.current_terminal_size();
        self.resize_active_terminal(terminal_size);
        let terminal_frame = self.terminal_render_frame();
        self.refresh_active_terminal_status();

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
        let on_toggle_file_tree_node =
            move |path: PathBuf, _event: &gpui::ClickEvent, _window: &mut Window, app: &mut App| {
                view.update(app, |shell, cx| {
                    shell
                        .file_tree_expansion
                        .toggle(crate::ui::view_models::TreeExpansionKey::File(path.clone()));
                    cx.notify();
                })
                .ok();
            };
        let view = cx.entity().downgrade();
        let on_open_file_from_inspector =
            move |file_path: PathBuf,
                  _event: &gpui::ClickEvent,
                  _window: &mut Window,
                  app: &mut App| {
                view.update(app, |shell, cx| {
                    shell.open_file_from_inspector(file_path, cx);
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
            if shell.handle_terminal_key_down(event, cx) {
                cx.stop_propagation();
            }
        });
        let on_retry_terminal = cx.listener(|shell, _event, _window, cx| {
            shell.retry_active_terminal();
            cx.notify();
        });
        let on_edit_terminal_command = cx.listener(|shell, _event, _window, cx| {
            if let Some(selected) = shell.model.selected_worktree().cloned() {
                shell.open_command_settings_dialog(selected.repo_id, cx);
            }
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
        let on_terminal_mouse_down = cx.listener(|shell, event: &MouseDownEvent, window, cx| {
            window.focus(&shell.terminal_focus);
            let Some(button) = terminal_mouse_button(event.button) else {
                return;
            };
            if shell.write_terminal_mouse_event(
                TerminalMouseAction::Press,
                button,
                event.position,
                event.modifiers,
            ) {
                cx.stop_propagation();
                cx.notify();
            }
        });
        let on_terminal_mouse_up = cx.listener(|shell, event: &MouseUpEvent, _window, cx| {
            let Some(button) = terminal_mouse_button(event.button) else {
                return;
            };
            if shell.write_terminal_mouse_event(
                TerminalMouseAction::Release,
                button,
                event.position,
                event.modifiers,
            ) {
                cx.stop_propagation();
                cx.notify();
            }
        });
        let on_terminal_mouse_move = cx.listener(|shell, event: &MouseMoveEvent, _window, cx| {
            let button = event
                .pressed_button
                .and_then(terminal_mouse_button)
                .unwrap_or(TerminalMouseButton::None);
            if shell.write_terminal_mouse_event(
                TerminalMouseAction::Motion,
                button,
                event.position,
                event.modifiers,
            ) {
                cx.stop_propagation();
                cx.notify();
            }
        });
        let terminal_screen_mode = terminal_frame
            .as_ref()
            .map(|frame| frame.screen_mode)
            .unwrap_or(TerminalScreenMode::Main);
        let terminal_scrollback_rows = terminal_frame
            .as_ref()
            .map_or(0, |frame| frame.scrollback_rows);
        let on_terminal_scroll =
            cx.listener(move |shell, event: &ScrollWheelEvent, _window, cx| {
                if shell.write_terminal_wheel_input(event)
                    || shell.scroll_terminal(event, terminal_screen_mode, terminal_scrollback_rows)
                {
                    cx.stop_propagation();
                    cx.notify();
                }
            });
        let view = cx.entity().downgrade();
        let on_terminal_body_bounds = move |bounds: gpui::Bounds<gpui::Pixels>, app: &mut App| {
            view.update(app, |shell, cx| {
                if shell.update_terminal_body_bounds(bounds) {
                    cx.notify();
                }
            })
            .ok();
        };
        let view = cx.entity().downgrade();
        let on_select_workspace_tab = move |tab_id: WorkspaceTabId,
                                            _event: &gpui::ClickEvent,
                                            _window: &mut Window,
                                            app: &mut App| {
            view.update(app, |shell, cx| {
                shell.select_workspace_tab(tab_id);
                cx.notify();
            })
            .ok();
        };
        let view = cx.entity().downgrade();
        let on_close_workspace_tab = move |tab_id: WorkspaceTabId,
                                           _event: &gpui::ClickEvent,
                                           _window: &mut Window,
                                           app: &mut App| {
            view.update(app, |shell, cx| {
                shell.close_workspace_tab(tab_id);
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
        let on_sidebar_menu_action = move |menu: SidebarMenuState,
                                           action_id: ActionId,
                                           _event: &gpui::ClickEvent,
                                           window: &mut Window,
                                           app: &mut App| {
            let view = view.clone();
            view.update(app, |shell, cx| {
                shell.handle_sidebar_menu_action_from_target(menu, action_id, window, cx);
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
        let status_bar_tab = match active_tab {
            Some(tab) => tab.name.clone(),
            None => "No tab".to_string(),
        };
        let is_active_terminal_tab = active_tab.is_some_and(|t| t.is_terminal());
        let active_terminal_error = active_tab
            .and_then(|t| t.terminal_tab_state())
            .and_then(|state| state.failure_cause.as_deref())
            .or_else(|| {
                active_tab
                    .is_none()
                    .then_some(self.terminal_error.as_deref())
                    .flatten()
            });
        let active_terminal_status = if active_terminal_error.is_some() {
            Some(TerminalStatus::Failed)
        } else {
            active_tab
                .and_then(|t| t.terminal_tab_state())
                .and_then(|state| terminal_status_from_tab_status(&state.status))
        };
        let status_bar_terminal_status = if active_terminal_error.is_some() {
            Some(TerminalTabStatus::Failed)
        } else if is_active_terminal_tab {
            active_tab
                .and_then(|t| t.terminal_tab_state())
                .map(|state| state.status.clone())
        } else {
            None
        };

        let selected_worktree = self.model.selected_worktree();
        let terminal_state = active_tab.and_then(|t| t.terminal_tab_state());
        let file_load_state = active_tab.and_then(|t| match &t.content {
            WorkspaceTabContent::File(state) => Some(state.load_state.clone()),
            WorkspaceTabContent::Terminal(_) => None,
        });

        let workspace_body = if let Some(load_state) = file_load_state {
            render_file_pane(&load_state).into_any_element()
        } else {
            render_terminal_pane(
                selected_worktree,
                active_tab,
                terminal_state,
                terminal_frame,
                active_terminal_status,
                self.terminal_metrics,
                active_terminal_error,
                on_retry_terminal,
                on_edit_terminal_command,
                on_restart_terminal,
                on_focus_terminal,
                on_terminal_scroll,
                on_terminal_mouse_down,
                on_terminal_mouse_up,
                on_terminal_mouse_move,
                on_terminal_body_bounds,
            )
            .into_any_element()
        };
        div()
            .on_action(cx.listener(|_shell, _: &crate::ui::lifecycle::Quit, _window, cx| {
                cx.quit();
            }))
            .relative()
            .flex()
            .size_full()
            // On macOS the root is intentionally unpainted so the window's
            // NSVisualEffectView material shows through anywhere a child
            // does not paint its own background.
            .when_some(root_background(), |element, color| element.bg(color))
            .text_color(TEXT)
            .child(render_sidebar(
                self.model.repositories(),
                self.model.selected_worktree(),
                cx.listener(|shell, _event, _window, cx| shell.open_add_repository_dialog(cx)),
                on_select_worktree,
                on_sidebar_menu_action,
                self.add_repository_error(),
            ))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .min_w(px(0.0))
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
                                on_select_workspace_tab,
                                on_close_workspace_tab,
                                on_new_terminal_tab,
                                workspace_body,
                            )),
                    ),
            )
            .child(render_project_inspector(
                self.model.selected_worktree(),
                &self.inspector_state,
                &self.file_tree_expansion,
                on_toggle_file_tree_node,
                on_open_file_from_inspector,
            ))
            .child(render_status_bar(
                status_bar_repo,
                status_bar_tab,
                status_bar_terminal_status.as_ref(),
                active_tab.map(|tab| tab.kind),
            ))
    }
}

pub fn run() -> anyhow::Result<()> {
    Application::new().run(|cx: &mut App| {
        crate::ui::lifecycle::setup_lifecycle(cx);
        gpui_component::init(cx);

        cx.open_window(alas_window_options(), |window, cx| {
            apply_window_background_appearance(window);
            let shell = cx.new(AlasShell::new);
            let weak_shell = shell.downgrade();
            let weak_shell_for_keys = shell.downgrade();
            cx.intercept_keystrokes(move |event, window, cx| {
                weak_shell_for_keys
                    .update(cx, |shell, cx| {
                        if !terminal_should_intercept_key(
                            shell.terminal_focus.contains_focused(window, cx),
                        ) {
                            return;
                        }

                        let key_down = KeyDownEvent {
                            keystroke: event.keystroke.clone(),
                            is_held: false,
                        };
                        if shell.handle_terminal_key_down(&key_down, cx) {
                            cx.stop_propagation();
                        }
                    })
                    .ok();
            })
            .detach();
            window.on_window_should_close(cx, move |_window, cx| {
                weak_shell.update(cx, |shell, _cx| shell.shutdown()).ok();
                true
            });
            cx.new(|cx| gpui_component::Root::new(shell, window, cx))
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminal_refresh_interval_targets_sixty_fps_input_echo() {
        assert!(terminal_refresh_interval() <= Duration::from_millis(16));
    }

    #[test]
    fn terminal_intercepts_keys_only_while_focused() {
        assert!(terminal_should_intercept_key(true));
        assert!(!terminal_should_intercept_key(false));
    }

    #[test]
    fn terminal_tab_with_active_session_routes_terminal_input() {
        assert!(AlasShell::should_route_terminal_input_for(
            Some(WorkspaceTabKind::Terminal(TerminalTabKind::Shell)),
            true,
        ));
    }

    #[test]
    fn file_tab_does_not_route_terminal_input() {
        assert!(!AlasShell::should_route_terminal_input_for(
            Some(WorkspaceTabKind::File),
            true,
        ));
    }

    #[test]
    fn terminal_tab_without_active_session_does_not_route_terminal_input() {
        assert!(!AlasShell::should_route_terminal_input_for(
            Some(WorkspaceTabKind::Terminal(TerminalTabKind::Shell)),
            false,
        ));
    }
}
