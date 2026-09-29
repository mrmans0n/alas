//! Sprite sheets decoded by build.rs. Pixels are palette indices; 0 is transparent.

pub struct Sheet {
    pub width: usize,
    pub height: usize,
    pub pixels: &'static [u8],
}

include!(concat!(env!("OUT_DIR"), "/sprites.rs"));
