use std::{
    path::{Path, PathBuf},
    time::Duration,
};

use directories::ProjectDirs;

use crate::{
    agent::{
        AcpCancelHandle, AcpProcessConnection, AgentDebugEvent, AgentProviderConfig,
        AgentProviderSuggestion, AgentRuntime, AgentThreadRecord, AgentThreadState,
        AgentThreadStatus, AgentThreadStore, AgentTranscriptEntry, AgentTrustMode,
        OsCredentialStore, ProviderSettingsState, apply_provider_discovery_to_config,
        discover_agent_providers, filter_agent_thread_records, merge_agent_thread_records,
        remove_provider_and_record_discovery_ignore, resolve_provider_cwd,
    },
    app::{
        ActionId, AlasModel, FileLoader, FileTabLoadState, HighlightError, ImageZoom,
        InspectorPaneState, MarkdownViewMode, RepositoryNode, TerminalTabKind, TerminalTabStatus,
        WorkspaceSession, WorkspaceTabContent, WorkspaceTabId, WorkspaceTabKind, highlight_source,
        is_supported_image_path,
    },
    config::{
        AppConfig, AppConfigStore, AppRepository, CommandEntry, RepoConfigStore,
        ResolvedRepoConfig, repository_id_for_path,
    },
    git::{GitInspectorService, GitRunner, GitWorktreeService},
    notifications::{
        DefaultAppFocusState, DefaultNotificationSink, NotificationActivation,
        NotificationController, NotificationTabTarget, drain_notification_activations,
    },
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
        agent_pane::{AgentPaneHandlers, render_agent_pane},
        chrome::{alas_window_options, apply_window_background_appearance},
        command_picker::render_command_picker,
        dialogs::{
            AddRepositoryDialogState, CommandSettingsDialogState, ConfirmPruneWorktreesDialog,
            ConfirmRemoveRepositoryDialog, ConfirmRemoveWorktreeDialog, CreateWorktreeDialogState,
            CreateWorktreeField, NotificationPreferencesDialogState,
        },
        image_view::render_image_view,
        inspector::render_project_inspector,
        markdown_pane::render_markdown_pane,
        provider_settings::{
            ProviderSettingsField, ProviderSettingsHandlers, render_provider_settings,
        },
        resize_handle::{
            RESIZE_HANDLE_WIDTH_PX, SidebarLayoutState, SidebarResizeDrag, SidebarResizeTarget,
            clamp_sidebar_width,
        },
        sidebar::{SidebarMenuState, render_sidebar},
        source_viewer::render_source_viewer,
        terminal_canvas::measure_terminal_metrics,
        terminal_pane::render_terminal_pane,
        terminal_view::{
            TERMINAL_CANVAS_HORIZONTAL_PADDING_PX, TERMINAL_FONT_FAMILY, TERMINAL_FONT_SIZE_PX,
        },
        theme::{DANGER, PANEL_BG, PANEL_BORDER, SUCCESS, TEXT, TEXT_MUTED, root_background},
        view_models::TreeExpansionState,
        workspace::{
            AgentChatProviderFlow, NewWorkspaceTabChoice, agent_chat_provider_flow,
            new_workspace_tab_choice_label, new_workspace_tab_choices, render_workspace,
        },
    },
};
use gpui::{
    App, Application, Bounds, ClipboardItem, Context, FocusHandle, IntoElement, KeyDownEvent,
    MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent, PathPromptOptions, Pixels,
    PromptLevel, Render, ScrollDelta, ScrollWheelEvent, SharedString, Task, Window, div,
    prelude::*, px, rgb, transparent_black,
};
use indexmap::IndexMap;
use std::{
    borrow::BorrowMut,
    collections::{BTreeMap, BTreeSet, HashMap},
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
};

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

fn agent_thread_persist_debounce_interval() -> Duration {
    Duration::from_millis(400)
}

fn provider_plain_env(
    settings: &ProviderSettingsState,
    provider_id: &str,
) -> Option<(String, String)> {
    let provider = settings
        .providers
        .iter()
        .find(|provider| provider.id == provider_id)?;
    Some(
        provider
            .env
            .iter()
            .find(|entry| entry.secure_ref.is_none())
            .map(|entry| {
                (
                    entry.name.clone(),
                    entry.value.clone().unwrap_or_else(String::new),
                )
            })
            .unwrap_or_else(|| (String::new(), String::new())),
    )
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
    notification_preferences_dialog: Option<NotificationPreferencesDialogState>,
    notification_controller: NotificationController<DefaultNotificationSink, DefaultAppFocusState>,
    command_picker: Option<CommandPickerState>,
    new_tab_picker_open: bool,
    agent_provider_picker: Option<Vec<AgentProviderConfig>>,
    provider_discovery_suggestions: Vec<AgentProviderSuggestion>,
    provider_discovery_error: Option<String>,
    provider_settings: Option<ProviderSettingsState>,
    provider_settings_focus: FocusHandle,
    provider_settings_active_field: Option<ProviderSettingsField>,
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
    agent_composer_focus: FocusHandle,
    active_agent_composer_tab: Option<WorkspaceTabId>,
    inspector_state: InspectorPaneState,
    inspector_request_generation: u64,
    file_tree_expansion: TreeExpansionState,
    sidebar_layout: SidebarLayoutState,
    active_sidebar_resize: Option<SidebarResizeDrag>,
    agent_runtimes: HashMap<WorkspaceTabId, AgentRuntime<AcpProcessConnection>>,
    agent_cancel_handles: HashMap<WorkspaceTabId, AcpCancelHandle>,
    agent_thread_store: AgentThreadStore,
    agent_thread_records_cache: BTreeMap<String, AgentThreadRecord>,
    agent_thread_records_loaded: bool,
    pending_agent_thread_exclusions: BTreeSet<String>,
    pending_removed_agent_worktrees: BTreeSet<PathBuf>,
    pending_removed_agent_repos: BTreeSet<PathBuf>,
    agent_thread_persist_generation: Arc<AtomicU64>,
    agent_thread_persist_lock: Arc<Mutex<()>>,
}

impl AlasShell {
    fn new(cx: &mut Context<Self>) -> Self {
        let app_config_store =
            AppConfigStore::default_store().expect("failed to resolve app config store");
        let mut config = app_config_store.load().unwrap_or_default();
        let notification_preferences = config.notifications.clone();
        let sidebar_layout = SidebarLayoutState::from_config(
            config.layout.left_sidebar_width_px,
            config.layout.right_sidebar_width_px,
        );
        let provider_discovery = discover_agent_providers();
        let provider_discovery_startup =
            apply_provider_discovery_to_config(&mut config, &provider_discovery, |config| {
                app_config_store.save(config)
            });

        let agent_thread_store = AgentThreadStore::new(
            ProjectDirs::from("dev", "alas", "Alas")
                .expect("failed to resolve app data directory")
                .data_dir()
                .join("agent_threads.json"),
        );
        let agent_thread_records_cache = BTreeMap::new();

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
            notification_preferences_dialog: None,
            notification_controller: NotificationController::new_with_preferences_and_focus(
                DefaultNotificationSink::default(),
                notification_preferences,
                DefaultAppFocusState::default(),
            ),
            command_picker: None,
            new_tab_picker_open: false,
            agent_provider_picker: None,
            provider_discovery_suggestions: provider_discovery_startup.suggestions,
            provider_discovery_error: provider_discovery_startup.error,
            provider_settings: None,
            provider_settings_focus: cx.focus_handle(),
            provider_settings_active_field: None,
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
            agent_composer_focus: cx.focus_handle(),
            active_agent_composer_tab: None,
            inspector_state: InspectorPaneState::default(),
            inspector_request_generation: 0,
            file_tree_expansion: TreeExpansionState::default(),
            sidebar_layout,
            active_sidebar_resize: None,
            agent_runtimes: HashMap::new(),
            agent_cancel_handles: HashMap::new(),
            agent_thread_store,
            agent_thread_records_cache,
            agent_thread_records_loaded: false,
            pending_agent_thread_exclusions: BTreeSet::new(),
            pending_removed_agent_worktrees: BTreeSet::new(),
            pending_removed_agent_repos: BTreeSet::new(),
            agent_thread_persist_generation: Arc::new(AtomicU64::new(0)),
            agent_thread_persist_lock: Arc::new(Mutex::new(())),
        };
        shell.start_agent_thread_record_load(cx);
        shell.refresh_repositories_and_restore_agent_threads(cx);
        shell.start_terminal_refresh(cx);
        shell.register_app_quit_cleanup(cx);
        shell
    }

    fn start_agent_thread_record_load(&self, cx: &mut Context<Self>) {
        let store = self.agent_thread_store.clone();
        let task = cx
            .background_executor()
            .spawn(async move { store.load_records() });

        cx.spawn(async move |this, cx| {
            let result = task.await;
            this.update(cx, |shell, cx| {
                let loaded_records = match result {
                    Ok(records) => records,
                    Err(error) => {
                        eprintln!("failed to load agent threads: {error:#}");
                        Vec::new()
                    }
                };
                let loaded_records = filter_agent_thread_records(
                    loaded_records,
                    shell.pending_agent_thread_exclusions.iter().cloned(),
                    shell.pending_removed_agent_worktrees.iter().cloned(),
                    shell.pending_removed_agent_repos.iter().cloned(),
                );
                let records = merge_agent_thread_records(
                    loaded_records,
                    shell.workspace_session.agent_thread_records(),
                    Vec::<String>::new(),
                );
                shell.agent_thread_records_cache = records
                    .iter()
                    .cloned()
                    .map(|record| (record.thread_id.clone(), record))
                    .collect();
                shell.agent_thread_records_loaded = true;
                shell.pending_agent_thread_exclusions.clear();
                shell.pending_removed_agent_worktrees.clear();
                shell.pending_removed_agent_repos.clear();
                shell.restore_agent_threads_for_known_worktrees(cx);
            })
            .ok();
        })
        .detach();
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

        if self.handle_image_key_down(event) {
            cx.notify();
            return true;
        }

        if !self.should_route_terminal_input() {
            return false;
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
                        shell.add_repository_from_dialog(cx);
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

    fn add_repository_from_dialog(&mut self, cx: &mut Context<Self>) {
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
        self.refresh_repositories_and_restore_agent_threads(cx);
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

    fn open_notification_preferences_dialog(&mut self) {
        self.notification_preferences_dialog = Some(
            NotificationPreferencesDialogState::from_config(&self.config),
        );
    }

    fn close_notification_preferences_dialog(&mut self) {
        self.notification_preferences_dialog = None;
    }

    fn toggle_harness_completion_notifications(&mut self) {
        if let Some(dialog) = self.notification_preferences_dialog.as_mut() {
            dialog.harness_completion_enabled = !dialog.harness_completion_enabled;
            dialog.error = None;
        }
    }

    fn toggle_success_completion_notifications(&mut self) {
        if let Some(dialog) = self.notification_preferences_dialog.as_mut() {
            dialog.harness_completion_success = !dialog.harness_completion_success;
            dialog.error = None;
        }
    }

    fn toggle_failure_completion_notifications(&mut self) {
        if let Some(dialog) = self.notification_preferences_dialog.as_mut() {
            dialog.harness_completion_failure = !dialog.harness_completion_failure;
            dialog.error = None;
        }
    }

    fn save_notification_preferences_from_dialog(&mut self) {
        let Some(dialog) = self.notification_preferences_dialog.clone() else {
            return;
        };
        let mut next_config = self.config.clone();
        dialog.apply_to_config(&mut next_config);

        if let Err(error) = self.app_config_store.save(&next_config) {
            self.set_notification_preferences_error(error.to_string());
            return;
        }
        self.config = next_config;
        self.notification_controller
            .update_preferences(self.config.notifications.clone());
        self.notification_preferences_dialog = None;
    }

    fn set_notification_preferences_error(&mut self, error: impl Into<String>) {
        if let Some(dialog) = self.notification_preferences_dialog.as_mut() {
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

        self.refresh_repositories_and_restore_agent_threads(cx);
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
        self.start_or_reuse_terminal_tab(repo_id.clone(), path.clone(), tab_id);
        self.restore_agent_threads_for_selected_worktree(cx);
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
            self.active_agent_composer_tab = None;
            self.terminal_scroll_offset_rows = 0;
            self.terminal_error = None;
        }
    }

    fn drain_notification_activations(&mut self, window: &mut gpui::Window) {
        for activation in drain_notification_activations() {
            match activation {
                NotificationActivation::HarnessCompletion(target) => {
                    self.activate_harness_notification(target, window);
                }
            }
        }
    }

    fn activate_harness_notification(
        &mut self,
        target: NotificationTabTarget,
        window: &mut gpui::Window,
    ) {
        if self
            .workspace_session
            .activate_terminal_tab_target(&target)
            .is_err()
        {
            window.focus(&self.terminal_focus);
            return;
        }

        self.model
            .select_worktree(target.repo_id.clone(), target.worktree_path.clone());
        self.start_or_reuse_terminal_tab(
            target.repo_id,
            target.worktree_path,
            target.terminal_tab_id,
        );
        window.focus(&self.terminal_focus);
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

    fn active_image_zoom(&self) -> Option<(WorkspaceTabId, ImageZoom)> {
        let selected = self.model.selected_worktree()?;
        let tab = self
            .workspace_session
            .active_tab(&selected.repo_id, &selected.path)?;
        tab.image_tab_state().map(|state| (tab.id, state.zoom))
    }

    fn set_image_zoom_for_tab(&mut self, tab_id: WorkspaceTabId, zoom: ImageZoom) {
        let Some(selected) = self.model.selected_worktree().cloned() else {
            return;
        };
        let _ =
            self.workspace_session
                .set_image_zoom(&selected.repo_id, &selected.path, tab_id, zoom);
    }

    fn handle_image_key_down(&mut self, event: &KeyDownEvent) -> bool {
        let Some((tab_id, zoom)) = self.active_image_zoom() else {
            return false;
        };
        if !event.keystroke.modifiers.platform {
            return false;
        }

        match event.keystroke.key.as_str() {
            "=" | "+" => self.set_image_zoom_for_tab(tab_id, zoom.zoom_in()),
            "-" => self.set_image_zoom_for_tab(tab_id, zoom.zoom_out()),
            "0" => self.set_image_zoom_for_tab(tab_id, ImageZoom::Fit),
            _ => return false,
        }
        true
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

    fn close_workspace_tab(&mut self, tab_id: WorkspaceTabId, cx: &mut Context<Self>) {
        let Some(selected) = self.model.selected_worktree().cloned() else {
            return;
        };

        let tab = self
            .workspace_session
            .tab(&selected.repo_id, &selected.path, tab_id);
        let is_terminal = tab.is_some_and(|t| t.is_terminal());
        let closed_agent_thread_id = tab
            .and_then(|tab| tab.agent_thread_state())
            .map(|thread| thread.thread_id.clone());

        self.agent_runtimes.remove(&tab_id);
        self.agent_cancel_handles.remove(&tab_id);
        if self.active_agent_composer_tab == Some(tab_id) {
            self.active_agent_composer_tab = None;
        }

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
                self.active_agent_composer_tab = None;
                self.terminal_error = None;
            }
        } else {
            self.active_terminal_tab = None;
            self.active_terminal = None;
            self.terminal_error = None;
        }
        self.persist_agent_threads_excluding(closed_agent_thread_id.as_deref(), cx);
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

        if is_supported_image_path(&file_path) {
            let tab_id = self.workspace_session.open_or_focus_image_tab(
                &selected.repo_id,
                selected.path.clone(),
                file_path,
            );
            self.select_workspace_tab(tab_id);
            return;
        }

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
                WorkspaceTabContent::Markdown(state) => Some(state.file.load_state.clone()),
                WorkspaceTabContent::Terminal(_)
                | WorkspaceTabContent::Image(_)
                | WorkspaceTabContent::AgentChat(_) => None,
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

            let loaded = FileLoader::default()
                .load_source_file(&file_path)
                .map_err(|error| error.to_string())?;
            let language = crate::app::detect_language(&file_path);
            let (highlight, highlight_error) = match highlight_source(&loaded.text, language) {
                Ok(highlight) => (Some(highlight), None),
                Err(HighlightError::Unsupported(_)) => (None, None),
                Err(error) => (None, Some(error.to_string())),
            };

            Ok(FileTabLoadState::Loaded {
                content: loaded.text,
                size_bytes: loaded.size_bytes,
                line_count: loaded.line_count,
                highlight,
                highlight_error,
            })
        });

        cx.spawn(async move |this, cx| {
            let result = task.await;
            this.update(cx, |shell, cx| {
                let load_state = match result {
                    Ok(load_state) => load_state,
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
        self.provider_settings = None;
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

    fn open_new_tab_picker(&mut self, cx: &mut Context<Self>) {
        self.new_tab_picker_open = true;
        self.command_picker = None;
        self.agent_provider_picker = None;
        self.provider_settings = None;
        cx.notify();
    }

    fn close_new_tab_picker(&mut self) {
        self.new_tab_picker_open = false;
    }

    fn open_provider_settings(&mut self, cx: &mut Context<Self>) {
        self.new_tab_picker_open = false;
        self.agent_provider_picker = None;
        let mut settings = ProviderSettingsState {
            providers: self.config.agent_providers.clone(),
            selected_provider_id: self
                .config
                .agent_providers
                .first()
                .map(|provider| provider.id.clone()),
            discovery_suggestions: self.provider_discovery_suggestions.clone(),
            ..ProviderSettingsState::default()
        };
        if let Some(error) = self.provider_discovery_error.as_ref() {
            settings.error = Some(error.clone());
        }
        self.provider_settings = Some(settings);
        self.provider_settings_active_field = None;
        cx.notify();
    }

    fn close_provider_settings(&mut self) {
        self.provider_settings = None;
        self.provider_settings_active_field = None;
    }

    fn add_provider_settings_entry(&mut self) {
        let Some(settings) = self.provider_settings.as_mut() else {
            return;
        };
        let mut index = settings.providers.len() + 1;
        let provider_id = loop {
            let candidate = format!("provider-{index}");
            if !settings
                .providers
                .iter()
                .any(|provider| provider.id == candidate)
            {
                break candidate;
            }
            index += 1;
        };
        settings.add_provider(AgentProviderConfig::new(
            provider_id.clone(),
            "New Provider",
            "agent-acp",
        ));
        self.provider_settings_active_field = Some(ProviderSettingsField::DisplayName(provider_id));
    }

    fn set_provider_settings_field(&mut self, field: ProviderSettingsField) {
        self.provider_settings_active_field = Some(field);
        if let Some(settings) = self.provider_settings.as_mut() {
            settings.error = None;
        }
    }

    fn edit_provider_settings_field(
        &mut self,
        event: &KeyDownEvent,
        cx: &mut Context<Self>,
    ) -> bool {
        if self.provider_settings.is_none() || self.provider_settings_active_field.is_none() {
            return false;
        }

        match event.keystroke.key.as_str() {
            "escape" => {
                self.provider_settings_active_field = None;
                return true;
            }
            "enter" => {
                self.save_provider_settings(cx);
                return true;
            }
            "tab" => {
                self.advance_provider_settings_field();
                return true;
            }
            "backspace" => {
                self.edit_active_provider_settings_text(|text| {
                    text.pop();
                });
                return true;
            }
            _ => {}
        }

        if event.keystroke.modifiers.control || event.keystroke.modifiers.platform {
            return false;
        }
        if let Some(text) = event.keystroke.key_char.as_deref() {
            self.edit_active_provider_settings_text(|active_text| active_text.push_str(text));
            return true;
        }

        false
    }

    fn edit_active_provider_settings_text(&mut self, edit: impl FnOnce(&mut String)) {
        let Some(field) = self.provider_settings_active_field.clone() else {
            return;
        };
        let Some(settings) = self.provider_settings.as_mut() else {
            return;
        };
        match field {
            ProviderSettingsField::DisplayName(provider_id) => {
                if let Some(provider) = settings
                    .providers
                    .iter()
                    .find(|provider| provider.id == provider_id)
                {
                    let mut value = provider.display_name.clone();
                    edit(&mut value);
                    settings.update_display_name(&provider_id, value);
                }
            }
            ProviderSettingsField::Command(provider_id) => {
                if let Some(provider) = settings
                    .providers
                    .iter()
                    .find(|provider| provider.id == provider_id)
                {
                    let mut value = provider.command.clone();
                    edit(&mut value);
                    settings.update_command(&provider_id, value);
                }
            }
            ProviderSettingsField::Args(provider_id) => {
                let _ = settings.edit_args_json(&provider_id, edit);
            }
            ProviderSettingsField::EnvKey(provider_id) => {
                if let Some((mut key, value)) = provider_plain_env(settings, &provider_id) {
                    edit(&mut key);
                    settings.update_plain_env(&provider_id, vec![(key, value)]);
                }
            }
            ProviderSettingsField::EnvValue(provider_id) => {
                if let Some((key, mut value)) = provider_plain_env(settings, &provider_id) {
                    edit(&mut value);
                    settings.update_plain_env(&provider_id, vec![(key, value)]);
                }
            }
            ProviderSettingsField::AuthEnvValue {
                provider_id,
                env_name,
            } => {
                let mut value = settings.auth_env_value(&provider_id, &env_name);
                edit(&mut value);
                settings.update_auth_env_value(&provider_id, &env_name, value);
            }
        }
    }

    fn authenticate_provider_settings(&mut self, provider_id: &str, cx: &mut Context<Self>) {
        let Some(settings) = self.provider_settings.as_ref() else {
            return;
        };
        let provider_id = provider_id.to_string();
        let original_provider = settings
            .providers
            .iter()
            .find(|provider| provider.id == provider_id)
            .cloned();
        let mut next_settings = settings.clone();
        let task = cx.background_executor().spawn(async move {
            let result = next_settings
                .authenticate_with_available_method(&provider_id, &OsCredentialStore)
                .map_err(|error| error.to_string());
            (provider_id, original_provider, next_settings, result)
        });

        cx.spawn(async move |this, cx| {
            let (provider_id, original_provider, mut next_settings, result) = task.await;
            this.update(cx, |shell, cx| {
                let Some(current_settings) = shell.provider_settings.as_mut() else {
                    return;
                };
                let provider_unchanged = current_settings
                    .providers
                    .iter()
                    .find(|provider| provider.id == provider_id)
                    == original_provider.as_ref();
                if !provider_unchanged {
                    return;
                }
                if let Err(error) = result {
                    next_settings.error = Some(error);
                }
                current_settings.apply_auth_io_result(&provider_id, &next_settings);
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    fn run_provider_settings_terminal_auth(&mut self, provider_id: &str) {
        if let Some(settings) = self.provider_settings.as_mut() {
            settings.mark_terminal_auth_unavailable(provider_id);
        }
    }

    fn clear_provider_settings_credentials(&mut self, provider_id: &str, cx: &mut Context<Self>) {
        let Some(settings) = self.provider_settings.as_ref() else {
            return;
        };
        let provider_id = provider_id.to_string();
        let original_provider = settings
            .providers
            .iter()
            .find(|provider| provider.id == provider_id)
            .cloned();
        let mut next_settings = settings.clone();
        let task = cx.background_executor().spawn(async move {
            let result = next_settings
                .clear_env_auth_values(&provider_id, &OsCredentialStore)
                .map_err(|error| error.to_string());
            (provider_id, original_provider, next_settings, result)
        });

        cx.spawn(async move |this, cx| {
            let (provider_id, original_provider, mut next_settings, result) = task.await;
            this.update(cx, |shell, cx| {
                let Some(current_settings) = shell.provider_settings.as_mut() else {
                    return;
                };
                let provider_unchanged = current_settings
                    .providers
                    .iter()
                    .find(|provider| provider.id == provider_id)
                    == original_provider.as_ref();
                if !provider_unchanged {
                    return;
                }
                if let Err(error) = result {
                    next_settings.error = Some(error);
                }
                current_settings.apply_clear_auth_io_result(&provider_id, &next_settings);
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    fn view_provider_settings_auth_instructions(&mut self, provider_id: &str) {
        if let Some(settings) = self.provider_settings.as_mut() {
            settings.show_auth_instructions(provider_id);
        }
    }

    fn advance_provider_settings_field(&mut self) {
        let Some(settings) = self.provider_settings.as_ref() else {
            return;
        };
        if settings.providers.is_empty() {
            self.provider_settings_active_field = None;
            return;
        }
        let fields = settings
            .providers
            .iter()
            .flat_map(|provider| {
                [
                    ProviderSettingsField::DisplayName(provider.id.clone()),
                    ProviderSettingsField::Command(provider.id.clone()),
                    ProviderSettingsField::Args(provider.id.clone()),
                    ProviderSettingsField::EnvKey(provider.id.clone()),
                    ProviderSettingsField::EnvValue(provider.id.clone()),
                ]
                .into_iter()
                .chain(provider.auth_methods.iter().flat_map(|method| {
                    match method {
                        crate::agent::AgentAuthMethod::EnvVar { fields, .. } => fields
                            .iter()
                            .map(|field| ProviderSettingsField::AuthEnvValue {
                                provider_id: provider.id.clone(),
                                env_name: field.env_name.clone(),
                            })
                            .collect::<Vec<_>>(),
                        crate::agent::AgentAuthMethod::Agent { .. }
                        | crate::agent::AgentAuthMethod::Terminal { .. } => Vec::new(),
                    }
                }))
            })
            .collect::<Vec<_>>();
        let next_index = self
            .provider_settings_active_field
            .as_ref()
            .and_then(|active| fields.iter().position(|field| field == active))
            .map(|index| (index + 1) % fields.len())
            .unwrap_or(0);
        self.provider_settings_active_field = fields.get(next_index).cloned();
    }

    fn toggle_provider_settings_enabled(&mut self, provider_id: &str) {
        if let Some(settings) = self.provider_settings.as_mut()
            && let Some(provider) = settings
                .providers
                .iter()
                .find(|provider| provider.id == provider_id)
        {
            settings.update_enabled(provider_id, !provider.enabled);
        }
    }

    fn cycle_provider_settings_trust_mode(&mut self, provider_id: &str) {
        if let Some(settings) = self.provider_settings.as_mut()
            && let Some(provider) = settings
                .providers
                .iter()
                .find(|provider| provider.id == provider_id)
        {
            let next = match provider.trust_mode {
                AgentTrustMode::AllowEverything => AgentTrustMode::Ask,
                AgentTrustMode::Ask => AgentTrustMode::WorktreeOnly,
                AgentTrustMode::WorktreeOnly => AgentTrustMode::Deny,
                AgentTrustMode::Deny => AgentTrustMode::AllowEverything,
            };
            settings.update_trust_mode(provider_id, next);
        }
    }

    fn save_provider_settings(&mut self, cx: &mut Context<Self>) {
        let Some(settings) = self.provider_settings.as_ref() else {
            return;
        };
        let providers = settings.providers.clone();
        self.config.agent_providers = providers.clone();
        let config = self.config.clone();
        let app_config_store = self.app_config_store.clone();
        let task = cx.background_executor().spawn(async move {
            app_config_store
                .save(&config)
                .map(|_| providers)
                .map_err(|error| error.to_string())
        });

        cx.spawn(async move |this, cx| {
            let result = task.await;
            this.update(cx, |shell, cx| {
                match result {
                    Ok(saved_providers) => {
                        if shell
                            .provider_settings
                            .as_ref()
                            .is_some_and(|settings| settings.providers == saved_providers)
                        {
                            shell.provider_settings = None;
                        }
                    }
                    Err(error) => {
                        if let Some(settings) = shell.provider_settings.as_mut() {
                            settings.error = Some(error);
                        }
                    }
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    fn remove_provider_settings_entry(&mut self, provider_id: &str) {
        if let Some(settings) = self.provider_settings.as_mut()
            && remove_provider_and_record_discovery_ignore(&mut self.config, settings, provider_id)
        {
            self.provider_discovery_suggestions
                .retain(|suggestion| suggestion.id != provider_id);
        }
    }

    fn create_agent_chat_from_provider(&mut self, provider_id: &str, cx: &mut Context<Self>) {
        let Some(provider) = self
            .config
            .agent_providers
            .iter()
            .find(|provider| provider.id == provider_id && provider.enabled)
            .cloned()
        else {
            if let Some(settings) = self.provider_settings.as_mut() {
                settings.error = Some("Provider is not enabled or no longer exists".to_string());
            }
            cx.notify();
            return;
        };
        self.create_agent_chat_tab(provider, cx);
    }

    fn handle_new_workspace_tab_choice(
        &mut self,
        choice: NewWorkspaceTabChoice,
        cx: &mut Context<Self>,
    ) {
        self.close_new_tab_picker();
        match choice {
            NewWorkspaceTabChoice::Terminal => self.open_command_picker(cx),
            NewWorkspaceTabChoice::AgentChat => {
                match agent_chat_provider_flow(&self.config.agent_providers) {
                    AgentChatProviderFlow::ProviderSettings => {
                        self.open_provider_settings(cx);
                        if let Some(settings) = self.provider_settings.as_mut() {
                            settings.error = Some(
                                "Add or enable an agent provider to start a chat.".to_string(),
                            );
                        }
                        cx.notify();
                    }
                    AgentChatProviderFlow::CreateTab(provider) => {
                        self.create_agent_chat_tab(provider, cx)
                    }
                    AgentChatProviderFlow::ProviderPicker(providers) => {
                        self.provider_settings = None;
                        self.agent_provider_picker = Some(providers);
                        cx.notify();
                    }
                }
            }
        }
    }

    fn create_agent_chat_tab(&mut self, provider: AgentProviderConfig, cx: &mut Context<Self>) {
        let Some(selected) = self.model.selected_worktree().cloned() else {
            return;
        };
        self.agent_provider_picker = None;
        self.provider_settings = None;
        let tab_id = self.workspace_session.create_agent_chat_tab(
            selected.repo_id,
            selected.path,
            provider.id.clone(),
        );
        self.start_agent_runtime_for_tab(tab_id, provider, cx);
        self.persist_agent_threads(cx);
        cx.notify();
    }

    fn start_agent_runtime_for_tab(
        &mut self,
        tab_id: WorkspaceTabId,
        provider: AgentProviderConfig,
        cx: &mut Context<Self>,
    ) {
        let Some(selected) = self.model.selected_worktree().cloned() else {
            return;
        };
        let repository_root = self
            .model
            .repositories()
            .iter()
            .find(|repo| repo.id == selected.repo_id)
            .map(|repo| repo.path.as_path())
            .unwrap_or(selected.path.as_path());
        let cwd = resolve_provider_cwd(&provider, &selected.path, repository_root);
        let Some(tab) =
            self.workspace_session
                .tab_mut(selected.repo_id.clone(), &selected.path, tab_id)
        else {
            return;
        };
        let Some(thread) = tab.agent_thread_state_mut() else {
            return;
        };
        thread.status = AgentThreadStatus::Starting;
        let initial_thread = thread.clone();
        self.persist_agent_threads(cx);
        cx.notify();

        let repo_id = selected.repo_id.clone();
        let worktree_path = selected.path.clone();
        let task = cx.background_executor().spawn(async move {
            let mut thread = initial_thread;
            match AcpProcessConnection::spawn_with_credentials(&provider, cwd, &OsCredentialStore) {
                Ok(connection) => {
                    let cancel_handle = connection.cancel_handle();
                    let connection = connection.with_callback_services(
                        crate::agent::FilesystemCallbackService::new(
                            provider.trust_mode.clone(),
                            worktree_path.clone(),
                        ),
                        crate::agent::AgentTerminalService::new(
                            provider.trust_mode.clone(),
                            worktree_path.clone(),
                        ),
                    );
                    let filesystem = crate::agent::FilesystemCallbackService::new(
                        provider.trust_mode.clone(),
                        worktree_path.clone(),
                    );
                    let terminal = crate::agent::AgentTerminalService::new(
                        provider.trust_mode.clone(),
                        worktree_path.clone(),
                    );
                    let mut runtime = AgentRuntime::with_connection(thread, connection)
                        .with_callback_services(filesystem, terminal);
                    let start_result = runtime.initialize().and_then(|_| runtime.create_session());
                    let (thread, runtime_with_cancel) =
                        finish_agent_runtime_start(runtime, cancel_handle, start_result);
                    (repo_id, worktree_path, tab_id, thread, runtime_with_cancel)
                }
                Err(error) => {
                    thread.status = AgentThreadStatus::Failed {
                        message: error.to_string(),
                    };
                    (repo_id, worktree_path, tab_id, thread, None)
                }
            }
        });

        cx.spawn(async move |this, cx| {
            let (repo_id, worktree_path, tab_id, updated_thread, runtime_with_cancel) = task.await;
            this.update(cx, |shell, cx| {
                if let Some(tab) = shell
                    .workspace_session
                    .tab_mut(repo_id, &worktree_path, tab_id)
                    && let Some(thread) = tab.agent_thread_state_mut()
                {
                    *thread = updated_thread;
                    if let Some((runtime, cancel_handle)) = runtime_with_cancel {
                        shell.agent_cancel_handles.insert(tab_id, cancel_handle);
                        shell.agent_runtimes.insert(tab_id, runtime);
                    } else {
                        shell.agent_cancel_handles.remove(&tab_id);
                    }
                    shell.persist_agent_threads(cx);
                    cx.notify();
                }
            })
            .ok();
        })
        .detach();
    }

    fn send_agent_prompt(&mut self, tab_id: WorkspaceTabId, cx: &mut Context<Self>) {
        let Some(selected) = self.model.selected_worktree().cloned() else {
            return;
        };
        let prompt = self
            .workspace_session
            .tab(selected.repo_id.clone(), &selected.path, tab_id)
            .and_then(|tab| tab.agent_thread_state())
            .map(|thread| thread.draft.clone())
            .unwrap_or_default();
        if prompt.trim().is_empty() {
            return;
        }
        if let Some(mut runtime) = self.agent_runtimes.remove(&tab_id) {
            if matches!(runtime.thread().status, AgentThreadStatus::ReadOnly { .. }) {
                runtime.thread_mut().push_debug_event(AgentDebugEvent {
                    message: "Ignored stale prompt send for read-only ACP session".to_string(),
                });
                self.agent_runtimes.insert(tab_id, runtime);
                self.sync_agent_thread_from_runtime(tab_id);
                self.persist_agent_threads(cx);
                cx.notify();
                return;
            }

            if let Some(tab) =
                self.workspace_session
                    .tab_mut(selected.repo_id.clone(), &selected.path, tab_id)
                && let Some(thread) = tab.agent_thread_state_mut()
            {
                thread.status = AgentThreadStatus::Running;
                thread.draft.clear();
            }
            self.persist_agent_threads(cx);
            cx.notify();

            let repo_id = selected.repo_id.clone();
            let worktree_path = selected.path.clone();
            let task = cx.background_executor().spawn(async move {
                if let Err(error) = runtime.prompt(prompt) {
                    runtime.thread_mut().status = AgentThreadStatus::Failed {
                        message: error.to_string(),
                    };
                }
                runtime.thread_mut().draft.clear();
                (repo_id, worktree_path, tab_id, runtime)
            });

            cx.spawn(async move |this, cx| {
                let (repo_id, worktree_path, tab_id, runtime) = task.await;
                this.update(cx, |shell, cx| {
                    let updated = runtime.thread().clone();
                    if let Some(tab) =
                        shell
                            .workspace_session
                            .tab_mut(repo_id, &worktree_path, tab_id)
                        && let Some(thread) = tab.agent_thread_state_mut()
                    {
                        *thread = updated;
                        shell.agent_runtimes.insert(tab_id, runtime);
                        shell.persist_agent_threads(cx);
                        cx.notify();
                    }
                })
                .ok();
            })
            .detach();
            return;
        } else if let Some(tab) =
            self.workspace_session
                .tab_mut(selected.repo_id, &selected.path, tab_id)
            && let Some(thread) = tab.agent_thread_state_mut()
        {
            if matches!(thread.status, AgentThreadStatus::ReadOnly { .. }) {
                thread.push_debug_event(AgentDebugEvent {
                    message: "Ignored stale prompt send for read-only ACP session".to_string(),
                });
            } else if matches!(
                thread.status,
                AgentThreadStatus::Starting | AgentThreadStatus::Running
            ) {
                thread.push_debug_event(AgentDebugEvent {
                    message: "Ignored prompt send while ACP runtime is busy".to_string(),
                });
            } else {
                thread.transcript.push(AgentTranscriptEntry::user(prompt));
                thread.draft.clear();
                thread.status = AgentThreadStatus::Failed {
                    message: "Agent runtime is not connected".to_string(),
                };
            }
            self.persist_agent_threads(cx);
        }
        cx.notify();
    }

    fn cycle_agent_mode(&mut self, tab_id: WorkspaceTabId, cx: &mut Context<Self>) {
        let Some(selected) = self.model.selected_worktree().cloned() else {
            return;
        };
        let Some(tab) = self
            .workspace_session
            .tab_mut(&selected.repo_id, &selected.path, tab_id)
        else {
            return;
        };
        let Some(thread) = tab.agent_thread_state_mut() else {
            return;
        };
        if thread.available_modes.len() < 2 {
            return;
        }
        let current = thread.current_mode.as_deref();
        let index = thread
            .available_modes
            .iter()
            .position(|mode| Some(mode.id.as_str()) == current)
            .unwrap_or(0);
        let next_mode = thread.available_modes[(index + 1) % thread.available_modes.len()]
            .id
            .clone();
        self.run_agent_selector_update(
            tab_id,
            selected.repo_id,
            selected.path,
            move |runtime| runtime.set_mode(next_mode),
            cx,
        );
    }

    fn cycle_agent_config_option(
        &mut self,
        tab_id: WorkspaceTabId,
        config_id: String,
        cx: &mut Context<Self>,
    ) {
        let Some(selected) = self.model.selected_worktree().cloned() else {
            return;
        };
        let Some(tab) = self
            .workspace_session
            .tab_mut(&selected.repo_id, &selected.path, tab_id)
        else {
            return;
        };
        let Some(thread) = tab.agent_thread_state_mut() else {
            return;
        };
        let Some(option) = thread
            .config_options
            .iter_mut()
            .find(|option| option.id == config_id)
        else {
            return;
        };
        if option.options.len() < 2 {
            return;
        }
        let current = option.value.as_deref();
        let index = option
            .options
            .iter()
            .position(|value| Some(value.id.as_str()) == current)
            .unwrap_or(0);
        let next_value = option.options[(index + 1) % option.options.len()]
            .id
            .clone();
        self.run_agent_selector_update(
            tab_id,
            selected.repo_id,
            selected.path,
            move |runtime| runtime.set_config_option(config_id, next_value),
            cx,
        );
    }

    fn run_agent_selector_update(
        &mut self,
        tab_id: WorkspaceTabId,
        repo_id: String,
        worktree_path: PathBuf,
        update: impl FnOnce(&mut AgentRuntime<AcpProcessConnection>) -> anyhow::Result<()>
        + Send
        + 'static,
        cx: &mut Context<Self>,
    ) {
        let Some(mut runtime) = self.agent_runtimes.remove(&tab_id) else {
            if let Some(tab) = self
                .workspace_session
                .tab_mut(&repo_id, &worktree_path, tab_id)
                && let Some(thread) = tab.agent_thread_state_mut()
            {
                thread.push_debug_event(AgentDebugEvent {
                    message: "Ignored selector change while ACP runtime is busy or disconnected"
                        .to_string(),
                });
                self.persist_agent_threads(cx);
            }
            return;
        };
        let task = cx.background_executor().spawn(async move {
            if let Err(error) = update(&mut runtime) {
                runtime.thread_mut().push_debug_event(AgentDebugEvent {
                    message: error.to_string(),
                });
            }
            (repo_id, worktree_path, tab_id, runtime)
        });
        cx.spawn(async move |this, cx| {
            let (repo_id, worktree_path, tab_id, runtime) = task.await;
            this.update(cx, |shell, cx| {
                let updated = runtime.thread().clone();
                if let Some(tab) = shell
                    .workspace_session
                    .tab_mut(repo_id, &worktree_path, tab_id)
                    && let Some(thread) = tab.agent_thread_state_mut()
                {
                    *thread = updated;
                    shell.agent_runtimes.insert(tab_id, runtime);
                    shell.persist_agent_threads(cx);
                    cx.notify();
                }
            })
            .ok();
        })
        .detach();
    }

    fn focus_agent_composer(
        &mut self,
        tab_id: WorkspaceTabId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.active_agent_composer_tab = Some(tab_id);
        window.focus(&self.agent_composer_focus);
        cx.notify();
    }

    fn handle_agent_composer_key_down(
        &mut self,
        event: &KeyDownEvent,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(tab_id) = self.active_agent_composer_tab else {
            return false;
        };

        match event.keystroke.key.as_str() {
            "escape" => {
                self.active_agent_composer_tab = None;
                return true;
            }
            "enter" => {
                self.send_agent_prompt(tab_id, cx);
                return true;
            }
            "backspace" => {
                self.edit_agent_draft(
                    tab_id,
                    |draft| {
                        draft.pop();
                    },
                    cx,
                );
                cx.notify();
                return true;
            }
            _ => {}
        }

        if event.keystroke.modifiers.control || event.keystroke.modifiers.platform {
            return false;
        }

        if let Some(text) = event.keystroke.key_char.as_deref() {
            self.edit_agent_draft(tab_id, |draft| draft.push_str(text), cx);
            cx.notify();
            return true;
        }

        false
    }

    fn edit_agent_draft(
        &mut self,
        tab_id: WorkspaceTabId,
        edit: impl FnOnce(&mut String),
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(selected) = self.model.selected_worktree().cloned() else {
            return false;
        };
        let Some(tab) = self
            .workspace_session
            .tab_mut(&selected.repo_id, &selected.path, tab_id)
        else {
            return false;
        };
        let Some(thread) = tab.agent_thread_state_mut() else {
            return false;
        };

        edit(&mut thread.draft);
        if let Some(runtime) = self.agent_runtimes.get_mut(&tab_id) {
            runtime.thread_mut().draft = thread.draft.clone();
        }
        self.persist_agent_threads(cx);
        true
    }

    fn cancel_agent_prompt(&mut self, tab_id: WorkspaceTabId, cx: &mut Context<Self>) {
        let Some(selected) = self.model.selected_worktree().cloned() else {
            return;
        };
        let Some(tab) = self
            .workspace_session
            .tab_mut(&selected.repo_id, &selected.path, tab_id)
        else {
            return;
        };
        let Some(thread) = tab.agent_thread_state_mut() else {
            return;
        };
        let Some(session_id) = thread.acp_session_id.clone() else {
            thread.push_debug_event(AgentDebugEvent {
                message: "Cannot cancel ACP prompt without an active session".to_string(),
            });
            self.persist_agent_threads(cx);
            cx.notify();
            return;
        };
        let Some(cancel_handle) = self.agent_cancel_handles.get(&tab_id).cloned() else {
            thread.push_debug_event(AgentDebugEvent {
                message: "Cannot cancel ACP prompt because the runtime is not connected"
                    .to_string(),
            });
            self.persist_agent_threads(cx);
            cx.notify();
            return;
        };

        let repo_id = selected.repo_id.clone();
        let worktree_path = selected.path.clone();
        let task = cx
            .background_executor()
            .spawn(async move { cancel_handle.cancel(session_id) });

        cx.spawn(async move |this, cx| {
            let result = task.await;
            this.update(cx, |shell, cx| {
                if let Some(tab) = shell
                    .workspace_session
                    .tab_mut(repo_id, &worktree_path, tab_id)
                    && let Some(thread) = tab.agent_thread_state_mut()
                {
                    match result {
                        Ok(()) => {
                            thread.status = AgentThreadStatus::Ready;
                            if let Some(runtime) = shell.agent_runtimes.get_mut(&tab_id) {
                                runtime.thread_mut().status = AgentThreadStatus::Ready;
                            }
                        }
                        Err(error) => {
                            let message = error.to_string();
                            thread.push_debug_event(AgentDebugEvent {
                                message: message.clone(),
                            });
                            if let Some(runtime) = shell.agent_runtimes.get_mut(&tab_id) {
                                runtime
                                    .thread_mut()
                                    .push_debug_event(AgentDebugEvent { message });
                            }
                        }
                    }
                    shell.persist_agent_threads(cx);
                    cx.notify();
                }
            })
            .ok();
        })
        .detach();
        cx.notify();
    }

    fn resolve_agent_permission(
        &mut self,
        tab_id: WorkspaceTabId,
        request_id: &str,
        allow: bool,
        cx: &mut Context<Self>,
    ) {
        if let Some(runtime) = self.agent_runtimes.get_mut(&tab_id) {
            if let Err(error) = runtime.resolve_permission_request(request_id, allow) {
                runtime
                    .thread_mut()
                    .push_debug_event(crate::agent::AgentDebugEvent {
                        message: error.to_string(),
                    });
            }
            self.sync_agent_thread_from_runtime(tab_id);
            self.persist_agent_threads(cx);
        }
    }

    fn persist_agent_threads(&mut self, cx: &mut Context<Self>) {
        self.persist_agent_threads_with_exclusions(
            Vec::new(),
            agent_thread_persist_debounce_interval(),
            cx,
        )
        .detach();
    }

    fn persist_agent_threads_excluding(
        &mut self,
        excluded_thread_id: Option<&str>,
        cx: &mut Context<Self>,
    ) {
        let excluded_thread_ids = excluded_thread_id
            .into_iter()
            .map(str::to_string)
            .collect::<Vec<_>>();
        self.persist_agent_threads_immediately_excluding(excluded_thread_ids, cx);
    }

    fn persist_agent_threads_immediately_excluding(
        &mut self,
        excluded_thread_ids: Vec<String>,
        cx: &mut Context<Self>,
    ) {
        self.persist_agent_threads_with_exclusions(excluded_thread_ids, Duration::ZERO, cx)
            .detach();
    }

    fn persist_agent_threads_with_exclusions(
        &mut self,
        excluded_thread_ids: Vec<String>,
        delay: Duration,
        cx: &mut Context<Self>,
    ) -> Task<()> {
        if !self.agent_thread_records_loaded {
            self.pending_agent_thread_exclusions
                .extend(excluded_thread_ids.iter().cloned());
        }
        let records = merge_agent_thread_records(
            self.agent_thread_records_cache.values().cloned(),
            self.workspace_session.agent_thread_records(),
            excluded_thread_ids,
        );
        self.agent_thread_records_cache = records
            .iter()
            .cloned()
            .map(|record| (record.thread_id.clone(), record))
            .collect();
        self.spawn_agent_thread_records_save(records, delay, cx)
    }

    fn spawn_agent_thread_records_save(
        &self,
        records: Vec<AgentThreadRecord>,
        delay: Duration,
        cx: &mut Context<Self>,
    ) -> Task<()> {
        let store = self.agent_thread_store.clone();
        let latest_generation = self.agent_thread_persist_generation.clone();
        let generation = latest_generation.fetch_add(1, Ordering::SeqCst) + 1;
        let save_lock = self.agent_thread_persist_lock.clone();
        let executor = cx.background_executor().clone();
        let timer_executor = executor.clone();

        executor.spawn(async move {
            timer_executor.timer(delay).await;
            let _guard = match save_lock.lock() {
                Ok(guard) => guard,
                Err(poisoned) => poisoned.into_inner(),
            };
            if generation != latest_generation.load(Ordering::SeqCst) {
                return;
            }
            if let Err(error) = store.save_records(&records) {
                eprintln!("failed to persist agent threads: {error:#}");
            }
        })
    }

    fn cached_agent_thread_records(&self) -> Vec<AgentThreadRecord> {
        self.agent_thread_records_cache.values().cloned().collect()
    }

    fn agent_thread_ids_for_worktree(&self, path: &Path) -> Vec<String> {
        let workspace_records = self.workspace_session.agent_thread_records();
        self.agent_thread_records_cache
            .values()
            .chain(workspace_records.iter())
            .filter(|record| record.state.worktree_path == path)
            .map(|record| record.thread_id.clone())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect()
    }

    fn agent_thread_ids_for_repo(&self, repo_id: &str) -> Vec<String> {
        let repository_path = self.repository_path(repo_id);
        let worktree_paths = self
            .model
            .repositories()
            .iter()
            .find(|repository| repository.id == repo_id)
            .map(|repository| {
                repository
                    .worktrees
                    .iter()
                    .map(|worktree| worktree.path.clone())
                    .collect::<BTreeSet<_>>()
            })
            .unwrap_or_default();
        let workspace_records = self.workspace_session.agent_thread_records();
        self.agent_thread_records_cache
            .values()
            .chain(workspace_records.iter())
            .filter(|record| {
                worktree_paths.contains(&record.state.worktree_path)
                    || repository_path
                        .as_ref()
                        .is_some_and(|path| record.state.worktree_path.starts_with(path))
            })
            .map(|record| record.thread_id.clone())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect()
    }

    fn restore_agent_threads_for_selected_worktree(&mut self, cx: &mut Context<Self>) {
        let Some(selected) = self.model.selected_worktree().cloned() else {
            return;
        };
        let records = self.cached_agent_thread_records();
        if !self
            .workspace_session
            .restore_agent_chat_tabs(&selected.repo_id, &selected.path, &records)
            .is_empty()
        {
            cx.notify();
        }
    }

    fn restore_agent_threads_for_known_worktrees(&mut self, cx: &mut Context<Self>) {
        let records = self.cached_agent_thread_records();
        let worktrees = self
            .model
            .repositories()
            .iter()
            .flat_map(|repository| {
                repository
                    .worktrees
                    .iter()
                    .map(|worktree| (repository.id.clone(), worktree.path.clone()))
            })
            .collect::<Vec<_>>();
        if !self
            .workspace_session
            .restore_agent_chat_tabs_for_worktrees(worktrees, &records)
            .is_empty()
        {
            cx.notify();
        }
    }

    fn sync_agent_thread_from_runtime(&mut self, tab_id: WorkspaceTabId) {
        let Some(selected) = self.model.selected_worktree().cloned() else {
            return;
        };
        let Some(runtime_thread) = self
            .agent_runtimes
            .get(&tab_id)
            .map(|runtime| runtime.thread().clone())
        else {
            return;
        };
        if let Some(tab) = self
            .workspace_session
            .tab_mut(selected.repo_id, &selected.path, tab_id)
            && let Some(thread) = tab.agent_thread_state_mut()
        {
            *thread = runtime_thread;
        }
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
            ActionId::NotificationPreferences => self.open_notification_preferences_dialog(),
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
                if should_remove && let Err(error) = shell.remove_repository_from_alas(&repo_id, cx)
                {
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

    fn remove_repository_from_alas(
        &mut self,
        repo_id: &str,
        cx: &mut Context<Self>,
    ) -> anyhow::Result<()> {
        let mut next_config = self.config.clone();
        next_config
            .repositories
            .retain(|repository| repository.id != repo_id);
        next_config.archived_worktrees.shift_remove(repo_id);

        let excluded_thread_ids = self.agent_thread_ids_for_repo(repo_id);
        let pending_removed_repo = self.repository_path(repo_id);
        let pending_removed_worktrees = self
            .model
            .repositories()
            .iter()
            .find(|repository| repository.id == repo_id)
            .map(|repository| {
                repository
                    .worktrees
                    .iter()
                    .map(|worktree| worktree.path.clone())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();

        self.app_config_store.save(&next_config)?;
        if !self.agent_thread_records_loaded {
            if let Some(path) = pending_removed_repo {
                self.pending_removed_agent_repos.insert(path);
            }
            self.pending_removed_agent_worktrees
                .extend(pending_removed_worktrees);
        }
        self.config = next_config;
        self.cleanup_repository_sessions(repo_id);
        self.workspace_session.remove_repository(repo_id);
        self.persist_agent_threads_immediately_excluding(excluded_thread_ids, cx);

        if self
            .model
            .selected_worktree()
            .is_some_and(|selected| selected.repo_id == repo_id)
        {
            self.clear_selection_and_active_terminal();
        }

        self.refresh_repositories_and_restore_agent_threads(cx);
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
                if should_remove && let Err(error) = shell.remove_worktree(&repo_id, &path, cx) {
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

    fn remove_worktree(
        &mut self,
        repo_id: &str,
        path: &Path,
        cx: &mut Context<Self>,
    ) -> anyhow::Result<()> {
        let repo_path = self
            .repository_path(repo_id)
            .ok_or_else(|| anyhow::anyhow!("Repository not found"))?;

        let excluded_thread_ids = self.agent_thread_ids_for_worktree(path);

        GitWorktreeService::new(GitRunner::new()).remove_worktree(&repo_path, path)?;
        if !self.agent_thread_records_loaded {
            self.pending_removed_agent_worktrees
                .insert(path.to_path_buf());
        }
        self.cleanup_worktree_sessions(repo_id, path);
        self.workspace_session.remove_worktree(repo_id, path);
        self.persist_agent_threads_immediately_excluding(excluded_thread_ids, cx);

        if self
            .model
            .selected_worktree()
            .is_some_and(|selected| selected.repo_id == repo_id && selected.path == path)
        {
            self.clear_selection_and_active_terminal();
        }

        self.refresh_repositories_and_restore_agent_threads(cx);
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
        cx.on_app_quit(|shell, cx| {
            let save = shell.persist_agent_threads_with_exclusions(Vec::new(), Duration::ZERO, cx);
            shell.shutdown();
            async move {
                save.await;
            }
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

    fn refresh_repositories_and_restore_agent_threads(&mut self, cx: &mut Context<Self>) {
        self.refresh_repositories();
        self.restore_agent_threads_for_known_worktrees(cx);
    }

    fn add_repository_error(&self) -> Option<&str> {
        self.add_repository_dialog
            .as_ref()
            .and_then(|dialog| dialog.error.as_deref())
    }

    fn render_resize_handle(
        &self,
        target: SidebarResizeTarget,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let is_active = self
            .active_sidebar_resize
            .as_ref()
            .is_some_and(|drag| drag.target == target);

        let handle_id = match target {
            SidebarResizeTarget::Left => "resize-handle-left",
            SidebarResizeTarget::Right => "resize-handle-right",
        };

        let on_mouse_down = cx.listener(move |shell, event: &MouseDownEvent, _window, cx| {
            if event.button != MouseButton::Left {
                return;
            }
            let start_width = match target {
                SidebarResizeTarget::Left => shell.sidebar_layout.left_width_px,
                SidebarResizeTarget::Right => shell.sidebar_layout.right_width_px,
            };
            shell.active_sidebar_resize = Some(SidebarResizeDrag {
                target,
                start_x: f32::from(event.position.x),
                start_width,
            });
            cx.stop_propagation();
            cx.notify();
        });

        let on_mouse_move = cx.listener(move |shell, event: &MouseMoveEvent, window, cx| {
            if shell.update_sidebar_resize(event, window) {
                cx.stop_propagation();
                cx.notify();
            }
        });

        div()
            .id(handle_id)
            .flex_shrink_0()
            .w(px(RESIZE_HANDLE_WIDTH_PX))
            .h_full()
            .cursor_col_resize()
            .when(is_active, |el| el.bg(PANEL_BORDER))
            .hover(|el| el.bg(PANEL_BORDER))
            .on_mouse_down(MouseButton::Left, on_mouse_down)
            .on_mouse_move(on_mouse_move)
    }

    fn update_sidebar_resize(&mut self, event: &MouseMoveEvent, window: &Window) -> bool {
        let Some(drag) = self.active_sidebar_resize else {
            return false;
        };

        if event.pressed_button != Some(MouseButton::Left) {
            return self.finish_sidebar_resize();
        }

        let delta = f32::from(event.position.x) - drag.start_x;
        let requested = match drag.target {
            SidebarResizeTarget::Left => drag.start_width + delta,
            SidebarResizeTarget::Right => drag.start_width - delta,
        };
        let other_width = match drag.target {
            SidebarResizeTarget::Left => self.sidebar_layout.right_width_px,
            SidebarResizeTarget::Right => self.sidebar_layout.left_width_px,
        };
        let window_width = f32::from(window.bounds().size.width);
        let clamped = clamp_sidebar_width(drag.target, requested, other_width, window_width);
        match drag.target {
            SidebarResizeTarget::Left => self.sidebar_layout.left_width_px = clamped,
            SidebarResizeTarget::Right => self.sidebar_layout.right_width_px = clamped,
        }
        true
    }

    fn finish_sidebar_resize(&mut self) -> bool {
        if self.active_sidebar_resize.take().is_none() {
            return false;
        }

        self.config.layout.left_sidebar_width_px = self.sidebar_layout.left_width_px as u32;
        self.config.layout.right_sidebar_width_px = self.sidebar_layout.right_width_px as u32;
        let _ = self.app_config_store.save(&self.config);
        true
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

fn render_notification_toggle(
    id: &'static str,
    label: &'static str,
    checked: bool,
    on_toggle: impl Fn(&gpui::ClickEvent, &mut Window, &mut App) + 'static,
) -> impl IntoElement {
    div()
        .id(id)
        .flex()
        .items_center()
        .justify_between()
        .gap_3()
        .px_2()
        .py_2()
        .rounded_md()
        .bg(rgb(0xffffff))
        .border_1()
        .border_color(rgb(0xd1d5db))
        .child(div().text_sm().text_color(rgb(0x111827)).child(label))
        .child(
            div()
                .w(px(44.0))
                .h(px(24.0))
                .rounded_full()
                .flex()
                .items_center()
                .justify_center()
                .text_xs()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .text_color(if checked {
                    rgb(0xffffff)
                } else {
                    rgb(0x4b5563)
                })
                .bg(if checked {
                    rgb(0x2563eb)
                } else {
                    rgb(0xe5e7eb)
                })
                .child(if checked { "On" } else { "Off" }),
        )
        .on_click(on_toggle)
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
        None if matches!(active_tab_kind, Some(WorkspaceTabKind::Image)) => {
            ("image".to_string(), TEXT_MUTED)
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

fn render_new_tab_picker(
    on_select: impl Fn(NewWorkspaceTabChoice, &gpui::ClickEvent, &mut Window, &mut App)
    + Clone
    + 'static,
    on_cancel: impl Fn(&gpui::ClickEvent, &mut Window, &mut App) + 'static,
) -> impl IntoElement {
    div()
        .id("new-tab-picker")
        .m_3()
        .p_3()
        .rounded_md()
        .border_1()
        .border_color(PANEL_BORDER)
        .bg(PANEL_BG)
        .flex()
        .flex_col()
        .gap_2()
        .child(
            div()
                .text_sm()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .child("New Workspace Tab"),
        )
        .children(new_workspace_tab_choices().into_iter().map(|choice| {
            let on_select = on_select.clone();
            div()
                .id(SharedString::from(format!("new-tab-choice-{choice:?}")))
                .px_3()
                .py_2()
                .rounded_md()
                .text_sm()
                .text_color(rgb(0x111827))
                .bg(rgb(0xe5e7eb))
                .child(new_workspace_tab_choice_label(choice))
                .on_click(move |event, window, cx| on_select(choice, event, window, cx))
        }))
        .child(
            div()
                .id("cancel-new-tab-picker")
                .px_3()
                .py_2()
                .rounded_md()
                .text_sm()
                .text_color(TEXT_MUTED)
                .child("Cancel")
                .on_click(on_cancel),
        )
}

fn render_agent_provider_picker(
    providers: &[AgentProviderConfig],
    on_select: impl Fn(AgentProviderConfig, &gpui::ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_cancel: impl Fn(&gpui::ClickEvent, &mut Window, &mut App) + 'static,
) -> impl IntoElement {
    div()
        .id("agent-provider-picker")
        .m_3()
        .p_3()
        .rounded_md()
        .border_1()
        .border_color(PANEL_BORDER)
        .bg(PANEL_BG)
        .flex()
        .flex_col()
        .gap_2()
        .child(
            div()
                .text_sm()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .child("Choose Agent Provider"),
        )
        .children(providers.iter().map(|provider| {
            let on_select = on_select.clone();
            let provider = provider.clone();
            div()
                .id(SharedString::from(format!(
                    "agent-provider-{}",
                    provider.id
                )))
                .px_3()
                .py_2()
                .rounded_md()
                .text_sm()
                .text_color(rgb(0x111827))
                .bg(rgb(0xe5e7eb))
                .child(SharedString::from(provider.display_name.clone()))
                .on_click(move |event, window, cx| on_select(provider.clone(), event, window, cx))
        }))
        .child(
            div()
                .id("cancel-agent-provider-picker")
                .px_3()
                .py_2()
                .rounded_md()
                .text_sm()
                .text_color(TEXT_MUTED)
                .child("Cancel")
                .on_click(on_cancel),
        )
}

impl Render for AlasShell {
    fn render(&mut self, window: &mut gpui::Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.drain_notification_activations(window);

        let measured_metrics =
            measure_terminal_metrics(window, TERMINAL_FONT_FAMILY, TERMINAL_FONT_SIZE_PX);
        if self.terminal_metrics != measured_metrics {
            self.terminal_metrics = measured_metrics;
        }
        self.sidebar_layout
            .clamp_for_window(f32::from(window.bounds().size.width));

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
        let on_toggle_harness_completion_notifications =
            cx.listener(|shell, _event, _window, cx| {
                shell.toggle_harness_completion_notifications();
                cx.notify();
            });
        let on_toggle_success_completion_notifications =
            cx.listener(|shell, _event, _window, cx| {
                shell.toggle_success_completion_notifications();
                cx.notify();
            });
        let on_toggle_failure_completion_notifications =
            cx.listener(|shell, _event, _window, cx| {
                shell.toggle_failure_completion_notifications();
                cx.notify();
            });
        let on_submit_notification_preferences = cx.listener(|shell, _event, _window, cx| {
            shell.save_notification_preferences_from_dialog();
            cx.notify();
        });
        let on_cancel_notification_preferences = cx.listener(|shell, _event, _window, cx| {
            shell.close_notification_preferences_dialog();
            cx.notify();
        });
        let on_terminal_key_down = cx.listener(|shell, event: &KeyDownEvent, _window, cx| {
            if shell.handle_terminal_key_down(event, cx) {
                cx.stop_propagation();
            }
        });
        let on_agent_composer_key_down = cx.listener(|shell, event: &KeyDownEvent, _window, cx| {
            if shell.handle_agent_composer_key_down(event, cx) {
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
                shell.close_workspace_tab(tab_id, cx);
                cx.notify();
            })
            .ok();
        };
        let on_new_workspace_tab = cx.listener(|shell, _event, _window, cx| {
            shell.open_new_tab_picker(cx);
        });
        let view = cx.entity().downgrade();
        let on_image_fit = move |tab_id: WorkspaceTabId,
                                 _event: &gpui::ClickEvent,
                                 _window: &mut Window,
                                 app: &mut App| {
            view.update(app, |shell, cx| {
                shell.set_image_zoom_for_tab(tab_id, ImageZoom::Fit);
                cx.notify();
            })
            .ok();
        };
        let view = cx.entity().downgrade();
        let on_image_zoom_in = move |tab_id: WorkspaceTabId,
                                     _event: &gpui::ClickEvent,
                                     _window: &mut Window,
                                     app: &mut App| {
            view.update(app, |shell, cx| {
                if let Some((active_tab_id, zoom)) = shell.active_image_zoom()
                    && active_tab_id == tab_id
                {
                    shell.set_image_zoom_for_tab(tab_id, zoom.zoom_in());
                    cx.notify();
                }
            })
            .ok();
        };
        let view = cx.entity().downgrade();
        let on_image_zoom_out = move |tab_id: WorkspaceTabId,
                                      _event: &gpui::ClickEvent,
                                      _window: &mut Window,
                                      app: &mut App| {
            view.update(app, |shell, cx| {
                if let Some((active_tab_id, zoom)) = shell.active_image_zoom()
                    && active_tab_id == tab_id
                {
                    shell.set_image_zoom_for_tab(tab_id, zoom.zoom_out());
                    cx.notify();
                }
            })
            .ok();
        };
        let view = cx.entity().downgrade();
        let on_set_markdown_mode = move |tab_id: WorkspaceTabId,
                                         mode: MarkdownViewMode,
                                         _event: &gpui::ClickEvent,
                                         _window: &mut Window,
                                         app: &mut App| {
            view.update(app, |shell, cx| {
                let Some(selected) = shell.model.selected_worktree().cloned() else {
                    return;
                };
                if let Err(error) = shell.workspace_session.set_markdown_view_mode(
                    &selected.repo_id,
                    &selected.path,
                    tab_id,
                    mode,
                ) {
                    shell.terminal_error = Some(error.to_string());
                }
                cx.notify();
            })
            .ok();
        };
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
        let on_select_new_tab_choice = move |choice: NewWorkspaceTabChoice,
                                             _event: &gpui::ClickEvent,
                                             _window: &mut Window,
                                             app: &mut App| {
            view.update(app, |shell, cx| {
                shell.handle_new_workspace_tab_choice(choice, cx);
            })
            .ok();
        };
        let on_cancel_new_tab_picker = cx.listener(|shell, _event, _window, cx| {
            shell.close_new_tab_picker();
            cx.notify();
        });
        let view = cx.entity().downgrade();
        let on_select_agent_provider = move |provider: AgentProviderConfig,
                                             _event: &gpui::ClickEvent,
                                             _window: &mut Window,
                                             app: &mut App| {
            view.update(app, |shell, cx| {
                shell.create_agent_chat_from_provider(&provider.id, cx);
            })
            .ok();
        };
        let on_cancel_agent_provider_picker = cx.listener(|shell, _event, _window, cx| {
            shell.agent_provider_picker = None;
            cx.notify();
        });
        let on_close_provider_settings = cx.listener(|shell, _event, _window, cx| {
            shell.close_provider_settings();
            cx.notify();
        });
        let on_add_provider = cx.listener(|shell, _event, window, cx| {
            shell.add_provider_settings_entry();
            window.focus(&shell.provider_settings_focus);
            cx.notify();
        });
        let on_save_provider_settings = cx.listener(|shell, _event, _window, cx| {
            shell.save_provider_settings(cx);
            cx.notify();
        });
        let on_cancel_provider_settings = cx.listener(|shell, _event, _window, cx| {
            shell.close_provider_settings();
            cx.notify();
        });
        let on_provider_settings_key_down =
            cx.listener(|shell, event: &KeyDownEvent, _window, cx| {
                if shell.edit_provider_settings_field(event, cx) {
                    cx.stop_propagation();
                    cx.notify();
                }
            });
        let view = cx.entity().downgrade();
        let on_select_provider_settings_field = Arc::new(
            move |field: ProviderSettingsField,
                  _event: &gpui::ClickEvent,
                  window: &mut Window,
                  app: &mut App| {
                view.update(app, |shell, cx| {
                    shell.set_provider_settings_field(field);
                    window.focus(&shell.provider_settings_focus);
                    cx.notify();
                })
                .ok();
            },
        );
        let view = cx.entity().downgrade();
        let on_toggle_provider_enabled = Arc::new(
            move |provider_id: String,
                  _event: &gpui::ClickEvent,
                  _window: &mut Window,
                  app: &mut App| {
                view.update(app, |shell, cx| {
                    shell.toggle_provider_settings_enabled(&provider_id);
                    cx.notify();
                })
                .ok();
            },
        );
        let view = cx.entity().downgrade();
        let on_cycle_provider_trust_mode = Arc::new(
            move |provider_id: String,
                  _event: &gpui::ClickEvent,
                  _window: &mut Window,
                  app: &mut App| {
                view.update(app, |shell, cx| {
                    shell.cycle_provider_settings_trust_mode(&provider_id);
                    cx.notify();
                })
                .ok();
            },
        );
        let view = cx.entity().downgrade();
        let on_remove_provider = Arc::new(
            move |provider_id: String,
                  _event: &gpui::ClickEvent,
                  _window: &mut Window,
                  app: &mut App| {
                view.update(app, |shell, cx| {
                    shell.remove_provider_settings_entry(&provider_id);
                    cx.notify();
                })
                .ok();
            },
        );
        let view = cx.entity().downgrade();
        let on_authenticate_provider = Arc::new(
            move |provider_id: String,
                  _event: &gpui::ClickEvent,
                  _window: &mut Window,
                  app: &mut App| {
                view.update(app, |shell, cx| {
                    shell.authenticate_provider_settings(&provider_id, cx);
                    cx.notify();
                })
                .ok();
            },
        );
        let view = cx.entity().downgrade();
        let on_run_terminal_auth = Arc::new(
            move |provider_id: String,
                  _event: &gpui::ClickEvent,
                  _window: &mut Window,
                  app: &mut App| {
                view.update(app, |shell, cx| {
                    shell.run_provider_settings_terminal_auth(&provider_id);
                    cx.notify();
                })
                .ok();
            },
        );
        let view = cx.entity().downgrade();
        let on_clear_credentials = Arc::new(
            move |provider_id: String,
                  _event: &gpui::ClickEvent,
                  _window: &mut Window,
                  app: &mut App| {
                view.update(app, |shell, cx| {
                    shell.clear_provider_settings_credentials(&provider_id, cx);
                    cx.notify();
                })
                .ok();
            },
        );
        let view = cx.entity().downgrade();
        let on_view_auth_instructions = Arc::new(
            move |provider_id: String,
                  _event: &gpui::ClickEvent,
                  _window: &mut Window,
                  app: &mut App| {
                view.update(app, |shell, cx| {
                    shell.view_provider_settings_auth_instructions(&provider_id);
                    cx.notify();
                })
                .ok();
            },
        );
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
        let on_send_agent_prompt = {
            let tab_id = active_tab.map(|tab| tab.id);
            let view = cx.entity().downgrade();
            Arc::new(
                move |_event: &gpui::ClickEvent, _window: &mut Window, app: &mut App| {
                    if let Some(tab_id) = tab_id {
                        view.update(app, |shell, cx| shell.send_agent_prompt(tab_id, cx))
                            .ok();
                    }
                },
            )
        };
        let on_cancel_agent_prompt = {
            let tab_id = active_tab.map(|tab| tab.id);
            let view = cx.entity().downgrade();
            Arc::new(
                move |_event: &gpui::ClickEvent, _window: &mut Window, app: &mut App| {
                    if let Some(tab_id) = tab_id {
                        view.update(app, |shell, cx| shell.cancel_agent_prompt(tab_id, cx))
                            .ok();
                    }
                },
            )
        };
        let on_focus_agent_composer = {
            let tab_id = active_tab.map(|tab| tab.id);
            let view = cx.entity().downgrade();
            Arc::new(
                move |_event: &gpui::ClickEvent, window: &mut Window, app: &mut App| {
                    if let Some(tab_id) = tab_id {
                        view.update(app, |shell, cx| {
                            shell.focus_agent_composer(tab_id, window, cx)
                        })
                        .ok();
                    }
                },
            )
        };
        let on_allow_agent_permission = {
            let tab_id = active_tab.map(|tab| tab.id);
            let view = cx.entity().downgrade();
            Arc::new(
                move |request_id: String,
                      _event: &gpui::ClickEvent,
                      _window: &mut Window,
                      app: &mut App| {
                    if let Some(tab_id) = tab_id {
                        view.update(app, |shell, cx| {
                            shell.resolve_agent_permission(tab_id, &request_id, true, cx)
                        })
                        .ok();
                    }
                },
            )
        };
        let on_deny_agent_permission = {
            let tab_id = active_tab.map(|tab| tab.id);
            let view = cx.entity().downgrade();
            Arc::new(
                move |request_id: String,
                      _event: &gpui::ClickEvent,
                      _window: &mut Window,
                      app: &mut App| {
                    if let Some(tab_id) = tab_id {
                        view.update(app, |shell, cx| {
                            shell.resolve_agent_permission(tab_id, &request_id, false, cx)
                        })
                        .ok();
                    }
                },
            )
        };
        let on_cycle_agent_mode = {
            let tab_id = active_tab.map(|tab| tab.id);
            let view = cx.entity().downgrade();
            Arc::new(
                move |_event: &gpui::ClickEvent, _window: &mut Window, app: &mut App| {
                    if let Some(tab_id) = tab_id {
                        view.update(app, |shell, cx| shell.cycle_agent_mode(tab_id, cx))
                            .ok();
                    }
                },
            )
        };
        let on_cycle_agent_config = {
            let tab_id = active_tab.map(|tab| tab.id);
            let view = cx.entity().downgrade();
            Arc::new(
                move |config_id: String,
                      _event: &gpui::ClickEvent,
                      _window: &mut Window,
                      app: &mut App| {
                    if let Some(tab_id) = tab_id {
                        view.update(app, |shell, cx| {
                            shell.cycle_agent_config_option(tab_id, config_id, cx)
                        })
                        .ok();
                    }
                },
            )
        };
        let on_sidebar_resize_mouse_move =
            cx.listener(|shell, event: &MouseMoveEvent, window, cx| {
                if shell.update_sidebar_resize(event, window) {
                    cx.stop_propagation();
                    cx.notify();
                }
            });
        let on_sidebar_resize_mouse_up = cx.listener(|shell, event: &MouseUpEvent, _window, cx| {
            if event.button != MouseButton::Left {
                return;
            }
            if shell.finish_sidebar_resize() {
                cx.stop_propagation();
                cx.notify();
            }
        });
        let workspace_body = match active_tab.map(|tab| &tab.content) {
            Some(WorkspaceTabContent::File(state)) => render_source_viewer(state),
            Some(WorkspaceTabContent::Markdown(state)) => render_markdown_pane(
                active_tab
                    .map(|tab| tab.id)
                    .expect("active markdown tab has id"),
                state,
                on_set_markdown_mode,
            ),
            Some(WorkspaceTabContent::Image(state)) => render_image_view(
                active_tab
                    .map(|tab| tab.id)
                    .expect("active image tab has id"),
                state,
                on_image_fit,
                on_image_zoom_in,
                on_image_zoom_out,
            )
            .into_any_element(),
            Some(WorkspaceTabContent::Terminal(_)) | None => render_terminal_pane(
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
            .into_any_element(),
            Some(WorkspaceTabContent::AgentChat(state)) => div()
                .track_focus(&self.agent_composer_focus)
                .on_key_down(on_agent_composer_key_down)
                .child(render_agent_pane(
                    state,
                    AgentPaneHandlers {
                        on_send: on_send_agent_prompt,
                        on_cancel: on_cancel_agent_prompt,
                        on_focus_composer: on_focus_agent_composer,
                        on_allow_permission: on_allow_agent_permission,
                        on_deny_permission: on_deny_agent_permission,
                        on_cycle_mode: on_cycle_agent_mode,
                        on_cycle_config: on_cycle_agent_config,
                    },
                ))
                .into_any_element(),
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
                cx.listener(|shell, _event, _window, cx| {
                    shell.open_notification_preferences_dialog();
                    cx.notify();
                }),
                on_select_worktree,
                on_sidebar_menu_action,
                self.add_repository_error(),
                self.sidebar_layout.left_width_px,
            ))
            .child(self.render_resize_handle(SidebarResizeTarget::Left, cx))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .min_w(px(0.0))
                    .child(
                        div()
                            .flex()
                            .flex_1()
                            .min_h(px(0.0))
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
                    .when(self.notification_preferences_dialog.is_some(), |element| {
                        let dialog = self.notification_preferences_dialog.as_ref().unwrap();
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
                                .child(
                                    div()
                                        .text_sm()
                                        .font_weight(gpui::FontWeight::SEMIBOLD)
                                        .child("Notification Preferences"),
                                )
                                .child(
                                    div()
                                        .text_xs()
                                        .text_color(rgb(0x4b5563))
                                        .child("Hook-backed harnesses"),
                                )
                                .child(render_notification_toggle(
                                    "harness-completion-notifications",
                                    "Harness completion notifications",
                                    dialog.harness_completion_enabled,
                                    on_toggle_harness_completion_notifications,
                                ))
                                .child(render_notification_toggle(
                                    "harness-completion-success-notifications",
                                    "Successful completions",
                                    dialog.harness_completion_success,
                                    on_toggle_success_completion_notifications,
                                ))
                                .child(render_notification_toggle(
                                    "harness-completion-failure-notifications",
                                    "Failed completions",
                                    dialog.harness_completion_failure,
                                    on_toggle_failure_completion_notifications,
                                ))
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
                                                .id("submit-notification-preferences")
                                                .px_3()
                                                .py_2()
                                                .rounded_md()
                                                .text_sm()
                                                .font_weight(gpui::FontWeight::SEMIBOLD)
                                                .text_color(rgb(0xffffff))
                                                .bg(rgb(0x2563eb))
                                                .child("Save")
                                                .on_click(on_submit_notification_preferences),
                                        )
                                        .child(
                                            div()
                                                .id("cancel-notification-preferences")
                                                .px_3()
                                                .py_2()
                                                .rounded_md()
                                                .text_sm()
                                                .font_weight(gpui::FontWeight::SEMIBOLD)
                                                .text_color(rgb(0x374151))
                                                .bg(rgb(0xe5e7eb))
                                                .child("Cancel")
                                                .on_click(on_cancel_notification_preferences),
                                        ),
                                ),
                        )
                    })
                    .when(self.new_tab_picker_open, |element| {
                        element.child(render_new_tab_picker(
                            on_select_new_tab_choice,
                            on_cancel_new_tab_picker,
                        ))
                    })
                    .when(self.agent_provider_picker.is_some(), |element| {
                        element.child(render_agent_provider_picker(
                            self.agent_provider_picker.as_deref().unwrap_or(&[]),
                            on_select_agent_provider,
                            on_cancel_agent_provider_picker,
                        ))
                    })
                    .when(self.provider_settings.is_some(), |element| {
                        element.child(
                            div()
                                .track_focus(&self.provider_settings_focus)
                                .on_key_down(on_provider_settings_key_down)
                                .child(render_provider_settings(
                                    self.provider_settings.as_ref().unwrap(),
                                    self.provider_settings_active_field.as_ref(),
                                    ProviderSettingsHandlers {
                                        on_close: Arc::new(on_close_provider_settings),
                                        on_add_provider: Arc::new(on_add_provider),
                                        on_save: Arc::new(on_save_provider_settings),
                                        on_cancel: Arc::new(on_cancel_provider_settings),
                                        on_select_field: on_select_provider_settings_field,
                                        on_toggle_enabled: on_toggle_provider_enabled,
                                        on_cycle_trust_mode: on_cycle_provider_trust_mode,
                                        on_remove_provider,
                                        on_authenticate: on_authenticate_provider,
                                        on_run_terminal_auth,
                                        on_clear_credentials,
                                        on_view_auth_instructions,
                                    },
                                )),
                        )
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
                                on_new_workspace_tab,
                                workspace_body,
                            )),
                    ),
                            )
                            .child(self.render_resize_handle(SidebarResizeTarget::Right, cx))
                            .child(render_project_inspector(
                                self.model.selected_worktree(),
                                &self.inspector_state,
                                &self.file_tree_expansion,
                                on_toggle_file_tree_node,
                                on_open_file_from_inspector,
                                self.sidebar_layout.right_width_px,
                            )),
                    )
                    .child(render_status_bar(
                        status_bar_repo,
                        status_bar_tab,
                        status_bar_terminal_status.as_ref(),
                        active_tab.map(|tab| tab.kind),
                    )),
            )
            .when(self.active_sidebar_resize.is_some(), |element| {
                element.child(
                    div()
                        .absolute()
                        .size_full()
                        .cursor_col_resize()
                        .bg(transparent_black())
                        .on_mouse_move(on_sidebar_resize_mouse_move)
                        .capture_any_mouse_up(on_sidebar_resize_mouse_up),
                )
            })
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

fn finish_agent_runtime_start<C, H>(
    mut runtime: AgentRuntime<C>,
    cancel_handle: H,
    start_result: anyhow::Result<()>,
) -> (AgentThreadState, Option<(AgentRuntime<C>, H)>) {
    match start_result {
        Ok(()) => {
            let thread = runtime.thread().clone();
            (thread, Some((runtime, cancel_handle)))
        }
        Err(error) => {
            runtime.thread_mut().status = AgentThreadStatus::Failed {
                message: error.to_string(),
            };
            (runtime.thread().clone(), None)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminal_refresh_interval_targets_sixty_fps_input_echo() {
        assert!(terminal_refresh_interval() <= Duration::from_millis(16));
    }

    #[test]
    fn failed_agent_runtime_start_drops_runtime_and_cancel_handle() {
        let thread = AgentThreadState::new("provider", PathBuf::from("/repo/worktree"));
        let runtime =
            AgentRuntime::with_connection(thread, crate::agent::fake::FakeAcpConnection::new());

        let (thread, runtime_with_cancel) = finish_agent_runtime_start::<_, String>(
            runtime,
            "cancel-handle".to_string(),
            Err(anyhow::anyhow!("create session failed")),
        );

        assert!(runtime_with_cancel.is_none());
        assert!(matches!(
            thread.status,
            AgentThreadStatus::Failed { ref message } if message == "create session failed"
        ));
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
