use std::path::PathBuf;

use crate::{app::RepositoryNode, git::WorktreeKind};
use gpui::{
    App, ClickEvent, Div, FontWeight, IntoElement, ParentElement, Rgba, SharedString, Styled,
    Window, div, prelude::*, px, rgb,
};

pub fn render_sidebar(
    repositories: &[RepositoryNode],
    on_add_repository: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    on_remove_repository: impl Fn(String, String, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_prune_worktrees: impl Fn(String, String, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_create_worktree: impl Fn(String, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_command_settings: impl Fn(String, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_select_worktree: impl Fn(String, PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_toggle_show_archived: impl Fn(String, bool, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_archive_worktree: impl Fn(String, PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_unarchive_worktree: impl Fn(String, PathBuf, &ClickEvent, &mut Window, &mut App)
    + Clone
    + 'static,
    on_remove_worktree: impl Fn(String, PathBuf, bool, &ClickEvent, &mut Window, &mut App)
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
        .when(repositories.is_empty(), |element| {
            element.child(
                div()
                    .p_3()
                    .rounded_md()
                    .border_1()
                    .border_color(rgb(0xd8dee9))
                    .bg(rgb(0xffffff))
                    .text_sm()
                    .text_color(rgb(0x6b7280))
                    .child("No repositories configured. Add a Git repository to begin."),
            )
        })
        .children(repositories.iter().map(|repository| {
            render_repository(
                repository,
                on_remove_repository.clone(),
                on_prune_worktrees.clone(),
                on_create_worktree.clone(),
                on_command_settings.clone(),
                on_select_worktree.clone(),
                on_toggle_show_archived.clone(),
                on_archive_worktree.clone(),
                on_unarchive_worktree.clone(),
                on_remove_worktree.clone(),
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
    on_prune_worktrees: impl Fn(String, String, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_create_worktree: impl Fn(String, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_command_settings: impl Fn(String, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_select_worktree: impl Fn(String, PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_toggle_show_archived: impl Fn(String, bool, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_archive_worktree: impl Fn(String, PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_unarchive_worktree: impl Fn(String, PathBuf, &ClickEvent, &mut Window, &mut App)
    + Clone
    + 'static,
    on_remove_worktree: impl Fn(String, PathBuf, bool, &ClickEvent, &mut Window, &mut App)
    + Clone
    + 'static,
) -> impl IntoElement {
    let repo_id = repository.id.clone();
    let repo_name = repository.name.clone();
    let create_worktree_repo_id = repository.id.clone();
    let command_settings_repo_id = repository.id.clone();
    let prune_worktrees_repo_id = repository.id.clone();
    let prune_worktrees_repo_name = repository.name.clone();
    let remove_label: SharedString = "Remove from Alas".into();
    let show_archived_label: SharedString = if repository.show_archived {
        "Hide archived".into()
    } else {
        "Show archived".into()
    };
    let has_visible_worktrees = repository
        .worktrees
        .iter()
        .any(|worktree| repository.show_archived || !worktree.archived);

    // GPUI 0.2 exposes low-level mouse events but no stable built-in context
    // menu/popover primitive in this app. Keep the full right-click menu action
    // set visible and grouped so no archive/remove/prune/settings affordance is
    // lost while native context menus are deferred.
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
                        .flex_wrap()
                        .justify_end()
                        .gap_1()
                        .child(
                            action_chip(show_archived_label, rgb(0x2563eb))
                                .id(SharedString::from(format!("toggle-archived-{repo_id}")))
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
                            action_chip("Commands".into(), rgb(0x2563eb))
                                .id(SharedString::from(format!(
                                    "command-settings-{command_settings_repo_id}"
                                )))
                                .on_click(move |event, window, cx| {
                                    on_command_settings(
                                        command_settings_repo_id.clone(),
                                        event,
                                        window,
                                        cx,
                                    );
                                }),
                        )
                        .child(
                            action_chip("Prune".into(), rgb(0x2563eb))
                                .id(SharedString::from(format!(
                                    "prune-worktrees-{prune_worktrees_repo_id}"
                                )))
                                .on_click(move |event, window, cx| {
                                    on_prune_worktrees(
                                        prune_worktrees_repo_id.clone(),
                                        prune_worktrees_repo_name.clone(),
                                        event,
                                        window,
                                        cx,
                                    );
                                }),
                        )
                        .child(
                            action_chip(remove_label, rgb(0xdc2626))
                                .id(SharedString::from(format!("remove-repository-{repo_id}")))
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
        .when(repository.unavailable, |element| {
            element.child(
                div()
                    .ml_3()
                    .p_2()
                    .rounded_md()
                    .bg(rgb(0xfef3c7))
                    .text_sm()
                    .text_color(rgb(0x92400e))
                    .child(
                        "Repository unavailable or moved. Check the path or remove it from Alas.",
                    ),
            )
        })
        .when(
            !repository.unavailable && repository.worktrees.is_empty(),
            |element| {
                element.child(
                    div()
                        .ml_3()
                        .p_2()
                        .rounded_md()
                        .bg(rgb(0xffffff))
                        .text_sm()
                        .text_color(rgb(0x6b7280))
                        .child("No worktrees found for this repository."),
                )
            },
        )
        .when(
            !repository.unavailable && !repository.worktrees.is_empty() && !has_visible_worktrees,
            |element| {
                element.child(
                    div()
                        .ml_3()
                        .p_2()
                        .rounded_md()
                        .bg(rgb(0xffffff))
                        .text_sm()
                        .text_color(rgb(0x6b7280))
                        .child("No visible worktrees. Show archived worktrees to view archived entries."),
                )
            },
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
                    let is_main = worktree.kind == WorktreeKind::Main;
                    let action_label: SharedString = if is_archived {
                        "Unarchive".into()
                    } else {
                        "Archive".into()
                    };
                    let select_repo_id = repo_id.clone();
                    let select_worktree_path = worktree_path.clone();
                    let open_repo_id = repo_id.clone();
                    let open_worktree_path = worktree_path.clone();
                    let remove_repo_id = repo_id.clone();
                    let remove_worktree_path = worktree_path.clone();
                    let on_archive_worktree = on_archive_worktree.clone();
                    let on_unarchive_worktree = on_unarchive_worktree.clone();
                    let on_select_row_worktree = on_select_worktree.clone();
                    let on_select_open_worktree = on_select_worktree.clone();
                    let on_remove_worktree = on_remove_worktree.clone();

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
                            on_select_row_worktree(
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
                                .flex()
                                .flex_wrap()
                                .justify_end()
                                .gap_1()
                                .child(
                                    action_chip("Open".into(), rgb(0x2563eb))
                                        .id(SharedString::from(format!(
                                            "open-worktree-{open_repo_id}-{}",
                                            open_worktree_path.display()
                                        )))
                                        .on_click(move |event, window, cx| {
                                            cx.stop_propagation();
                                            on_select_open_worktree(
                                                open_repo_id.clone(),
                                                open_worktree_path.clone(),
                                                event,
                                                window,
                                                cx,
                                            );
                                        }),
                                )
                                .child(
                                    action_chip(action_label, rgb(0x2563eb))
                                        .id(SharedString::from(format!(
                                            "archive-worktree-{repo_id}-{}",
                                            worktree_path.display()
                                        )))
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
                                .when(!is_main, |element| {
                                    element.child(
                                        action_chip("Remove".into(), rgb(0xdc2626))
                                            .id(SharedString::from(format!(
                                                "remove-worktree-{remove_repo_id}-{}",
                                                remove_worktree_path.display()
                                            )))
                                            .on_click(move |event, window, cx| {
                                                cx.stop_propagation();
                                                on_remove_worktree(
                                                    remove_repo_id.clone(),
                                                    remove_worktree_path.clone(),
                                                    is_main,
                                                    event,
                                                    window,
                                                    cx,
                                                );
                                            }),
                                    )
                                }),
                        )
                }),
        )
}

fn action_chip(label: SharedString, color: Rgba) -> Div {
    div()
        .px_2()
        .py_1()
        .rounded_md()
        .bg(rgb(0xe5e7eb))
        .text_xs()
        .font_weight(FontWeight::SEMIBOLD)
        .text_color(color)
        .child(label)
}
