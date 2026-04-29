use crate::{
    app::{TerminalTab, TerminalTabId, TerminalTabKind},
    ui::theme::{ACCENT, APP_BG, PANEL_BG, PANEL_BORDER, TEXT, TEXT_MUTED},
};
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
        .border_color(PANEL_BORDER)
        .bg(PANEL_BG)
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
                .border_color(if is_active { ACCENT } else { PANEL_BORDER })
                .bg(if is_active { rgb(0x22313b) } else { PANEL_BG })
                .text_sm()
                .text_color(if is_active { TEXT } else { TEXT_MUTED })
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
                .border_color(PANEL_BORDER)
                .bg(PANEL_BG)
                .text_sm()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .text_color(ACCENT)
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
