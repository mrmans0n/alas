use crate::{app::SelectedWorktree, terminal::TerminalSessionRef};
use gpui::{IntoElement, ParentElement, Styled, div, prelude::*, rgb};

pub fn render_terminal_placeholder(
    selected_worktree: Option<&SelectedWorktree>,
    active_terminal: Option<&TerminalSessionRef>,
    terminal_error: Option<&str>,
) -> impl IntoElement {
    div()
        .flex()
        .flex_1()
        .size_full()
        .items_center()
        .justify_center()
        .bg(rgb(0x111827))
        .text_color(rgb(0xe5e7eb))
        .child(
            div()
                .flex()
                .flex_col()
                .gap_2()
                .max_w(gpui::px(720.0))
                .when(selected_worktree.is_none(), |element| {
                    element.child("Select a worktree to start a terminal session")
                })
                .when(selected_worktree.is_some(), |element| {
                    let selected = selected_worktree.expect("checked selected worktree");
                    element
                        .child(format!("Worktree: {}", selected.path.display()))
                        .when(active_terminal.is_some(), |element| {
                            let session = active_terminal.expect("checked active terminal");
                            element
                                .child(format!("Command: {}", session.command.display))
                                .child(format!(
                                    "Program: {} {}",
                                    session.command.program,
                                    session.command.args.join(" ")
                                ))
                                .child(format!("Session handle: {}", session.handle.0))
                                .child(format!(
                                    "Backend session: {}",
                                    session.backend_session.backend_id
                                ))
                        })
                        .when(terminal_error.is_some(), |element| {
                            element
                                .child(format!(
                                    "Terminal failed to start: {}",
                                    terminal_error.unwrap_or_default()
                                ))
                                .child("Select the worktree again to retry.")
                        })
                }),
        )
}
