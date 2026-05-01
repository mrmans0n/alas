use crate::{
    app::{FileTabLoadState, MarkdownTabState, MarkdownViewMode, WorkspaceTabId},
    ui::{
        markdown_preview::{MarkdownBlock, parse_markdown_blocks},
        source_viewer::render_source_viewer,
        theme::{ACCENT, ACCENT_TEXT, PANEL_BG, PANEL_BORDER, TEXT, TEXT_MUTED},
    },
};
use gpui::{
    AnyElement, App, ClickEvent, IntoElement, ParentElement, SharedString, Styled, Window, div,
    prelude::*, px,
};

pub fn render_markdown_pane(
    tab_id: WorkspaceTabId,
    tab: &MarkdownTabState,
    on_set_mode: impl Fn(WorkspaceTabId, MarkdownViewMode, &ClickEvent, &mut Window, &mut App)
    + Clone
    + 'static,
) -> AnyElement {
    div()
        .id("markdown-pane")
        .flex()
        .flex_col()
        .flex_1()
        .size_full()
        .overflow_hidden()
        .bg(PANEL_BG)
        .child(render_mode_controls(tab_id, tab.view_mode, on_set_mode))
        .child(match (&tab.file.load_state, tab.view_mode) {
            (FileTabLoadState::Loading, _)
            | (FileTabLoadState::Error { .. }, _)
            | (FileTabLoadState::Loaded { .. }, MarkdownViewMode::Code) => {
                render_source_viewer(&tab.file)
            }
            (FileTabLoadState::Loaded { content, .. }, MarkdownViewMode::Preview) => {
                render_preview(content)
            }
            (FileTabLoadState::Loaded { content, .. }, MarkdownViewMode::Split) => div()
                .flex()
                .flex_1()
                .min_h(px(0.0))
                .overflow_hidden()
                .child(
                    div()
                        .flex()
                        .flex_1()
                        .min_w(px(0.0))
                        .border_r_1()
                        .border_color(PANEL_BORDER)
                        .child(render_source_viewer(&tab.file)),
                )
                .child(
                    div()
                        .flex()
                        .flex_1()
                        .min_w(px(0.0))
                        .child(render_preview(content)),
                )
                .into_any_element(),
        })
        .into_any_element()
}

fn render_mode_controls(
    tab_id: WorkspaceTabId,
    active_mode: MarkdownViewMode,
    on_set_mode: impl Fn(WorkspaceTabId, MarkdownViewMode, &ClickEvent, &mut Window, &mut App)
    + Clone
    + 'static,
) -> impl IntoElement {
    div()
        .flex()
        .items_center()
        .justify_between()
        .px_3()
        .py_2()
        .border_b_1()
        .border_color(PANEL_BORDER)
        .child(
            div()
                .text_xs()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .text_color(TEXT_MUTED)
                .child("Markdown"),
        )
        .child(
            div()
                .flex()
                .items_center()
                .gap_1()
                .p_1()
                .rounded_md()
                .bg(PANEL_BORDER)
                .child(render_mode_button(
                    tab_id,
                    "markdown-mode-code",
                    "Code",
                    MarkdownViewMode::Code,
                    active_mode,
                    on_set_mode.clone(),
                ))
                .child(render_mode_button(
                    tab_id,
                    "markdown-mode-preview",
                    "Preview",
                    MarkdownViewMode::Preview,
                    active_mode,
                    on_set_mode.clone(),
                ))
                .child(render_mode_button(
                    tab_id,
                    "markdown-mode-split",
                    "Split",
                    MarkdownViewMode::Split,
                    active_mode,
                    on_set_mode,
                )),
        )
}

fn render_mode_button(
    tab_id: WorkspaceTabId,
    id: &'static str,
    label: &'static str,
    mode: MarkdownViewMode,
    active_mode: MarkdownViewMode,
    on_set_mode: impl Fn(WorkspaceTabId, MarkdownViewMode, &ClickEvent, &mut Window, &mut App)
    + Clone
    + 'static,
) -> impl IntoElement {
    let is_active = mode == active_mode;
    div()
        .id(id)
        .px_3()
        .py_1()
        .rounded_md()
        .text_sm()
        .font_weight(if is_active {
            gpui::FontWeight::SEMIBOLD
        } else {
            gpui::FontWeight::NORMAL
        })
        .text_color(if is_active { ACCENT_TEXT } else { TEXT_MUTED })
        .bg(if is_active { ACCENT } else { PANEL_BORDER })
        .child(label)
        .on_click(move |event, window, cx| {
            on_set_mode(tab_id, mode, event, window, cx);
        })
}

fn render_preview(markdown: &str) -> AnyElement {
    div()
        .id("markdown-preview")
        .flex()
        .flex_col()
        .flex_1()
        .min_h(px(0.0))
        .overflow_scroll()
        .p_4()
        .gap_2()
        .children(
            parse_markdown_blocks(markdown)
                .into_iter()
                .map(render_block),
        )
        .into_any_element()
}

fn render_block(block: MarkdownBlock) -> AnyElement {
    match block {
        MarkdownBlock::Heading { level, text } => div()
            .pt(if level <= 2 { px(8.0) } else { px(4.0) })
            .text_size(px(match level {
                1 => 24.0,
                2 => 20.0,
                3 => 18.0,
                _ => 16.0,
            }))
            .font_weight(gpui::FontWeight::BOLD)
            .text_color(TEXT)
            .child(SharedString::from(text))
            .into_any_element(),
        MarkdownBlock::Paragraph(text) => div()
            .text_sm()
            .line_height(px(22.0))
            .text_color(TEXT)
            .child(SharedString::from(text))
            .into_any_element(),
        MarkdownBlock::ListItem(text) => div()
            .flex()
            .gap_2()
            .text_sm()
            .line_height(px(22.0))
            .text_color(TEXT)
            .child(div().text_color(TEXT_MUTED).child("•"))
            .child(SharedString::from(text))
            .into_any_element(),
        MarkdownBlock::BlockQuote(text) => div()
            .pl_3()
            .border_l_1()
            .border_color(PANEL_BORDER)
            .text_sm()
            .line_height(px(22.0))
            .text_color(TEXT_MUTED)
            .child(SharedString::from(text))
            .into_any_element(),
        MarkdownBlock::CodeBlock { language, code } => div()
            .flex()
            .flex_col()
            .gap_1()
            .p_3()
            .rounded_md()
            .border_1()
            .border_color(PANEL_BORDER)
            .font_family("monospace")
            .text_sm()
            .text_color(TEXT)
            .when(language.is_some(), |element| {
                element.child(
                    div()
                        .text_xs()
                        .text_color(TEXT_MUTED)
                        .child(SharedString::from(language.unwrap_or_default())),
                )
            })
            .child(SharedString::from(code))
            .into_any_element(),
        MarkdownBlock::Rule => div().h(px(1.0)).my_2().bg(PANEL_BORDER).into_any_element(),
    }
}
