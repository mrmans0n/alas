use std::path::PathBuf;

use crate::{
    app::{InspectorPaneState, SelectedWorktree},
    ui::theme::{DANGER, PANEL_BG, PANEL_BORDER, TEXT, TEXT_MUTED, sidebar_background},
    ui::view_models::{InspectorTreeRow, TreeExpansionState, build_inspector_tree_rows},
};

use gpui::{
    AnyElement, App, ClickEvent, FontWeight, IntoElement, ParentElement, SharedString, Styled,
    Window, div, prelude::*, px,
};
use gpui_component::{Icon, IconName, Sizable, list::ListItem};

pub fn render_project_inspector(
    selected_worktree: Option<&SelectedWorktree>,
    state: &InspectorPaneState,
    file_expansion: &TreeExpansionState,
    on_toggle_file: impl Fn(PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_open_file: impl Fn(PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
) -> impl IntoElement {
    let rows = build_inspector_tree_rows(selected_worktree, state, file_expansion);

    div()
        .id("project-inspector")
        .flex()
        .flex_col()
        .flex_shrink_0()
        .size_full()
        .w(px(320.0))
        .px_4()
        .py_3()
        .gap_2()
        .border_l_1()
        .border_color(PANEL_BORDER)
        .bg(sidebar_background())
        .text_color(TEXT)
        .child(render_inspector_rows(rows, on_toggle_file, on_open_file))
}

fn render_inspector_rows(
    rows: Vec<InspectorTreeRow>,
    on_toggle_file: impl Fn(PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_open_file: impl Fn(PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
) -> impl IntoElement {
    div()
        .id("grouped-inspector-tree")
        .flex()
        .flex_col()
        .flex_1()
        .min_h(px(0.0))
        .overflow_scroll()
        .gap_1()
        .children(rows.into_iter().map(move |row| {
            render_inspector_row(row, on_toggle_file.clone(), on_open_file.clone())
        }))
}

fn render_inspector_row(
    row: InspectorTreeRow,
    on_toggle_file: impl Fn(PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_open_file: impl Fn(PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
) -> AnyElement {
    match row {
        InspectorTreeRow::EmptyState => {
            empty_text_owned("Select a worktree to inspect its files and changes.".to_string())
                .into_any_element()
        }
        InspectorTreeRow::Context {
            branch_label,
            changed_count,
        } => {
            let count = changed_count
                .map(|count| format!(" · {count} changed"))
                .unwrap_or_default();
            div()
                .px_1()
                .pb_2()
                .text_xs()
                .text_color(TEXT_MUTED)
                .child(SharedString::from(format!("{branch_label}{count}")))
                .into_any_element()
        }
        InspectorTreeRow::Section { title } => section_header(title).into_any_element(),
        InspectorTreeRow::Loading { section } => {
            loading_text_owned(format!("Loading {section}…")).into_any_element()
        }
        InspectorTreeRow::Error { section, message } => {
            warning_text(section, &message).into_any_element()
        }
        InspectorTreeRow::ChangedFile { status, path } => {
            changed_file_row(status, path).into_any_element()
        }
        InspectorTreeRow::Clean { path } => empty_text_owned(path).into_any_element(),
        InspectorTreeRow::File {
            depth,
            name,
            path,
            is_dir,
            expanded,
        } => file_row(
            depth,
            name,
            path,
            is_dir,
            expanded,
            on_toggle_file,
            on_open_file,
        )
        .into_any_element(),
        InspectorTreeRow::Truncated { depth } => truncated_row(depth).into_any_element(),
    }
}

fn section_header(title: impl Into<String>) -> impl IntoElement {
    div()
        .pt_2()
        .text_sm()
        .font_weight(FontWeight::SEMIBOLD)
        .child(SharedString::from(title.into()))
}

fn loading_text_owned(text: String) -> impl IntoElement {
    div().text_sm().text_color(TEXT_MUTED).child(text)
}

fn empty_text_owned(text: String) -> impl IntoElement {
    div().text_sm().text_color(TEXT_MUTED).child(text)
}

fn changed_file_row(status: String, path: String) -> impl IntoElement {
    div()
        .flex()
        .gap_2()
        .text_sm()
        .child(
            div()
                .w(px(32.0))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(TEXT_MUTED)
                .child(SharedString::from(status)),
        )
        .child(div().truncate().child(SharedString::from(path)))
}

fn file_row(
    depth: usize,
    name: String,
    path: PathBuf,
    is_dir: bool,
    expanded: bool,
    on_toggle_file: impl Fn(PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_open_file: impl Fn(PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
) -> impl IntoElement {
    let row_id = SharedString::from(format!("inspector-file-row-{}", path.display()));
    let row = ListItem::new(row_id).child(
        div()
            .flex()
            .items_center()
            .gap_2()
            .text_sm()
            .pl(px((depth * 12) as f32))
            .child(
                Icon::new(if is_dir {
                    if expanded {
                        IconName::FolderOpen
                    } else {
                        IconName::FolderClosed
                    }
                } else {
                    IconName::File
                })
                .small(),
            )
            .child(div().truncate().child(name)),
    );

    if is_dir {
        row.on_click(move |event, window, cx| {
            on_toggle_file(path.clone(), event, window, cx);
        })
    } else {
        row.on_click(move |event, window, cx| {
            on_open_file(path.clone(), event, window, cx);
        })
    }
}

fn truncated_row(depth: usize) -> impl IntoElement {
    div()
        .pl(px(((depth + 1) * 12) as f32))
        .text_xs()
        .text_color(TEXT_MUTED)
        .child("… additional entries hidden")
}

fn warning_text(title: &'static str, error: &str) -> impl IntoElement {
    div()
        .px_2()
        .py_2()
        .rounded_md()
        .bg(PANEL_BG)
        .border_1()
        .border_color(PANEL_BORDER)
        .text_sm()
        .text_color(DANGER)
        .child(SharedString::from(format!("{title}: {error}")))
}
