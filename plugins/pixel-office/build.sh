#!/usr/bin/env bash
# Builds this plugin and installs it into the Alas plugins folder, using this
# folder's name as the install folder. Copy the whole directory to start your own.
# Needs the wasm target: rustup target add wasm32-unknown-unknown
set -euo pipefail
cd "$(dirname "$0")"
# A Homebrew rustc earlier on PATH has no wasm32 std; prefer rustup's toolchain.
if command -v rustup >/dev/null; then
  PATH="$(dirname "$(rustup which cargo)"):$PATH"
  export PATH
fi
cargo build --release --target wasm32-unknown-unknown
wasm=(target/wasm32-unknown-unknown/release/*.wasm)
if [ "${#wasm[@]}" -ne 1 ]; then
  echo "expected exactly one .wasm in target/wasm32-unknown-unknown/release, found ${#wasm[@]}" >&2
  exit 1
fi
# ALAS_APP_SUPPORT_DIR installs into an isolated Alas profile instead of the everyday one.
dest="${ALAS_APP_SUPPORT_DIR:-$HOME/Library/Application Support/Alas}/Plugins/$(basename "$PWD")"
mkdir -p "$dest"
cp plugin.json "$dest/plugin.json"
cp "${wasm[0]}" "$dest/plugin.wasm"
echo "Installed to $dest"
