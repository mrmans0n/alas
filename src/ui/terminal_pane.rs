use crate::{
    app::{SelectedWorktree, TerminalTab},
    terminal::TerminalGridSnapshot,
    ui::{
        terminal_view::{
            CELL_HEIGHT_PX, TERMINAL_FONT_FAMILY, TERMINAL_FONT_SIZE_PX,
            render_terminal_bounds_probe, render_terminal_grid,
        },
        theme::{ACCENT, ACCENT_TEXT, DANGER, PANEL_BG, PANEL_BORDER, TEXT, TEXT_MUTED},
    },
};
use gpui::{
    AnyElement, App, Bounds, ClickEvent, IntoElement, ParentElement, Pixels, ScrollWheelEvent,
    SharedString, Styled, Window, div, prelude::*,
};

pub fn render_terminal_pane(
    selected_worktree: Option<&SelectedWorktree>,
    active_tab: Option<&TerminalTab>,
    snapshot: Option<&TerminalGridSnapshot>,
    terminal_error: Option<&str>,
    on_retry: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    on_edit_command: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    on_restart: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    on_focus: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    on_scroll: impl Fn(&ScrollWheelEvent, &mut Window, &mut App) + 'static,
    on_body_bounds: impl Fn(Bounds<Pixels>, &mut App) + 'static,
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
            element
                .items_center()
                .justify_center()
                .child(render_terminal_failure(
                    selected_worktree,
                    active_tab,
                    terminal_error.unwrap_or_default(),
                    on_retry,
                    on_edit_command,
                ))
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
                                                    .text_color(ACCENT_TEXT)
                                                    .bg(ACCENT)
                                                    .child("Restart")
                                                    .on_click(on_restart),
                                            ),
                                    )
                                },
                            ),
                    )
                    .when(
                        snapshot.is_some_and(|snapshot| snapshot.exited()),
                        |element| {
                            element.child(
                                div()
                                    .px_3()
                                    .py_2()
                                    .rounded_md()
                                    .border_1()
                                    .border_color(PANEL_BORDER)
                                    .bg(PANEL_BG)
                                    .text_xs()
                                    .text_color(TEXT_MUTED)
                                    .child("Process exited; final screen is preserved."),
                            )
                        },
                    )
                    .child(
                        div()
                            .flex_1()
                            .overflow_hidden()
                            .relative()
                            .child(render_terminal_body(snapshot))
                            .child(
                                div()
                                    .absolute()
                                    .size_full()
                                    .child(render_terminal_bounds_probe(on_body_bounds)),
                            ),
                    )
            },
        )
}

fn render_terminal_failure(
    selected_worktree: Option<&SelectedWorktree>,
    active_tab: Option<&TerminalTab>,
    terminal_error: &str,
    on_retry: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    on_edit_command: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
) -> impl IntoElement {
    let command = active_tab
        .map(|tab| tab.command.display.clone())
        .unwrap_or_else(|| "unknown command".to_string());
    let cwd = active_tab
        .map(|tab| tab.command.cwd.display().to_string())
        .or_else(|| selected_worktree.map(|worktree| worktree.path.display().to_string()))
        .unwrap_or_else(|| "unknown cwd".to_string());

    div()
        .flex()
        .flex_col()
        .gap_3()
        .max_w(gpui::px(760.0))
        .p_4()
        .rounded_lg()
        .border_1()
        .border_color(PANEL_BORDER)
        .bg(PANEL_BG)
        .child(
            div()
                .text_sm()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .text_color(DANGER)
                .child("Terminal startup or I/O failed"),
        )
        .child(detail_row("Command", command))
        .child(detail_row("Cwd", cwd))
        .child(detail_row("Cause", terminal_error.to_string()))
        .child(
            div()
                .flex()
                .gap_2()
                .child(
                    div()
                        .id("retry-terminal")
                        .px_3()
                        .py_2()
                        .rounded_md()
                        .text_sm()
                        .font_weight(gpui::FontWeight::SEMIBOLD)
                        .text_color(ACCENT_TEXT)
                        .bg(ACCENT)
                        .child("Retry")
                        .on_click(on_retry),
                )
                .child(
                    div()
                        .id("edit-terminal-command")
                        .px_3()
                        .py_2()
                        .rounded_md()
                        .border_1()
                        .border_color(PANEL_BORDER)
                        .text_sm()
                        .font_weight(gpui::FontWeight::SEMIBOLD)
                        .text_color(TEXT)
                        .bg(PANEL_BG)
                        .child("Edit Command")
                        .on_click(on_edit_command),
                ),
        )
}

fn detail_row(label: &'static str, value: String) -> impl IntoElement {
    div()
        .flex()
        .flex_col()
        .gap_1()
        .child(
            div()
                .text_xs()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .text_color(TEXT_MUTED)
                .child(label),
        )
        .child(
            div()
                .text_sm()
                .text_color(TEXT)
                .font_family("monospace")
                .child(SharedString::from(value)),
        )
}

fn render_terminal_body(snapshot: Option<&TerminalGridSnapshot>) -> AnyElement {
    match snapshot {
        Some(snapshot) => render_terminal_grid(snapshot).into_any_element(),
        None => div()
            .font_family(TERMINAL_FONT_FAMILY)
            .text_size(gpui::px(TERMINAL_FONT_SIZE_PX))
            .line_height(gpui::px(CELL_HEIGHT_PX))
            .child(" ")
            .into_any_element(),
    }
}
