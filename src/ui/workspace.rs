use crate::{
    app::{TerminalTab, TerminalTabId, TerminalTabKind},
    ui::theme::{ACCENT, APP_BG, PANEL_BG, PANEL_BORDER},
};
use gpui::{App, ClickEvent, IntoElement, ParentElement, Styled, Window, div, prelude::*};
use gpui_component::{
    Sizable,
    button::Button,
    tab::{Tab, TabBar},
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
    let selected_index = tabs.iter().position(|tab| Some(tab.id) == active_tab);

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
        .child(
            TabBar::new("workspace-tabs")
                .segmented()
                .small()
                .when_some(selected_index, |tab_bar, index| {
                    tab_bar.selected_index(index)
                })
                .children(tabs.iter().map(move |tab| {
                    let tab_id = tab.id;
                    let label = tab.name.clone();
                    let kind = tab.kind;
                    let on_select_tab = on_select_tab.clone();

                    Tab::new()
                        .label(format!("{}{}", tab_kind_prefix(kind), label))
                        .on_click(move |event, window, cx| {
                            on_select_tab(tab_id, event, window, cx);
                        })
                })),
        )
        .child(
            Button::new("workspace-new-tab")
                .small()
                .outline()
                .compact()
                .label("+")
                .text_color(ACCENT)
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
