# Alas UI Overhaul Design

Date: 2026-04-30

## Goal

Overhaul the Alas UI into a macOS-first, frameless, three-column workspace inspired by Superconductor while preserving the existing terminal, repository, worktree, file, and Git behavior.

The target layout is:

```text
[ repo/worktree tree ][ flush terminal/main pane ][ grouped files/git tree ]
```

The center terminal is the visual anchor. It should run top-to-bottom with no persistent title strip, no workspace card, no full-width status bar, and no always-visible worktree label.

## Non-goals

- Pixel-perfect Superconductor cloning.
- Linux frameless/custom titlebar parity in this pass.
- Replacing the terminal backend, session model, Git services, or file tree service.
- Building a full file explorer with file open/edit/rename/delete actions.
- Introducing split panes or a broader terminal workspace redesign beyond hover tabs.
- Large architectural rewrites unrelated to the requested UI overhaul.

## Design Approach

Use an incremental component modernization approach.

Keep the existing `AlasShell`, app model, terminal backend/session code, Git services, and file tree service. Refactor the GPUI view surfaces around them:

- left repository sidebar moves to `gpui-component` tree/menu/popover primitives where feasible,
- right inspector becomes a single grouped tree,
- center workspace becomes a flush terminal column with hover terminal tabs,
- contextual menus move from inline blocks to popovers.

This minimizes risk to terminal behavior while delivering the requested look and component migration.

## Product Shape and Visual Direction

Alas becomes a macOS-first frameless desktop app with three persistent columns.

The visual language is strongly Superconductor-inspired: dark calm surfaces, compact typography, subtle borders, rounded controls where they help, and icon-first utility controls. Alas should still feel distinct, primarily through its true flush terminal center column.

On macOS, remove or replace the normal titlebar where GPUI supports it. Reserve only a small top-left safe/chrome area for the traffic-light buttons, positioned approximately 20px from the top. The center terminal and right sidebar start at the top edge.

Window dragging is scoped to the top-left safe/chrome region. Terminal content, tree rows, and other interactive controls should not become accidental drag regions.

The current full-width bottom status bar is removed. Status is folded into local contextual surfaces:

- active repo/worktree state in the left tree,
- branch and changed-file metadata in the right grouped tree,
- terminal process/tab state in the hover tab overlay or inline terminal states.

## Layout and Chrome

The root shell remains a GPUI view, but its layout becomes a horizontal three-column flex row:

1. **Left sidebar**: fixed-width repository/worktree tree, dark sidebar surface, top-left macOS safe area.
2. **Center pane**: flexible true flush terminal surface.
3. **Right sidebar**: fixed-width grouped files/Git tree.

Remove the current `render_status_bar` from the default layout. Remove the current center `render_workspace` rounded card and persistent tab bar.

The center pane should fill all available vertical space. Any terminal tabs or tab actions are overlays, not structural chrome.

### macOS Frameless Gate

Include an implementation spike/gate for exact frameless behavior. Use GPUI window options or platform APIs if available. If exact titlebar removal is constrained, keep the titlebar/custom chrome work isolated so the main three-column layout can land without coupling sidebar or terminal code to platform-specific APIs.

Linux can keep conventional window chrome for now.

## Left Repository Sidebar

The left sidebar becomes a `gpui-component`-based collapsible tree.

### Structure

- Repository nodes are top-level tree parents.
- Worktrees are child rows.
- Repository rows show compact identity: repo name, unavailable state when relevant, and an overflow/context affordance.
- Worktree rows show branch/worktree name, main/linked/archived state, selection state, and practical Git metadata where available.
- Archived worktrees stay hidden unless “show archived” is enabled for that repository.

### Actions

Preserve existing actions:

- add repository,
- remove repository,
- create worktree,
- remove worktree,
- archive/unarchive worktree,
- prune worktrees,
- show/hide archived worktrees,
- command settings.

Right-click and overflow controls open contextual menus through the existing `ActionRegistry`. Menus should render as `gpui-component` popovers/menus instead of inline blocks inserted into the sidebar layout.

### Add Repository Control

Replace the current labeled primary button with an icon-only image button at the bottom of the left sidebar.

Use built-in `gpui-component` icons/buttons first. Add custom local SVG assets only when they materially improve visual quality. On hover/focus, show a tooltip or popover label such as “Add repository.” Add-repository errors remain visible near the bottom control, styled compactly.

## Right Grouped Inspector Tree

The right sidebar becomes a single grouped tree instead of Files/Changes tabs.

### Top Context

Show selected branch or detached-head state and a compact changed-file count/status summary when available. If no worktree is selected, show a quiet empty state.

### Sections

The tree has two primary sections.

#### Changed

- Lists changed files from the Git inspector.
- Shows status badges such as `M`, `A`, `D`, and `U` where available.
- Shows “No changed files.” when clean.
- Shows Git inspector loading/error state independently of file loading.

#### Files

- Shows the loaded file tree rooted at the selected worktree.
- Uses tree indentation and expand/collapse affordances.
- Uses `gpui-component` tree where feasible, with custom row rendering for file/directory icons and status.
- Shows file tree loading/error state independently of Git changes.
- Keeps truncation visible as a muted “additional entries hidden” row.

### Scope

This pass can add practical metadata if it is already available or cheap to compute, but should not become a full file explorer. File opening/editing/actions are not required unless they already exist.

The current file tree service loads to a depth and node budget. The UI should include expanded/collapsed row state, but implementation may initially render loaded nodes only and avoid recursive filesystem loading on expansion unless explicitly planned.

## Terminal/Main Pane

The terminal pane is the app’s visual anchor.

### Main Surface

- Remove the persistent `Worktree: ...` label.
- Remove the surrounding workspace card chrome.
- Terminal canvas fills the center column from top to bottom.
- Terminal background should read as the center column, not as a nested panel.
- Clicking the terminal focuses it.

Keyboard, mouse, scroll, paste, resize, and focus behavior continue to route through the existing terminal backend/session code.

Removing chrome must not reduce terminal cell measurement accuracy. Bounds probing must measure the actual drawable terminal area.

### Terminal Tabs

Terminal tabs remain per worktree.

The tab strip becomes an overlay anchored to the top edge of the center column. It appears on hover/focus and can also appear when:

- there is more than one terminal tab,
- a terminal exits or fails,
- the user invokes a tab-related action.

The new-tab control lives in this overlay. Tab labels stay compact and may include command/agent prefixes.

### Terminal States

- **No worktree selected**: show a centered, low-chrome empty state.
- **Startup or I/O failure**: show an inline failure panel with command, cwd, cause, Retry, and Edit Command, without restoring a full workspace header.
- **Process exited**: preserve the final terminal screen. Expose restart/status in the hover tab overlay or a subtle inline overlay, not a persistent top bar.

## State and Data Flow

Data flow remains close to today.

### Worktree Selection

1. User selects a worktree in the left tree.
2. The app updates the selected worktree in the model.
3. The app resolves or creates the selected worktree’s active terminal tab.
4. The app starts or reuses the terminal backend session.
5. The app clears inspector state and refreshes files and Git changes.
6. The right grouped tree updates from `InspectorPaneState` and selected worktree metadata.

### Actions and Menus

Left tree row actions dispatch through the existing `ActionRegistry`. The same action availability and destructive/confirmation behavior should be preserved. Popover/menu state is UI-layer state, not domain state.

### UI State Additions

Add or adapt UI state for:

- expanded/collapsed repository nodes,
- expanded/collapsed file tree nodes,
- active contextual popover/menu target,
- hover/focus visibility for terminal tabs.

Keep these states in the UI layer unless a value needs to persist beyond the current view/session.

### Assets

If custom icons are added, keep them under `assets/` and reference them through a small UI helper. Prefer `gpui-component` built-ins and text/icons already available before adding assets.

## Error Handling

- Repository unavailable state remains scoped to its repository row.
- Add-repository errors remain local to the bottom add control.
- Worktree action failures use existing dialogs/errors where possible.
- File tree errors appear only in the Files section.
- Git inspector errors appear only in the Changed section.
- Terminal errors remain per active terminal tab and do not break sidebar interaction.
- Destructive actions keep confirmations.

## Testing and Verification

Add or update tests for UI-independent state transformations where practical:

- tree expansion state,
- grouped inspector row construction,
- action/menu availability from `ActionRegistry`,
- preservation of terminal tab/session behavior after layout refactoring.

Existing tests for the app model, file tree, Git inspector, workspace session, terminal sessions, and terminal rendering should continue passing.

Update `docs/manual-test.md` to cover:

- macOS frameless/custom chrome and traffic-light safe area,
- hover terminal tabs and new-tab control,
- true flush terminal with no persistent worktree label,
- left repo/worktree tree expansion and context popovers,
- right grouped Changed/Files tree,
- icon-only add repository button and hover label,
- absence of the old full-width status bar.

Before finishing implementation, run the relevant project checks:

```bash
cargo fmt --all -- --check
cargo clippy --all-targets --all-features -- -D warnings
cargo build --all-features
cargo test --all-features
```
