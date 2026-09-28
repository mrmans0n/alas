#!/usr/bin/env bash
# Builds the sample and installs it into the Alas plugins folder.
# Needs the wasm target: rustup target add wasm32-unknown-unknown
set -euo pipefail
cd "$(dirname "$0")"
# A Homebrew rustc earlier on PATH has no wasm32 std; prefer rustup's toolchain.
if command -v rustup >/dev/null; then
  PATH="$(dirname "$(rustup which cargo)"):$PATH"
  export PATH
fi
cargo build --release --target wasm32-unknown-unknown
dest="$HOME/Library/Application Support/Alas/Plugins/hello-workspace"
mkdir -p "$dest"
cp plugin.json "$dest/plugin.json"
cp target/wasm32-unknown-unknown/release/hello_workspace.wasm "$dest/plugin.wasm"
echo "Installed to $dest"
