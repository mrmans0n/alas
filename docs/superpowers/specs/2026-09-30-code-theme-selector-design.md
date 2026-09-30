# Code theme selector — design

## Goal

Let users pick a well-known editor color theme (Solarized, Ayu, Catppuccin,
…) for every surface that renders code, without changing the app chrome.

## Decisions

- **Scope: code surfaces only.** App chrome (sidebar, panels, terminal) keeps
  the app theme (`cool-slate` / `light`).
- **Family, not variant.** The user picks a family; the light or dark variant
  is chosen from the current app theme's `darkMode`, so "match system" keeps
  working.
- **Bundled only.** No user-supplied or VS Code-imported themes in v1.
- **"Default" family** = today's colors, derived from app theme tokens. No
  visual change for users who never touch the setting.

## Bundled families

| Family      | Light variant  | Dark variant   |
|-------------|----------------|----------------|
| Default     | (app tokens)   | (app tokens)   |
| Ayu         | Light          | Mirage         |
| Catppuccin  | Latte          | Mocha          |
| Dracula     | → Default      | Dracula        |
| GitHub      | Light          | Dark           |
| Gruvbox     | Light          | Dark           |
| Nord        | → Default      | Nord           |
| One         | Light          | Dark           |
| Solarized   | Light          | Dark           |
| Tokyo Night | Day            | Night          |

16 JSON palette files. Colors come from each theme's published palette.
Dark-only families fall back to Default in light mode.

## Data model

Palette files live in `Alas/Resources/CodeThemes/<family>-<variant>.json`
(a new resources entry in `project.yml`; regenerate with `xcodegen`):

```json
{ "id": "solarized-dark", "family": "solarized", "name": "Solarized Dark", "dark": true,
  "colors": { "bg": "#002b36", "fg": "#839496", "gutter-fg": "#586e75", "selection": "#073642",
              "comment": "#586e75", "keyword": "#859900", "string": "#2aa198", "number": "#d33682",
              "type": "#b58900", "function": "#268bd2", "constant": "#cb4b16", "attribute": "#6c71c4" } }
```

All 12 slots are required. Captures without a slot (`variable`,
`parameter`, `property`, `operator`, `punctuation`, `plain`) use `fg`.

`struct CodePalette: Decodable` parses hex into `NSColor` once at load. A
static `CodePalette.families` table lists each family's display name and its
light and dark palette ids (`nil` = Default).

## Propagation

Every code surface already builds `EditorTheme(theme:)` from the environment
`Theme`, so the palette rides on `Theme` as a runtime field, mirroring
`accentOverride`:

- `Theme.codePalette: CodePalette?`. `nil` means Default. Excluded from
  `Codable`; included in `==` and `hash` (by palette id) so views redraw.
- `ThemeStore.setCodeTheme(family:)` stores the family and resolves the
  variant from `current.darkMode`. It re-resolves whenever `current`
  changes (`activate`, match-system flips), so the palette survives theme
  switches the same way the accent override does.
- `AppState` calls `themeStore.setCodeTheme(family: config.code.codeThemeFamily)`
  at startup next to the existing `setAccent` call (`AppState.swift:1470`).

## EditorTheme: the single capture→color mapping

- `color(for capture:, onChangedLine: Bool = false)` uses the palette slot
  when one is set and today's token mapping otherwise. `onChangedLine`
  carries the existing diff rule: comments on added or deleted lines render
  in `fg` for legibility.
- `bg`, `defaultFG`, and `faint` follow the palette when one is set.
- New `selection` and `gutterFG` accessors. The editor applies `selection` as
  its selected-text background; the line-number ruler uses `gutterFG`
  (today `fg-faint`) and `bg`.
- `diagnosticAttributes` keeps app tokens (`del` / `warn` / `info`).
- Delete `DiffCodeText.syntaxColor(for:inlineTone:theme:)` and
  `DiffSelectableTextBuilder.color(for:kind:theme:)`; both call
  `EditorTheme.color(for:onChangedLine:)`.

## Surface coverage

- **Full theme (bg + fg + syntax):** code editor (incl. gutter, selection),
  merge conflict/result panes.
- **fg + syntax, app background:** markdown and ACP transcript code blocks.
  They sit inside app-chrome cards; a palette background there would need
  card-level changes across several ACP views.
- **Syntax colors only:** diff and review views. Their background and
  add/delete row tints stay on app tokens, which are tuned against the app
  background.
- `ACPComposerShell`'s use of `syntax-keyword` as an accent is chrome, so it
  stays on the app token.

## Persistence

`AppConfig.Code.codeThemeFamily: String = "default"`, added to `CodingKeys`
and decoded in `AppConfig.init(from:)` with the existing
`(try? codeContainer.decode(...)) ?? "default"` pattern. No migration.

## Settings UI

In `CodePane.swift`, add a "Theme" row at the top of the **Appearance**
group: a menu picker of family names, with three color dots (keyword, string,
function) of the active code theme beside it. Dots do not go inside menu
items: macOS menus template-tint SwiftUI images.
Row description: "Follows the app's light/dark theme; dark-only themes use
Default in light mode." Selecting saves config and calls `setCodeTheme`.
No preview pane.

## Error handling

- Unknown family id in config → Default.
- Missing or undecodable bundled palette → Default, logged in DEBUG. Never
  crash, never show the pink missing-token sentinel.

## Testing

1. `ThemeTests`: one parameterized test over every palette id in
   `CodePalette.families`, asserting it loads and defines all 12 slots.
2. `ThemeStoreTests`: parameterized variant resolution. Solarized + dark app
   theme → `solarized-dark`; after activating `light` → `solarized-light`;
   Nord + light → `nil`; unknown family → `nil`.
3. No new diff test: `DiffSelectableTextTests` already pins "comments on
   changed rows use `fg`" for both diff paths, so it guards the move into
   `EditorTheme`.

Not tested: picker row composition, menu dots, gutter/selection forwarding,
decode defaults.

Local checks: `-only-testing` for `ThemeTests`, `ThemeStoreTests`,
`DiffSelectableTextTests`, `DiffPaneViewTests`, `ACPCodeBlockHighlighterTests`, `MarkdownRendererTests`
after `xcodegen`.

## Out of scope

User-supplied themes, VS Code theme import, per-theme terminal palettes,
extra flavors (Ayu Dark, Catppuccin Frappé/Macchiato). Each can be added
later as a new family entry or loader.
