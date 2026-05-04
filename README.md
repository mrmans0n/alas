# Alas

Native macOS app for working across git repositories, linked worktrees, project files, git changes, and long-lived terminal sessions from one workspace. Personalized, opinionated AI harness manager.

## Stack

Swift 5.9+ / SwiftUI on macOS 14.0 Sonoma+. Terminal embedded via the official Ghostty Swift package. Single Xcode app target generated from `project.yml` via [xcodegen](https://github.com/yonaskolb/XcodeGen).

## Develop

Prerequisites:

- macOS 14.0 Sonoma or later.
- Xcode 15.4+.
- `xcodegen` (`brew install xcodegen`).

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Open the project in Xcode for normal development; rerun `xcodegen` after any change to `project.yml`.

## Layout

```
Alas/
  Resources/        # Info.plist, asset catalog, theme JSON
  Sources/
    App/            # entry point, state, window chrome
    Sidebar/        # repo + worktree list
    Center/         # tab bar + tab views (terminal/editor/diff)
    Right/          # changes + files
    Layout/         # ThreePaneLayout, DragHandle
    Persistence/    # JSON store, AppConfig, ProjectConfig
    Theme/          # OKLCH parser, themes, environment
    Settings/       # settings window
    Dialogs/        # New project, New worktree, Empty state
    Terminal/       # Ghostty embed, sessions
    Git/            # GitService, WorktreeService
    Harness/        # detection, hook watcher, notifications
    UI/             # shared components
    Icons/          # icon set
AlasTests/          # Swift Testing framework
project.yml         # xcodegen manifest
```
