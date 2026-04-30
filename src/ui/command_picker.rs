use crate::config::CommandEntry;
use gpui::{
    App, ClickEvent, IntoElement, ParentElement, SharedString, Styled, Window, div, prelude::*, rgb,
};
use gpui_component::{
    Sizable,
    button::{Button, ButtonVariants},
};
use indexmap::IndexMap;

pub fn render_command_picker(
    commands: &IndexMap<String, CommandEntry>,
    on_select: impl Fn(String, String, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_cancel: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
) -> impl IntoElement {
    div()
        .id("command-picker")
        .m_3()
        .p_3()
        .rounded_md()
        .border_1()
        .border_color(rgb(0xbfdbfe))
        .bg(rgb(0xeff6ff))
        .flex()
        .flex_col()
        .gap_2()
        .child(
            div()
                .flex()
                .items_center()
                .justify_between()
                .child(
                    div()
                        .text_sm()
                        .font_weight(gpui::FontWeight::SEMIBOLD)
                        .text_color(rgb(0x1f2937))
                        .child("New Terminal Tab"),
                )
                .child(
                    Button::new("cancel-command-picker")
                        .xsmall()
                        .ghost()
                        .label("Cancel")
                        .text_color(rgb(0x374151))
                        .on_click(on_cancel),
                ),
        )
        .child(
            div()
                .text_xs()
                .text_color(rgb(0x4b5563))
                .child("Choose a configured command to launch in a named tab."),
        )
        .children(commands.iter().map(move |(name, entry)| {
            let name = name.clone();
            let command = entry.command.clone();
            let on_select = on_select.clone();

            div()
                .id(SharedString::from(format!("command-picker-entry-{name}")))
                .flex()
                .flex_col()
                .gap_1()
                .p_2()
                .rounded_md()
                .border_1()
                .border_color(rgb(0xdbeafe))
                .bg(rgb(0xffffff))
                .child(
                    div()
                        .text_sm()
                        .font_weight(gpui::FontWeight::SEMIBOLD)
                        .text_color(rgb(0x1d4ed8))
                        .child(name.clone()),
                )
                .child(
                    div()
                        .text_xs()
                        .text_color(rgb(0x4b5563))
                        .child(command.clone()),
                )
                .on_click(move |event, window, cx| {
                    on_select(name.clone(), command.clone(), event, window, cx);
                })
        }))
}
