use crate::{
    app::{TerminalTab, TerminalTabId, TerminalTabKind},
    ui::theme::{ACCENT, OVERLAY_BG, OVERLAY_BORDER, TERMINAL_BG},
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
    show_tabs: bool,
    on_tabs_hover: impl Fn(&bool, &mut Window, &mut App) + 'static,
    on_select_tab: impl Fn(TerminalTabId, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_new_tab: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    terminal_body: impl IntoElement,
) -> impl IntoElement {
    div()
        .id("workspace")
        .relative()
        .flex()
        .flex_col()
        .flex_1()
        .size_full()
        .overflow_hidden()
        .bg(TERMINAL_BG)
        .on_hover(on_tabs_hover)
        .child(
            div()
                .absolute()
                .top_0()
                .right_0()
                .bottom_0()
                .left_0()
                .child(terminal_body),
        )
        .when(show_tabs, |element| {
            element.child(render_tab_bar_overlay(
                tabs,
                active_tab,
                on_select_tab,
                on_new_tab,
            ))
        })
}

fn render_tab_bar_overlay(
    tabs: &[TerminalTab],
    active_tab: Option<TerminalTabId>,
    on_select_tab: impl Fn(TerminalTabId, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_new_tab: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
) -> impl IntoElement {
    let selected_index = tabs.iter().position(|tab| Some(tab.id) == active_tab);

    div()
        .id("workspace-tab-overlay")
        .absolute()
        .top_2()
        .left_0()
        .right_0()
        .flex()
        .justify_center()
        .child(
            div()
                .flex()
                .items_center()
                .gap_1()
                .px_2()
                .py_1()
                .rounded_full()
                .border_1()
                .border_color(OVERLAY_BORDER)
                .bg(OVERLAY_BG)
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
                ),
        )
}

fn tab_kind_prefix(kind: TerminalTabKind) -> &'static str {
    match kind {
        TerminalTabKind::Shell => "",
        TerminalTabKind::Command => "› ",
        TerminalTabKind::Agent => "⚙ ",
    }
}
