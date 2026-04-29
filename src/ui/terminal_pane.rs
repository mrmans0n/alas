use gpui::{IntoElement, ParentElement, Styled, div, rgb};

pub fn render_terminal_placeholder() -> impl IntoElement {
    div()
        .flex()
        .flex_1()
        .size_full()
        .items_center()
        .justify_center()
        .bg(rgb(0x111827))
        .text_color(rgb(0xe5e7eb))
        .child("Terminal will render here")
}
