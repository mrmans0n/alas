use crate::{
    app::{FileTabLoadState, FileTabState},
    ui::theme::{DANGER, PANEL_BG, PANEL_BORDER, TEXT, TEXT_MUTED},
};
use gpui::{AnyElement, IntoElement, ParentElement, SharedString, Styled, div, prelude::*, px};

pub fn render_source_viewer(file: &FileTabState) -> AnyElement {
    div()
        .id("source-viewer")
        .flex()
        .flex_col()
        .flex_1()
        .size_full()
        .overflow_hidden()
        .bg(PANEL_BG)
        .when(
            matches!(&file.load_state, FileTabLoadState::Error { .. }),
            |element| {
                let FileTabLoadState::Error { message } = &file.load_state else {
                    return element;
                };
                element.child(
                    div()
                        .m_3()
                        .p_3()
                        .rounded_md()
                        .border_1()
                        .border_color(PANEL_BORDER)
                        .text_sm()
                        .text_color(DANGER)
                        .child(SharedString::from(message.clone())),
                )
            },
        )
        .when(
            matches!(file.load_state, FileTabLoadState::Loaded { .. }),
            |element| {
                let FileTabLoadState::Loaded { content } = &file.load_state else {
                    return element;
                };
                element
                    .child(
                        div()
                            .px_3()
                            .py_2()
                            .border_b_1()
                            .border_color(PANEL_BORDER)
                            .text_xs()
                            .text_color(TEXT_MUTED)
                            .child(SharedString::from(file.file_path.display().to_string())),
                    )
                    .child(render_source_lines(content))
            },
        )
        .when(
            matches!(file.load_state, FileTabLoadState::Loading),
            |element| {
                element.child(
                    div()
                        .p_3()
                        .text_sm()
                        .text_color(TEXT_MUTED)
                        .child("Loading file..."),
                )
            },
        )
        .into_any_element()
}

fn render_source_lines(content: &str) -> impl IntoElement {
    div()
        .id("source-viewer-lines")
        .flex()
        .flex_col()
        .flex_1()
        .min_h(px(0.0))
        .overflow_scroll()
        .p_3()
        .gap_0()
        .children(content.lines().enumerate().map(|(index, line)| {
            div()
                .flex()
                .items_start()
                .font_family("monospace")
                .text_sm()
                .line_height(px(20.0))
                .child(
                    div()
                        .w(px(48.0))
                        .flex_shrink_0()
                        .pr_3()
                        .text_color(TEXT_MUTED)
                        .child(format!("{}", index + 1)),
                )
                .child(
                    div()
                        .flex_1()
                        .text_color(TEXT)
                        .child(SharedString::from(line.to_string())),
                )
        }))
}
