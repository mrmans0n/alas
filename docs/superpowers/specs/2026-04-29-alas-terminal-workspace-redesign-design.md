# Alas Terminal Workspace Redesign Design

Date: 2026-04-29

## Goal

Redesign Alas into a macOS-first terminal workspace for Git worktrees. V1 should ship a daily-usable, Ghostty-backed terminal experience inside a polished desktop shell inspired by Superconductor, while preserving the existing repository and worktree management features.

The long-term direction is terminal-emulator quality on par with Ghostty plus richer project and AI-agent workspace affordances. V1 starts with the terminal core and a redesigned project shell.

## Non-goals for V1

- Split panes.
- Restoring terminal tabs after app restart.
- Full command palette implementation.
- Rich non-terminal agent, chat, or document tabs.
- Linux or Windows parity.
- Pixel-perfect Superconductor cloning.

## Product Shape

Alas uses a three-pane desktop layout:

1. **Left Worktree Navigator**: repository and worktree navigation, with all current management actions preserved.
2. **Center Hybrid Workspace**: multiple persistent terminal tabs per selected worktree in V1, with room for future non-terminal tabs.
3. **Right Project Inspector**: Files and Git Changes tabs for the selected worktree.

The visual language should be Superconductor-inspired but distinct: dark, calm, spatially clear, and desktop-native.

## Architecture

Keep the app organized around testable boundaries rather than embedding terminal or Git logic directly in GPUI views.

### UI Shell

The shell coordinates selection, layout, focus, and pane visibility:

- left navigator state
- center workspace tab state
- right inspector state
- app-level action dispatch
- terminal focus and keyboard routing

Start from the existing GPUI app because the codebase already uses it. Before investing deeply in terminal rendering UI, run a feasibility gate for terminal-grade capabilities: custom cell rendering, high-frequency repaint, keyboard/text input fidelity, trackpad/mouse scroll, context/overflow menus, focus handling, and selection/copy. If GPUI cannot satisfy those requirements without fighting the framework, V1 may switch to another Rust UI stack that can, while preserving the app/domain/terminal backend boundaries in this spec.

### Terminal Engine Layer

Make Ghostty VT/rendering a required V1 path. The current `TerminalBackend` boundary should remain, but the model it returns must evolve from plain text lines to a real terminal render model.

Required render data includes:

- styled cells
- foreground/background colors
- cursor position and style
- terminal dimensions
- scrollback and viewport state
- alternate-screen state
- lifecycle status

Do not silently fall back to raw escape-code text when Ghostty VT fails. A Ghostty VT/rendering failure should fail the affected terminal tab clearly.

### State Model

Introduce or extend these concepts:

#### `WorkspaceSession`

Tracks:

- selected repo/worktree
- terminal tab sets per worktree
- active tab per worktree

#### `TerminalTab`

Tracks:

- stable tab id
- display name
- command spec
- cwd
- backend session id
- runtime status
- scroll offset / viewport state
- optional user-renamed title

Each terminal tab owns one PTY process and Ghostty VT state.

#### `ActionRegistry`

Defines repo/worktree actions once so multiple surfaces can use them:

- context menus in V1
- overflow menus in V1
- command palette later

Action metadata should include labels, availability, destructive/confirmation requirements, and execution handler identity.

#### `ProjectInspectorState`

Tracks:

- selected inspector tab: Files or Changes
- file tree loading/error state
- git changes loading/error state

Files and Changes failures are independent and should not disrupt terminal sessions.

## Terminal Behavior

V1 upgrades the terminal pane from a text output view to a terminal emulator surface.

Each terminal tab owns:

- PTY process
- Ghostty VT state
- scrollback
- current viewport/scroll offset
- cursor state
- selection/copy state, if implemented in V1
- title/name
- command spec and cwd
- lifecycle status: running, exited, failed, restarting

V1 must support:

- ANSI, 256-color, and truecolor styling through Ghostty VT
- proper control-code handling with no raw escape noise
- shell editing, arrows/history, backspace/delete, Ctrl keys, and Option/Alt where feasible on macOS
- resize propagation from GPUI pane to PTY and Ghostty VT
- mouse/trackpad scrollback
- alternate-screen apps: `less`, `vim`/`nvim`, `top`/`htop`
- cursor rendering
- long-running AI-agent sessions such as `claude` or `codex`, preserving output when switching tabs or worktrees

## Terminal Tabs

V1 supports multiple named terminal tabs per worktree.

Behavior:

- Selecting a worktree resolves that worktree's tab set.
- If no tabs exist for the selected worktree, create a default terminal tab.
- The default tab launches the repo default command or a plain shell.
- New tabs can launch configured repo commands.
- Tab labels and command choice UI should make room for future agent presets: Shell, Claude, Codex, Gemini, Tests, and similar commands.
- Tabs persist while the app is running.
- App restart opens fresh; restoring tab definitions or scrollback is roadmap only.

The tab model should avoid assumptions that block later support for split panes, terminal search, themes, bracketed paste, mouse reporting, configurable keybindings, or platform expansion.

## UI Layout and Interactions

### Left Worktree Navigator

Replace the current button-heavy sidebar with a cleaner navigator.

Show:

- repo sections with compact headers
- worktree rows with branch icon/name
- active row selection
- status indicators for dirty, archived, unavailable, and stale states
- diff counts where available
- last activity where available

Preserve all current actions:

- add repository
- remove repository
- create worktree
- remove worktree
- archive/unarchive worktree
- prune worktrees
- show/hide archived worktrees
- command settings

Move advanced and destructive actions out of always-visible chip rows into context menus and overflow menus. Destructive actions keep confirmations.

Use a shared action registry so a future command palette can expose the same operations by keyboard.

### Center Hybrid Workspace

The center pane is a focused workspace card.

V1 includes:

- terminal tab bar
- new-tab affordance
- command picker for configured commands
- terminal emulator body
- subtle exited/restart state
- inline startup failure state

Future non-terminal tabs should be able to reuse the same frame for agent chat, codebase overview, logs, or other document-like views.

### Right Project Inspector

V1 includes two tabs:

- **Files**: tree rooted at the selected worktree.
- **Changes**: current Git status/changed files, evolved from the existing inspector.

States:

- no worktree selected
- worktree unavailable
- loading
- empty
- error

Files and Changes should load and fail independently.

### App Chrome

Use shared dark theme tokens for:

- pane backgrounds
- card backgrounds
- borders
- selected rows
- muted text
- warning/error states
- terminal colors where app chrome participates

Add a bottom status bar with active repo, worktree, tab, and lightweight terminal status. Keep top/floating controls purposeful rather than ornamental.

## Data Flow

### Worktree Selection

1. User selects a worktree in the left navigator.
2. App updates the selected worktree in `WorkspaceSession`.
3. App resolves the selected worktree's terminal tab set.
4. If no terminal tab exists, app creates the default tab.
5. App starts or reuses the active tab's backend session.
6. Right inspector begins loading Files and Changes for the selected worktree.

### Terminal Rendering

1. PTY reader collects process output bytes.
2. Backend feeds bytes into Ghostty VT.
3. UI asks backend for a render snapshot for the active tab.
4. Snapshot returns styled cells, cursor, dimensions, scrollback/viewport, alternate-screen state, and lifecycle status.
5. GPUI terminal view renders the grid.
6. Keyboard, mouse, scroll, resize, and focus events route back to the active terminal tab/backend session.

### Inspector Loading

- Files tab reads directory entries from the selected worktree.
- Changes tab uses the existing Git inspector service.
- Errors are scoped to the inspector pane and do not interrupt terminal input or terminal session lifetime.

## Error Handling and Resilience

### Terminal Failures

- **Startup failure**: show inline error in the terminal card with command, cwd, cause, Retry, and Edit Command actions.
- **PTY read/write failure**: mark only that tab as failed; other tabs and worktrees remain usable.
- **Process exit**: keep final screen/scrollback visible and show exit status with Restart.
- **Ghostty VT/rendering failure**: fail the affected tab clearly; do not fall back to raw escape text.
- **Resize failure**: show subtle tab-level warning and retry on next resize/render.

### UI and Data Failures

- Unavailable repos/worktrees remain visible but de-emphasized.
- Files and Changes panes have independent loading, error, and empty states.
- Destructive actions require confirmation.
- Context menu actions are disabled or hidden when invalid for the selected row.
- Right pane failures do not steal terminal focus.

## Testing and Acceptance

### Automated Tests

Extend tests around:

- terminal tab model
  - multiple tabs per worktree
  - active tab per worktree
  - switching worktrees preserves running tabs
  - default tab creation
- terminal backend API
  - start/write/resize/snapshot/restart per tab
  - failed backend operations affect only one tab
  - Ghostty VT required; no raw fallback path
- action registry
  - all repo/worktree actions remain available
  - destructive actions include confirmation metadata
- inspector state
  - Files and Changes tab state/errors are independent

### Manual Acceptance Checks

On macOS, run the app and verify:

- shell basics: prompt editing, arrows/history, backspace/delete, Ctrl-C, resize
- color/control codes: ANSI 16-color, 256-color, and truecolor output render correctly with no raw escape sequences
- scrollback: mouse/trackpad scrolling, long output, and copy/selection if implemented in V1
- alternate-screen apps: `less`, `vim`/`nvim`, `top`/`htop`
- AI-agent sessions: `claude`/`codex` if installed, with long output preserved when switching tabs/worktrees
- multi-tab behavior: create multiple named tabs in one worktree, switch worktrees, return without losing sessions
- UI behavior: all existing repo/worktree actions are available through context/overflow menus

## Roadmap

After V1, the architecture should support:

- split panes
- restoring terminal tab definitions after restart
- restoring scrollback snapshots where feasible
- command palette backed by the action registry
- rich non-terminal agent/chat/document tabs
- terminal search
- bracketed paste
- mouse reporting
- configurable keybindings
- themes
- Linux and Windows support
- deeper Ghostty parity work
