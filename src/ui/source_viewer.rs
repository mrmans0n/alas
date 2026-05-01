use crate::{
    app::{FileTabLoadState, FileTabState, HighlightedLine, SourceTokenStyle},
    ui::{
        terminal_view::{CELL_HEIGHT_PX, TERMINAL_FONT_FAMILY, TERMINAL_FONT_SIZE_PX},
        theme::{DANGER, PANEL_BG, PANEL_BORDER, TEXT, TEXT_MUTED},
    },
};
use gpui::{
    AnyElement, IntoElement, ParentElement, Rgba, SharedString, Styled, div, prelude::*, px, rgb,
};

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
                let FileTabLoadState::Loaded {
                    content,
                    size_bytes,
                    line_count,
                    highlight,
                    highlight_error,
                } = &file.load_state
                else {
                    return element;
                };
                element
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .justify_between()
                            .gap_3()
                            .px_3()
                            .py_2()
                            .border_b_1()
                            .border_color(PANEL_BORDER)
                            .text_xs()
                            .text_color(TEXT_MUTED)
                            .child(
                                div().truncate().child(SharedString::from(
                                    file.file_path.display().to_string(),
                                )),
                            )
                            .child(SharedString::from(format!(
                                "{} • {} lines • {}",
                                file.language.label(),
                                line_count,
                                format_bytes(*size_bytes)
                            ))),
                    )
                    .when(highlight_error.is_some(), |element| {
                        element.child(
                            div()
                                .px_3()
                                .py_1()
                                .border_b_1()
                                .border_color(PANEL_BORDER)
                                .text_xs()
                                .text_color(TEXT_MUTED)
                                .child(SharedString::from(
                                    highlight_error.clone().unwrap_or_default(),
                                )),
                        )
                    })
                    .child(render_source_lines(
                        content,
                        *line_count,
                        highlight.as_ref(),
                    ))
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

fn render_source_lines(
    content: &str,
    line_count: usize,
    highlighted: Option<&crate::app::HighlightedSource>,
) -> impl IntoElement {
    let gutter_width = ((line_count.max(1).ilog10() + 1) as f32 * 9.0 + 24.0).max(48.0);
    let plain_lines: Vec<&str> = content.lines().collect();
    let visual_line_count = line_count.max(plain_lines.len()).max(1);

    div()
        .id("source-viewer-lines")
        .flex()
        .flex_col()
        .flex_1()
        .min_h(px(0.0))
        .overflow_scroll()
        .p_3()
        .gap_0()
        .font_family(TERMINAL_FONT_FAMILY)
        .text_size(px(TERMINAL_FONT_SIZE_PX))
        .line_height(px(CELL_HEIGHT_PX))
        .children((0..visual_line_count).map(move |index| {
            let plain_line = plain_lines.get(index).copied().unwrap_or_default();
            let highlighted_line = highlighted.and_then(|source| source.lines.get(index));
            render_source_line(index, gutter_width, plain_line, highlighted_line)
        }))
}

fn render_source_line(
    index: usize,
    gutter_width: f32,
    plain_line: &str,
    highlighted_line: Option<&HighlightedLine>,
) -> impl IntoElement {
    div()
        .flex()
        .items_start()
        .min_w(px(0.0))
        .h(px(CELL_HEIGHT_PX))
        .whitespace_nowrap()
        .child(
            div()
                .w(px(gutter_width))
                .flex_shrink_0()
                .pr_3()
                .text_color(TEXT_MUTED)
                .child(format!("{}", index + 1)),
        )
        .child(
            div()
                .flex()
                .min_w(px(0.0))
                .text_color(TEXT)
                .children(render_code_spans(plain_line, highlighted_line)),
        )
}

fn render_code_spans(
    plain_line: &str,
    highlighted_line: Option<&HighlightedLine>,
) -> Vec<AnyElement> {
    if let Some(line) = highlighted_line
        && !line.spans.is_empty()
    {
        return line
            .spans
            .iter()
            .map(|span| {
                div()
                    .text_color(token_color(span.style))
                    .child(SharedString::from(span.text.clone()))
                    .into_any_element()
            })
            .collect();
    }

    vec![
        div()
            .text_color(TEXT)
            .child(SharedString::from(plain_line.to_string()))
            .into_any_element(),
    ]
}

fn token_color(style: SourceTokenStyle) -> Rgba {
    match style {
        SourceTokenStyle::Plain => TEXT,
        SourceTokenStyle::Keyword => rgb(0xff7ab2),
        SourceTokenStyle::String => rgb(0xa6da95),
        SourceTokenStyle::Number | SourceTokenStyle::Constant => rgb(0xf5a97f),
        SourceTokenStyle::Comment => TEXT_MUTED,
        SourceTokenStyle::Function => rgb(0x8aadf4),
        SourceTokenStyle::Type => rgb(0x7dc4e4),
        SourceTokenStyle::Property | SourceTokenStyle::Variable => rgb(0xc6a0f6),
        SourceTokenStyle::Punctuation => rgb(0xcad3f5),
    }
}

fn format_bytes(bytes: u64) -> String {
    const KIB: f64 = 1024.0;
    const MIB: f64 = 1024.0 * 1024.0;

    if bytes >= 1024 * 1024 {
        format!("{:.1} MiB", bytes as f64 / MIB)
    } else if bytes >= 1024 {
        format!("{:.1} KiB", bytes as f64 / KIB)
    } else {
        format!("{bytes} B")
    }
}
