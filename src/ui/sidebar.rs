use crate::app::RepositoryNode;
use gpui::{
    App, ClickEvent, FontWeight, IntoElement, ParentElement, SharedString, Styled, Window, div,
    prelude::*, px, rgb,
};

pub fn render_sidebar(
    repositories: &[RepositoryNode],
    on_add_repository: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    on_remove_repository: impl Fn(String, String, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    add_repository_error: Option<&str>,
) -> impl IntoElement {
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
        .children(
            repositories
                .iter()
                .map(|repository| render_repository(repository, on_remove_repository.clone())),
        )
        .child(
            div()
                .mt_auto()
                .flex()
                .flex_col()
                .gap_2()
                .child(
                    div()
                        .id("add-repository")
                        .px_3()
                        .py_2()
                        .rounded_md()
                        .text_sm()
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(rgb(0xffffff))
                        .bg(rgb(0x2563eb))
                        .child("+ Add Repository")
                        .on_click(on_add_repository),
                )
                .when(add_repository_error.is_some(), |element| {
                    element.child(
                        div()
                            .text_sm()
                            .text_color(rgb(0xdc2626))
                            .child(add_repository_error.unwrap_or_default().to_string()),
                    )
                }),
        )
}

fn render_repository(
    repository: &RepositoryNode,
    on_remove_repository: impl Fn(String, String, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
) -> impl IntoElement {
    let repo_id = repository.id.clone();
    let repo_name = repository.name.clone();
    let remove_label: SharedString = "Remove from Alas".into();

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
                        .when(repository.unavailable, |element| {
                            element.text_color(rgb(0xdc2626)).child("Unavailable")
                        })
                        .when(!repository.unavailable, |element| {
                            element.text_color(rgb(0x2563eb)).child("+ Worktree")
                        }),
                ),
        )
        .child(
            div()
                .flex()
                .justify_between()
                .items_center()
                .gap_2()
                .child(
                    div()
                        .text_xs()
                        .text_color(rgb(0x6b7280))
                        .truncate()
                        .child(repository.path.display().to_string()),
                )
                .child(
                    div()
                        .id(SharedString::from(format!("remove-repository-{repo_id}")))
                        .text_xs()
                        .text_color(rgb(0xdc2626))
                        .child(remove_label)
                        .on_click(move |event, window, cx| {
                            on_remove_repository(
                                repo_id.clone(),
                                repo_name.clone(),
                                event,
                                window,
                                cx,
                            );
                        }),
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
