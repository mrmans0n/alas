use std::path::PathBuf;

use crate::{
    app::{AlasModel, RepositoryNode, WorktreeNode},
    git::WorktreeKind,
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
            model: static_model(),
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

fn static_model() -> AlasModel {
    let mut model = AlasModel::default();
    let repo_path = PathBuf::from("/tmp/alas-demo");

    model.set_repositories(vec![RepositoryNode {
        id: "alas-demo".to_string(),
        name: "alas-demo".to_string(),
        path: repo_path.clone(),
        show_archived: false,
        unavailable: false,
        worktrees: vec![
            WorktreeNode {
                path: repo_path.clone(),
                branch: Some("main".to_string()),
                head: Some("abc1234".to_string()),
                kind: WorktreeKind::Main,
                archived: false,
            },
            WorktreeNode {
                path: PathBuf::from("/tmp/alas-demo-feature"),
                branch: Some("feature/three-pane-shell".to_string()),
                head: Some("def5678".to_string()),
                kind: WorktreeKind::Linked,
                archived: false,
            },
            WorktreeNode {
                path: PathBuf::from("/tmp/alas-demo-archived"),
                branch: None,
                head: Some("987abcd".to_string()),
                kind: WorktreeKind::Linked,
                archived: true,
            },
        ],
    }]);

    model
}
