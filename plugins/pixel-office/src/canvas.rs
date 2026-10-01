use crate::sprites::{Sheet, FONT};

pub type Rgba = [u8; 4];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

impl Rect {
    pub const fn new(x: i32, y: i32, w: i32, h: i32) -> Rect {
        Rect { x, y, w, h }
    }

    pub fn intersects(&self, other: &Rect) -> bool {
        self.x < other.x + other.w && other.x < self.x + self.w && self.y < other.y + other.h && other.y < self.y + self.h
    }
}

/// Glyphs are 4x6 cells (3 px wide plus 1 px spacing), ASCII 32..=126, 16 per row.
pub const GLYPH_W: i32 = 4;
pub const GLYPH_H: i32 = 6;

pub struct Canvas {
    pub width: usize,
    pub height: usize,
    pub pixels: Vec<u8>,
}

impl Canvas {
    pub fn new(width: usize, height: usize) -> Canvas {
        Canvas { width, height, pixels: vec![0; width * height * 4] }
    }

    /// Clipped to the canvas, so callers can draw partly off-screen.
    fn clip(&self, r: Rect) -> Option<(usize, usize, usize, usize)> {
        let x0 = r.x.max(0) as usize;
        let y0 = r.y.max(0) as usize;
        let x1 = ((r.x + r.w).max(0) as usize).min(self.width);
        let y1 = ((r.y + r.h).max(0) as usize).min(self.height);
        (x0 < x1 && y0 < y1).then_some((x0, y0, x1, y1))
    }

    fn put(&mut self, x: i32, y: i32, color: Rgba) {
        if x < 0 || y < 0 || x as usize >= self.width || y as usize >= self.height {
            return;
        }
        let i = (y as usize * self.width + x as usize) * 4;
        self.pixels[i..i + 4].copy_from_slice(&color);
    }

    pub fn fill(&mut self, r: Rect, color: Rgba) {
        let Some((x0, y0, x1, y1)) = self.clip(r) else { return };
        for y in y0..y1 {
            for x in x0..x1 {
                let i = (y * self.width + x) * 4;
                self.pixels[i..i + 4].copy_from_slice(&color);
            }
        }
    }

    /// Copies `r` from `src`, which must be the same size as `self`.
    pub fn copy_from(&mut self, src: &Canvas, r: Rect) {
        let Some((x0, y0, x1, y1)) = self.clip(r) else { return };
        for y in y0..y1 {
            let a = (y * self.width + x0) * 4;
            let b = (y * self.width + x1) * 4;
            self.pixels[a..b].copy_from_slice(&src.pixels[a..b]);
        }
    }

    /// Draws `src` from `sheet` at (dx, dy). `palette[index]` gives each colour; index 0 is skipped.
    /// `dim` halves brightness, for the `unknown` state.
    #[allow(clippy::too_many_arguments)]
    pub fn blit(&mut self, sheet: &Sheet, src: Rect, dx: i32, dy: i32, palette: &[Rgba], flip: bool, dim: bool) {
        for sy in 0..src.h {
            for sx in 0..src.w {
                let (px, py) = ((src.x + sx) as usize, (src.y + sy) as usize);
                if px >= sheet.width || py >= sheet.height {
                    continue;
                }
                let index = sheet.pixels[py * sheet.width + px] as usize;
                if index == 0 {
                    continue;
                }
                let mut color = palette[index];
                if dim {
                    color = [color[0] / 2, color[1] / 2, color[2] / 2, 255];
                }
                let x = if flip { dx + src.w - 1 - sx } else { dx + sx };
                self.put(x, dy + sy, color);
            }
        }
    }

    pub fn text(&mut self, x: i32, y: i32, text: &str, color: Rgba) {
        for (n, ch) in text.chars().enumerate() {
            let code = if (' '..='~').contains(&ch) { ch as i32 - 32 } else { '?' as i32 - 32 };
            let src = Rect::new((code % 16) * GLYPH_W, (code / 16) * GLYPH_H, GLYPH_W, GLYPH_H);
            let palette = [[0, 0, 0, 0], color];
            // Any non-transparent font pixel is "on".
            for sy in 0..GLYPH_H {
                for sx in 0..GLYPH_W {
                    let (px, py) = ((src.x + sx) as usize, (src.y + sy) as usize);
                    if FONT.pixels[py * FONT.width + px] != 0 {
                        self.put(x + n as i32 * GLYPH_W + sx, y + sy, palette[1]);
                    }
                }
            }
        }
    }
}

pub fn text_width(text: &str) -> i32 {
    text.chars().count() as i32 * GLYPH_W
}

#[cfg(test)]
mod tests {
    use super::*;

    static SHEET: Sheet = Sheet { width: 2, height: 1, pixels: &[1, 0] };
    const PALETTE: [Rgba; 2] = [[0, 0, 0, 0], [9, 9, 9, 255]];

    fn at(c: &Canvas, x: usize, y: usize) -> Rgba {
        let i = (y * c.width + x) * 4;
        c.pixels[i..i + 4].try_into().unwrap()
    }

    #[test]
    fn blit_skips_transparent_pixels_flips_and_clips() {
        let mut c = Canvas::new(3, 1);
        c.fill(Rect::new(0, 0, 3, 1), [1, 1, 1, 255]);
        c.blit(&SHEET, Rect::new(0, 0, 2, 1), 0, 0, &PALETTE, false, false);
        assert_eq!([at(&c, 0, 0), at(&c, 1, 0)], [[9, 9, 9, 255], [1, 1, 1, 255]]);
        c.blit(&SHEET, Rect::new(0, 0, 2, 1), 1, 0, &PALETTE, true, true);
        assert_eq!(at(&c, 2, 0), [4, 4, 4, 255]);
        c.blit(&SHEET, Rect::new(0, 0, 2, 1), -1, 5, &PALETTE, false, false); // fully off-canvas: no panic
    }

    #[test]
    fn copy_from_restores_only_the_rect() {
        let background = Canvas::new(4, 4);
        let mut frame = Canvas::new(4, 4);
        frame.fill(Rect::new(0, 0, 4, 4), [7, 7, 7, 255]);
        frame.copy_from(&background, Rect::new(-2, -2, 3, 3));
        assert_eq!(at(&frame, 0, 0), [0, 0, 0, 0]);
        assert_eq!(at(&frame, 1, 1), [7, 7, 7, 255]);
    }
}
