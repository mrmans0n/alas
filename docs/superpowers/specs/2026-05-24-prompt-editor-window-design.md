# Prompt Editor Window Design

## Context

Settings -> Changes currently embeds the commit-message prompt editor directly in
the settings pane. The prompt is a long monospaced text value stored in
`AppConfig.changes.prompt` and used by the Changes sparkle action when generating
commit messages.

The inline editor consumes much of the Settings pane and auto-saves as the user
types. Moving it into a dedicated window will make Settings easier to scan and
make prompt editing feel like an intentional edit session.

## Goals

- Replace the inline prompt `TextEditor` in Settings -> Changes with a compact
  status row and an Edit button.
- Open a separate Commit Prompt window from that Edit button.
- Use a local draft in the editor window so prompt edits are applied only on
  Save.
- Keep the implementation aligned with existing SwiftUI settings/window
  patterns.

## Non-Goals

- No prompt preview panel.
- No multi-section prompt editor navigation.
- No prompt templates, validation rules, or commit-message test runner.
- No changes to the AI tool picker behavior.

## User Experience

Settings -> Changes keeps the current Tool row. The Prompt row becomes compact:

- Row title: `Prompt`
- Description: `Instructions sent to the CLI. The staged diff is appended on stdin.`
- Controls: `Edit` button aligned to the settings control column.
- Status chip: hidden when the stored prompt equals
  `AppConfig.defaultCommitPrompt`; right-aligned with text `Custom` otherwise.

Pressing `Edit` opens a dedicated `Commit Prompt` window. The window uses the
focused editor layout:

- titlebar/chrome consistent with the Settings window
- short heading and helper text
- large monospaced editor
- `Reset to Default`
- footer actions: `Cancel` and `Save`

The editor is draft-based. Opening the window copies
`state.config.changes.prompt` into local view state. Typing changes only the
draft. `Reset to Default` changes only the draft. `Cancel` closes the window
without saving. `Save` writes the draft to `state.config.changes.prompt`, calls
`state.saveConfig()`, and closes the window.

## Architecture

Add a new SwiftUI view under `Alas/Sources/Settings/` named
`CommitPromptEditorWindow`.

`AlasApp` adds a second settings-related scene:

```swift
Window("Commit Prompt", id: "commit-prompt-editor") {
    CommitPromptEditorWindow(state: state)
}
.windowStyle(.hiddenTitleBar)
.windowResizability(.contentSize)
.defaultSize(width: 720, height: 560)
```

`ChangesPane` reads `@Environment(\.openWindow)` and calls:

```swift
openWindow(id: "commit-prompt-editor")
```

from the Prompt row's Edit button.

`CommitPromptEditorWindow` receives `@Bindable var state: AppState`, reads the
current theme from `state.themeStore.current`, applies it through the existing
theme environment pattern, and uses `WindowConfigurator()` so the chrome matches
the Settings window. It owns local draft state:

```swift
@State private var draftPrompt = ""
```

The draft is initialized from config in `onAppear`. Save assigns the draft to the
config and persists it.

## Component Boundaries

- `ChangesPane`: owns the compact Settings row and window-launch action. It does
  not manage prompt edit drafts.
- `CommitPromptEditorWindow`: owns the prompt edit session, including draft,
  reset, save, cancel, and window close behavior.
- Prompt status helper: a small pure helper maps stored prompt text to no chip
  for the default prompt or `Custom` for custom prompts.

## Error Handling

`state.saveConfig()` currently returns `Bool`, but the existing Settings UI does
not expose save failures. This change will follow the current app behavior:
attempt the save and close after assigning the config. If a future settings save
error surface is added, this window can adopt it.

## Testing

Use focused tests where they add value:

- If a prompt status helper is extracted, add Swift Testing coverage for:
  - default prompt -> no status chip
  - modified prompt -> `Custom`
- Existing `AppConfigChangesTests` already cover prompt persistence. Leave them
  unchanged because the data model is not changing.

Full SwiftUI window behavior will be verified through the required project build
and test commands rather than brittle UI tests.

## Verification

After implementation, run:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```
