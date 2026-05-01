use crate::{
    app::{ImagePreflight, ImageTabState, ImageZoom, WorkspaceTabId},
    ui::theme::{ACCENT, ACCENT_TEXT, DANGER, PANEL_BG, PANEL_BORDER, TEXT, TEXT_MUTED},
};
use gpui::{
    App, ClickEvent, IntoElement, ObjectFit, ParentElement, SharedString, Styled, StyledImage,
    Window, div, img, prelude::*, px, rgb,
};

pub fn render_image_view(
    tab_id: WorkspaceTabId,
    state: &ImageTabState,
    on_fit: impl Fn(WorkspaceTabId, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_zoom_in: impl Fn(WorkspaceTabId, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_zoom_out: impl Fn(WorkspaceTabId, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
) -> impl IntoElement {
    div()
        .id("image-view")
        .flex()
        .flex_col()
        .size_full()
        .bg(rgb(0x111827))
        .child(render_image_toolbar(
            tab_id,
            state,
            on_fit,
            on_zoom_in,
            on_zoom_out,
        ))
        .child(render_image_body(state))
}

fn render_image_toolbar(
    tab_id: WorkspaceTabId,
    state: &ImageTabState,
    on_fit: impl Fn(WorkspaceTabId, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_zoom_in: impl Fn(WorkspaceTabId, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_zoom_out: impl Fn(WorkspaceTabId, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
) -> impl IntoElement {
    let zoom = state.zoom;
    let file_name = state
        .display_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("Image")
        .to_string();

    div()
        .id("image-toolbar")
        .flex()
        .items_center()
        .justify_between()
        .gap_3()
        .px_3()
        .py_2()
        .border_b_1()
        .border_color(PANEL_BORDER)
        .bg(PANEL_BG)
        .child(
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(toolbar_button("image-fit", "Fit", true, {
                    let on_fit = on_fit.clone();
                    move |event, window, cx| on_fit(tab_id, event, window, cx)
                }))
                .child(toolbar_button("image-zoom-out", "-", !zoom.is_min(), {
                    let on_zoom_out = on_zoom_out.clone();
                    move |event, window, cx| on_zoom_out(tab_id, event, window, cx)
                }))
                .child(
                    div()
                        .id("image-zoom-label")
                        .min_w(px(56.0))
                        .text_center()
                        .text_sm()
                        .font_weight(gpui::FontWeight::SEMIBOLD)
                        .text_color(TEXT)
                        .child(zoom.label()),
                )
                .child(toolbar_button("image-zoom-in", "+", !zoom.is_max(), {
                    let on_zoom_in = on_zoom_in.clone();
                    move |event, window, cx| on_zoom_in(tab_id, event, window, cx)
                })),
        )
        .child(
            div()
                .min_w(px(0.0))
                .text_sm()
                .text_color(TEXT_MUTED)
                .child(SharedString::from(file_name)),
        )
}

fn toolbar_button(
    id: &'static str,
    label: &'static str,
    enabled: bool,
    on_click: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
) -> impl IntoElement {
    div()
        .id(id)
        .px_3()
        .py_1()
        .rounded_md()
        .border_1()
        .border_color(PANEL_BORDER)
        .bg(if enabled { ACCENT } else { PANEL_BG })
        .text_sm()
        .font_weight(gpui::FontWeight::SEMIBOLD)
        .text_color(if enabled { ACCENT_TEXT } else { TEXT_MUTED })
        .child(label)
        .when(enabled, |element| element.on_click(on_click))
}

fn render_image_body(state: &ImageTabState) -> impl IntoElement {
    div()
        .id("image-body")
        .flex()
        .flex_1()
        .items_center()
        .justify_center()
        .overflow_scroll()
        .bg(rgb(0x111827))
        .when(state.preflight != ImagePreflight::Ready, |element| {
            element.child(render_preflight_error(state))
        })
        .when(state.preflight == ImagePreflight::Ready, |element| {
            element.child(render_ready_image(state))
        })
}

fn render_ready_image(state: &ImageTabState) -> impl IntoElement {
    let path = state.path.clone();
    let file_name = state
        .display_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("image")
        .to_string();
    let loading = || render_image_message("Loading image...", "").into_any_element();
    let fallback_file_name = file_name.clone();
    let fallback = move || {
        render_image_message(
            "Image could not be decoded",
            &format!(
                "{} may be corrupt or use unsupported encoding.",
                fallback_file_name
            ),
        )
        .into_any_element()
    };

    match state.zoom {
        ImageZoom::Fit => div()
            .size_full()
            .flex()
            .items_center()
            .justify_center()
            .child(
                img(path)
                    .id("image-preview")
                    .size_full()
                    .object_fit(ObjectFit::Contain)
                    .with_loading(loading)
                    .with_fallback(fallback),
            ),
        ImageZoom::Fixed(zoom) => div()
            .size_full()
            .flex()
            .items_center()
            .justify_center()
            .p_6()
            .child(
                img(path)
                    .id("image-preview")
                    .w(px(960.0 * zoom))
                    .object_fit(ObjectFit::Contain)
                    .with_loading(loading)
                    .with_fallback(fallback),
            ),
    }
}

fn render_preflight_error(state: &ImageTabState) -> impl IntoElement {
    render_image_message(
        state.preflight.title().to_string(),
        state.preflight.detail(),
    )
}

fn render_image_message(title: impl Into<String>, detail: impl Into<String>) -> impl IntoElement {
    let title = title.into();
    let detail = detail.into();
    div()
        .max_w(px(560.0))
        .p_4()
        .rounded_lg()
        .border_1()
        .border_color(PANEL_BORDER)
        .bg(PANEL_BG)
        .flex()
        .flex_col()
        .gap_2()
        .text_center()
        .child(
            div()
                .text_sm()
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .text_color(DANGER)
                .child(SharedString::from(title)),
        )
        .when(!detail.is_empty(), |element| {
            element.child(
                div()
                    .text_sm()
                    .text_color(TEXT_MUTED)
                    .child(SharedString::from(detail)),
            )
        })
}
