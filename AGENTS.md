# AGENTS.md - alas

## Project
- Repo: `mrmans0n/alas`
- Stack: Swift 5.9+ / SwiftUI macOS app, terminal via Ghostty Swift package
- Purpose: native workspace for git repos, linked worktrees, files, git changes, and persistent terminals — opinionated AI harness manager

## Development rules
- Keep code, comments, logs, and UI strings in English.
- Prefer small, reviewable changes with tests when practical.
- Tests use the Swift Testing framework (`import Testing`), not XCTest.
- After editing `project.yml`, regenerate the Xcode project with `xcodegen` and commit both files.
- `Info.plist` keys are pinned in `project.yml` under `info: properties:` — edit there, not the plist.
- Do not introduce large architectural changes without an explicit plan.

## Before finishing a change

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```
