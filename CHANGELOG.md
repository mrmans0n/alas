# Changelog

All notable changes to alas are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.10] - 2026-05-22

### ✨ Features

- redesign the Ghostty dead-key keyboard pipeline (#243).
- flatten Cmd-K into a grouped worktree selector (#246).
- add Kotlin LSP diagnostics support (#252).
- show a right-pane nudge when a worktree is behind its upstream branch (#251).

### 🐛 Fixes

- shrink agent logos in the tab bar menu (#244).
- resolve symlinks when opening files from the file tree (#245).
- stabilize right sidebar tree chevrons (#247).
- replace tab activity dots with stable tinted terminal icons (#248).
- stabilize worktree row height when status badges appear (#249).
- apply code font settings to diff panes (#250).

### 🏗️ Internal

- revise the documented system requirements.
- clean up generated Homebrew cask stanza grouping.

## [0.3.9] - 2026-05-22

### ✨ Features

- add terminal file-link routing with line and column positions (#222).
- add a context-menu action to delete a worktree while keeping its branch (#224).
- render markdown frontmatter as a metadata table in previews (#226).
- add vendor logos to terminal agents UI (#227).
- add advanced project cleanup settings behind the debug flag (#230).
- add image diff side-by-side, overlay, swipe, and difference modes (#231).
- show a purple submodule badge on directories in the Files pane (#232).
- add right sidebar toggle shortcut support (#236).

### 🐛 Fixes

- resolve symlinks before computing optimistic worktree IDs (#223).
- refresh terminal integration actions after install state changes (#228).
- prevent invalid git ref input for branch names and prefixes while leaving manual refs to Git validation (#229).
- polish image diff alignment, rename detection, and SVG support (#233).
- replace Files tree loading rows with inline loading indicators (#234).
- move the hidden-sidebar reveal control to the center header (#235).

### 🏗️ Internal

- release pipeline now publishes both arm64 and x86_64 DMGs; Homebrew cask serves both via `on_arm`/`on_intel`.

## [0.3.8] - 2026-05-21

### ✨ Features

- add Harness entry point from Agents settings (#208).
- add agent terminal launcher (#214).
- enable drag-to-reorder for center pane top tabs (#219).
- add drag-and-drop reordering for sidebar projects (#220).
- expand agent hook lifecycle support (#221).

### 🐛 Fixes

- broaden LSP install nudges with Mason fallback (#209).
- allow text selection in diff panes (#212).
- fix initial focus for command overlays (#216).
- make commit errors expandable (#218).

### 🏗️ Internal

- clarify Mason LSP search field (#210).
- reduce cursor-agent hook overhead and clean up harness on quit (#211).
- decouple agent bypass setting (#213).
- show copy feedback for git references (#215).
- share GhosttyKit builds across worktrees via fingerprint-keyed cache (#217).

## [0.3.7] - 2026-05-20

### ✨ Features

- add an `ao` shortcut for `alas open` (#194).
- add Cmd-K "Switch Repository" dialog (#195).
- add Files tab context menu to show or hide ignored files (#196).
- add customizable keyboard shortcuts in Settings (#197).
- add Cmd-D add-next-occurrence and Option-Shift-drag column selection (#198).
- add Archive action to failed worktree delete state (#200).
- expand commit details when clicking a commit header (#202).
- add sidebar contrast sliders (#204).
- show hook install nudge for supported terminal agents (#207).

### 🐛 Fixes

- fix right-pane reveal icon visibility and hide the button on the right pane (#193).
- fix half-dark first-launch appearance in light mode (#199).
- route Ghostty Cmd-click on workspace files to the Alas editor (#201).
- add more inter-line spacing to central-panel text surfaces (#203).
- fix Files sidebar flicker for nested ignored and excluded folders (#205).
- enlarge small touch targets (#206).

### 🏗️ Internal

- remove language server prerequisites from the README.
- forbid agent attributions in commits, PRs, and code.

## [0.3.6] - 2026-05-19

### ✨ Features

- add Alas terminal CLI support for opening files from agent/tooling flows (#189).
- show ignored files in the Files tab (#192).
- add Working Tree UI improvements: safe discard, per-hunk actions, and file context menu actions (#191).

### 🐛 Fixes

- fix repo sidebar chevron alignment (#190).

## [0.3.5] - 2026-05-18

### 🐛 Fixes

- fix tab drag reordering after separating tab drag from window drag (#186).
- hide the new worktree branch error while only the required prefix is typed (#187).
- handle missing Git LFS during worktree removal (#188).

## [0.3.4] - 2026-05-18

### ✨ Features

- add reveal control for auto-hidden right sidebar (#181).
- add context-menu Ignore action for untracked files and folders in the right pane (#182).
- allow tab drag-and-drop without dragging the window (#185).

### 🐛 Fixes

- preserve dirty-move snapshot cache fallback when rejected (#171).
- bound LSP shutdown wait for unresponsive servers (#172).
- report character columns for non-ASCII search matches (#173).
- reset commit diff state when loading commits (#174).
- clear stale commit details before loading commit (#175).
- SIGKILL child processes after SIGTERM grace period (#176).
- keep existing theme state if theme load fails (#177).
- run Codex AI commit in the worktree and skip trust check (#178).
- fix shifted TUI input in terminal sessions (#179).
- handle unmerged status paths containing spaces (#180).
- trim whitespace when saving agent and language server configs (#183).
- keep file and directory entries with the same name in the file tree (#184).

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
