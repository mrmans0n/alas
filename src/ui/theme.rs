use gpui::Rgba;

const fn rgb_const(hex: u32) -> Rgba {
    Rgba {
        r: ((hex >> 16) & 0xff) as f32 / 255.0,
        g: ((hex >> 8) & 0xff) as f32 / 255.0,
        b: (hex & 0xff) as f32 / 255.0,
        a: 1.0,
    }
}

pub const APP_BG: Rgba = rgb_const(0x202124);
pub const SIDEBAR_BG: Rgba = rgb_const(0x27282b);
pub const PANEL_BG: Rgba = rgb_const(0x1e1f22);
pub const PANEL_BORDER: Rgba = rgb_const(0x34363a);
pub const TEXT: Rgba = rgb_const(0xe8eaed);
pub const TEXT_MUTED: Rgba = rgb_const(0x9aa0a6);
pub const ACCENT: Rgba = rgb_const(0x2d9cff);
pub const DANGER: Rgba = rgb_const(0xff6b7a);
pub const SUCCESS: Rgba = rgb_const(0x6ee08d);
