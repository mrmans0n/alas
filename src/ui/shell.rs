use std::path::{Path, PathBuf};

use crate::{
    app::{AlasModel, RepositoryNode},
    config::{
        AppConfig, AppConfigStore, AppRepository, RepoConfigStore, ResolvedRepoConfig,
        repository_id_for_path,
    },
    git::{GitRunner, GitWorktreeService},
    terminal::{
        CommandSpec, GhosttyTerminalBackend, TerminalSessionId, TerminalSessionRef,
        TerminalSessionRegistry,
    },
    ui::{
        dialogs::{
            AddRepositoryDialogState, ConfirmRemoveRepositoryDialog, CreateWorktreeDialogState,
            CreateWorktreeField,
        },
        inspector::render_inspector_placeholder,
        sidebar::render_sidebar,
        terminal_pane::render_terminal_placeholder,
    },
};
use gpui::{
    App, Application, Context, FocusHandle, IntoElement, KeyDownEvent, PathPromptOptions,
    PromptLevel, Render, SharedString, Window, WindowOptions, div, prelude::*, px, rgb,
};

pub struct AlasShell {
    model: AlasModel,
    config: AppConfig,
    app_config_store: AppConfigStore,
    add_repository_dialog: Option<AddRepositoryDialogState>,
    create_worktree_dialog: Option<CreateWorktreeDialogState>,
    create_worktree_focus: FocusHandle,
    confirm_remove_repository_dialog: Option<ConfirmRemoveRepositoryDialog>,
    terminal_registry: TerminalSessionRegistry,
    terminal_backend: GhosttyTerminalBackend,
    active_terminal: Option<TerminalSessionRef>,
    terminal_error: Option<String>,
    git_inspector: Option<()>,
    git_inspector_error: Option<String>,
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
            confirm_remove_repository_dialog: None,
            terminal_registry: TerminalSessionRegistry::default(),
            terminal_backend: GhosttyTerminalBackend::new(),
            active_terminal: None,
            terminal_error: None,
            git_inspector: None,
            git_inspector_error: None,
        };
        shell.refresh_repositories();
        shell
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

    fn edit_create_worktree_field(&mut self, event: &KeyDownEvent) -> bool {
        if self.create_worktree_dialog.is_none() {
            return false;
        }

        match event.keystroke.key.as_str() {
            "escape" => {
                self.create_worktree_dialog = None;
                return true;
            }
            "enter" => {
                self.create_worktree_from_dialog();
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

    fn create_worktree_from_dialog(&mut self) {
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
        self.select_worktree(dialog.repo_id.clone(), target_path);
    }

    fn select_worktree(&mut self, repo_id: String, path: PathBuf) {
        self.model.select_worktree(repo_id.clone(), path.clone());
        let command = self.resolve_default_command(&repo_id, path.clone());
        let id = TerminalSessionId::new(repo_id, path);

        match self
            .terminal_registry
            .get_or_start(id, command, &mut self.terminal_backend)
        {
            Ok(session) => {
                self.active_terminal = Some(session);
                self.terminal_error = None;
            }
            Err(error) => {
                self.active_terminal = None;
                self.terminal_error = Some(error.to_string());
            }
        }
    }

    fn resolve_default_command(&self, repo_id: &str, worktree_path: PathBuf) -> CommandSpec {
        let Some(repo) = self
            .config
            .repositories
            .iter()
            .find(|repository| repository.id == repo_id)
        else {
            return CommandSpec::shell_command("$SHELL", worktree_path);
        };

        let repo_file = RepoConfigStore::for_repo(&repo.path).load().ok().flatten();
        let resolved = ResolvedRepoConfig::resolve(
            repo.id.clone(),
            repo.path.clone(),
            repo.name.clone(),
            &self.config,
            repo_file,
        );

        CommandSpec::shell_command(resolved.default_command().command.clone(), worktree_path)
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

    fn clear_selection_and_active_terminal(&mut self) {
        self.model.clear_selection();
        self.active_terminal = None;
        self.terminal_error = None;
        self.git_inspector = None;
        self.git_inspector_error = None;
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

impl Render for AlasShell {
    fn render(&mut self, _window: &mut gpui::Window, cx: &mut Context<Self>) -> impl IntoElement {
        let view = cx.entity().downgrade();
        let on_remove_repository = move |repo_id: String,
                                         repo_name: String,
                                         _event: &gpui::ClickEvent,
                                         window: &mut Window,
                                         app: &mut App| {
            view.update(app, |shell, cx| {
                shell.confirm_remove_repository(repo_id, repo_name, window, cx);
            })
            .ok();
        };
        let view = cx.entity().downgrade();
        let on_create_worktree = move |repo_id: String,
                                       _event: &gpui::ClickEvent,
                                       _window: &mut Window,
                                       app: &mut App| {
            view.update(app, |shell, cx| {
                shell.open_create_worktree_dialog(repo_id, cx);
            })
            .ok();
        };
        let view = cx.entity().downgrade();
        let on_select_worktree = move |repo_id: String,
                                       path: PathBuf,
                                       _event: &gpui::ClickEvent,
                                       _window: &mut Window,
                                       app: &mut App| {
            view.update(app, |shell, cx| {
                shell.select_worktree(repo_id, path);
                cx.notify();
            })
            .ok();
        };
        let view = cx.entity().downgrade();
        let on_toggle_show_archived = move |repo_id: String,
                                            show: bool,
                                            _event: &gpui::ClickEvent,
                                            _window: &mut Window,
                                            app: &mut App| {
            view.update(app, |shell, cx| {
                shell.set_show_archived(&repo_id, show);
                cx.notify();
            })
            .ok();
        };
        let view = cx.entity().downgrade();
        let on_archive_worktree = move |repo_id: String,
                                        path: PathBuf,
                                        _event: &gpui::ClickEvent,
                                        _window: &mut Window,
                                        app: &mut App| {
            view.update(app, |shell, cx| {
                if let Err(error) = shell.archive_worktree(&repo_id, path) {
                    shell.set_add_repository_error(error.to_string());
                }
                cx.notify();
            })
            .ok();
        };
        let view = cx.entity().downgrade();
        let on_unarchive_worktree = move |repo_id: String,
                                          path: PathBuf,
                                          _event: &gpui::ClickEvent,
                                          _window: &mut Window,
                                          app: &mut App| {
            view.update(app, |shell, cx| {
                if let Err(error) = shell.unarchive_worktree(&repo_id, &path) {
                    shell.set_add_repository_error(error.to_string());
                }
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
        let on_submit_create_worktree = cx.listener(|shell, _event, _window, cx| {
            shell.create_worktree_from_dialog();
            cx.notify();
        });
        let on_cancel_create_worktree = cx.listener(|shell, _event, _window, cx| {
            shell.close_create_worktree_dialog();
            cx.notify();
        });
        let on_create_worktree_key_down =
            cx.listener(|shell, event: &KeyDownEvent, _window, cx| {
                if shell.edit_create_worktree_field(event) {
                    cx.stop_propagation();
                    cx.notify();
                }
            });

        div()
            .flex()
            .size_full()
            .child(render_sidebar(
                self.model.repositories(),
                cx.listener(|shell, _event, _window, cx| shell.open_add_repository_dialog(cx)),
                on_remove_repository,
                on_create_worktree,
                on_select_worktree,
                on_toggle_show_archived,
                on_archive_worktree,
                on_unarchive_worktree,
                self.add_repository_error(),
            ))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
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
                    .child(render_terminal_placeholder(
                        self.model.selected_worktree(),
                        self.active_terminal.as_ref(),
                        self.terminal_error.as_deref(),
                    )),
            )
            .child(render_inspector_placeholder())
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
