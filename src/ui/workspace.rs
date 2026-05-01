use crate::{
    app::{TerminalTabKind, WorkspaceTab, WorkspaceTabId, WorkspaceTabKind},
    ui::theme::{ACCENT, ACTIVE_TAB_BG, APP_BG, PANEL_BG, PANEL_BORDER, TEXT, TEXT_MUTED},
};
use gpui::{
    App, ClickEvent, IntoElement, ParentElement, SharedString, Styled, Window, div, prelude::*,
};

pub fn render_workspace(
    tabs: &[WorkspaceTab],
    active_tab: Option<WorkspaceTabId>,
    on_select_tab: impl Fn(WorkspaceTabId, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_close_tab: impl Fn(WorkspaceTabId, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_new_tab: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    body: impl IntoElement,
) -> impl IntoElement {
    div()
        .id("workspace")
        .flex()
        .flex_col()
        .flex_1()
        .size_full()
        .p_3()
        .bg(APP_BG)
        .child(
            div()
                .flex()
                .flex_col()
                .flex_1()
                .overflow_hidden()
                .rounded_lg()
                .border_1()
                .border_color(PANEL_BORDER)
                .bg(PANEL_BG)
                .child(render_tab_bar(
                    tabs,
                    active_tab,
                    on_select_tab,
                    on_close_tab,
                    on_new_tab,
                ))
                .child(div().flex().flex_1().overflow_hidden().child(body)),
        )
}

fn render_tab_bar(
    tabs: &[WorkspaceTab],
    active_tab: Option<WorkspaceTabId>,
    on_select_tab: impl Fn(WorkspaceTabId, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_close_tab: impl Fn(WorkspaceTabId, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_new_tab: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
) -> impl IntoElement {
    div()
        .id("workspace-tab-bar")
        .flex()
        .items_center()
        .gap_1()
        .px_2()
        .py_2()
        .border_b_1()
        .border_color(PANEL_BORDER)
        .bg(PANEL_BG)
        .children(tabs.iter().map(move |tab| {
            let tab_id = tab.id;
            let is_active = Some(tab_id) == active_tab;
            let label = tab_label(tab);
            let on_select_tab = on_select_tab.clone();
            let on_close_tab = on_close_tab.clone();

            div()
                .id(SharedString::from(format!("workspace-tab-{}", tab_id.0)))
                .flex()
                .items_center()
                .gap_2()
                .px_3()
                .py_1()
                .rounded_md()
                .border_1()
                .border_color(if is_active { ACCENT } else { PANEL_BORDER })
                .bg(if is_active { ACTIVE_TAB_BG } else { PANEL_BG })
                .text_sm()
                .text_color(if is_active { TEXT } else { TEXT_MUTED })
                .font_weight(if is_active {
                    gpui::FontWeight::SEMIBOLD
                } else {
                    gpui::FontWeight::NORMAL
                })
                .child(label)
                .child(
                    div()
                        .id(SharedString::from(format!(
                            "workspace-tab-close-{}",
                            tab_id.0
                        )))
                        .px_1()
                        .text_xs()
                        .text_color(TEXT_MUTED)
                        .child("×")
                        .on_click(move |event, window, cx| {
                            cx.stop_propagation();
                            on_close_tab(tab_id, event, window, cx);
                        }),
                )
                .on_click(move |event, window, cx| {
                    on_select_tab(tab_id, event, window, cx);
                })
        }))
        .child(
            div()
                .id("workspace-new-tab")
                .px_3()
                .py_1()
                .rounded_md()
                .border_1()
                .border_color(PANEL_BORDER)
                .bg(PANEL_BG)
                .text_sm()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .text_color(ACCENT)
                .child("+")
                .on_click(on_new_tab),
        )
}

fn tab_label(tab: &WorkspaceTab) -> String {
    match tab.kind {
        WorkspaceTabKind::Terminal(kind) => match kind {
            TerminalTabKind::Shell => tab.name.clone(),
            TerminalTabKind::Command => format!("› {}", tab.name),
            TerminalTabKind::Agent => format!("⚙ {}", tab.name),
        },
        WorkspaceTabKind::File => tab.name.clone(),
        WorkspaceTabKind::Image => format!("▧ {}", tab.name),
    }
}
