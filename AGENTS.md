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
- Do not add agent attributions of any kind: no `Co-Authored-By: Claude` (or any other model/tool) trailers in commits, no "Generated with Claude Code" footers in PR/MR descriptions, no "🤖" markers, no "this was written by an AI" notes in code, comments, docs, or commit/PR bodies. Commits and PRs should read as if written by the human author.

## Before finishing a change

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```
