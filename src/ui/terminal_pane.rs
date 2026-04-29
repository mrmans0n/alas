use crate::{
    app::SelectedWorktree,
    terminal::TerminalGridSnapshot,
    ui::{
        terminal_view::render_terminal_grid,
        theme::{ACCENT, PANEL_BG, PANEL_BORDER, TEXT, TEXT_MUTED},
    },
};
use gpui::{
    AnyElement, App, ClickEvent, IntoElement, ParentElement, ScrollWheelEvent, Styled, Window, div,
    prelude::*, rgb,
};

pub fn render_terminal_pane(
    selected_worktree: Option<&SelectedWorktree>,
    snapshot: Option<&TerminalGridSnapshot>,
    terminal_error: Option<&str>,
    on_retry: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    on_restart: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    on_focus: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    on_scroll: impl Fn(&ScrollWheelEvent, &mut Window, &mut App) + 'static,
) -> impl IntoElement {
    div()
        .id("terminal-pane")
        .flex()
        .flex_1()
        .size_full()
        .bg(PANEL_BG)
        .text_color(TEXT)
        .on_click(on_focus)
        .on_scroll_wheel(on_scroll)
        .when(selected_worktree.is_none(), |element| {
            element.items_center().justify_center().child(
                div()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child("Select a worktree to start a terminal session"),
            )
        })
        .when(terminal_error.is_some(), |element| {
            element.items_center().justify_center().child(
                div()
                    .flex()
                    .flex_col()
                    .gap_3()
                    .max_w(gpui::px(720.0))
                    .child(format!(
                        "Terminal failed: {}",
                        terminal_error.unwrap_or_default()
                    ))
                    .child(
                        div()
                            .id("retry-terminal")
                            .px_3()
                            .py_2()
                            .rounded_md()
                            .text_sm()
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .text_color(rgb(0xffffff))
                            .bg(ACCENT)
                            .child("Retry")
                            .on_click(on_retry),
                    ),
            )
        })
        .when(
            selected_worktree.is_some() && terminal_error.is_none(),
            |element| {
                element
                    .flex_col()
                    .p_3()
                    .gap_2()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .justify_between()
                            .text_xs()
                            .text_color(TEXT_MUTED)
                            .child(format!(
                                "Worktree: {}",
                                selected_worktree
                                    .expect("checked selected worktree")
                                    .path
                                    .display()
                            ))
                            .when(
                                snapshot.is_some_and(|snapshot| snapshot.exited()),
                                |element| {
                                    let status = snapshot
                                        .and_then(|snapshot| snapshot.exit_status())
                                        .map(|status| status.to_string())
                                        .unwrap_or_else(|| "unknown".to_string());
                                    element.child(
                                        div()
                                            .flex()
                                            .items_center()
                                            .gap_2()
                                            .child(format!("Exited: {status}"))
                                            .child(
                                                div()
                                                    .id("restart-terminal")
                                                    .px_2()
                                                    .py_1()
                                                    .rounded_md()
                                                    .font_weight(gpui::FontWeight::SEMIBOLD)
                                                    .text_color(rgb(0xffffff))
                                                    .bg(ACCENT)
                                                    .child("Restart")
                                                    .on_click(on_restart),
                                            ),
                                    )
                                },
                            ),
                    )
                    .when(snapshot.is_some_and(|snapshot| snapshot.exited()), |element| {
                        element.child(
                            div()
                                .p_3()
                                .rounded_md()
                                .border_1()
                                .border_color(PANEL_BORDER)
                                .bg(PANEL_BG)
                                .text_sm()
                                .text_color(TEXT_MUTED)
                                .child("Terminal process exited. Restart to run the configured command again."),
                        )
                    })
                    .child(
                        div()
                            .flex_1()
                            .overflow_hidden()
                            .child(render_terminal_body(snapshot)),
                    )
            },
        )
}

fn render_terminal_body(snapshot: Option<&TerminalGridSnapshot>) -> AnyElement {
    match snapshot {
        Some(snapshot) => render_terminal_grid(snapshot).into_any_element(),
        None => div()
            .font_family("monospace")
            .text_sm()
            .line_height(gpui::px(18.0))
            .child(" ")
            .into_any_element(),
    }
}
