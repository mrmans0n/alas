//! Sprite rectangles in the sheets under assets/. Keep in sync with the PNG layouts.
use crate::canvas::Rect;

pub const CHAR_W: i32 = 16;
pub const CHAR_H: i32 = 24;
pub const WALK_DOWN: i32 = 0;
pub const WALK_UP: i32 = 24;
pub const WALK_RIGHT: i32 = 48;
pub const SIT: Rect = Rect::new(0, 72, 16, 24);
pub const TYPE: [Rect; 2] = [Rect::new(16, 72, 16, 24), Rect::new(32, 72, 16, 24)];
pub const HAND: Rect = Rect::new(48, 72, 16, 24);
pub const SLEEP: Rect = Rect::new(64, 72, 16, 24);

pub const FLOOR: Rect = Rect::new(0, 0, 16, 16);
pub const WALL: Rect = Rect::new(16, 0, 16, 16);
pub const DESK: Rect = Rect::new(32, 0, 64, 16);
pub const CHAIR: Rect = Rect::new(96, 0, 16, 16);
pub const PLANT: Rect = Rect::new(112, 0, 16, 16);
pub const MONITOR_OFF: Rect = Rect::new(0, 16, 16, 16);
pub const MONITOR_ON: [Rect; 2] = [Rect::new(16, 16, 16, 16), Rect::new(32, 16, 16, 16)];
pub const LAMP_OFF: Rect = Rect::new(48, 16, 8, 16);
pub const LAMP_ON: Rect = Rect::new(56, 16, 8, 16);
pub const COUCH: Rect = Rect::new(64, 16, 32, 16);
pub const COFFEE: Rect = Rect::new(0, 32, 16, 32);
pub const COOLER: Rect = Rect::new(16, 32, 16, 32);
pub const DOOR: Rect = Rect::new(32, 32, 16, 32);
pub const SIGN: Rect = Rect::new(48, 32, 32, 16);

pub const BUBBLE_Q: Rect = Rect::new(0, 0, 16, 16);
pub const BUBBLE_BANG: [Rect; 2] = [Rect::new(16, 0, 16, 16), Rect::new(32, 0, 16, 16)];
pub const ZZ: Rect = Rect::new(48, 0, 8, 8);
pub const WARNING: Rect = Rect::new(56, 0, 8, 8);
pub const PAPERS: [Rect; 3] = [Rect::new(0, 16, 16, 16), Rect::new(16, 16, 16, 16), Rect::new(32, 16, 16, 16)];
pub const BAR_FRAME: Rect = Rect::new(48, 16, 16, 4);

/// Walk frame `n` (0..4) in the row at `row_y`.
pub fn walk(row_y: i32, n: i32) -> Rect {
    Rect::new(n * CHAR_W, row_y, CHAR_W, CHAR_H)
}

#[cfg(test)]
mod tests {
    use crate::sprites::{CHARACTERS, FONT, FURNITURE, OVERLAYS};

    #[test]
    fn sheets_have_the_documented_sizes() {
        assert_eq!((CHARACTERS.width, CHARACTERS.height), (80, 96));
        assert_eq!((FURNITURE.width, FURNITURE.height), (128, 64));
        assert_eq!((OVERLAYS.width, OVERLAYS.height), (64, 32));
        assert_eq!((FONT.width, FONT.height), (64, 36));
    }

    #[test]
    fn every_printable_glyph_and_character_frame_is_drawn() {
        for code in 33..127 {
            let (gx, gy) = (((code - 32) % 16) * 4, ((code - 32) / 16) * 6);
            let lit = (0..6).any(|y| (0..4).any(|x| FONT.pixels[(gy + y) * FONT.width + gx + x] != 0));
            assert!(lit, "glyph {:?} is empty", char::from(code as u8));
        }
        for (x, y) in (0..4).flat_map(|n| [(n * 16, 0), (n * 16, 24), (n * 16, 48)]).chain((0..5).map(|n| (n * 16, 72))) {
            let lit = (0..24).any(|dy| (0..16).any(|dx| CHARACTERS.pixels[(y + dy) * CHARACTERS.width + x + dx] != 0));
            assert!(lit, "character frame at ({x}, {y}) is empty");
        }
    }
}
