use crate::app::{TerminalTab, TerminalTabId, TerminalTabKind};
use gpui::{
    App, ClickEvent, IntoElement, ParentElement, SharedString, Styled, Window, div, prelude::*, rgb,
};

pub fn render_workspace(
    tabs: &[TerminalTab],
    active_tab: Option<TerminalTabId>,
    on_select_tab: impl Fn(TerminalTabId, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_new_tab: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    terminal_body: impl IntoElement,
) -> impl IntoElement {
    div()
        .id("workspace")
        .flex()
        .flex_col()
        .flex_1()
        .size_full()
        .p_3()
        .bg(rgb(0xf3f4f6))
        .child(
            div()
                .flex()
                .flex_col()
                .flex_1()
                .overflow_hidden()
                .rounded_md()
                .border_1()
                .border_color(rgb(0xd1d5db))
                .bg(rgb(0xffffff))
                .child(render_tab_bar(tabs, active_tab, on_select_tab, on_new_tab))
                .child(div().flex().flex_1().overflow_hidden().child(terminal_body)),
        )
}

fn render_tab_bar(
    tabs: &[TerminalTab],
    active_tab: Option<TerminalTabId>,
    on_select_tab: impl Fn(TerminalTabId, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
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
        .border_color(rgb(0xe5e7eb))
        .bg(rgb(0xf9fafb))
        .children(tabs.iter().map(move |tab| {
            let tab_id = tab.id;
            let is_active = Some(tab_id) == active_tab;
            let label = tab.name.clone();
            let kind = tab.kind;
            let on_select_tab = on_select_tab.clone();

            div()
                .id(SharedString::from(format!("workspace-tab-{}", tab_id.0)))
                .px_3()
                .py_1()
                .rounded_md()
                .border_1()
                .border_color(if is_active {
                    rgb(0x93c5fd)
                } else {
                    rgb(0xe5e7eb)
                })
                .bg(if is_active {
                    rgb(0xdbeafe)
                } else {
                    rgb(0xffffff)
                })
                .text_sm()
                .text_color(if is_active {
                    rgb(0x1d4ed8)
                } else {
                    rgb(0x374151)
                })
                .font_weight(if is_active {
                    gpui::FontWeight::SEMIBOLD
                } else {
                    gpui::FontWeight::NORMAL
                })
                .child(format!("{}{}", tab_kind_prefix(kind), label))
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
                .border_color(rgb(0xd1d5db))
                .bg(rgb(0xffffff))
                .text_sm()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .text_color(rgb(0x2563eb))
                .child("+")
                .on_click(on_new_tab),
        )
}

fn tab_kind_prefix(kind: TerminalTabKind) -> &'static str {
    match kind {
        TerminalTabKind::Shell => "",
        TerminalTabKind::Command => "› ",
        TerminalTabKind::Agent => "⚙ ",
    }
}
