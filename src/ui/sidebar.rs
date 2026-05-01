use std::path::PathBuf;

use crate::{
    app::{
        ActionAvailability, ActionDefinition, ActionId, ActionRegistry, ActionScope,
        RepositoryNode, SelectedWorktree, WorktreeNode,
    },
    git::WorktreeKind,
    ui::{
        chrome::render_mac_titlebar_safe_area_spacer,
        theme::{
            ACTIVE_TAB_BG, DANGER, PANEL_BG, PANEL_BORDER, TEXT, TEXT_MUTED, sidebar_background,
        },
        view_models::{RepoSection, RepoWorktreeRow, build_repo_sections},
    },
};
use gpui::{
    App, ClickEvent, FontWeight, IntoElement, ParentElement, SharedString, Styled, Window, div,
    prelude::*, px,
};
use gpui_component::{
    Sizable,
    button::{Button, ButtonVariants},
    menu::{ContextMenuExt, DropdownMenu as _, PopupMenu, PopupMenuItem},
    tag::Tag,
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
    on_add_repository: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    on_notification_preferences: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    on_select_worktree: impl Fn(String, PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_sidebar_menu_action: impl Fn(SidebarMenuState, ActionId, &ClickEvent, &mut Window, &mut App)
    + Clone
    + 'static,
    add_repository_error: Option<&str>,
) -> impl IntoElement {
    let sections = build_repo_sections(repositories, selected_worktree);

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
        .bg(sidebar_background())
        .text_color(TEXT)
        .child(render_mac_titlebar_safe_area_spacer())
        .child(
            div()
                .flex()
                .items_center()
                .justify_between()
                .child(
                    div()
                        .text_base()
                        .font_weight(FontWeight::BOLD)
                        .child("Repositories"),
                )
                .child(
                    Button::new("add-repository")
                        .ghost()
                        .compact()
                        .label("+")
                        .tooltip("Add repository")
                        .on_click(on_add_repository),
                ),
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
        .child(
            div()
                .flex()
                .flex_col()
                .gap_3()
                .children(sections.into_iter().map(|section| {
                    let repository = repositories
                        .iter()
                        .find(|repository| repository.id == section.id)
                        .cloned()
                        .expect("repository section must have a matching repository");
                    render_repository_section(
                        section,
                        repository,
                        on_select_worktree.clone(),
                        on_sidebar_menu_action.clone(),
                    )
                })),
        )
        .child(
            Button::new("notification-preferences")
                .ghost()
                .compact()
                .mt_auto()
                .label("Notifications")
                .on_click(on_notification_preferences),
        )
        .when(add_repository_error.is_some(), |element| {
            element.child(
                div()
                    .text_sm()
                    .text_color(DANGER)
                    .child(add_repository_error.unwrap_or_default().to_string()),
            )
        })
}

fn render_repository_section(
    section: RepoSection,
    repository: RepositoryNode,
    on_select_worktree: impl Fn(String, PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_sidebar_menu_action: impl Fn(SidebarMenuState, ActionId, &ClickEvent, &mut Window, &mut App)
    + Clone
    + 'static,
) -> impl IntoElement {
    let repo_id = section.id.clone();
    let menu_state = SidebarMenuState {
        repo_id: repo_id.clone(),
        worktree_path: None,
        scope: ActionScope::Repository,
    };

    let repository_for_header_menu = repository.clone();
    let menu_state_for_header_menu = menu_state.clone();
    let on_action_for_header_menu = on_sidebar_menu_action.clone();

    let repository_for_context = repository.clone();
    let menu_state_for_context = menu_state.clone();
    let on_action_for_context = on_sidebar_menu_action.clone();

    div()
        .id(SharedString::from(format!("repo-section-{repo_id}")))
        .flex()
        .flex_col()
        .gap_1()
        .child(
            div()
                .id(SharedString::from(format!("repo-section-header-{repo_id}")))
                .flex()
                .items_center()
                .justify_between()
                .gap_2()
                .w_full()
                .px_2()
                .py_1()
                .rounded_md()
                .child(
                    div()
                        .flex()
                        .items_center()
                        .justify_start()
                        .min_w(px(0.0))
                        .flex_1()
                        .child(
                            div()
                                .truncate()
                                .text_sm()
                                .font_weight(FontWeight::SEMIBOLD)
                                .child(section.name),
                        )
                        .when(section.unavailable, |el| {
                            el.child(status_badge("Unavailable"))
                        }),
                )
                .child(sidebar_menu_button(
                    format!("repository-actions-{repo_id}"),
                    repository_for_header_menu,
                    None,
                    menu_state_for_header_menu,
                    on_action_for_header_menu,
                ))
                .context_menu(move |menu, _window, _cx| {
                    build_sidebar_popup_menu(
                        menu,
                        repository_for_context.clone(),
                        None,
                        menu_state_for_context.clone(),
                        on_action_for_context.clone(),
                    )
                }),
        )
        .child(
            div()
                .flex()
                .flex_col()
                .gap_1()
                .children(section.worktrees.into_iter().map(move |worktree| {
                    let worktree_node = repository
                        .worktrees
                        .iter()
                        .find(|candidate| candidate.path == worktree.path)
                        .cloned()
                        .expect("worktree row must have a matching worktree");
                    let menu_state = SidebarMenuState {
                        repo_id: worktree.repo_id.clone(),
                        worktree_path: Some(worktree.path.clone()),
                        scope: ActionScope::Worktree,
                    };
                    render_worktree_row(
                        worktree,
                        repository.clone(),
                        worktree_node,
                        menu_state,
                        on_select_worktree.clone(),
                        on_sidebar_menu_action.clone(),
                    )
                })),
        )
}

fn render_worktree_row(
    worktree: RepoWorktreeRow,
    repository: RepositoryNode,
    worktree_node: WorktreeNode,
    menu_state: SidebarMenuState,
    on_select_worktree: impl Fn(String, PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_sidebar_menu_action: impl Fn(SidebarMenuState, ActionId, &ClickEvent, &mut Window, &mut App)
    + Clone
    + 'static,
) -> impl IntoElement {
    let repo_id = worktree.repo_id.clone();
    let path = worktree.path.clone();
    let on_click = move |event: &ClickEvent, window: &mut Window, cx: &mut App| {
        if event.is_right_click() {
            return;
        }
        on_select_worktree(repo_id.clone(), path.clone(), event, window, cx);
    };

    let row_id = format!(
        "worktree-row-{}-{}",
        worktree.repo_id,
        worktree.path.display()
    );
    let is_main = worktree.kind == WorktreeKind::Main;

    let repository_for_menu = repository.clone();
    let worktree_for_menu = worktree_node.clone();
    let menu_state_for_menu = menu_state.clone();
    let on_action_for_menu = on_sidebar_menu_action.clone();

    let repository_for_context = repository.clone();
    let worktree_for_context = worktree_node.clone();
    let menu_state_for_context = menu_state.clone();
    let on_action_for_context = on_sidebar_menu_action.clone();

    div()
        .id(SharedString::from(row_id))
        .flex()
        .items_center()
        .justify_between()
        .gap_2()
        .w_full()
        .ml_2()
        .px_2()
        .py_1()
        .rounded_md()
        .when(worktree.selected, |element| element.bg(ACTIVE_TAB_BG))
        .on_click(on_click)
        .child(
            div()
                .flex()
                .items_center()
                .gap_2()
                .min_w(px(0.0))
                .flex_1()
                .child(div().truncate().text_sm().child(worktree.label))
                .when(worktree.archived, |el| el.child(status_badge("Archived")))
                .child(status_badge(if is_main { "Main" } else { "Linked" })),
        )
        .child(sidebar_menu_button(
            format!(
                "worktree-actions-{}-{}",
                worktree.repo_id,
                worktree.path.display()
            ),
            repository_for_menu,
            Some(worktree_for_menu),
            menu_state_for_menu,
            on_action_for_menu,
        ))
        .context_menu(move |menu, _window, _cx| {
            build_sidebar_popup_menu(
                menu,
                repository_for_context.clone(),
                Some(worktree_for_context.clone()),
                menu_state_for_context.clone(),
                on_action_for_context.clone(),
            )
        })
}

fn sidebar_menu_button(
    id: String,
    repository: RepositoryNode,
    worktree: Option<WorktreeNode>,
    menu_state: SidebarMenuState,
    on_sidebar_menu_action: impl Fn(SidebarMenuState, ActionId, &ClickEvent, &mut Window, &mut App)
    + Clone
    + 'static,
) -> impl IntoElement {
    Button::new(SharedString::from(id))
        .ghost()
        .compact()
        .label("⋯")
        .tooltip("Actions")
        .on_click(|_event, _window, cx| {
            cx.stop_propagation();
        })
        .dropdown_menu(move |menu, _window, _cx| {
            build_sidebar_popup_menu(
                menu,
                repository.clone(),
                worktree.clone(),
                menu_state.clone(),
                on_sidebar_menu_action.clone(),
            )
        })
}

fn build_sidebar_popup_menu(
    mut menu: PopupMenu,
    repository: RepositoryNode,
    worktree: Option<WorktreeNode>,
    menu_state: SidebarMenuState,
    on_sidebar_menu_action: impl Fn(SidebarMenuState, ActionId, &ClickEvent, &mut Window, &mut App)
    + Clone
    + 'static,
) -> PopupMenu {
    let registry = ActionRegistry::default();
    let scope = if worktree.is_some() {
        ActionScope::Worktree
    } else {
        ActionScope::Repository
    };

    for action in registry
        .actions()
        .iter()
        .filter(|action| action.scope == scope)
        .filter(|action| action_is_available(action, &repository, worktree.as_ref()))
    {
        let action_id = action.id;
        let label = sidebar_action_label(action, &repository);
        let menu_state = menu_state.clone();
        let on_sidebar_menu_action = on_sidebar_menu_action.clone();

        menu = menu.item(
            PopupMenuItem::new(label).on_click(move |event, window, cx| {
                on_sidebar_menu_action(menu_state.clone(), action_id, event, window, cx);
            }),
        );
    }

    menu
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

fn status_badge(label: &'static str) -> impl IntoElement {
    Tag::secondary().small().child(label)
}
