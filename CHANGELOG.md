# Changelog

All notable changes to alas are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.2] - 2026-05-28

### ✨ Features

- Add a uniform chip row across agents (#328).
- Add a terminal/chat selector to the new worktree dialog (#324).
- Add a toggle to disable cross-quit session persistence (#323).

### 🐛 Fixes

- Isolate terminal session restore state (#326).
- Use a consistent loading spinner UI (#327).
- Route the language selector settings link to the Code section (#325).

## [0.4.1] - 2026-05-28

### 🐛 Fixes

- Fix Gatekeeper detection so only actually quarantined language server binaries are reported as blocked (#321).
- Re-probe Gatekeeper-blocked LSP availability instead of caching stale blocked states after user approval or quarantine removal (#322).

## [0.4.0] - 2026-05-27

### ✨ Features

- Add persistent terminal sessions across app quit via bundled zmx (#317).
- Add a vendor-neutral ACP chat pane (#316).
- Add a shortcut to focus the current project's main worktree (#318).
- Add worktree empty state agent entrypoints (#320).
- Add a fetch-remote-before-create-worktree setting (#315).

### 🐛 Fixes

- Hide the draft commit prompt when no changes are staged (#313).
- Refine the Changes tab visual design (#314).
- Show agent logos in harness notifications (#319).

## [0.3.14] - 2026-05-26

### ✨ Features

- Add tree-sitter syntax highlighting for YAML, JSON, TOML, Python, Rust, Go, Bash, JavaScript, TypeScript, TSX, Java, Kotlin, C, and C++ (#289, #290, #291, #292, #293, #294, #295, #296, #297, #298, #299, #300, #301).
- Replace the inline commit composer with a center-pane Draft commit tab (#310).
- Add a line number gutter to the code editor (#307).
- Show LSP status in the editor breadcrumb (#302).
- Handle macOS Gatekeeper-blocked language servers with an install/status nudge (#308).
- Add extra terminal arguments to agent settings (#312).
- Make the file breadcrumb clickable to reveal files in the Files tab (#304).

### 🐛 Fixes

- Save commit edits with Cmd+Enter from the title or description fields (#305).
- Disable format-on-save by default while preserving explicit preferences (#306).
- Re-apply the editor base style after watcher-driven revert events (#309).
- Address review feedback across the highlighting language stack (#303).

### 🏗️ Internal

- Cache Xcode SwiftPM packages in CI (#311).

## [0.3.13] - 2026-05-25

### ✨ Features

- 3-way merge editor redesign (IntelliJ-style) (#286).
- Add live commit editor (#288).
- bulk agent resolve + editable prompts + tab polish (#284).
- merge-conflicts UX followups (#281).
- use Nerd Font icons for special folders in files sidebar (#280).
- agent assist + special conflict kinds for merge editor (#278).
- clickable base branch selector in commits header (#275).
- three-column merge editor in the center pane (#276).
- detect and orchestrate git merge conflicts in the right pane (#273).
- sync terminal tab title with terminal OSC title (#272).
- allow dropping projects to empty bottom area to reorder last (#267).
- show agent icons in picker dropdowns and rename Tool to Agent (#264).

### 🐛 Fixes

- selector header spacing (#283).
- folder icon review feedback (#282).
- align conventional commit verb chip to first-line baseline (#279).
- strip trailing period from Ghostty file links when file not found (#274).
- clamp agent logo icons in settings pickers to 14pt (#269).
- show full bypass permissions description in Settings Agents (#266).

### 🏗️ Internal

- parse diffs off the main thread (#270).

## [0.3.12] - 2026-05-23

### ✨ Features

- parallelize macOS release builds for arm64 and x86_64 (#261).
- hide the left sidebar with Cmd-B (#263).

### 🏗️ Internal

- verify the published Homebrew cask during release.
- rename Advanced settings to Debug and move it last in the settings sidebar (#262).

## [0.3.11] - 2026-05-23

### ✨ Features

- add LSP-backed editor autocomplete (#257).
- add a breathing opacity animation to terminal tab icons for activity state (#258).
- redesign LSP hover with a dwell trigger and shared overlay panel (#259).
- refresh behind chips when HEAD changes (#255).
- expand the conventional commit detector verbs (#260).

### 🐛 Fixes

- resolve terminal Cmd-click links against the current working directory and worktree root (#254).

### 🏗️ Internal

- optimize Ghostty cache usage in the release workflow (#253).

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
