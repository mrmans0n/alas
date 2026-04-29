use crate::app::RepositoryNode;
use gpui::{FontWeight, IntoElement, ParentElement, Styled, div, px, rgb};

pub fn render_sidebar(repositories: &[RepositoryNode]) -> impl IntoElement {
    div()
        .flex()
        .flex_col()
        .flex_shrink_0()
        .size_full()
        .w(px(280.0))
        .p_4()
        .gap_3()
        .border_r_1()
        .border_color(rgb(0xd8dee9))
        .bg(rgb(0xf4f6f8))
        .child(
            div()
                .text_lg()
                .font_weight(FontWeight::BOLD)
                .child("Repositories"),
        )
        .children(repositories.iter().map(render_repository))
}

fn render_repository(repository: &RepositoryNode) -> impl IntoElement {
    div()
        .flex()
        .flex_col()
        .gap_2()
        .child(
            div()
                .flex()
                .items_center()
                .justify_between()
                .child(
                    div()
                        .font_weight(FontWeight::SEMIBOLD)
                        .truncate()
                        .child(repository.name.clone()),
                )
                .child(
                    div()
                        .text_sm()
                        .text_color(rgb(0x2563eb))
                        .child("+ Worktree"),
                ),
        )
        .children(
            repository
                .worktrees
                .iter()
                .filter(|worktree| repository.show_archived || !worktree.archived)
                .map(|worktree| {
                    let label = worktree
                        .branch
                        .clone()
                        .unwrap_or_else(|| worktree.path.display().to_string());

                    div()
                        .ml_3()
                        .px_2()
                        .py_1()
                        .rounded_md()
                        .text_sm()
                        .truncate()
                        .bg(rgb(0xffffff))
                        .child(label)
                }),
        )
}
