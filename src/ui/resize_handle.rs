use gpui::{Pixels, px};

pub const LEFT_SIDEBAR_MIN_WIDTH_PX: f32 = 180.0;
pub const LEFT_SIDEBAR_MAX_WIDTH_PX: f32 = 480.0;
pub const RIGHT_SIDEBAR_MIN_WIDTH_PX: f32 = 200.0;
pub const RIGHT_SIDEBAR_MAX_WIDTH_PX: f32 = 500.0;
pub const CENTER_MIN_WIDTH_PX: f32 = 300.0;
pub const RESIZE_HANDLE_WIDTH_PX: f32 = 6.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SidebarResizeTarget {
    Left,
    Right,
}

#[derive(Debug, Clone, Copy)]
pub struct SidebarResizeDrag {
    pub target: SidebarResizeTarget,
    pub start_x: f32,
    pub start_width: f32,
}

#[derive(Debug, Clone, Copy)]
pub struct SidebarLayoutState {
    pub left_width_px: f32,
    pub right_width_px: f32,
}

impl SidebarLayoutState {
    pub fn from_config(left: u32, right: u32) -> Self {
        Self {
            left_width_px: left as f32,
            right_width_px: right as f32,
        }
    }

    pub fn left_width(&self) -> Pixels {
        px(self.left_width_px)
    }

    pub fn right_width(&self) -> Pixels {
        px(self.right_width_px)
    }
}

/// Clamp a sidebar width based on its own limits and the available window width.
pub fn clamp_sidebar_width(
    target: SidebarResizeTarget,
    requested: f32,
    other_sidebar_width: f32,
    window_width: f32,
) -> f32 {
    let (min, max) = match target {
        SidebarResizeTarget::Left => (LEFT_SIDEBAR_MIN_WIDTH_PX, LEFT_SIDEBAR_MAX_WIDTH_PX),
        SidebarResizeTarget::Right => (RIGHT_SIDEBAR_MIN_WIDTH_PX, RIGHT_SIDEBAR_MAX_WIDTH_PX),
    };

    // Ensure center pane keeps minimum width
    let effective_max = (window_width - other_sidebar_width - CENTER_MIN_WIDTH_PX).max(min);
    requested.clamp(min, max.min(effective_max))
}

#[cfg(test)]
mod tests {
    use super::*;

    const NORMAL_WINDOW: f32 = 1440.0;

    #[test]
    fn left_clamps_to_min() {
        let result = clamp_sidebar_width(SidebarResizeTarget::Left, 100.0, 320.0, NORMAL_WINDOW);
        assert_eq!(result, LEFT_SIDEBAR_MIN_WIDTH_PX);
    }

    #[test]
    fn left_clamps_to_max() {
        let result = clamp_sidebar_width(SidebarResizeTarget::Left, 600.0, 320.0, NORMAL_WINDOW);
        assert_eq!(result, LEFT_SIDEBAR_MAX_WIDTH_PX);
    }

    #[test]
    fn right_clamps_to_min() {
        let result = clamp_sidebar_width(SidebarResizeTarget::Right, 100.0, 280.0, NORMAL_WINDOW);
        assert_eq!(result, RIGHT_SIDEBAR_MIN_WIDTH_PX);
    }

    #[test]
    fn right_clamps_to_max() {
        let result = clamp_sidebar_width(SidebarResizeTarget::Right, 600.0, 280.0, NORMAL_WINDOW);
        assert_eq!(result, RIGHT_SIDEBAR_MAX_WIDTH_PX);
    }

    #[test]
    fn narrow_window_preserves_center_minimum() {
        // Window = 700, other sidebar = 280, center min = 300
        // So left max = 700 - 280 - 300 = 120 — but that's below the sidebar min of 180
        // The effective max should be clamped to min (180)
        let result = clamp_sidebar_width(SidebarResizeTarget::Left, 400.0, 280.0, 700.0);
        assert_eq!(result, LEFT_SIDEBAR_MIN_WIDTH_PX);
    }

    #[test]
    fn defaults_survive_normal_window() {
        let left = clamp_sidebar_width(SidebarResizeTarget::Left, 280.0, 320.0, NORMAL_WINDOW);
        let right = clamp_sidebar_width(SidebarResizeTarget::Right, 320.0, 280.0, NORMAL_WINDOW);
        assert_eq!(left, 280.0);
        assert_eq!(right, 320.0);
    }

    #[test]
    fn center_preserved_when_both_sidebars_expand() {
        // Window = 1000, right = 400, center min = 300
        // left max = 1000 - 400 - 300 = 300
        let result = clamp_sidebar_width(SidebarResizeTarget::Left, 400.0, 400.0, 1000.0);
        assert_eq!(result, 300.0);
    }
}
