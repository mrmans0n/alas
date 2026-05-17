# Alas

**Every agent. Every worktree. One window.**

Spin up agents across worktrees, hop between them like browser tabs, and keep the terminal, diff, and files in one place. Native macOS, built on [libghostty](https://github.com/ghostty-org/ghostty).

> Requires macOS 14 Sonoma or later. Apple Silicon only.

## Install

```bash
brew install --cask mrmans0n/tap/alas
```

Or grab the signed DMG from [Releases](https://github.com/mrmans0n/alas/releases/latest).

## Why Alas

Coding agents are most useful when you can run several of them — one per worktree, one per branch, one per experiment — and review their work without context-switching across windows. Alas is the workspace for that flow: a three-pane macOS app that keeps every project, every worktree, every terminal session, and every diff side-by-side, with first-class support for the harnesses you already use.

## Features

- **Parallel worktrees, one window.** Every repo lives in the sidebar with all its linked worktrees underneath. Switching is instant; your terminal sessions, tabs, and scroll positions persist per worktree.
- **Long-lived terminals.** Ghostty under the hood. Sessions survive window changes and worktree switches — no more re-running `claude` or `codex` after every context shift.
- **Git that gets out of the way.** Right-pane changes list with file-level staging, inline diffs, AI-drafted commit messages, and a commit composer that doesn't make you leave your editor.
- **Harness-aware.** Detects Claude Code, Codex, and other agent harnesses running in your worktrees and surfaces their state — hook activity, project config, and per-harness watchers.
- **Tabs for everything.** Terminals, file viewers, diffs, and Markdown — open in tabs, drag to reorder, restore on relaunch.
- **Native and signed.** Signed + notarized + stapled. No Gatekeeper popups, no quarantine flags.

## Develop

Prerequisites: macOS 14 Sonoma+, Xcode 15.4+, `brew install xcodegen`.

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Open the project in Xcode for normal development; rerun `xcodegen` after any change to `project.yml`. See [AGENTS.md](AGENTS.md) for contributor conventions.

## Stack

Swift 5.9+ / SwiftUI on macOS 14+. Terminal embedded via the official Ghostty Swift package. Tree-sitter for syntax. Swift-markdown for rendering. Single Xcode app target generated from `project.yml` via [xcodegen](https://github.com/yonaskolb/XcodeGen).

## Language Server Prerequisites

Alas bundles built-in language server presets, but the actual servers must be installed separately. The app discovers them via `PATH`, `/usr/local/bin`, `/opt/homebrew/bin`, and common tool directories.

- **Swift** – bundled with Xcode (`sourcekit-lsp`)
- **Python** – [Pyright](https://github.com/microsoft/pyright)
  ```bash
  brew install pyright
  # or: npm install -g pyright
  ```
- **Shell scripts** – [bash-language-server](https://github.com/bash-lsp/bash-language-server)
  ```bash
  npm install -g bash-language-server
  ```
  Also install [ShellCheck](https://github.com/koalaman/shellcheck) for diagnostics:
  ```bash
  brew install shellcheck
  ```
- **Rust** – `rust-analyzer`
- **TypeScript / JavaScript / JSON** – `typescript-language-server`, `vscode-json-languageserver`
- **Markdown** – `marksman`

If a server is missing, Alas opens the file as a plain text buffer and shows **Not installed** in Settings → Code. You can also override commands and environment variables per language in the same settings pane.

## License

[MIT](LICENSE).
