#!/usr/bin/env bash
# Cuts the iOS app's file-type icon font out of the Mac's Nerd Font: the glyphs
# FileTypeIcon.swift names, plus ASCII for the extension tiles of unknown types.
# Run after changing a symbol there; FileTypeIconTests fails while one is missing.
# Needs fonttools (`pip install fonttools`, or uv on PATH to run it ad hoc).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
source_font="$root/ThirdParty/ghostty/src/font/res/JetBrainsMonoNerdFont-Regular.ttf"
table="$root/Alas/Sources/Right/FileTypeIcon.swift"
output="$root/Mobile/Resources/FileTypeIcons.ttf"

[[ -f "$source_font" ]] || { echo "Missing $source_font; initialize the ghostty submodule." >&2; exit 1; }

unicodes="$(grep -oE '\\u\{[0-9A-Fa-f]+\}' "$table" | sed -E 's/\\u\{([0-9A-Fa-f]+)\}/U+\1/' | sort -u | paste -sd, -)"

if command -v pyftsubset >/dev/null; then
  subset=(pyftsubset)
else
  subset=(uvx --from 'fonttools==4.*' pyftsubset)
fi

"${subset[@]}" "$source_font" \
  --unicodes="U+0020-007E,$unicodes" \
  --layout-features='' --no-hinting --desubroutinize \
  --name-IDs='*' --output-file="$output"

echo "Wrote $output ($(wc -c < "$output" | tr -d ' ') bytes)"
