#!/usr/bin/env bash
# Installs this plugin into the Alas plugins folder, using this folder's name as the install folder.
# There is nothing to compile: plugin.js is the plugin. Copy the whole directory to start your own.
set -euo pipefail
cd "$(dirname "$0")"
# ALAS_APP_SUPPORT_DIR installs into an isolated Alas profile instead of the everyday one.
dest="${ALAS_APP_SUPPORT_DIR:-$HOME/Library/Application Support/Alas}/Plugins/$(basename "$PWD")"
mkdir -p "$dest"
cp plugin.json plugin.js "$dest/"
echo "Installed to $dest"
