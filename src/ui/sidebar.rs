use std::path::PathBuf;

use crate::{
    app::{
        ActionAvailability, ActionDefinition, ActionId, ActionRegistry, ActionScope,
        RepositoryNode, SelectedWorktree, WorktreeNode,
    },
    git::WorktreeKind,
    ui::{
        chrome::render_mac_titlebar_safe_area_spacer,
        theme::{DANGER, PANEL_BG, PANEL_BORDER, SIDEBAR_BG, TEXT, TEXT_MUTED},
        view_models::{RepoTreeRow, TreeExpansionState, build_repo_tree_rows},
    },
};
use gpui::{
    App, ClickEvent, FontWeight, IntoElement, ParentElement, SharedString, Styled, Window, div,
    prelude::*, px,
};
use gpui_component::{
    Icon, IconName, Sizable,
    button::{Button, ButtonVariants},
    list::ListItem,
    menu::{ContextMenuExt, DropdownMenu as _, PopupMenu, PopupMenuItem},
    tag::Tag,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SidebarMenuState {
    pub repo_id: String,
    pub worktree_path: Option<PathBuf>,
    pub scope: ActionScope,
}

#[allow(clippy::too_many_arguments)]
pub fn render_sidebar(
    repositories: &[RepositoryNode],
    selected_worktree: Option<&SelectedWorktree>,
    expansion: &TreeExpansionState,
    on_toggle_repository: impl Fn(String, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_add_repository: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    on_select_worktree: impl Fn(String, PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_sidebar_menu_action: impl Fn(SidebarMenuState, ActionId, &ClickEvent, &mut Window, &mut App)
    + Clone
    + 'static,
    add_repository_error: Option<&str>,
) -> impl IntoElement {
    let rows = build_repo_tree_rows(repositories, selected_worktree, expansion);

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
        .child(render_mac_titlebar_safe_area_spacer())
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
        .children(rows.into_iter().map(|row| match row {
            RepoTreeRow::Repository {
                id,
                name,
                unavailable,
                expanded,
            } => {
                let repository = repositories
                    .iter()
                    .find(|r| r.id == id)
                    .cloned()
                    .expect("repository row must have a matching repository");
                let menu_state = SidebarMenuState {
                    repo_id: id.clone(),
                    worktree_path: None,
                    scope: ActionScope::Repository,
                };
                render_repository_row(
                    id,
                    name,
                    unavailable,
                    expanded,
                    repository,
                    menu_state,
                    on_toggle_repository.clone(),
                    on_sidebar_menu_action.clone(),
                )
                .into_any_element()
            }
            RepoTreeRow::Worktree {
                repo_id,
                path,
                label,
                selected,
                archived,
                kind,
            } => {
                let repository = repositories
                    .iter()
                    .find(|r| r.id == repo_id)
                    .cloned()
                    .expect("worktree row must have a matching repository");
                let worktree = repository
                    .worktrees
                    .iter()
                    .find(|w| w.path == path)
                    .cloned()
                    .expect("worktree row must have a matching worktree");
                let menu_state = SidebarMenuState {
                    repo_id: repo_id.clone(),
                    worktree_path: Some(path.clone()),
                    scope: ActionScope::Worktree,
                };
                render_worktree_row(
                    repo_id,
                    path,
                    label,
                    selected,
                    archived,
                    kind,
                    repository,
                    worktree,
                    menu_state,
                    on_select_worktree.clone(),
                    on_sidebar_menu_action.clone(),
                )
                .into_any_element()
            }
        }))
        .child(
            div()
                .mt_auto()
                .flex()
                .flex_col()
                .gap_2()
                .child(
                    Button::new("add-repository")
                        .ghost()
                        .compact()
                        .icon(IconName::Plus)
                        .tooltip("Add repository")
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

#[allow(clippy::too_many_arguments)]
fn render_repository_row(
    repo_id: String,
    name: String,
    unavailable: bool,
    expanded: bool,
    repository: RepositoryNode,
    menu_state: SidebarMenuState,
    on_toggle_repository: impl Fn(String, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_sidebar_menu_action: impl Fn(SidebarMenuState, ActionId, &ClickEvent, &mut Window, &mut App)
    + Clone
    + 'static,
) -> impl IntoElement {
    let repo_id_for_click = repo_id.clone();
    let on_toggle = move |event: &ClickEvent, window: &mut Window, cx: &mut App| {
        if event.is_right_click() {
            return;
        }
        on_toggle_repository(repo_id_for_click.clone(), event, window, cx);
    };

    let repo_id_for_button = repo_id.clone();
    let repository_for_suffix = repository.clone();
    let menu_state_for_suffix = menu_state.clone();
    let on_action_for_suffix = on_sidebar_menu_action.clone();

    let repository_for_context = repository.clone();
    let menu_state_for_context = menu_state.clone();
    let on_action_for_context = on_sidebar_menu_action.clone();

    ListItem::new(SharedString::from(format!("repo-row-{repo_id}")))
        .on_click(on_toggle)
        .child(
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(
                    Icon::new(if expanded {
                        IconName::ChevronDown
                    } else {
                        IconName::ChevronRight
                    })
                    .small(),
                )
                .child(
                    div()
                        .font_weight(FontWeight::SEMIBOLD)
                        .truncate()
                        .child(name),
                )
                .when(unavailable, |el| el.child(status_badge("Unavailable"))),
        )
        .suffix(move |_window: &mut Window, _cx: &mut App| {
            let repository = repository_for_suffix.clone();
            let menu_state = menu_state_for_suffix.clone();
            let on_sidebar_menu_action = on_action_for_suffix.clone();
            Button::new(SharedString::from(format!(
                "repository-actions-{repo_id_for_button}"
            )))
            .ghost()
            .compact()
            .icon(IconName::Ellipsis)
            .on_click(|_event, _window, cx| {
                cx.stop_propagation();
            })
            .dropdown_menu(move |menu, _window, _cx| {
                build_sidebar_popup_menu(
                    menu,
                    repository.clone(),
                    None,
                    menu_state.clone(),
                    on_sidebar_menu_action.clone(),
                )
            })
            .into_any_element()
        })
        .context_menu(move |menu, _window, _cx| {
            build_sidebar_popup_menu(
                menu,
                repository_for_context.clone(),
                None,
                menu_state_for_context.clone(),
                on_action_for_context.clone(),
            )
        })
}

#[allow(clippy::too_many_arguments)]
fn render_worktree_row(
    repo_id: String,
    path: PathBuf,
    label: String,
    selected: bool,
    archived: bool,
    kind: WorktreeKind,
    repository: RepositoryNode,
    worktree: WorktreeNode,
    menu_state: SidebarMenuState,
    on_select_worktree: impl Fn(String, PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_sidebar_menu_action: impl Fn(SidebarMenuState, ActionId, &ClickEvent, &mut Window, &mut App)
    + Clone
    + 'static,
) -> impl IntoElement {
    let repo_id_for_click = repo_id.clone();
    let path_for_click = path.clone();
    let on_click = move |event: &ClickEvent, window: &mut Window, cx: &mut App| {
        if event.is_right_click() {
            return;
        }
        on_select_worktree(
            repo_id_for_click.clone(),
            path_for_click.clone(),
            event,
            window,
            cx,
        );
    };

    let is_main = kind == WorktreeKind::Main;

    let repo_id_for_button = repo_id.clone();
    let path_for_button = path.clone();
    let repository_for_suffix = repository.clone();
    let worktree_for_suffix = worktree.clone();
    let menu_state_for_suffix = menu_state.clone();
    let on_action_for_suffix = on_sidebar_menu_action.clone();

    let repository_for_context = repository.clone();
    let worktree_for_context = worktree.clone();
    let menu_state_for_context = menu_state.clone();
    let on_action_for_context = on_sidebar_menu_action.clone();

    ListItem::new(SharedString::from(format!(
        "worktree-row-{repo_id}-{}",
        path.display()
    )))
    .selected(selected)
    .on_click(on_click)
    .child(
        div()
            .flex()
            .items_center()
            .gap_2()
            .pl_4()
            .child(div().truncate().child(label))
            .when(archived, |el| el.child(status_badge("Archived")))
            .child(status_badge(if is_main { "Main" } else { "Linked" })),
    )
    .suffix(move |_window: &mut Window, _cx: &mut App| {
        let repository = repository_for_suffix.clone();
        let worktree = worktree_for_suffix.clone();
        let menu_state = menu_state_for_suffix.clone();
        let on_sidebar_menu_action = on_action_for_suffix.clone();
        Button::new(SharedString::from(format!(
            "worktree-actions-{repo_id_for_button}-{}",
            path_for_button.display()
        )))
        .ghost()
        .compact()
        .icon(IconName::Ellipsis)
        .on_click(|_event, _window, cx| {
            cx.stop_propagation();
        })
        .dropdown_menu(move |menu, _window, _cx| {
            build_sidebar_popup_menu(
                menu,
                repository.clone(),
                Some(worktree.clone()),
                menu_state.clone(),
                on_sidebar_menu_action.clone(),
            )
        })
        .into_any_element()
    })
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
        let _destructive = action.destructive;
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
