use crate::{
    app::{SelectedWorktree, TerminalTab},
    terminal::{GhosttyRenderFrame, TerminalMetrics, TerminalStatus},
    ui::{
        terminal_canvas::render_terminal_canvas,
        terminal_view::{
            CELL_HEIGHT_PX, TERMINAL_FONT_FAMILY, TERMINAL_FONT_SIZE_PX,
            render_terminal_bounds_probe,
        },
        theme::{DANGER, PANEL_BG, PANEL_BORDER, TERMINAL_BG, TEXT, TEXT_MUTED},
    },
};
use gpui::{
    AnyElement, App, Bounds, ClickEvent, IntoElement, MouseDownEvent, MouseMoveEvent, MouseUpEvent,
    ParentElement, Pixels, ScrollWheelEvent, SharedString, Styled, Window, div, prelude::*,
};
use gpui_component::{
    Sizable,
    button::{Button, ButtonVariants},
};

#[allow(clippy::too_many_arguments)]
pub fn render_terminal_pane(
    selected_worktree: Option<&SelectedWorktree>,
    active_tab: Option<&TerminalTab>,
    terminal_frame: Option<GhosttyRenderFrame>,
    terminal_status: Option<TerminalStatus>,
    terminal_metrics: TerminalMetrics,
    terminal_error: Option<&str>,
    on_retry: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    on_edit_command: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    on_restart: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    on_focus: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    on_scroll: impl Fn(&ScrollWheelEvent, &mut Window, &mut App) + 'static,
    on_mouse_down: impl Fn(&MouseDownEvent, &mut Window, &mut App) + 'static,
    on_mouse_up: impl Fn(&MouseUpEvent, &mut Window, &mut App) + 'static,
    on_mouse_move: impl Fn(&MouseMoveEvent, &mut Window, &mut App) + 'static,
    on_body_bounds: impl Fn(Bounds<Pixels>, &mut App) + 'static,
) -> impl IntoElement {
    div()
        .id("terminal-pane")
        .flex()
        .flex_1()
        .size_full()
        .bg(TERMINAL_BG)
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
                element.flex_col().child(
                    div()
                        .flex_1()
                        .overflow_hidden()
                        .relative()
                        .on_any_mouse_down(on_mouse_down)
                        .capture_any_mouse_up(on_mouse_up)
                        .on_mouse_move(on_mouse_move)
                        .child(render_terminal_body(terminal_frame, terminal_metrics))
                        .child(
                            div()
                                .absolute()
                                .size_full()
                                .child(render_terminal_bounds_probe(on_body_bounds)),
                        )
                        .when(terminal_exited(terminal_status), |element| {
                            let status = terminal_exit_status(terminal_status)
                                .map(|status| status.to_string())
                                .unwrap_or_else(|| "unknown".to_string());
                            element.child(
                                div()
                                    .absolute()
                                    .bottom_0()
                                    .left_0()
                                    .right_0()
                                    .flex()
                                    .flex_col()
                                    .px_3()
                                    .py_2()
                                    .bg(PANEL_BG)
                                    .border_t_1()
                                    .border_color(PANEL_BORDER)
                                    .text_xs()
                                    .text_color(TEXT_MUTED)
                                    .child(
                                        div()
                                            .flex()
                                            .items_center()
                                            .justify_between()
                                            .child(format!("Exited: {status}"))
                                            .child(
                                                Button::new("restart-terminal")
                                                    .small()
                                                    .primary()
                                                    .compact()
                                                    .label("Restart")
                                                    .on_click(on_restart),
                                            ),
                                    )
                                    .child(
                                        div().child("Process exited; final screen is preserved."),
                                    ),
                            )
                        }),
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
                    Button::new("retry-terminal")
                        .primary()
                        .label("Retry")
                        .on_click(on_retry),
                )
                .child(
                    Button::new("edit-terminal-command")
                        .outline()
                        .label("Edit Command")
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

fn terminal_exited(status: Option<TerminalStatus>) -> bool {
    matches!(status, Some(TerminalStatus::Exited(_)))
}

fn terminal_exit_status(status: Option<TerminalStatus>) -> Option<i32> {
    match status {
        Some(TerminalStatus::Exited(status)) => status,
        Some(TerminalStatus::Running | TerminalStatus::Failed) | None => None,
    }
}

fn render_terminal_body(
    terminal_frame: Option<GhosttyRenderFrame>,
    terminal_metrics: TerminalMetrics,
) -> AnyElement {
    match terminal_frame {
        Some(frame) => render_terminal_canvas(frame, terminal_metrics).into_any_element(),
        None => div()
            .font_family(TERMINAL_FONT_FAMILY)
            .text_size(gpui::px(TERMINAL_FONT_SIZE_PX))
            .line_height(gpui::px(CELL_HEIGHT_PX))
            .child(" ")
            .into_any_element(),
    }
}
