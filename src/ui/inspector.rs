use gpui::{FontWeight, IntoElement, ParentElement, Styled, div, px, rgb};

pub fn render_inspector_placeholder() -> impl IntoElement {
    div()
        .flex()
        .flex_col()
        .flex_shrink_0()
        .size_full()
        .w(px(320.0))
        .p_4()
        .border_l_1()
        .border_color(rgb(0xd8dee9))
        .bg(rgb(0xf9fafb))
        .child(
            div()
                .text_lg()
                .font_weight(FontWeight::BOLD)
                .child("Git Inspector"),
        )
}
