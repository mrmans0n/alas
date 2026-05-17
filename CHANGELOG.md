# Changelog

All notable changes to alas are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.3] - 2026-05-17

### ✨ Features

- add Remove Project context-menu entry (#156).
- add NSTextInputClient integration for dead keys, IME, and Opt+Delete (#165).

### 🐛 Fixes

- render search line numbers without locale grouping (#155).
- only enable available agents whose binary is installed (#157).
- use UTF-8 byte offsets for tree-sitter InputEdit (#158).
- expand untracked directories in Changes (#160).
- reject decoded pane splits without exactly two children (#161).
- commit latest cursor idle harness event after debounce (#163).
- guard against pid overflow when decoding agent hook events (#164).
- drop stale LSP hover, definition, and symbols responses (#166).
- report persistence save failures from AppState (#167).
- use stdin mode for Codex commit messages (#168).
- cancel ProjectGitWatcher async start after stop (#169).
- restore editor buffer snapshot path after dirty move (#170).

### 🏗️ Internal

- inject PATH via parameter in agent tests instead of mutating the environment (#159).
- support concurrent waiters in EventHolder tests (#162).

## [0.3.2] - 2026-05-17

### ✨ Features

- add multi-cursor editing in editor panes (#153).
- add LSP format on save (#151).

### 🐛 Fixes

- pass unknown icon names through as SF Symbol names (#152).

### 🏗️ Internal

- sort Settings sections alphabetically and remove empty General section (#154).

## [0.3.1] - 2026-05-16

### ✨ Features

- add changelog-driven release notes (#150).

### 🐛 Fixes

- handle submodule worktree delete failures (#149).

## [0.1.1] - 2026-05-15

### 🏗️ Internal
- Detect new Alas cask file in release workflow.
