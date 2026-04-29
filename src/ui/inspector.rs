use crate::{
    app::{InspectorPaneState, InspectorTab, SelectedWorktree},
    git::GitInspectorState,
    project::FileTreeNode,
};

use gpui::{
    AnyElement, App, ClickEvent, FontWeight, IntoElement, ParentElement, SharedString, Styled,
    Window, div, prelude::*, px, rgb,
};

pub fn render_project_inspector(
    selected_worktree: Option<&SelectedWorktree>,
    state: &InspectorPaneState,
    on_select_tab: impl Fn(InspectorTab, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
) -> impl IntoElement {
    div()
        .flex()
        .flex_col()
        .flex_shrink_0()
        .size_full()
        .w(px(320.0))
        .p_4()
        .gap_3()
        .border_l_1()
        .border_color(rgb(0xd8dee9))
        .bg(rgb(0xf9fafb))
        .child(
            div()
                .text_lg()
                .font_weight(FontWeight::BOLD)
                .child("Inspector"),
        )
        .child(render_tab_bar(state.selected_tab, on_select_tab))
        .when(selected_worktree.is_none(), |element| {
            element.child(
                div()
                    .text_sm()
                    .text_color(rgb(0x6b7280))
                    .child("Select a worktree to inspect its files and changes."),
            )
        })
        .when(selected_worktree.is_some(), |element| {
            let selected_worktree = selected_worktree.expect("checked selected worktree");
            element
                .child(
                    div()
                        .text_xs()
                        .text_color(rgb(0x6b7280))
                        .child(SharedString::from(
                            selected_worktree.path.display().to_string(),
                        )),
                )
                .child(match state.selected_tab {
                    InspectorTab::Files => render_files_tab(state),
                    InspectorTab::Changes => render_changes_tab(state),
                })
        })
}

fn render_tab_bar(
    selected_tab: InspectorTab,
    on_select_tab: impl Fn(InspectorTab, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
) -> impl IntoElement {
    div()
        .flex()
        .items_center()
        .gap_1()
        .p_1()
        .rounded_md()
        .bg(rgb(0xe5e7eb))
        .child(render_tab_button(
            "inspector-tab-files",
            "Files",
            InspectorTab::Files,
            selected_tab,
            on_select_tab.clone(),
        ))
        .child(render_tab_button(
            "inspector-tab-changes",
            "Changes",
            InspectorTab::Changes,
            selected_tab,
            on_select_tab,
        ))
}

fn render_tab_button(
    id: &'static str,
    label: &'static str,
    tab: InspectorTab,
    selected_tab: InspectorTab,
    on_select_tab: impl Fn(InspectorTab, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
) -> impl IntoElement {
    let is_active = tab == selected_tab;

    div()
        .id(id)
        .flex_1()
        .px_3()
        .py_1()
        .rounded_md()
        .text_sm()
        .font_weight(if is_active {
            FontWeight::SEMIBOLD
        } else {
            FontWeight::NORMAL
        })
        .text_color(if is_active {
            rgb(0xe5e7eb)
        } else {
            rgb(0x374151)
        })
        .bg(if is_active {
            rgb(0x111827)
        } else {
            rgb(0xe5e7eb)
        })
        .child(label)
        .on_click(move |event, window, cx| {
            on_select_tab(tab, event, window, cx);
        })
}

fn render_files_tab(state: &InspectorPaneState) -> AnyElement {
    div()
        .flex()
        .flex_col()
        .gap_2()
        .overflow_hidden()
        .when(state.files_error.is_some(), |element| {
            element.child(warning_text(
                "Files tree load failed",
                state.files_error.as_deref().unwrap_or_default(),
            ))
        })
        .when(
            state.files.is_none() && state.files_error.is_none(),
            |element| element.child(loading_text("Loading file tree…")),
        )
        .when(state.files.is_some(), |element| {
            let root = state.files.as_ref().expect("checked files state");
            element
                .when(root.children.is_empty(), |element| {
                    element.child(empty_text("No files found."))
                })
                .when(!root.children.is_empty(), |element| {
                    element.child(render_file_node(root, 0))
                })
        })
        .into_any_element()
}

fn render_file_node(node: &FileTreeNode, depth: usize) -> impl IntoElement {
    div()
        .flex()
        .flex_col()
        .gap_1()
        .child(div().pl(px((depth * 12) as f32)).text_sm().child(format!(
            "{} {}",
            if node.is_dir { "▸" } else { "☰" },
            node.name
        )))
        .children(
            node.children
                .iter()
                .map(move |child| render_file_node(child, depth + 1)),
        )
        .when(node.truncated, |element| {
            element.child(
                div()
                    .pl(px(((depth + 1) * 12) as f32))
                    .text_xs()
                    .text_color(rgb(0x6b7280))
                    .child("… additional entries hidden"),
            )
        })
}

fn render_changes_tab(state: &InspectorPaneState) -> AnyElement {
    div()
        .flex()
        .flex_col()
        .gap_2()
        .when(state.changes_error.is_some(), |element| {
            element.child(warning_text(
                "Git changes refresh failed",
                state.changes_error.as_deref().unwrap_or_default(),
            ))
        })
        .when(
            state.changes.is_none() && state.changes_error.is_none(),
            |element| element.child(loading_text("Loading Git changes…")),
        )
        .when(state.changes.is_some(), |element| {
            let changes = state.changes.as_ref().expect("checked changes state");
            element.child(render_changes(changes))
        })
        .into_any_element()
}

fn render_changes(state: &GitInspectorState) -> impl IntoElement {
    div()
        .flex()
        .flex_col()
        .gap_2()
        .child(section_header("Branch"))
        .child(
            div().text_sm().child(SharedString::from(
                state
                    .branch
                    .as_deref()
                    .unwrap_or("Detached HEAD")
                    .to_string(),
            )),
        )
        .child(section_header("Changed Files"))
        .when(state.changed_files.is_empty(), |element| {
            element.child(empty_text("No changed files."))
        })
        .children(state.changed_files.iter().map(|file| {
            div()
                .flex()
                .gap_2()
                .text_sm()
                .child(
                    div()
                        .w(px(32.0))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(rgb(0x4b5563))
                        .child(SharedString::from(file.status.clone())),
                )
                .child(SharedString::from(file.path.clone()))
        }))
}

fn section_header(title: &'static str) -> impl IntoElement {
    div()
        .pt_2()
        .text_sm()
        .font_weight(FontWeight::SEMIBOLD)
        .child(title)
}

fn loading_text(text: &'static str) -> impl IntoElement {
    div().text_sm().text_color(rgb(0x6b7280)).child(text)
}

fn empty_text(text: &'static str) -> impl IntoElement {
    div().text_sm().text_color(rgb(0x6b7280)).child(text)
}

fn warning_text(title: &'static str, error: &str) -> impl IntoElement {
    div()
        .px_2()
        .py_2()
        .rounded_md()
        .bg(rgb(0xfef3c7))
        .text_sm()
        .text_color(rgb(0x92400e))
        .child(SharedString::from(format!("{title}: {error}")))
}
