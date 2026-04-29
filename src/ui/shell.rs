use std::path::Path;

use crate::{
    app::{AlasModel, RepositoryNode},
    ui::{
        inspector::render_inspector_placeholder, sidebar::render_sidebar,
        terminal_pane::render_terminal_placeholder,
    },
};
use gpui::{App, Application, Context, IntoElement, Render, WindowOptions, div, prelude::*};

pub struct AlasShell {
    model: AlasModel,
}

impl AlasShell {
    fn new() -> Self {
        Self {
            model: configured_model(),
        }
    }
}

impl Render for AlasShell {
    fn render(&mut self, _window: &mut gpui::Window, _cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .flex()
            .size_full()
            .child(render_sidebar(self.model.repositories()))
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

fn configured_model() -> AlasModel {
    let config = crate::config::AppConfigStore::default_store()
        .and_then(|store| store.load())
        .unwrap_or_default();

    let mut model = AlasModel::default();
    model.set_repositories(
        config
            .repositories
            .into_iter()
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
