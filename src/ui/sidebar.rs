use std::path::PathBuf;

use crate::{
    app::{
        ActionAvailability, ActionDefinition, ActionId, ActionRegistry, ActionScope,
        RepositoryNode, SelectedWorktree, WorktreeNode,
    },
    git::WorktreeKind,
    ui::theme::{
        ACCENT, ACCENT_TEXT, DANGER, PANEL_BG, PANEL_BORDER, SIDEBAR_BG, TEXT, TEXT_MUTED,
    },
};
use gpui::{
    App, ClickEvent, Div, FontWeight, IntoElement, MouseButton, ParentElement, SharedString,
    Styled, Window, div, prelude::*, px,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SidebarMenuState {
    pub repo_id: String,
    pub worktree_path: Option<PathBuf>,
    pub scope: ActionScope,
}

pub fn render_sidebar(
    repositories: &[RepositoryNode],
    selected_worktree: Option<&SelectedWorktree>,
    sidebar_menu: Option<&SidebarMenuState>,
    on_add_repository: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    on_select_worktree: impl Fn(String, PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_open_sidebar_menu: impl Fn(SidebarMenuState, &mut Window, &mut App) + Clone + 'static,
    on_sidebar_menu_action: impl Fn(ActionId, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_close_sidebar_menu: impl Fn(&ClickEvent, &mut Window, &mut App) + Clone + 'static,
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
        .border_color(PANEL_BORDER)
        .bg(SIDEBAR_BG)
        .text_color(TEXT)
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
                    .border_color(PANEL_BORDER)
                    .bg(PANEL_BG)
                    .text_sm()
                    .text_color(TEXT_MUTED)
                    .child("No repositories configured. Add a Git repository to begin."),
            )
        })
        .children(repositories.iter().map(|repository| {
            render_repository(
                repository,
                selected_worktree,
                sidebar_menu,
                on_select_worktree.clone(),
                on_open_sidebar_menu.clone(),
                on_sidebar_menu_action.clone(),
                on_close_sidebar_menu.clone(),
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
                        .text_color(ACCENT_TEXT)
                        .bg(ACCENT)
                        .child("+ Add Repository")
                        .on_click(on_add_repository),
                )
                .when(add_repository_error.is_some(), |element| {
                    element.child(
                        div()
                            .text_sm()
                            .text_color(DANGER)
                            .child(add_repository_error.unwrap_or_default().to_string()),
                    )
                }),
        )
}

fn render_repository(
    repository: &RepositoryNode,
    selected_worktree: Option<&SelectedWorktree>,
    sidebar_menu: Option<&SidebarMenuState>,
    on_select_worktree: impl Fn(String, PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_open_sidebar_menu: impl Fn(SidebarMenuState, &mut Window, &mut App) + Clone + 'static,
    on_sidebar_menu_action: impl Fn(ActionId, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_close_sidebar_menu: impl Fn(&ClickEvent, &mut Window, &mut App) + Clone + 'static,
) -> impl IntoElement {
    let repository_menu = SidebarMenuState {
        repo_id: repository.id.clone(),
        worktree_path: None,
        scope: ActionScope::Repository,
    };
    let repository_menu_is_open = sidebar_menu == Some(&repository_menu);
    let has_visible_worktrees = repository
        .worktrees
        .iter()
        .any(|worktree| repository.show_archived || !worktree.archived);

    div()
        .flex()
        .flex_col()
        .gap_2()
        .child(
            div()
                .flex()
                .items_start()
                .justify_between()
                .gap_2()
                .on_mouse_down(MouseButton::Right, {
                    let on_open_sidebar_menu = on_open_sidebar_menu.clone();
                    let repository_menu = repository_menu.clone();
                    move |event, window, cx| {
                        cx.stop_propagation();
                        if event.button == MouseButton::Right {
                            on_open_sidebar_menu(repository_menu.clone(), window, cx);
                        }
                    }
                })
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .gap_1()
                        .overflow_hidden()
                        .child(
                            div()
                                .flex()
                                .items_center()
                                .gap_2()
                                .child(
                                    div()
                                        .font_weight(FontWeight::SEMIBOLD)
                                        .truncate()
                                        .child(repository.name.clone()),
                                )
                                .when(repository.unavailable, |element| {
                                    element.child(status_badge("Unavailable"))
                                }),
                        )
                        .child(
                            div()
                                .text_xs()
                                .text_color(TEXT_MUTED)
                                .truncate()
                                .child(repository.path.display().to_string()),
                        ),
                )
                .child(overflow_button(
                    SharedString::from(format!("repository-actions-{}", repository.id)),
                    repository_menu,
                    on_open_sidebar_menu.clone(),
                )),
        )
        .when(repository_menu_is_open, |element| {
            element.child(render_sidebar_menu(
                repository,
                None,
                on_sidebar_menu_action.clone(),
                on_close_sidebar_menu.clone(),
            ))
        })
        .when(repository.unavailable, |element| {
            element.child(
                div()
                    .ml_3()
                    .p_2()
                    .rounded_md()
                    .border_1()
                    .border_color(PANEL_BORDER)
                    .bg(PANEL_BG)
                    .text_sm()
                    .text_color(TEXT_MUTED)
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
                        .bg(PANEL_BG)
                        .text_sm()
                        .text_color(TEXT_MUTED)
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
                        .bg(PANEL_BG)
                        .text_sm()
                        .text_color(TEXT_MUTED)
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
                    render_worktree_row(
                        repository,
                        worktree,
                        selected_worktree,
                        sidebar_menu,
                        on_select_worktree.clone(),
                        on_open_sidebar_menu.clone(),
                        on_sidebar_menu_action.clone(),
                        on_close_sidebar_menu.clone(),
                    )
                }),
        )
}

fn render_worktree_row(
    repository: &RepositoryNode,
    worktree: &WorktreeNode,
    selected_worktree: Option<&SelectedWorktree>,
    sidebar_menu: Option<&SidebarMenuState>,
    on_select_worktree: impl Fn(String, PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_open_sidebar_menu: impl Fn(SidebarMenuState, &mut Window, &mut App) + Clone + 'static,
    on_sidebar_menu_action: impl Fn(ActionId, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_close_sidebar_menu: impl Fn(&ClickEvent, &mut Window, &mut App) + Clone + 'static,
) -> impl IntoElement {
    let label = worktree.branch.clone().unwrap_or_else(|| {
        worktree
            .path
            .file_name()
            .and_then(|name| name.to_str())
            .map(ToString::to_string)
            .unwrap_or_else(|| worktree.path.display().to_string())
    });
    let is_main = worktree.kind == WorktreeKind::Main;
    let repo_id = repository.id.clone();
    let worktree_path = worktree.path.clone();
    let menu_state = SidebarMenuState {
        repo_id: repo_id.clone(),
        worktree_path: Some(worktree_path.clone()),
        scope: ActionScope::Worktree,
    };
    let menu_is_open = sidebar_menu == Some(&menu_state);
    let is_selected = selected_worktree
        .is_some_and(|selected| selected.repo_id == repo_id && selected.path == worktree_path);
    let is_subdued = worktree.archived || repository.unavailable;
    let row_id = SharedString::from(format!(
        "select-worktree-{repo_id}-{}",
        worktree_path.display()
    ));

    div()
        .flex()
        .flex_col()
        .gap_1()
        .child(
            div()
                .ml_3()
                .px_2()
                .py_1()
                .rounded_md()
                .border_1()
                .border_color(if is_selected { ACCENT } else { SIDEBAR_BG })
                .id(row_id)
                .text_sm()
                .text_color(if is_subdued { TEXT_MUTED } else { TEXT })
                .bg(if is_selected { PANEL_BG } else { SIDEBAR_BG })
                .flex()
                .items_center()
                .justify_between()
                .gap_2()
                .on_mouse_down(MouseButton::Right, {
                    let on_open_sidebar_menu = on_open_sidebar_menu.clone();
                    let menu_state = menu_state.clone();
                    move |event, window, cx| {
                        cx.stop_propagation();
                        if event.button == MouseButton::Right {
                            on_open_sidebar_menu(menu_state.clone(), window, cx);
                        }
                    }
                })
                .on_click({
                    let on_select_worktree = on_select_worktree.clone();
                    let repo_id = repo_id.clone();
                    let worktree_path = worktree_path.clone();
                    move |event, window, cx| {
                        if event.is_right_click() {
                            return;
                        }
                        on_select_worktree(
                            repo_id.clone(),
                            worktree_path.clone(),
                            event,
                            window,
                            cx,
                        );
                    }
                })
                .child(
                    div()
                        .flex()
                        .items_center()
                        .gap_2()
                        .overflow_hidden()
                        .child(div().truncate().child(label))
                        .when(worktree.archived, |element| {
                            element.child(status_badge("Archived"))
                        })
                        .child(status_badge(if is_main { "Main" } else { "Linked" })),
                )
                .child(
                    div()
                        .flex()
                        .items_center()
                        .justify_end()
                        .gap_2()
                        .child(
                            div()
                                .w(px(44.0))
                                .text_xs()
                                .text_color(TEXT_MUTED)
                                .child(" "),
                        )
                        .child(overflow_button(
                            SharedString::from(format!(
                                "worktree-actions-{repo_id}-{}",
                                worktree_path.display()
                            )),
                            menu_state.clone(),
                            on_open_sidebar_menu.clone(),
                        )),
                ),
        )
        .when(menu_is_open, |element| {
            element.child(render_sidebar_menu(
                repository,
                Some(worktree),
                on_sidebar_menu_action.clone(),
                on_close_sidebar_menu.clone(),
            ))
        })
}

fn render_sidebar_menu(
    repository: &RepositoryNode,
    worktree: Option<&WorktreeNode>,
    on_sidebar_menu_action: impl Fn(ActionId, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_close_sidebar_menu: impl Fn(&ClickEvent, &mut Window, &mut App) + Clone + 'static,
) -> impl IntoElement {
    let registry = ActionRegistry::default();
    let scope = if worktree.is_some() {
        ActionScope::Worktree
    } else {
        ActionScope::Repository
    };
    let actions = registry
        .actions()
        .iter()
        .filter(|action| action.scope == scope)
        .filter(|action| action_is_available(action, repository, worktree))
        .cloned()
        .collect::<Vec<_>>();

    div()
        .ml_3()
        .mr_1()
        .p_1()
        .rounded_md()
        .border_1()
        .border_color(PANEL_BORDER)
        .bg(PANEL_BG)
        .flex()
        .flex_col()
        .gap_1()
        .child(
            div()
                .flex()
                .items_center()
                .justify_between()
                .px_2()
                .py_1()
                .child(
                    div()
                        .text_xs()
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(TEXT_MUTED)
                        .child(if scope == ActionScope::Repository {
                            "Repository actions"
                        } else {
                            "Worktree actions"
                        }),
                )
                .child(
                    div()
                        .id("close-sidebar-menu")
                        .px_1()
                        .rounded_md()
                        .text_xs()
                        .text_color(TEXT_MUTED)
                        .child("×")
                        .on_click(move |event, window, cx| {
                            cx.stop_propagation();
                            on_close_sidebar_menu(event, window, cx);
                        }),
                ),
        )
        .children(actions.into_iter().map(move |action| {
            let on_sidebar_menu_action = on_sidebar_menu_action.clone();
            let action_id = action.id;
            menu_action_row(
                SharedString::from(format!("sidebar-action-{action_id:?}")),
                sidebar_action_label(&action, repository),
                action.destructive,
                action_id,
                on_sidebar_menu_action,
            )
        }))
}

fn action_is_available(
    action: &ActionDefinition,
    repository: &RepositoryNode,
    worktree: Option<&WorktreeNode>,
) -> bool {
    match action.availability {
        ActionAvailability::Always => true,
        ActionAvailability::WhenRepositoryAvailable => !repository.unavailable,
        ActionAvailability::WhenWorktreeAvailable => worktree.is_some() && !repository.unavailable,
        ActionAvailability::WhenWorktreeIsArchived => {
            worktree.is_some_and(|worktree| worktree.archived) && !repository.unavailable
        }
        ActionAvailability::WhenWorktreeIsNotArchived => {
            worktree.is_some_and(|worktree| !worktree.archived) && !repository.unavailable
        }
        ActionAvailability::WhenWorktreeIsLinked => {
            worktree.is_some_and(|worktree| worktree.kind != WorktreeKind::Main)
                && !repository.unavailable
        }
    }
}

fn sidebar_action_label(action: &ActionDefinition, repository: &RepositoryNode) -> SharedString {
    match action.id {
        ActionId::ToggleArchivedWorktrees if repository.show_archived => "Hide archived".into(),
        ActionId::ToggleArchivedWorktrees => "Show archived".into(),
        _ => action.label.into(),
    }
}

fn overflow_button(
    id: SharedString,
    menu_state: SidebarMenuState,
    on_open_sidebar_menu: impl Fn(SidebarMenuState, &mut Window, &mut App) + Clone + 'static,
) -> impl IntoElement {
    div()
        .id(id)
        .px_2()
        .py_1()
        .rounded_md()
        .text_sm()
        .font_weight(FontWeight::SEMIBOLD)
        .text_color(TEXT_MUTED)
        .bg(PANEL_BG)
        .child("⋯")
        .on_click(move |_event, window, cx| {
            cx.stop_propagation();
            on_open_sidebar_menu(menu_state.clone(), window, cx);
        })
}

fn menu_action_row(
    id: SharedString,
    label: SharedString,
    destructive: bool,
    action_id: ActionId,
    on_sidebar_menu_action: impl Fn(ActionId, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
) -> impl IntoElement {
    div()
        .id(id)
        .px_2()
        .py_1()
        .rounded_md()
        .text_sm()
        .text_color(if destructive { DANGER } else { TEXT })
        .child(label)
        .on_click(move |event, window, cx| {
            cx.stop_propagation();
            on_sidebar_menu_action(action_id, event, window, cx);
        })
}

fn status_badge(label: &'static str) -> Div {
    div()
        .px_1()
        .py_1()
        .rounded_md()
        .bg(PANEL_BORDER)
        .text_xs()
        .text_color(TEXT_MUTED)
        .child(label)
}
