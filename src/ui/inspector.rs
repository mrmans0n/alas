use crate::{app::SelectedWorktree, git::GitInspectorState};

use gpui::{
    FontWeight, IntoElement, ParentElement, SharedString, Styled, div, prelude::*, px, rgb,
};

pub fn render_git_inspector(
    selected_worktree: Option<&SelectedWorktree>,
    state: Option<&GitInspectorState>,
    error: Option<&str>,
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
                .child("Git Inspector"),
        )
        .when(selected_worktree.is_none(), |element| {
            element.child(
                div()
                    .text_sm()
                    .text_color(rgb(0x6b7280))
                    .child("Select a worktree to inspect its Git state."),
            )
        })
        .when(selected_worktree.is_some(), |element| {
            let selected_worktree = selected_worktree.unwrap();
            element
                .child(
                    div()
                        .text_xs()
                        .text_color(rgb(0x6b7280))
                        .child(SharedString::from(
                            selected_worktree.path.display().to_string(),
                        )),
                )
                .when(error.is_some(), |element| {
                    element.child(
                        div()
                            .px_2()
                            .py_2()
                            .rounded_md()
                            .bg(rgb(0xfef3c7))
                            .text_sm()
                            .text_color(rgb(0x92400e))
                            .child(SharedString::from(format!(
                                "Git inspector refresh failed: {}",
                                error.unwrap_or_default()
                            ))),
                    )
                })
                .when(state.is_none() && error.is_none(), |element| {
                    element.child(
                        div()
                            .text_sm()
                            .text_color(rgb(0x6b7280))
                            .child("Loading Git details…"),
                    )
                })
                .when(state.is_some(), |element| {
                    let state = state.unwrap();
                    element
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
                        .child(section_header("Recent Commits"))
                        .when(state.recent_commits.is_empty(), |element| {
                            element.child(empty_text("No recent commits."))
                        })
                        .children(state.recent_commits.iter().map(|commit| {
                            div()
                                .flex()
                                .flex_col()
                                .gap_1()
                                .text_sm()
                                .child(
                                    div()
                                        .text_color(rgb(0x4b5563))
                                        .font_weight(FontWeight::SEMIBOLD)
                                        .child(SharedString::from(commit.hash.clone())),
                                )
                                .child(SharedString::from(commit.summary.clone()))
                        }))
                })
        })
}

fn section_header(title: &'static str) -> impl IntoElement {
    div()
        .pt_2()
        .text_sm()
        .font_weight(FontWeight::SEMIBOLD)
        .child(title)
}

fn empty_text(text: &'static str) -> impl IntoElement {
    div().text_sm().text_color(rgb(0x6b7280)).child(text)
}
