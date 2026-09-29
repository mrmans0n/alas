//! Decodes assets/*.png into palette-indexed bytes at build time, so the wasm
//! embeds raw sprites and never decodes PNG. Any colour not in palette.hex fails the build.

use std::{env, fs, path::Path};

fn main() {
    println!("cargo:rerun-if-changed=assets");
    let out = env::var("OUT_DIR").unwrap();
    let palette: Vec<[u8; 3]> = fs::read_to_string("assets/palette.hex")
        .unwrap()
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            let hex = u32::from_str_radix(line.trim().trim_start_matches('#'), 16).unwrap();
            [(hex >> 16) as u8, (hex >> 8) as u8, hex as u8]
        })
        .collect();
    let mut rust = String::from("pub static PALETTE: [[u8; 4]; ");
    rust += &format!("{}] = [[0, 0, 0, 0]", palette.len() + 1);
    for [r, g, b] in &palette {
        rust += &format!(", [{r}, {g}, {b}, 255]");
    }
    rust += "];\n";
    for name in ["characters", "furniture", "overlays", "font"] {
        let file = fs::File::open(format!("assets/{name}.png")).unwrap();
        let mut decoder = png::Decoder::new(file);
        decoder.set_transformations(png::Transformations::normalize_to_color8() | png::Transformations::ALPHA);
        let mut reader = decoder.read_info().unwrap();
        let mut buf = vec![0; reader.output_buffer_size()];
        let info = reader.next_frame(&mut buf).unwrap();
        assert_eq!(info.color_type, png::ColorType::Rgba, "{name}.png must decode to RGBA");
        let indices: Vec<u8> = buf[..info.buffer_size()]
            .chunks(4)
            .enumerate()
            .map(|(i, px)| {
                if px[3] == 0 {
                    return 0;
                }
                let rgb = [px[0], px[1], px[2]];
                let index = palette.iter().position(|c| *c == rgb).unwrap_or_else(|| {
                    panic!("{name}.png ({}, {}) uses #{:02x}{:02x}{:02x}, not in palette.hex",
                        i as u32 % info.width, i as u32 / info.width, rgb[0], rgb[1], rgb[2])
                });
                index as u8 + 1
            })
            .collect();
        fs::write(Path::new(&out).join(format!("{name}.bin")), indices).unwrap();
        rust += &format!(
            "pub static {}: Sheet = Sheet {{ width: {}, height: {}, pixels: include_bytes!(concat!(env!(\"OUT_DIR\"), \"/{name}.bin\")) }};\n",
            name.to_uppercase(), info.width, info.height);
    }
    fs::write(Path::new(&out).join("sprites.rs"), rust).unwrap();
}
