# Alas UI Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the approved macOS-first, Superconductor-inspired three-column UI overhaul with a collapsible repository tree, flush terminal center pane, grouped right inspector tree, contextual popovers, and icon-only add repository control.

**Architecture:** Keep the existing Alas app model, terminal backend/session code, Git services, and file tree service. Add small UI view-model helpers for testable tree/overlay state, then refactor the GPUI surfaces around `gpui-component` tree/menu/button primitives. Keep platform-specific window chrome isolated in one module.

**Tech Stack:** Rust 2024, GPUI 0.2, gpui-component 0.5.1 (`tree`, `button`, `menu`, `popover`, `IconName`), Ghostty-backed terminal renderer, existing Cargo test suite.

---

## Reference Inputs

- Approved spec: `docs/superpowers/specs/2026-04-30-ui-overhaul-design.md`
- Existing UI files:
  - `src/ui/shell.rs`
  - `src/ui/sidebar.rs`
  - `src/ui/inspector.rs`
  - `src/ui/workspace.rs`
  - `src/ui/terminal_pane.rs`
  - `src/ui/theme.rs`
- Relevant GPUI component APIs:
  - `gpui_component::tree::{tree, TreeEntry, TreeItem, TreeState}`
  - `gpui_component::list::ListItem`
  - `gpui_component::menu::{ContextMenuExt, DropdownMenu as _, PopupMenu, PopupMenuItem}`
  - `gpui_component::button::{Button, ButtonVariants}`
  - `gpui_component::{Icon, IconName, Sizable}`
- Relevant GPUI window chrome APIs:
  - `gpui::WindowOptions`
  - `gpui::TitlebarOptions`
  - `gpui::point`
  - `gpui::px`

## File Structure

Create or modify these files.

- Create `src/ui/view_models.rs`
  - Pure, testable UI helpers for tree expansion state, repo tree rows, grouped inspector rows, and terminal tab overlay visibility.
  - No GPUI element construction here.
- Create `src/ui/chrome.rs`
  - Window options for macOS transparent titlebar and traffic-light placement.
  - Constants for traffic-light safe area.
- Modify `src/ui/mod.rs`
  - Export new UI modules.
- Modify `src/ui/shell.rs`
  - Add tree state fields.
  - Use `chrome::alas_window_options()` in `run()`.
  - Compose three-column layout directly.
  - Remove full-width status bar from default render path.
  - Track terminal tab overlay hover state.
- Modify `src/ui/workspace.rs`
  - Replace rounded workspace card with flush center pane and hover/focus tab overlay.
- Modify `src/ui/terminal_pane.rs`
  - Remove persistent worktree label/top chrome.
  - Keep terminal bounds probe, error state, restart/retry flows, and focus/input hooks.
- Modify `src/ui/sidebar.rs`
  - Migrate repository/worktree display to `gpui-component` tree rows.
  - Replace inline contextual menus with popover/dropdown/context menus.
  - Replace labeled add button with icon-only button and tooltip.
- Modify `src/ui/inspector.rs`
  - Replace Files/Changes tabs with a single grouped Changed/Files tree.
- Modify `src/ui/theme.rs`
  - Add small number of reusable colors/tokens for chrome/terminal/sidebar polish.
- Modify `docs/manual-test.md`
  - Add manual checks for frameless macOS chrome, hover terminal tabs, grouped right tree, left tree menus, and icon-only add button.
- Create `tests/ui_view_model_tests.rs`
  - Tests for pure helper behavior.

Keep existing files focused. Do not move terminal backend code, Git services, or file tree loading code.

---

### Task 1: Add testable UI view models

**Files:**
- Create: `src/ui/view_models.rs`
- Modify: `src/ui/mod.rs`
- Test: `tests/ui_view_model_tests.rs`

- [ ] **Step 1: Write failing tests for view-model helpers**

Create `tests/ui_view_model_tests.rs` with these tests:

```rust
use std::path::PathBuf;

use alas::{
    app::{InspectorPaneState, RepositoryNode, SelectedWorktree, TerminalTabStatus, WorktreeNode},
    git::{ChangedFile, GitInspectorState, WorktreeKind},
    project::FileTreeNode,
    ui::view_models::{
        InspectorTreeRow, RepoTreeRow, TreeExpansionKey, TreeExpansionState,
        build_inspector_tree_rows, build_repo_tree_rows, terminal_tab_overlay_visible,
    },
};

fn worktree(path: &str, branch: &str, archived: bool, kind: WorktreeKind) -> WorktreeNode {
    WorktreeNode {
        path: PathBuf::from(path),
        branch: Some(branch.to_string()),
        head: Some("abc123".to_string()),
        kind,
        archived,
    }
}

#[test]
fn expansion_state_tracks_repository_and_file_keys() {
    let repo_key = TreeExpansionKey::Repository("repo-1".to_string());
    let file_key = TreeExpansionKey::File(PathBuf::from("/repo/src"));
    let mut state = TreeExpansionState::default();

    assert!(!state.is_expanded(&repo_key));
    state.set_expanded(repo_key.clone(), true);
    state.toggle(file_key.clone());

    assert!(state.is_expanded(&repo_key));
    assert!(state.is_expanded(&file_key));

    state.toggle(file_key.clone());
    assert!(!state.is_expanded(&file_key));
}

#[test]
fn repo_tree_rows_filter_archived_worktrees_and_mark_selection() {
    let mut expansion = TreeExpansionState::default();
    expansion.set_expanded(TreeExpansionKey::Repository("repo-1".to_string()), true);

    let repos = vec![RepositoryNode {
        id: "repo-1".to_string(),
        name: "alas".to_string(),
        path: PathBuf::from("/repo"),
        worktrees: vec![
            worktree("/repo", "main", false, WorktreeKind::Main),
            worktree("/repo/old", "old", true, WorktreeKind::Linked),
        ],
        show_archived: false,
        unavailable: false,
    }];
    let selected = SelectedWorktree {
        repo_id: "repo-1".to_string(),
        path: PathBuf::from("/repo"),
    };

    let rows = build_repo_tree_rows(&repos, Some(&selected), &expansion);

    assert_eq!(
        rows,
        vec![
            RepoTreeRow::Repository {
                id: "repo-1".to_string(),
                name: "alas".to_string(),
                unavailable: false,
                expanded: true,
            },
            RepoTreeRow::Worktree {
                repo_id: "repo-1".to_string(),
                path: PathBuf::from("/repo"),
                label: "main".to_string(),
                selected: true,
                archived: false,
                kind: WorktreeKind::Main,
            },
        ]
    );
}

#[test]
fn grouped_inspector_rows_keep_file_and_git_errors_independent() {
    let selected = SelectedWorktree {
        repo_id: "repo-1".to_string(),
        path: PathBuf::from("/repo"),
    };
    let mut state = InspectorPaneState::default();
    state.set_files_error("files down");
    state.set_changes(GitInspectorState {
        branch: Some("main".to_string()),
        changed_files: vec![ChangedFile {
            status: "M".to_string(),
            path: "src/ui/shell.rs".to_string(),
        }],
        recent_commits: Vec::new(),
    });

    let file_expansion = TreeExpansionState::default();
    let rows = build_inspector_tree_rows(Some(&selected), &state, &file_expansion);

    assert!(rows.contains(&InspectorTreeRow::Context {
        branch_label: "main".to_string(),
        changed_count: Some(1),
    }));
    assert!(rows.contains(&InspectorTreeRow::ChangedFile {
        status: "M".to_string(),
        path: "src/ui/shell.rs".to_string(),
    }));
    assert!(rows.contains(&InspectorTreeRow::Error {
        section: "Files",
        message: "files down".to_string(),
    }));
}

#[test]
fn grouped_inspector_rows_flatten_file_tree_with_truncation() {
    let selected = SelectedWorktree {
        repo_id: "repo-1".to_string(),
        path: PathBuf::from("/repo"),
    };
    let mut state = InspectorPaneState::default();
    state.set_changes(GitInspectorState {
        branch: None,
        changed_files: Vec::new(),
        recent_commits: Vec::new(),
    });
    state.set_files(FileTreeNode {
        name: "repo".to_string(),
        path: PathBuf::from("/repo"),
        is_dir: true,
        truncated: false,
        children: vec![FileTreeNode {
            name: "src".to_string(),
            path: PathBuf::from("/repo/src"),
            is_dir: true,
            truncated: true,
            children: vec![FileTreeNode {
                name: "main.rs".to_string(),
                path: PathBuf::from("/repo/src/main.rs"),
                is_dir: false,
                children: Vec::new(),
                truncated: false,
            }],
        }],
    });

    let mut file_expansion = TreeExpansionState::default();
    file_expansion.set_expanded(TreeExpansionKey::File(PathBuf::from("/repo/src")), true);
    let rows = build_inspector_tree_rows(Some(&selected), &state, &file_expansion);

    assert!(rows.contains(&InspectorTreeRow::Context {
        branch_label: "Detached HEAD".to_string(),
        changed_count: Some(0),
    }));
    assert!(rows.contains(&InspectorTreeRow::File {
        depth: 0,
        name: "src".to_string(),
        path: PathBuf::from("/repo/src"),
        is_dir: true,
        expanded: true,
    }));
    assert!(rows.contains(&InspectorTreeRow::File {
        depth: 1,
        name: "main.rs".to_string(),
        path: PathBuf::from("/repo/src/main.rs"),
        is_dir: false,
        expanded: false,
    }));
    assert!(rows.contains(&InspectorTreeRow::Truncated { depth: 1 }));
}

#[test]
fn terminal_tab_overlay_visibility_matches_design() {
    assert!(!terminal_tab_overlay_visible(false, false, 1, None, false));
    assert!(terminal_tab_overlay_visible(true, false, 1, None, false));
    assert!(terminal_tab_overlay_visible(false, true, 1, None, false));
    assert!(terminal_tab_overlay_visible(false, false, 2, None, false));
    assert!(terminal_tab_overlay_visible(
        false,
        false,
        1,
        Some(&TerminalTabStatus::Exited(Some(1))),
        false,
    ));
    assert!(terminal_tab_overlay_visible(
        false,
        false,
        1,
        Some(&TerminalTabStatus::Failed),
        false,
    ));
    assert!(terminal_tab_overlay_visible(false, false, 1, None, true));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cargo test --test ui_view_model_tests --all-features
```

Expected: FAIL because `alas::ui::view_models` does not exist.

- [ ] **Step 3: Export the new module**

Modify `src/ui/mod.rs`:

```rust
pub mod view_models;
```

Add it alongside the existing UI modules.

- [ ] **Step 4: Implement `src/ui/view_models.rs`**

Create `src/ui/view_models.rs` with the pure helper types and functions needed by the tests. Use this implementation shape:

```rust
use std::{collections::HashSet, path::PathBuf};

use crate::{
    app::{InspectorPaneState, RepositoryNode, SelectedWorktree, TerminalTabStatus},
    git::WorktreeKind,
    project::FileTreeNode,
};

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum TreeExpansionKey {
    Repository(String),
    File(PathBuf),
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct TreeExpansionState {
    expanded: HashSet<TreeExpansionKey>,
}

impl TreeExpansionState {
    pub fn is_expanded(&self, key: &TreeExpansionKey) -> bool {
        self.expanded.contains(key)
    }

    pub fn set_expanded(&mut self, key: TreeExpansionKey, expanded: bool) {
        if expanded {
            self.expanded.insert(key);
        } else {
            self.expanded.remove(&key);
        }
    }

    pub fn toggle(&mut self, key: TreeExpansionKey) {
        if !self.expanded.remove(&key) {
            self.expanded.insert(key);
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RepoTreeRow {
    Repository {
        id: String,
        name: String,
        unavailable: bool,
        expanded: bool,
    },
    Worktree {
        repo_id: String,
        path: PathBuf,
        label: String,
        selected: bool,
        archived: bool,
        kind: WorktreeKind,
    },
}

pub fn build_repo_tree_rows(
    repositories: &[RepositoryNode],
    selected_worktree: Option<&SelectedWorktree>,
    expansion: &TreeExpansionState,
) -> Vec<RepoTreeRow> {
    let mut rows = Vec::new();

    for repository in repositories {
        let key = TreeExpansionKey::Repository(repository.id.clone());
        let expanded = expansion.is_expanded(&key);
        rows.push(RepoTreeRow::Repository {
            id: repository.id.clone(),
            name: repository.name.clone(),
            unavailable: repository.unavailable,
            expanded,
        });

        if !expanded {
            continue;
        }

        for worktree in repository
            .worktrees
            .iter()
            .filter(|worktree| repository.show_archived || !worktree.archived)
        {
            let label = worktree.branch.clone().unwrap_or_else(|| {
                worktree
                    .path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .map(ToString::to_string)
                    .unwrap_or_else(|| worktree.path.display().to_string())
            });
            let selected = selected_worktree.is_some_and(|selected| {
                selected.repo_id == repository.id && selected.path == worktree.path
            });

            rows.push(RepoTreeRow::Worktree {
                repo_id: repository.id.clone(),
                path: worktree.path.clone(),
                label,
                selected,
                archived: worktree.archived,
                kind: worktree.kind.clone(),
            });
        }
    }

    rows
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InspectorTreeRow {
    EmptyState(String),
    Context {
        branch_label: String,
        changed_count: Option<usize>,
    },
    Section(&'static str),
    Loading(&'static str),
    Error {
        section: &'static str,
        message: String,
    },
    ChangedFile {
        status: String,
        path: String,
    },
    Clean,
    File {
        depth: usize,
        name: String,
        path: PathBuf,
        is_dir: bool,
        expanded: bool,
    },
    Truncated {
        depth: usize,
    },
}

pub fn build_inspector_tree_rows(
    selected_worktree: Option<&SelectedWorktree>,
    state: &InspectorPaneState,
    file_expansion: &TreeExpansionState,
) -> Vec<InspectorTreeRow> {
    if selected_worktree.is_none() {
        return vec![InspectorTreeRow::EmptyState(
            "Select a worktree to inspect files and changes.".to_string(),
        )];
    }

    let branch_label = state
        .changes
        .as_ref()
        .and_then(|changes| changes.branch.clone())
        .unwrap_or_else(|| "Detached HEAD".to_string());
    let changed_count = state
        .changes
        .as_ref()
        .map(|changes| changes.changed_files.len());

    let mut rows = vec![InspectorTreeRow::Context {
        branch_label,
        changed_count,
    }];

    rows.push(InspectorTreeRow::Section("Changed"));
    match (&state.changes, &state.changes_error) {
        (_, Some(error)) => rows.push(InspectorTreeRow::Error {
            section: "Changed",
            message: error.clone(),
        }),
        (None, None) => rows.push(InspectorTreeRow::Loading("Changed")),
        (Some(changes), None) if changes.changed_files.is_empty() => {
            rows.push(InspectorTreeRow::Clean)
        }
        (Some(changes), None) => rows.extend(changes.changed_files.iter().map(|file| {
            InspectorTreeRow::ChangedFile {
                status: file.status.clone(),
                path: file.path.clone(),
            }
        })),
    }

    rows.push(InspectorTreeRow::Section("Files"));
    match (&state.files, &state.files_error) {
        (_, Some(error)) => rows.push(InspectorTreeRow::Error {
            section: "Files",
            message: error.clone(),
        }),
        (None, None) => rows.push(InspectorTreeRow::Loading("Files")),
        (Some(root), None) if root.children.is_empty() => rows.push(InspectorTreeRow::EmptyState(
            "No files found.".to_string(),
        )),
        (Some(root), None) => {
            for child in &root.children {
                flatten_file_rows(child, 0, file_expansion, &mut rows);
            }
            if root.truncated {
                rows.push(InspectorTreeRow::Truncated { depth: 0 });
            }
        }
    }

    rows
}

fn flatten_file_rows(
    node: &FileTreeNode,
    depth: usize,
    file_expansion: &TreeExpansionState,
    rows: &mut Vec<InspectorTreeRow>,
) {
    let expansion_key = TreeExpansionKey::File(node.path.clone());
    let expanded = node.is_dir && file_expansion.is_expanded(&expansion_key);

    rows.push(InspectorTreeRow::File {
        depth,
        name: node.name.clone(),
        path: node.path.clone(),
        is_dir: node.is_dir,
        expanded,
    });

    if !expanded {
        return;
    }

    for child in &node.children {
        flatten_file_rows(child, depth + 1, file_expansion, rows);
    }

    if node.truncated {
        rows.push(InspectorTreeRow::Truncated { depth: depth + 1 });
    }
}

pub fn terminal_tab_overlay_visible(
    hovered: bool,
    terminal_focused: bool,
    tab_count: usize,
    terminal_status: Option<&TerminalTabStatus>,
    terminal_error: bool,
) -> bool {
    hovered
        || terminal_focused
        || tab_count > 1
        || terminal_error
        || matches!(
            terminal_status,
            Some(TerminalTabStatus::Exited(_) | TerminalTabStatus::Failed)
        )
}
```

- [ ] **Step 5: Run the focused tests**

Run:

```bash
cargo test --test ui_view_model_tests --all-features
```

Expected: PASS.

- [ ] **Step 6: Run format check**

Run:

```bash
cargo fmt --all -- --check
```

Expected: PASS. If it fails, run `cargo fmt --all`, then re-run the check.

- [ ] **Step 7: Commit**

```bash
git add src/ui/mod.rs src/ui/view_models.rs tests/ui_view_model_tests.rs
git commit -m "test: add UI view model helpers"
```

---

### Task 2: Isolate macOS window chrome options

**Files:**
- Create: `src/ui/chrome.rs`
- Modify: `src/ui/mod.rs`
- Modify: `src/ui/shell.rs`

- [ ] **Step 1: Write the chrome module**

Create `src/ui/chrome.rs`:

```rust
use gpui::{IntoElement, WindowOptions, div, prelude::*, px};

pub const TRAFFIC_LIGHT_LEFT_PX: f32 = 20.0;
pub const TRAFFIC_LIGHT_TOP_PX: f32 = 20.0;
pub const MAC_SAFE_AREA_WIDTH_PX: f32 = 116.0;
pub const MAC_SAFE_AREA_HEIGHT_PX: f32 = 56.0;

pub fn mac_titlebar_safe_area_height_px() -> f32 {
    if cfg!(target_os = "macos") {
        MAC_SAFE_AREA_HEIGHT_PX
    } else {
        0.0
    }
}

pub fn alas_window_options() -> WindowOptions {
    let mut options = WindowOptions::default();

    #[cfg(target_os = "macos")]
    {
        options.titlebar = Some(gpui::TitlebarOptions {
            title: None,
            appears_transparent: true,
            traffic_light_position: Some(gpui::point(
                px(TRAFFIC_LIGHT_LEFT_PX),
                px(TRAFFIC_LIGHT_TOP_PX),
            )),
        });
    }

    options
}

pub fn render_mac_titlebar_safe_area_spacer() -> impl IntoElement {
    div()
        .id("mac-titlebar-safe-area-spacer")
        .flex_shrink_0()
        .w(px(MAC_SAFE_AREA_WIDTH_PX))
        .h(px(mac_titlebar_safe_area_height_px()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[cfg(target_os = "macos")]
    fn macos_window_options_use_transparent_titlebar_and_moved_traffic_lights() {
        let options = alas_window_options();
        let titlebar = options.titlebar.expect("titlebar options");
        assert!(titlebar.appears_transparent);
        assert!(titlebar.title.is_none());
        assert!(titlebar.traffic_light_position.is_some());
    }

    #[test]
    #[cfg(not(target_os = "macos"))]
    fn non_macos_window_options_keep_default_titlebar() {
        let options = alas_window_options();
        let titlebar = options.titlebar.expect("default titlebar options");
        assert!(!titlebar.appears_transparent);
    }
}
```

Note: GPUI exposes transparent titlebar and traffic-light positioning on macOS. The safe-area spacer must be rendered at the top of the left sidebar, not as a root absolute overlay, so left-sidebar rows do not sit under the traffic-light buttons while the center and right columns remain flush. There is no separate app-drawn window-drag implementation in this pass; manual testing must verify that the remaining transparent titlebar/safe region has acceptable native dragging behavior and that terminal/tree rows do not drag the window.

- [ ] **Step 2: Export `chrome` module**

Modify `src/ui/mod.rs`:

```rust
pub mod chrome;
```

- [ ] **Step 3: Use chrome options when opening the window**

In `src/ui/shell.rs`, update the existing nested `ui` import block to include `chrome::alas_window_options`.

Replace:

```rust
cx.open_window(WindowOptions::default(), |window, cx| {
```

with:

```rust
cx.open_window(alas_window_options(), |window, cx| {
```

Remove `WindowOptions` from the `gpui` import list if it is no longer used directly in `shell.rs`.

- [ ] **Step 4: Run focused tests**

Run:

```bash
cargo test --lib --all-features chrome
```

Expected: PASS.

- [ ] **Step 5: Run a build check**

Run:

```bash
cargo check --all-features
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/ui/chrome.rs src/ui/mod.rs src/ui/shell.rs
git commit -m "feat: isolate macOS window chrome options"
```

---

### Task 3: Make the center workspace a true flush terminal with hover tabs

**Files:**
- Modify: `src/ui/shell.rs`
- Modify: `src/ui/workspace.rs`
- Modify: `src/ui/terminal_pane.rs`
- Modify: `src/ui/theme.rs`
- Test: `tests/ui_view_model_tests.rs` from Task 1 already covers overlay visibility logic

- [ ] **Step 1: Add center-pane theme tokens**

Modify `src/ui/theme.rs` and add these constants near the existing colors:

```rust
pub const TERMINAL_BG: Rgba = rgb_const(0x141518);
pub const OVERLAY_BG: Rgba = rgb_const(0x25272d);
pub const OVERLAY_BORDER: Rgba = rgb_const(0x444850);
pub const SIDEBAR_SECTION_TEXT: Rgba = rgb_const(0x8f96a3);
```

- [ ] **Step 2: Add terminal tab hover state to the shell**

In `src/ui/shell.rs`, add a field to `AlasShell`:

```rust
terminal_tab_overlay_hovered: bool,
```

Initialize it in `AlasShell::new`:

```rust
terminal_tab_overlay_hovered: false,
```

In `render`, before rendering the workspace, compute:

```rust
let terminal_focused = self.terminal_focus.contains_focused(window, cx);
let show_terminal_tabs = crate::ui::view_models::terminal_tab_overlay_visible(
    self.terminal_tab_overlay_hovered,
    terminal_focused,
    workspace_tabs.len(),
    status_bar_terminal_status.as_ref(),
    active_terminal_error.is_some(),
);
```

If `status_bar_terminal_status` is renamed later because the bottom status bar is removed, keep the value under a local name such as `active_tab_status_for_overlay`.

- [ ] **Step 3: Add an overlay hover listener**

In `src/ui/shell.rs`, create this listener near the existing terminal listeners:

```rust
let on_terminal_tabs_hover = cx.listener(
    |shell, hovered: &bool, _window, cx| {
        if shell.terminal_tab_overlay_hovered != *hovered {
            shell.terminal_tab_overlay_hovered = *hovered;
            cx.notify();
        }
    },
);
```

- [ ] **Step 4: Change `render_workspace` signature**

Modify `src/ui/workspace.rs` so `render_workspace` accepts the overlay visibility and hover listener:

```rust
pub fn render_workspace(
    tabs: &[TerminalTab],
    active_tab: Option<TerminalTabId>,
    show_tabs: bool,
    on_tabs_hover: impl Fn(&bool, &mut Window, &mut App) + 'static,
    on_select_tab: impl Fn(TerminalTabId, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_new_tab: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    terminal_body: impl IntoElement,
) -> impl IntoElement
```

Update the call site in `src/ui/shell.rs` to pass `show_terminal_tabs` and `on_terminal_tabs_hover` before the existing tab callbacks.

- [ ] **Step 5: Replace workspace card rendering with a flush pane**

In `src/ui/workspace.rs`, replace the current rounded-card layout. Inside the new `render_workspace` function from Step 4, return this element:

```rust
div()
    .id("workspace")
    .relative()
    .flex()
    .flex_col()
    .flex_1()
    .size_full()
    .overflow_hidden()
    .bg(TERMINAL_BG)
    .on_hover(on_tabs_hover)
    .child(
        div()
            .absolute()
            .top_0()
            .right_0()
            .bottom_0()
            .left_0()
            .child(terminal_body),
    )
    .when(show_tabs, |element| {
        element.child(render_tab_bar_overlay(
            tabs,
            active_tab,
            on_select_tab,
            on_new_tab,
        ))
    })
```

Add `render_tab_bar_overlay` by adapting the old `render_tab_bar` body:

```rust
fn render_tab_bar_overlay(
    tabs: &[TerminalTab],
    active_tab: Option<TerminalTabId>,
    on_select_tab: impl Fn(TerminalTabId, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_new_tab: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
) -> impl IntoElement {
    let selected_index = tabs.iter().position(|tab| Some(tab.id) == active_tab);

    div()
        .id("workspace-tab-overlay")
        .absolute()
        .top(px(8.0))
        .left_0()
        .right_0()
        .flex()
        .justify_center()
        .child(
            div()
                .flex()
                .items_center()
                .gap_1()
                .px_2()
                .py_1()
                .rounded_full()
                .border_1()
                .border_color(OVERLAY_BORDER)
                .bg(OVERLAY_BG)
                .child(
                    TabBar::new("workspace-tabs")
                        .segmented()
                        .small()
                        .when_some(selected_index, |tab_bar, index| tab_bar.selected_index(index))
                        .children(tabs.iter().map(move |tab| {
                            let tab_id = tab.id;
                            let label = tab.name.clone();
                            let kind = tab.kind;
                            let on_select_tab = on_select_tab.clone();

                            Tab::new()
                                .label(format!("{}{}", tab_kind_prefix(kind), label))
                                .on_click(move |event, window, cx| {
                                    on_select_tab(tab_id, event, window, cx);
                                })
                        })),
                )
                .child(
                    Button::new("workspace-new-tab")
                        .small()
                        .ghost()
                        .compact()
                        .label("+")
                        .text_color(ACCENT)
                        .on_click(on_new_tab),
                ),
        )
}
```

Keep `tab_kind_prefix` unchanged. Do not use unsupported z-index helpers; the overlay is painted above the terminal because it is added as a later child of the relative workspace container.

- [ ] **Step 6: Remove terminal pane top label and padding chrome**

In `src/ui/terminal_pane.rs`, remove the child block that renders:

```rust
format!(
    "Worktree: {}",
    selected_worktree
        .expect("checked selected worktree")
        .path
        .display()
)
```

Also remove the surrounding `.p_3()` and `.gap_2()` from the normal terminal state. The normal state should be:

```rust
element.flex_col().child(
    div()
        .flex_1()
        .overflow_hidden()
        .relative()
        .on_any_mouse_down(on_mouse_down)
        .capture_any_mouse_up(on_mouse_up)
        .on_mouse_move(on_mouse_move)
        .child(render_terminal_body(terminal_frame, terminal_metrics))
        .child(
            div()
                .absolute()
                .size_full()
                .child(render_terminal_bounds_probe(on_body_bounds)),
        ),
)
```

Set the terminal pane normal background to `TERMINAL_BG` instead of `PANEL_BG` so the center column reads as the terminal surface. Keep the exited-state message and the Restart action. Render them as an absolute/subtle overlay near the bottom or as status content inside the hover tab overlay. Do not remove the restart callback and do not reintroduce a persistent top bar.

- [ ] **Step 7: Remove unused imports**

After editing `workspace.rs` and `terminal_pane.rs`, remove unused imports such as `APP_BG` or `PANEL_BORDER` if the compiler reports them.

- [ ] **Step 8: Run focused tests and checks**

Run:

```bash
cargo test --test ui_view_model_tests --all-features
cargo check --all-features
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add src/ui/shell.rs src/ui/workspace.rs src/ui/terminal_pane.rs src/ui/theme.rs tests/ui_view_model_tests.rs
git commit -m "feat: make terminal workspace flush with hover tabs"
```

---

### Task 4: Replace the left sidebar with a gpui-component repository tree and popover menus

**Files:**
- Modify: `src/ui/shell.rs`
- Modify: `src/ui/sidebar.rs`
- Test: `tests/ui_view_model_tests.rs`

- [ ] **Step 1: Add tree state fields to `AlasShell`**

In `src/ui/shell.rs`, import `TreeExpansionState`:

```rust
use crate::ui::view_models::TreeExpansionState;
```

Add fields:

```rust
repo_tree_expansion: TreeExpansionState,
```

Initialize the field in `AlasShell::new`:

```rust
repo_tree_expansion: TreeExpansionState::default(),
```

Default behavior: when repositories are refreshed, repository nodes may start collapsed. The user can expand them. If manual testing shows the first repository should open by default for discoverability, make that a small follow-up after this task.

- [ ] **Step 2: Update `render_sidebar` signature**

In `src/ui/sidebar.rs`, replace the existing `render_sidebar` signature with one that receives mutable view-state inputs through callbacks instead of owning shell state directly:

```rust
#[allow(clippy::too_many_arguments)]
pub fn render_sidebar(
    repositories: &[RepositoryNode],
    selected_worktree: Option<&SelectedWorktree>,
    expansion: &TreeExpansionState,
    on_toggle_repository: impl Fn(String, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_add_repository: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    on_select_worktree: impl Fn(String, PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_sidebar_menu_action: impl Fn(SidebarMenuState, ActionId, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    add_repository_error: Option<&str>,
) -> impl IntoElement
```

Remove `sidebar_menu`, `on_open_sidebar_menu`, and `on_close_sidebar_menu` from the left-sidebar API after popovers are in place. Keep `SidebarMenuState` as the action target passed back to the shell.

- [ ] **Step 3: Wire repository expansion callback in `shell.rs`**

In `src/ui/shell.rs`, add an owned-`String` callback before rendering the sidebar. Use the current project pattern for `on_select_worktree` so the callback matches `render_sidebar`'s `Fn(String, &ClickEvent, &mut Window, &mut App)` shape:

```rust
let view = cx.entity().downgrade();
let on_toggle_repository = move |repo_id: String,
                                 _event: &ClickEvent,
                                 _window: &mut Window,
                                 app: &mut App| {
    view.update(app, |shell, cx| {
        shell
            .repo_tree_expansion
            .toggle(crate::ui::view_models::TreeExpansionKey::Repository(repo_id.clone()));
        cx.notify();
    })
    .ok();
};
```

Update the `render_sidebar` call to pass `&self.repo_tree_expansion` and the new callbacks.

- [ ] **Step 4: Build tree rows using `gpui-component` row primitives**

In `src/ui/sidebar.rs`, import:

```rust
use crate::ui::chrome::render_mac_titlebar_safe_area_spacer;
use gpui_component::{
    Icon, IconName, Sizable,
    button::{Button, ButtonVariants},
    list::ListItem,
    menu::{DropdownMenu as _, PopupMenu, PopupMenuItem},
};
```

At the top of the sidebar column, render `render_mac_titlebar_safe_area_spacer()` before repository rows. This reserves the macOS traffic-light safe area only in the left sidebar; do not add matching top padding to the terminal or right sidebar.

Use `build_repo_tree_rows(repositories, selected_worktree, expansion)` from `src/ui/view_models.rs` to render rows. It is acceptable for this pass to render the rows inside a scrollable column while using `gpui-component::ListItem`, `Button`, and popover menu primitives. If direct `gpui_component::tree::TreeState` integration is straightforward, use it; if it causes selection/expansion conflicts, keep the tested `TreeExpansionState` and `ListItem` rows for this task, then create a follow-up to adopt `TreeState` fully. The key requirement for this task is a collapsible tree UI using gpui-component row/menu/button primitives, not a large state rewrite.

Render repository rows with:

- chevron icon (`IconName::ChevronRight` or `IconName::ChevronDown`),
- repo name,
- unavailable badge if needed,
- overflow dropdown button.

Render worktree rows with:

- indentation,
- branch icon or text glyph,
- label,
- main/linked/archived badges,
- selected row styling.

- [ ] **Step 5: Implement popup menu builders**

Replace inline `render_sidebar_menu` blocks with menu builders returning `PopupMenu` items.

Add helper in `sidebar.rs`:

```rust
fn build_sidebar_popup_menu(
    mut menu: PopupMenu,
    repository: RepositoryNode,
    worktree: Option<WorktreeNode>,
    menu_state: SidebarMenuState,
    on_sidebar_menu_action: impl Fn(SidebarMenuState, ActionId, &ClickEvent, &mut Window, &mut App)
        + Clone
        + 'static,
) -> PopupMenu {
    let registry = ActionRegistry::default();
    let scope = if worktree.is_some() {
        ActionScope::Worktree
    } else {
        ActionScope::Repository
    };

    for action in registry
        .actions()
        .iter()
        .filter(|action| action.scope == scope)
        .filter(|action| action_is_available(action, &repository, worktree.as_ref()))
    {
        let action_id = action.id;
        let label = sidebar_action_label(action, &repository);
        let destructive = action.destructive;
        let menu_state = menu_state.clone();
        let on_sidebar_menu_action = on_sidebar_menu_action.clone();

        menu = menu.item(
            PopupMenuItem::new(label)
                .when(destructive, |item| item)
                .on_click(move |event, window, cx| {
                    on_sidebar_menu_action(menu_state.clone(), action_id, event, window, cx);
                }),
        );
    }

    menu
}
```

The `dropdown_menu` and `context_menu` builders require `'static` closures. Clone `RepositoryNode` and `WorktreeNode` values before moving them into those closures; do not capture borrowed `&RepositoryNode` or `&WorktreeNode` references.

If `.when(destructive, |item| item)` is not useful, remove it and apply destructive color through a custom `PopupMenuItem::element` later. Do not block the migration on destructive text coloring.

Use a formatted unique id such as `Button::new(SharedString::from(format!("repository-actions-{repo_id}"))).ghost().compact().icon(IconName::Ellipsis).dropdown_menu(move |menu, window, cx| build_sidebar_popup_menu(menu, repository.clone(), None, menu_state.clone(), on_sidebar_menu_action.clone()))` for repository overflow buttons. Use an equivalent formatted `worktree-actions-{repo_id}-{path}` id for worktree overflow buttons and pass `Some(worktree.clone())`.

- [ ] **Step 6: Preserve right-click behavior**

Add `ContextMenuExt` where practical:

```rust
use gpui_component::menu::ContextMenuExt;
```

Wrap repository and worktree row elements with `.context_menu(move |menu, window, cx| { build_sidebar_popup_menu(menu, repository.clone(), worktree.clone(), menu_state.clone(), on_sidebar_menu_action.clone()) })` so right-click and overflow expose the same actions. Right-click support is required before this task is committed. If `ContextMenuExt` conflicts with nested click handlers, use a direct right-button `on_mouse_down` handler plus a small anchored `Popover` fallback, but do not drop right-click behavior.

- [ ] **Step 7: Replace add repository button**

At the bottom of `render_sidebar`, replace the labeled primary button with:

```rust
Button::new("add-repository")
    .ghost()
    .compact()
    .icon(IconName::Plus)
    .tooltip("Add repository")
    .on_click(on_add_repository)
```

Keep `add_repository_error` rendered below or beside the bottom control in compact danger styling.

- [ ] **Step 8: Update action callback in `shell.rs`**

Because `render_sidebar` now passes the `SidebarMenuState` with the clicked action, adjust the shell callback to:

```rust
let on_sidebar_menu_action = move |menu: SidebarMenuState,
                                   action_id: ActionId,
                                   _event: &ClickEvent,
                                   window: &mut Window,
                                   cx: &mut App| {
    let view = view.clone();
    view.update(cx, |shell, cx| {
        shell.handle_sidebar_menu_action_from_target(menu, action_id, window, cx);
    })
    .ok();
};
```

Add a new shell method rather than rewriting the existing method in place:

```rust
fn handle_sidebar_menu_action_from_target(
    &mut self,
    menu: SidebarMenuState,
    action_id: ActionId,
    window: &mut Window,
    cx: &mut Context<Self>,
) {
    self.sidebar_menu = Some(menu);
    self.handle_sidebar_menu_action(action_id, window, cx);
}
```

This preserves the existing action handling logic and confirmations while the UI menu state is migrated away from inline menus.

After the popover path works, remove obsolete inline-menu render helpers and unused callbacks (`open_sidebar_menu`, `close_sidebar_menu`, `render_sidebar_menu`, `menu_action_row`) if they are no longer referenced. Do not leave dead code that would fail Clippy with `-D warnings`.

- [ ] **Step 9: Run focused tests and checks**

Run:

```bash
cargo test --test ui_view_model_tests --all-features
cargo test --test action_registry_tests --all-features
cargo check --all-features
```

Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add src/ui/shell.rs src/ui/sidebar.rs tests/ui_view_model_tests.rs
git commit -m "feat: modernize repository sidebar tree"
```

---

### Task 5: Replace the right inspector tabs with a grouped Changed/Files tree

**Files:**
- Modify: `src/ui/inspector.rs`
- Modify: `src/ui/shell.rs` only if its inspector call signature changes
- Test: `tests/ui_view_model_tests.rs`

- [ ] **Step 1: Remove tab-specific rendering from `inspector.rs`**

In `src/ui/inspector.rs`, remove usage of:

```rust
gpui_component::tab::{Tab, TabBar}
```

Keep `InspectorTab` in the app state for compatibility if removing it would cause broad churn. The UI no longer needs to call `render_tab_bar`.

- [ ] **Step 2: Add file expansion state to the shell**

In `src/ui/shell.rs`, add a field to `AlasShell`:

```rust
file_tree_expansion: TreeExpansionState,
```

Initialize it in `AlasShell::new`:

```rust
file_tree_expansion: TreeExpansionState::default(),
```

Reset it when a new worktree is selected, next to the existing inspector reset in `select_worktree`:

```rust
self.inspector_state.clear_for_new_worktree();
self.file_tree_expansion = TreeExpansionState::default();
```

Add a file-toggle callback before rendering the inspector. Use the same owned-closure pattern as other shell callbacks so it matches `render_project_inspector`'s `Fn(PathBuf, &ClickEvent, &mut Window, &mut App)` signature:

```rust
let view = cx.entity().downgrade();
let on_toggle_file_tree_node = move |path: PathBuf,
                                     _event: &ClickEvent,
                                     _window: &mut Window,
                                     app: &mut App| {
    view.update(app, |shell, cx| {
        shell
            .file_tree_expansion
            .toggle(crate::ui::view_models::TreeExpansionKey::File(path.clone()));
        cx.notify();
    })
    .ok();
};
```

- [ ] **Step 3: Update `render_project_inspector` signature**

Change:

```rust
pub fn render_project_inspector(
    selected_worktree: Option<&SelectedWorktree>,
    state: &InspectorPaneState,
    on_select_tab: impl Fn(InspectorTab, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
) -> impl IntoElement
```

to:

```rust
pub fn render_project_inspector(
    selected_worktree: Option<&SelectedWorktree>,
    state: &InspectorPaneState,
    file_expansion: &TreeExpansionState,
    on_toggle_file: impl Fn(PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
) -> impl IntoElement
```

Then update the call in `src/ui/shell.rs` to pass `&self.file_tree_expansion` and `on_toggle_file_tree_node`. Remove the now-unused `on_select_inspector_tab` closure if no other code needs it.

- [ ] **Step 4: Render grouped rows from the view model**

In `inspector.rs`, import:

```rust
use crate::ui::view_models::{
    InspectorTreeRow, TreeExpansionState, build_inspector_tree_rows,
};
```

Inside `render_project_inspector`, build rows:

```rust
let rows = build_inspector_tree_rows(selected_worktree, state, file_expansion);
```

Render a single scrollable column:

```rust
div()
    .id("project-inspector")
    .flex()
    .flex_col()
    .flex_shrink_0()
    .size_full()
    .w(px(320.0))
    .px_4()
    .py_3()
    .gap_2()
    .border_l_1()
    .border_color(PANEL_BORDER)
    .bg(PANEL_BG)
    .text_color(TEXT)
    .child(render_inspector_rows(rows, on_toggle_file))
```

Do not show the old “Inspector” title if it wastes top space. Prefer compact context rows.

- [ ] **Step 5: Add row renderer with file expand/collapse affordances**

Add:

```rust
fn render_inspector_rows(
    rows: Vec<InspectorTreeRow>,
    on_toggle_file: impl Fn(PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
) -> impl IntoElement {
    div()
        .id("grouped-inspector-tree")
        .flex()
        .flex_col()
        .flex_1()
        .min_h(px(0.0))
        .overflow_scroll()
        .gap_1()
        .children(rows.into_iter().map(move |row| {
            render_inspector_row(row, on_toggle_file.clone())
        }))
}

fn render_inspector_row(
    row: InspectorTreeRow,
    on_toggle_file: impl Fn(PathBuf, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
) -> AnyElement {
    match row {
        InspectorTreeRow::EmptyState(message) => empty_text_owned(message).into_any_element(),
        InspectorTreeRow::Context { branch_label, changed_count } => {
            let count = changed_count
                .map(|count| format!(" · {count} changed"))
                .unwrap_or_default();
            div()
                .px_1()
                .pb_2()
                .text_xs()
                .text_color(TEXT_MUTED)
                .child(SharedString::from(format!("{branch_label}{count}")))
                .into_any_element()
        }
        InspectorTreeRow::Section(title) => section_header(title).into_any_element(),
        InspectorTreeRow::Loading(section) => {
            loading_text_owned(format!("Loading {section}…")).into_any_element()
        }
        InspectorTreeRow::Error { section, message } => {
            warning_text(section, &message).into_any_element()
        }
        InspectorTreeRow::ChangedFile { status, path } => {
            changed_file_row(status, path).into_any_element()
        }
        InspectorTreeRow::Clean => empty_text("No changed files.").into_any_element(),
        InspectorTreeRow::File { depth, name, path, is_dir, expanded } => {
            file_row(depth, name, path, is_dir, expanded, on_toggle_file).into_any_element()
        }
        InspectorTreeRow::Truncated { depth } => truncated_row(depth).into_any_element(),
    }
}
```

Implement `empty_text_owned`, `loading_text_owned`, `changed_file_row`, `file_row`, and `truncated_row` by adapting the existing `empty_text`, `loading_text`, `render_file_node`, and `render_changes` styling. `file_row` must show an expand/collapse affordance for directories and call `on_toggle_file(path, event, window, cx)` when a directory row is clicked. Use `IconName::FolderClosed`, `IconName::FolderOpen`, and `IconName::File` if the imports stay simple; otherwise use text glyphs for this task.

- [ ] **Step 6: Remove obsolete functions**

Remove or stop using:

- `render_tab_bar`
- `render_files_tab`
- `render_changes_tab`
- recursive `render_file_node` if replaced by flattened rows
- `render_changes` if replaced by grouped row renderer

Keep shared helpers like `section_header`, `loading_text`, `empty_text`, and `warning_text` if still used.

- [ ] **Step 7: Run focused tests and checks**

Run:

```bash
cargo test --test ui_view_model_tests --all-features
cargo test --test inspector_state_tests --all-features
cargo check --all-features
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add src/ui/inspector.rs src/ui/shell.rs tests/ui_view_model_tests.rs
git commit -m "feat: show grouped project inspector tree"
```

---

### Task 6: Compose final three-column shell and remove the old status bar path

**Files:**
- Modify: `src/ui/shell.rs`
- Modify: `src/ui/theme.rs` if final spacing/color tokens are needed

- [ ] **Step 1: Remove status-bar rendering from the default layout**

In `src/ui/shell.rs`, remove the final root child that calls `render_status_bar` with `status_bar_repo`, `status_bar_tab`, and `status_bar_terminal_status`.

If `render_status_bar` becomes unused, remove the helper function and any imports only used by it. If it is still useful for a hidden future path, leave it private but unused only if the compiler allows it. Prefer removing unused code.

- [ ] **Step 2: Compose the root as three direct columns**

In `src/ui/shell.rs`, the root render should have this shape:

```rust
div()
    .on_action(cx.listener(|_shell, _: &crate::ui::lifecycle::Quit, _window, cx| {
        cx.quit();
    }))
    .relative()
    .flex()
    .size_full()
    .bg(APP_BG)
    .text_color(TEXT)
    .child(render_sidebar(
        self.model.repositories(),
        self.model.selected_worktree(),
        &self.repo_tree_expansion,
        on_toggle_repository,
        cx.listener(|shell, _event, _window, cx| shell.open_add_repository_dialog(cx)),
        on_select_worktree,
        on_sidebar_menu_action,
        self.add_repository_error(),
    ))
    .child(
        div()
            .flex()
            .flex_col()
            .flex_1()
            .min_w(px(0.0))
            .when(self.command_picker.is_some(), |element| {
                // Preserve the existing command picker render block here.
                element
            })
            .when(self.command_settings_dialog.is_some(), |element| {
                // Preserve the existing command settings dialog render block here.
                element
            })
            .when(self.create_worktree_dialog.is_some(), |element| {
                // Preserve the existing create-worktree dialog render block here.
                element
            })
            .child(
                div()
                    .flex()
                    .flex_1()
                    .track_focus(&self.terminal_focus)
                    .on_key_down(on_terminal_key_down)
                    .child(render_workspace(
                        workspace_tabs,
                        active_workspace_tab,
                        show_terminal_tabs,
                        on_terminal_tabs_hover,
                        on_select_terminal_tab,
                        on_new_terminal_tab,
                        render_terminal_pane(
                            self.model.selected_worktree(),
                            active_tab,
                            terminal_frame,
                            active_terminal_status,
                            self.terminal_metrics,
                            active_terminal_error,
                            on_retry_terminal,
                            on_edit_terminal_command,
                            on_restart_terminal,
                            on_focus_terminal,
                            on_terminal_scroll,
                            on_terminal_mouse_down,
                            on_terminal_mouse_up,
                            on_terminal_mouse_move,
                            on_terminal_body_bounds,
                        ),
                    )),
            ),
    )
    .child(render_project_inspector(
        self.model.selected_worktree(),
        &self.inspector_state,
        &self.file_tree_expansion,
        on_toggle_file_tree_node,
    ))
```

The macOS safe-area spacer is rendered inside `render_sidebar`, not at the root. This keeps the center terminal and right sidebar flush with the window top while preventing left-sidebar rows from overlapping traffic-light buttons.

- [ ] **Step 3: Keep command picker and dialogs functional**

The current shell renders command picker and command/create-worktree dialogs above the workspace inside the center column. Preserve that behavior by placing these dialog blocks before the terminal focus/key wrapper and before the `render_workspace` call inside the center column.

Do not move dialog business logic. Only relocate the existing render blocks so they still appear above the center pane. Keep `.track_focus(&self.terminal_focus)` and `.on_key_down(on_terminal_key_down)` on the inner workspace wrapper only, not on the outer center column, so dialog key events do not bubble into terminal input handling.

- [ ] **Step 4: Compile and fix unused variables**

Run:

```bash
cargo check --all-features
```

Expected: PASS. Remove now-unused locals such as `status_bar_repo`, `status_bar_tab`, or `active_workspace_tab` only if they no longer feed active tab logic.

- [ ] **Step 5: Run focused terminal tests**

Run:

```bash
cargo test --test terminal_render_tests --all-features
cargo test --test terminal_session_tests --all-features
cargo test --test workspace_session_tests --all-features
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/ui/shell.rs src/ui/theme.rs
git commit -m "feat: compose frameless three-column shell"
```

---

### Task 7: Update manual tests and run full verification

**Files:**
- Modify: `docs/manual-test.md`

- [ ] **Step 1: Update manual test script**

Edit `docs/manual-test.md` and add a new section after “Repository and Worktree Management”:

```markdown
## UI Overhaul

1. On macOS, start Alas with `cargo run` and confirm the normal titlebar is visually reclaimed: app content is flush with the window and traffic-light buttons sit approximately 20px from the top.
2. Confirm the top-left safe area is reserved in the left sidebar: no repository row, text, or button sits under the traffic-light buttons.
3. Drag the window from the top-left safe/chrome area and confirm the window moves.
4. Try dragging from terminal content, repository rows, worktree rows, and right-sidebar rows; confirm those areas do not drag the window.
5. Confirm Linux still shows conventional window chrome if tested on Linux.
6. Confirm the app reads as three columns: repository/worktree tree, flush terminal pane, grouped files/Git tree.
7. Expand and collapse repository nodes in the left sidebar.
8. Right-click a repository row and a worktree row; confirm contextual popover menus show the expected actions.
9. Click each overflow button and confirm it opens the same action set as right-click.
10. Use the bottom icon-only add repository button; confirm its hover tooltip says “Add repository.”
11. Select a worktree and confirm the center terminal starts without a persistent `Worktree:` label or workspace card border.
12. Hover the top edge of the terminal; confirm terminal tabs and the new-tab control appear.
13. Open a second terminal tab and confirm the tab overlay remains available for switching.
14. Confirm terminal scroll, mouse, keyboard, paste, resize, and alternate-screen behavior still match the Terminal Emulator Behavior section.
15. Confirm the right sidebar shows a single grouped tree with Changed and Files sections, not Files/Changes tabs.
16. Expand and collapse directories in the right Files section.
17. Create or modify a file and confirm the Changed section updates independently of the Files section.
18. Confirm the old full-width bottom status bar is gone.
```

Also replace the existing stale `## Files and Changes Inspector` section at the bottom of `docs/manual-test.md` with:

```markdown
## Grouped Project Inspector

1. Select a worktree and confirm the right sidebar shows a single grouped tree, not separate Files and Changes tabs.
2. Confirm the Changed section shows modified/untracked files with status badges.
3. Confirm the Files section shows worktree files and supports directory expand/collapse.
4. Confirm file loading errors remain scoped to the Files section and do not break terminal input.
5. Confirm Git status loading errors remain scoped to the Changed section and do not break terminal input.
```

- [ ] **Step 2: Run format check**

Run:

```bash
cargo fmt --all -- --check
```

Expected: PASS. If it fails, run `cargo fmt --all`, then re-run the check.

- [ ] **Step 3: Run Clippy**

Run:

```bash
cargo clippy --all-targets --all-features -- -D warnings
```

Expected: PASS.

- [ ] **Step 4: Run build**

Run:

```bash
cargo build --all-features
```

Expected: PASS.

- [ ] **Step 5: Run full tests**

Run:

```bash
cargo test --all-features
```

Expected: PASS.

- [ ] **Step 6: Commit docs and verification fixes**

```bash
git add docs/manual-test.md src tests
git commit -m "docs: update manual tests for UI overhaul"
```

If no source/test files changed in this task, use:

```bash
git add docs/manual-test.md
git commit -m "docs: update manual tests for UI overhaul"
```

---

## Implementation Notes

- Keep UI strings, comments, and logs in English.
- Keep all destructive action confirmations intact.
- Do not rewrite terminal backend/session logic.
- Do not add file open/edit/delete features in the right tree.
- If exact `gpui-component::tree::TreeState` integration causes implementation friction, land the collapsible tree using `TreeExpansionState` plus `gpui-component::ListItem`, `Button`, `Icon`, and popover/menu primitives. Record the full `TreeState` migration as a follow-up rather than destabilizing the UI overhaul.
- The old `sidebar_menu` shell field can remain temporarily as an adapter for existing action handling. Remove it only if doing so is a straightforward cleanup after popover action dispatch works.
- If custom SVG assets are needed, add them under `assets/` and include them in a focused commit. Prefer `IconName::Plus`, `IconName::Ellipsis`, `IconName::FolderClosed`, `IconName::FolderOpen`, `IconName::File`, and `IconName::SquareTerminal` first.
- The macOS titlebar change must be manually verified. Automated tests can only check the `WindowOptions` construction.
