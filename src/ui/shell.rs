use std::path::{Path, PathBuf};

use crate::{
    app::{AlasModel, RepositoryNode},
    config::{AppConfig, AppConfigStore, AppRepository, repository_id_for_path},
    git::{GitRunner, GitWorktreeService},
    ui::{
        dialogs::{AddRepositoryDialogState, ConfirmRemoveRepositoryDialog},
        inspector::render_inspector_placeholder,
        sidebar::render_sidebar,
        terminal_pane::render_terminal_placeholder,
    },
};
use gpui::{
    App, Application, Context, IntoElement, PathPromptOptions, PromptLevel, Render, Window,
    WindowOptions, div, prelude::*,
};

pub struct AlasShell {
    model: AlasModel,
    config: AppConfig,
    app_config_store: AppConfigStore,
    add_repository_dialog: Option<AddRepositoryDialogState>,
    confirm_remove_repository_dialog: Option<ConfirmRemoveRepositoryDialog>,
    active_terminal: Option<()>,
    git_inspector: Option<()>,
    git_inspector_error: Option<String>,
}

impl AlasShell {
    fn new() -> Self {
        let app_config_store =
            AppConfigStore::default_store().expect("failed to resolve app config store");
        let config = app_config_store.load().unwrap_or_default();
        let model = configured_model(&config);

        Self {
            model,
            config,
            app_config_store,
            add_repository_dialog: None,
            confirm_remove_repository_dialog: None,
            active_terminal: None,
            git_inspector: None,
            git_inspector_error: None,
        }
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
        if !self
            .config
            .repositories
            .iter()
            .any(|repository| repository.id == id)
        {
            self.config.repositories.push(AppRepository {
                id,
                path: path.clone(),
                name: path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .map(str::to_string),
            });
        }

        if let Err(error) = self.app_config_store.save(&self.config) {
            self.set_add_repository_error(error.to_string());
            return;
        }

        self.add_repository_dialog = None;
        self.refresh_repositories();
    }

    fn set_add_repository_error(&mut self, error: impl Into<String>) {
        let dialog = self
            .add_repository_dialog
            .get_or_insert_with(AddRepositoryDialogState::default);
        dialog.error = Some(error.into());
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
        self.config
            .repositories
            .retain(|repository| repository.id != repo_id);
        self.config.archived_worktrees.shift_remove(repo_id);

        if self
            .model
            .selected_worktree()
            .is_some_and(|selected| selected.repo_id == repo_id)
        {
            self.clear_selection_and_active_terminal();
        }

        self.app_config_store.save(&self.config)?;
        self.refresh_repositories();
        Ok(())
    }

    fn clear_selection_and_active_terminal(&mut self) {
        self.model.clear_selection();
        self.active_terminal = None;
        self.git_inspector = None;
        self.git_inspector_error = None;
    }

    fn refresh_repositories(&mut self) {
        self.model = configured_model(&self.config);
    }

    fn add_repository_error(&self) -> Option<&str> {
        self.add_repository_dialog
            .as_ref()
            .and_then(|dialog| dialog.error.as_deref())
    }
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

        div()
            .flex()
            .size_full()
            .child(render_sidebar(
                self.model.repositories(),
                cx.listener(|shell, _event, _window, cx| shell.open_add_repository_dialog(cx)),
                on_remove_repository,
                self.add_repository_error(),
            ))
            .child(render_terminal_placeholder())
            .child(render_inspector_placeholder())
    }
}

pub fn run() -> anyhow::Result<()> {
    Application::new().run(|cx: &mut App| {
        cx.open_window(WindowOptions::default(), |_, cx| {
            cx.new(|_| AlasShell::new())
        })
        .expect("failed to open Alas window");
    });

    Ok(())
}

fn configured_model(config: &AppConfig) -> AlasModel {
    let mut model = AlasModel::default();
    model.set_repositories(
        config
            .repositories
            .iter()
            .cloned()
            .map(|repository| RepositoryNode {
                id: repository.id,
                name: repository
                    .name
                    .unwrap_or_else(|| infer_repository_name(&repository.path)),
                path: repository.path,
                show_archived: false,
                unavailable: false,
                worktrees: Vec::new(),
            })
            .collect(),
    );

    model
}

fn infer_repository_name(path: &Path) -> String {
    path.file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .map(ToString::to_string)
        .unwrap_or_else(|| path.display().to_string())
}
