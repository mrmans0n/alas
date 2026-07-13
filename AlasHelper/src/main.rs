use serde::{Deserialize, Serialize};

const PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct Handshake<'a> {
    name: &'a str,
    protocol_version: u32,
    binary_version: &'a str,
}

fn handshake() -> Handshake<'static> {
    Handshake {
        name: env!("CARGO_PKG_NAME"),
        protocol_version: PROTOCOL_VERSION,
        binary_version: env!("CARGO_PKG_VERSION"),
    }
}

fn main() {
    let command = std::env::args().nth(1);
    if command.as_deref().is_some_and(|value| value != "version") {
        eprintln!("usage: alas-helper [version]");
        std::process::exit(2);
    }
    println!(
        "{}",
        serde_json::to_string(&handshake()).expect("handshake serialization must succeed")
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_manifest_matches_handshake() {
        let manifest: Handshake<'_> =
            serde_json::from_str(include_str!("../manifest.json")).expect("valid manifest");
        assert_eq!(manifest, handshake());
    }
}
