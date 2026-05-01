use crate::{
    app::FileTabLoadState,
    ui::theme::{DANGER, PANEL_BG, TEXT, TEXT_MUTED},
};
use gpui::{AnyElement, IntoElement, SharedString, Styled, div, prelude::*};

pub fn render_file_pane(load_state: &FileTabLoadState) -> impl IntoElement {
    div()
        .id("file-pane")
        .flex()
        .flex_1()
        .size_full()
        .bg(PANEL_BG)
        .text_color(TEXT)
        .items_center()
        .justify_center()
        .child(render_file_content(load_state))
}

fn render_file_content(load_state: &FileTabLoadState) -> AnyElement {
    match load_state {
        FileTabLoadState::Loading => div()
            .text_sm()
            .text_color(TEXT_MUTED)
            .child("Loading file…")
            .into_any_element(),
        FileTabLoadState::Loaded { content, .. } => div()
            .id("file-pane-content")
            .flex()
            .flex_1()
            .size_full()
            .overflow_scroll()
            .p_3()
            .child(
                div()
                    .text_sm()
                    .font_family("monospace")
                    .child(SharedString::from(content.clone())),
            )
            .into_any_element(),
        FileTabLoadState::Error { message } => div()
            .text_sm()
            .text_color(DANGER)
            .child(format!("Failed to load file: {message}"))
            .into_any_element(),
    }
}
