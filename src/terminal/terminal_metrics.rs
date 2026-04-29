use super::TerminalSize;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TerminalMetrics {
    pub cell_width_px: f32,
    pub cell_height_px: f32,
    pub font_size_px: f32,
}

impl TerminalMetrics {
    pub fn fallback() -> Self {
        Self {
            cell_width_px: 9.0,
            cell_height_px: 19.0,
            font_size_px: 14.0,
        }
    }

    pub fn size_from_pixels(self, width_px: f32, height_px: f32) -> TerminalSize {
        TerminalSize {
            cols: (width_px / self.cell_width_px).floor().max(20.0) as u16,
            rows: (height_px / self.cell_height_px).floor().max(4.0) as u16,
        }
    }

    pub fn cell_at(self, x_px: f32, y_px: f32) -> Option<(u16, u16)> {
        if x_px < 0.0 || y_px < 0.0 {
            return None;
        }
        Some((
            (x_px / self.cell_width_px).floor() as u16,
            (y_px / self.cell_height_px).floor() as u16,
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fallback_metrics_compute_terminal_size_from_pixels() {
        let metrics = TerminalMetrics::fallback();
        assert_eq!(metrics.size_from_pixels(180.0, 76.0).cols, 20);
        assert_eq!(metrics.size_from_pixels(180.0, 76.0).rows, 4);
        assert_eq!(metrics.size_from_pixels(900.0, 380.0).cols, 100);
        assert_eq!(metrics.size_from_pixels(900.0, 380.0).rows, 20);
    }

    #[test]
    fn fallback_metrics_convert_pixels_to_cell_coordinates() {
        let metrics = TerminalMetrics::fallback();
        assert_eq!(metrics.cell_at(0.0, 0.0), Some((0, 0)));
        assert_eq!(metrics.cell_at(8.9, 18.9), Some((0, 0)));
        assert_eq!(metrics.cell_at(9.0, 19.0), Some((1, 1)));
        assert_eq!(metrics.cell_at(-1.0, 0.0), None);
    }
}
