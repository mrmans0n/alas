use gpui::{IntoElement, Window, WindowBackgroundAppearance, WindowOptions, div, prelude::*, px};

pub const TRAFFIC_LIGHT_LEFT_PX: f32 = 20.0;
pub const TRAFFIC_LIGHT_TOP_PX: f32 = 20.0;
pub const MAC_SAFE_AREA_WIDTH_PX: f32 = 116.0;
pub const MAC_SAFE_AREA_HEIGHT_PX: f32 = 56.0;

pub fn mac_titlebar_safe_area_height_px() -> f32 {
    if cfg!(target_os = "macos") {
        MAC_SAFE_AREA_HEIGHT_PX
    } else {
        0.0
    }
}

pub fn alas_window_options() -> WindowOptions {
    let options = WindowOptions::default();

    #[cfg(target_os = "macos")]
    let options = {
        let mut options = options;
        options.titlebar = Some(gpui::TitlebarOptions {
            title: None,
            appears_transparent: true,
            traffic_light_position: Some(gpui::point(
                px(TRAFFIC_LIGHT_LEFT_PX),
                px(TRAFFIC_LIGHT_TOP_PX),
            )),
        });
        options
    };

    options
}

pub fn render_mac_titlebar_safe_area_spacer() -> impl IntoElement {
    div()
        .id("mac-titlebar-safe-area-spacer")
        .flex_shrink_0()
        .w(px(MAC_SAFE_AREA_WIDTH_PX))
        .h(px(mac_titlebar_safe_area_height_px()))
}

pub fn macos_window_background_appearance() -> WindowBackgroundAppearance {
    if cfg!(target_os = "macos") {
        WindowBackgroundAppearance::Blurred
    } else {
        WindowBackgroundAppearance::Opaque
    }
}

pub fn apply_window_background_appearance(window: &Window) {
    window.set_background_appearance(macos_window_background_appearance());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[cfg(target_os = "macos")]
    fn macos_window_options_use_transparent_titlebar_and_moved_traffic_lights() {
        let options = alas_window_options();
        let titlebar = options.titlebar.expect("titlebar options");
        assert!(titlebar.appears_transparent);
        assert!(titlebar.title.is_none());
        assert!(titlebar.traffic_light_position.is_some());
    }

    #[test]
    #[cfg(not(target_os = "macos"))]
    fn non_macos_window_options_keep_default_titlebar() {
        let options = alas_window_options();
        let titlebar = options.titlebar.expect("default titlebar options");
        assert!(!titlebar.appears_transparent);
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn macos_window_uses_blurred_background_appearance() {
        assert_eq!(
            macos_window_background_appearance(),
            gpui::WindowBackgroundAppearance::Blurred,
        );
    }

    #[test]
    #[cfg(not(target_os = "macos"))]
    fn non_macos_window_uses_opaque_background_appearance() {
        assert_eq!(
            macos_window_background_appearance(),
            gpui::WindowBackgroundAppearance::Opaque,
        );
    }
}
