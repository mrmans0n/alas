use std::path::PathBuf;

use crate::app::RepositoryNode;
use gpui::{
    App, ClickEvent, FontWeight, IntoElement, ParentElement, SharedString, Styled, Window, div,
    prelude::*, px, rgb,
};

pub fn render_sidebar(
    repositories: &[RepositoryNode],
    on_add_repository: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    on_remove_repository: impl Fn(String, String, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_create_worktree: impl Fn(String, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_select_worktree: impl Fn(String, PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_toggle_show_archived: impl Fn(String, bool, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_archive_worktree: impl Fn(String, PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_unarchive_worktree: impl Fn(String, PathBuf, &ClickEvent, &mut Window, &mut App)
    + Clone
    + 'static,
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
        .children(repositories.iter().map(|repository| {
            render_repository(
                repository,
                on_remove_repository.clone(),
                on_create_worktree.clone(),
                on_select_worktree.clone(),
                on_toggle_show_archived.clone(),
                on_archive_worktree.clone(),
                on_unarchive_worktree.clone(),
            )
        }))
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
    on_create_worktree: impl Fn(String, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_select_worktree: impl Fn(String, PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_toggle_show_archived: impl Fn(String, bool, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_archive_worktree: impl Fn(String, PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_unarchive_worktree: impl Fn(String, PathBuf, &ClickEvent, &mut Window, &mut App)
    + Clone
    + 'static,
) -> impl IntoElement {
    let repo_id = repository.id.clone();
    let repo_name = repository.name.clone();
    let create_worktree_repo_id = repository.id.clone();
    let remove_label: SharedString = "Remove from Alas".into();
    let show_archived_label: SharedString = if repository.show_archived {
        "Hide archived".into()
    } else {
        "Show archived".into()
    };

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
                        .id(SharedString::from(format!(
                            "create-worktree-{create_worktree_repo_id}"
                        )))
                        .text_sm()
                        .when(repository.unavailable, |element| {
                            element.text_color(rgb(0xdc2626)).child("Unavailable")
                        })
                        .when(!repository.unavailable, |element| {
                            element
                                .text_color(rgb(0x2563eb))
                                .child("+ Worktree")
                                .on_click(move |event, window, cx| {
                                    on_create_worktree(
                                        create_worktree_repo_id.clone(),
                                        event,
                                        window,
                                        cx,
                                    );
                                })
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
                        .flex()
                        .gap_2()
                        .child(
                            div()
                                .id(SharedString::from(format!("toggle-archived-{repo_id}")))
                                .text_xs()
                                .text_color(rgb(0x2563eb))
                                .child(show_archived_label)
                                .on_click({
                                    let repo_id = repo_id.clone();
                                    let show_archived = repository.show_archived;
                                    move |event, window, cx| {
                                        on_toggle_show_archived(
                                            repo_id.clone(),
                                            !show_archived,
                                            event,
                                            window,
                                            cx,
                                        );
                                    }
                                }),
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
                    let repo_id = repository.id.clone();
                    let worktree_path = worktree.path.clone();
                    let is_archived = worktree.archived;
                    let action_label: SharedString = if is_archived {
                        "Unarchive".into()
                    } else {
                        "Archive".into()
                    };
                    let select_repo_id = repo_id.clone();
                    let select_worktree_path = worktree_path.clone();
                    let on_archive_worktree = on_archive_worktree.clone();
                    let on_unarchive_worktree = on_unarchive_worktree.clone();
                    let on_select_worktree = on_select_worktree.clone();

                    div()
                        .ml_3()
                        .px_2()
                        .py_1()
                        .rounded_md()
                        .id(SharedString::from(format!(
                            "select-worktree-{select_repo_id}-{}",
                            select_worktree_path.display()
                        )))
                        .text_sm()
                        .bg(rgb(0xffffff))
                        .flex()
                        .items_center()
                        .justify_between()
                        .gap_2()
                        .on_click(move |event, window, cx| {
                            on_select_worktree(
                                select_repo_id.clone(),
                                select_worktree_path.clone(),
                                event,
                                window,
                                cx,
                            );
                        })
                        .child(div().truncate().child(label))
                        .child(
                            div()
                                .id(SharedString::from(format!(
                                    "archive-worktree-{repo_id}-{}",
                                    worktree_path.display()
                                )))
                                .text_xs()
                                .text_color(rgb(0x2563eb))
                                .child(action_label)
                                .on_click(move |event, window, cx| {
                                    cx.stop_propagation();
                                    if is_archived {
                                        on_unarchive_worktree(
                                            repo_id.clone(),
                                            worktree_path.clone(),
                                            event,
                                            window,
                                            cx,
                                        );
                                    } else {
                                        on_archive_worktree(
                                            repo_id.clone(),
                                            worktree_path.clone(),
                                            event,
                                            window,
                                            cx,
                                        );
                                    }
                                }),
                        )
                }),
        )
}
