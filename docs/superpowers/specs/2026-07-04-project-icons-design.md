# Project Icons Design

## Summary

Give users direct control over the rounded-square project icons used for repositories across Alas. The icon is a project identity setting, not a worktree setting. Users can choose between letter, symbol, emoji, or image modes from the existing Add/Edit Project dialog, with richer color control and GitHub/GitLab avatar presets when a repository remote supports them.

Existing projects continue to render as they do today: a colored sqcircle with the first letter of the project name.

## Goals

- Support four equal icon modes: Letter, Symbol, Emoji, and Image.
- Keep icon customization inside the existing Add/Edit Project dialog for v1.
- Preserve the current color-palette workflow while adding arbitrary custom colors.
- Let Letter mode use an editable 1-2 character label.
- Let Symbol mode use SF Symbols plus existing Alas aliases/custom glyphs.
- Let Image mode import local images and use detected GitHub/GitLab owner avatars as presets.
- Copy all selected images into Alas-managed Application Support storage.
- Render project icons consistently wherever project identity appears.
- Preserve tolerant decoding for old `projects.json` files.

## Non-Goals

- Do not add a quick customization popover from the sidebar or Cmd-K in v1.
- Do not add per-worktree icons.
- Do not reference external image files after selection.
- Do not add an image crop editor. Image mode uses full-bleed center crop.
- Do not refresh remote avatars outside the Add/Edit Project dialog in v1.

## User Experience

The Add/Edit Project dialog gains an Icon section near the project name and path fields. The section contains:

- a live preview at large, sidebar, and Cmd-K sizes
- an equal segmented mode picker: Letter, Symbol, Emoji, Image
- mode-specific controls
- curated color swatches plus a custom color picker or hex field

Letter mode defaults to the project-name initial. Users can override it with a 1-2 character label. Empty labels fall back to the project-name initial.

Symbol mode offers SF Symbols plus the aliases already supported by Alas, such as `github`, `gitlab`, and `commit`. V1 uses a curated searchable list of common project symbols and aliases, plus a text field for entering an SF Symbol name directly. Invalid or unavailable symbols fall back to Letter mode at render time.

Emoji mode accepts a single emoji-style glyph. If input is empty or unusable, rendering falls back to Letter mode.

Image mode supports choosing a local image file. Images render full-bleed inside the sqcircle with center crop. If a supported GitHub or GitLab remote is detected for the project, the dialog automatically attempts to fetch the remote owner avatar and shows it as a preset. Fetching is non-blocking; the dialog must open immediately even if the network is slow or unavailable.

Selecting a local image or avatar preset copies the image into Alas-managed storage. The project stores a reference to that managed asset, not to the original source URL or source file.

## Data Model

Add a structured icon value to `ProjectConfig`:

```swift
struct ProjectIcon: Codable, Equatable {
    enum Mode: String, Codable, Equatable {
        case letter
        case symbol
        case emoji
        case image
    }

    var mode: Mode
    var color: String
    var label: String?
    var symbolName: String?
    var emoji: String?
    var imageAssetName: String?
}
```

`ProjectConfig` gains `var icon: ProjectIcon`. Keep the existing `color` field during the migration period for backward compatibility and for old code paths while call sites move to the new renderer.

When decoding an older project without `icon`, synthesize:

- `mode = .letter`
- `color = project.color`
- `label = nil`

When encoding new project data, include both `icon` and the legacy `color`. The legacy `color` should mirror `icon.color` so older code and simple tests keep behaving predictably during the transition.

`ProjectUpdate`, `ProjectsManager.addProject`, `ProjectsManager.updateProject`, and `AppState.addProject/updateProject` should accept and persist the structured icon rather than only a color.

## Image Storage

Add a managed icon asset location under Application Support:

```text
Application Support/Alas/project-icons/<project-id>/
```

Image staging should:

- accept PNG, JPEG, GIF, and WebP image inputs
- reject oversized or unsupported inputs with a user-visible dialog error
- copy data into the project icon directory
- use content-addressed filenames derived from the copied image bytes
- store only the managed filename or relative managed path in `ProjectIcon.imageAssetName`

Removing or replacing an image icon does not need aggressive garbage collection in v1. A best-effort cleanup of superseded files is acceptable if it stays simple.

## Avatar Presets

Use the existing `CodeHostRemoteDetector` to inspect project remotes. If it detects GitHub or GitLab, the Add/Edit Project dialog derives one owner-avatar preset candidate:

- GitHub owner avatar for `https://github.com/<owner>/<repo>`
- GitLab owner or namespace avatar for the detected GitLab host when available from the unauthenticated public API

The fetch is automatic, asynchronous, and non-blocking. Failure should not block editing or saving the project. The UI should either hide the preset or show it as unavailable with quiet copy.

When the user chooses the avatar preset, Alas copies the downloaded image into the same managed storage used for manual image imports. After selection, the project icon no longer depends on the network or on the remote account.

Private or self-hosted remotes may fail to expose avatars without authentication. That is acceptable in v1; the preset simply remains unavailable.

## Rendering

Introduce one reusable project icon renderer, for example:

```swift
ProjectIconView(icon: project.icon, fallbackName: project.name, size: .sidebar)
```

The renderer owns all fallback behavior and sizing rules. V1 replaces direct `RepoDot` and project color-dot usage in these known project identity surfaces:

- `RepoGroupView`
- `RepoSelectorRowView`
- `ProjectPicker`
- Add/Edit Project preview

Rendering rules:

- Letter: colored rounded square with the 1-2 character label
- Symbol: colored rounded square with centered SF Symbol or Alas glyph
- Emoji: colored rounded square with centered emoji glyph
- Image: full-bleed rounded image, center-cropped
- Fallback: render Letter mode using fallback project name and icon color

The renderer should keep stable dimensions so hover states, row layout, and project header alignment do not shift. Sidebar sizing remains close to the current 16x16 `RepoDot`; larger picker/dialog sizes can be surface-specific.

## Architecture

Keep the feature local to project identity:

- `ProjectIcon` owns persisted icon configuration.
- `ProjectIconView` owns visual rendering and fallback.
- A small image-staging helper owns copying and validating images.
- A small avatar-preset helper owns remote detection and async fetch for the dialog.
- `ProjectDialog` owns the editing controls and maps draft state to `ProjectIcon`.

Avoid making `ProjectsManager` responsible for network fetches or image decoding. It should persist project records only. The dialog or a focused helper can fetch avatar presets because that work is UI-adjacent and only happens while editing a project.

## Error Handling

- Invalid hex colors fall back to `#5fb7c4`.
- Empty letter labels fall back to the project-name initial.
- Overlong letter labels are clamped to two display characters.
- Invalid or unavailable symbols fall back to Letter mode.
- Missing or unreadable image assets fall back to Letter mode and do not mutate stored config.
- Avatar fetch failures are non-blocking and quiet.
- Saving project edits should not wait for an in-flight avatar fetch unless the user selected that avatar and the image copy is required.

## Testing

Add focused Swift Testing coverage for:

- decoding old `ProjectConfig` records without `icon`
- round-tripping each `ProjectIcon` mode
- keeping legacy `color` in sync with `icon.color`
- clamping and fallback behavior for labels, symbols, colors, and missing images
- image staging path behavior under `project-icons/<project-id>`
- remote detection to avatar-preset candidate mapping
- sidebar and Cmd-K renderer/layout behavior at small sizes

Manual verification should cover:

- adding a project with the default Letter icon
- editing Letter label and custom color
- selecting a Symbol icon and seeing it in sidebar and Cmd-K
- selecting an Emoji icon and seeing it in sidebar and Cmd-K
- importing a local image and relaunching to confirm it persists
- selecting an automatically fetched GitHub/GitLab avatar preset
- opening Add/Edit Project while offline or when avatar fetch fails
- deleting or moving the original image file after import and confirming the icon still renders

## Deferred

- Sidebar or Cmd-K quick customization entry points.
- Per-worktree icon overrides.
- Linked external images.
- Crop/zoom controls for image icons.
- Scheduled avatar refresh or "refresh avatar" actions.
- Rich symbol browser beyond the basic SF Symbol plus Alas alias selection needed for v1.
