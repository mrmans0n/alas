use gpui::Rgba;

const fn rgb_const(hex: u32) -> Rgba {
    Rgba {
        r: ((hex >> 16) & 0xff) as f32 / 255.0,
        g: ((hex >> 8) & 0xff) as f32 / 255.0,
        b: (hex & 0xff) as f32 / 255.0,
        a: 1.0,
    }
}

const fn rgba_const(hex: u32, alpha: f32) -> Rgba {
    Rgba {
        r: ((hex >> 16) & 0xff) as f32 / 255.0,
        g: ((hex >> 8) & 0xff) as f32 / 255.0,
        b: (hex & 0xff) as f32 / 255.0,
        a: alpha,
    }
}

pub const APP_BG: Rgba = rgb_const(0x202124);
pub const SIDEBAR_BG: Rgba = rgb_const(0x27282b);
pub const SIDEBAR_BG_TRANSLUCENT: Rgba = rgba_const(0x27282b, 0.70);
pub const PANEL_BG: Rgba = rgb_const(0x1e1f22);
pub const PANEL_BORDER: Rgba = rgb_const(0x34363a);
pub const TEXT: Rgba = rgb_const(0xe8eaed);
pub const TEXT_MUTED: Rgba = rgb_const(0x9aa0a6);
pub const ACCENT: Rgba = rgb_const(0x2d9cff);
pub const ACCENT_TEXT: Rgba = rgb_const(0x0b1220);
pub const ACTIVE_TAB_BG: Rgba = rgb_const(0x22313b);
pub const DANGER: Rgba = rgb_const(0xff6b7a);
pub const SUCCESS: Rgba = rgb_const(0x6ee08d);
pub const TERMINAL_BG: Rgba = rgb_const(0x141518);
pub const OVERLAY_BG: Rgba = rgb_const(0x25272d);
pub const OVERLAY_BORDER: Rgba = rgb_const(0x444850);
pub const SIDEBAR_SECTION_TEXT: Rgba = rgb_const(0x8f96a3);

pub fn sidebar_background() -> Rgba {
    if cfg!(target_os = "macos") {
        SIDEBAR_BG_TRANSLUCENT
    } else {
        SIDEBAR_BG
    }
}

pub fn root_background() -> Option<Rgba> {
    if cfg!(target_os = "macos") {
        None
    } else {
        Some(APP_BG)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rgba_const_decomposes_hex_and_uses_provided_alpha() {
        let color = rgba_const(0x27282b, 0.7);
        assert!((color.r - (0x27 as f32 / 255.0)).abs() < f32::EPSILON);
        assert!((color.g - (0x28 as f32 / 255.0)).abs() < f32::EPSILON);
        assert!((color.b - (0x2b as f32 / 255.0)).abs() < f32::EPSILON);
        assert!((color.a - 0.7).abs() < f32::EPSILON);
    }

    #[test]
    fn sidebar_bg_translucent_uses_70_percent_alpha() {
        assert!((SIDEBAR_BG_TRANSLUCENT.a - 0.7).abs() < f32::EPSILON);
        assert!((SIDEBAR_BG_TRANSLUCENT.r - SIDEBAR_BG.r).abs() < f32::EPSILON);
        assert!((SIDEBAR_BG_TRANSLUCENT.g - SIDEBAR_BG.g).abs() < f32::EPSILON);
        assert!((SIDEBAR_BG_TRANSLUCENT.b - SIDEBAR_BG.b).abs() < f32::EPSILON);
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn sidebar_background_is_translucent_on_macos() {
        let bg = sidebar_background();
        assert!((bg.a - 0.7).abs() < f32::EPSILON);
        assert!((bg.r - SIDEBAR_BG.r).abs() < f32::EPSILON);
    }

    #[test]
    #[cfg(not(target_os = "macos"))]
    fn sidebar_background_is_opaque_off_macos() {
        let bg = sidebar_background();
        assert!((bg.a - 1.0).abs() < f32::EPSILON);
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn root_background_is_none_on_macos() {
        assert!(root_background().is_none());
    }

    #[test]
    #[cfg(not(target_os = "macos"))]
    fn root_background_is_app_bg_off_macos() {
        let bg = root_background().expect("root_background should be Some off macOS");
        assert!((bg.a - 1.0).abs() < f32::EPSILON);
        assert!((bg.r - APP_BG.r).abs() < f32::EPSILON);
    }
}
