#!/usr/bin/env bash
set -euo pipefail

# Packages a built .app bundle into a .app.zip (ditto-style) and a .dmg
# (via create-dmg). Used by .github/workflows/release.yml and nightly.yml.
#
# Usage: scripts/package-app.sh <app-path> <output-prefix>
#   <app-path>      path to the built .app bundle
#   <output-prefix> basename for produced artifacts (e.g. "Alas" or "Alas-nightly")
#
# Outputs (next to the .app): <prefix>.app.zip and <prefix>.dmg

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <app-path> <output-prefix>" >&2
  exit 2
fi

app_path="$1"
prefix="$2"

if [ ! -d "$app_path" ]; then
  echo "error: $app_path is not a directory" >&2
  exit 1
fi

out_dir="$(cd "$(dirname "$app_path")" && pwd)"
app_name="$(basename "$app_path")"

# .app.zip: ditto preserves macOS metadata (extended attrs, symlinks); plain
# `zip -r` does not, which would corrupt any signature we add later.
( cd "$out_dir" && ditto -c -k --keepParent "$app_name" "$prefix.app.zip" )

# .dmg: create-dmg's documented contract is `<output.dmg> <source_folder>`
# and copies the *contents* of <source_folder> into the DMG. Stage the .app
# inside a temp folder so we pass a folder (not the .app itself), guaranteeing
# the .app lands at the DMG root and the --icon flag resolves.
# --hdiutil-quiet keeps CI logs clean. create-dmg refuses to overwrite output.
rm -f "$out_dir/$prefix.dmg"
stage_dir="$(mktemp -d -t package-app)"
trap 'rm -rf "$stage_dir"' EXIT
cp -a "$app_path" "$stage_dir/"
create-dmg \
  --volname "Alas" \
  --window-size 540 380 \
  --icon-size 96 \
  --icon "$app_name" 140 190 \
  --app-drop-link 400 190 \
  --no-internet-enable \
  --hdiutil-quiet \
  "$out_dir/$prefix.dmg" \
  "$stage_dir"

echo "Wrote $out_dir/$prefix.app.zip"
echo "Wrote $out_dir/$prefix.dmg"
