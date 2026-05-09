# Alas Assets

Brand iconography (Scout wing mark) — duotone wings of freedom crest.

| File | Use |
| --- | --- |
| `scout-icon.svg` | Production duotone mark on dark surfaces. Wing A filled brand teal, Wing B outlined light. |
| `scout-icon-mono.svg` | Single-color variant driven by `currentColor` — set `color:` on the parent. |
| `scout-icon-favicon-16.svg` | Aggressively simplified mark for sub-16px favicons (two primary feathers, both filled). |

## Color tokens

| Token | oklch (canonical) | hex (fallback) |
| --- | --- | --- |
| `--brand` | `oklch(0.78 0.11 195)` | `#3FC9D4` |
| `--fg` | `oklch(0.94 0.012 220)` | `#E8EDF0` |
| `--surface-dock` | `linear-gradient(160deg, #0e3138, #061418)` | — |

The brand teal must match the app's `--accent`.

## Adaptive simplification (raster sizes)

- ≥ 32 px → full `scout-icon.svg`
- 17–31 px → drop feathers 4 and 5 from Wing B
- ≤ 16 px → use `scout-icon-favicon-16.svg`

## App icon

The macOS app icon set lives at `Alas/Resources/Assets.xcassets/AppIcon.appiconset/`.
Slot PNGs are pre-rendered: the mark sits at ~70% of the canvas on the dock-ground
gradient. The 16×16 slot uses the favicon-simplified geometry; all others use the
full mark.
