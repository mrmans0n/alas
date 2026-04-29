# Alas Terminal Workspace Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Alas v1 as a polished macOS-first Git worktree terminal workspace with multiple Ghostty-backed terminal tabs per worktree, a redesigned Superconductor-inspired shell, and Files/Changes inspection.

**Architecture:** Keep app/domain state separate from UI rendering. First prove the UI framework can support terminal-grade rendering/input; then build reusable state models (`WorkspaceSession`, terminal tabs, action registry, inspector state), upgrade the terminal backend to styled Ghostty snapshots, and finally wire the redesigned GPUI shell. If the GPUI feasibility gate fails, stop the GPUI UI tasks and write a migration plan that preserves the same app/domain/terminal interfaces.

**Tech Stack:** Rust 2024, Cargo, GPUI 0.2 initially, `portable-pty`, `libghostty-vt`, Git CLI, `serde`/`toml`, `indexmap`, `tempfile`, existing test harness.

---

## Source Documents

- Spec: `docs/superpowers/specs/2026-04-29-alas-terminal-workspace-redesign-design.md`
- Existing manual test script: `docs/manual-test.md`
- Existing implementation reference: `docs/superpowers/plans/2026-04-28-alas-implementation.md`

## Current Code Map

- `src/ui/shell.rs`: current GPUI app shell, selection, dialogs, terminal input routing, terminal refresh loop.
- `src/ui/sidebar.rs`: current sidebar with visible action chips; target for navigator redesign.
- `src/ui/terminal_pane.rs`: current raw text terminal pane; target for terminal workspace/view split.
- `src/ui/inspector.rs`: current Git inspector; target for Files/Changes tabs.
- `src/terminal/session.rs`: current one-session-per-worktree registry; target for multi-tab session ids.
- `src/terminal/ghostty_adapter.rs`: PTY + optional Ghostty VT adapter; target for required styled VT snapshots.
- `src/config/types.rs`: repo command config already exists; use this for terminal command choices.
- `src/app/model.rs`: current repository/worktree selection model.
- `src/app/actions.rs`: current coarse action enum; target for action registry metadata.
- `src/git/inspector.rs`: current branch/changed-files/recent-commits service.

## Target File Structure

Create or modify these files over the plan:

- Create: `docs/superpowers/decisions/2026-04-29-ui-framework-feasibility.md` — records GPUI pass/fail decision.
- Create: `examples/terminal_probe.rs` — disposable but committed GPUI capability probe for terminal-grade rendering/input.
- Create: `src/ui/theme.rs` — shared dark theme tokens.
- Create: `src/ui/workspace.rs` — center workspace card, tab strip, command picker shell.
- Create: `src/ui/terminal_view.rs` — terminal grid rendering, cursor, scroll/focus/input surface.
- Create: `src/app/workspace.rs` — `WorkspaceSession`, `TerminalTab`, and tab state transitions.
- Create: `src/app/action_registry.rs` — action ids, labels, scope, destructive metadata.
- Create: `src/project/mod.rs` and `src/project/file_tree.rs` — Files pane directory tree model/service.
- Modify: `src/app/mod.rs` — export new app modules.
- Modify: `src/app/model.rs` — keep selection/repository model focused; add helpers only if needed.
- Modify: `src/app/actions.rs` — align action ids with registry if still useful.
- Modify: `src/terminal/mod.rs` — export render model and updated backend/session types.
- Modify: `src/terminal/session.rs` — support tab-scoped terminal session ids.
- Modify: `src/terminal/ghostty_adapter.rs` — required Ghostty VT path and styled snapshots.
- Modify: `src/ui/shell.rs` — wire workspace session, action registry, inspector tabs, terminal tabs.
- Modify: `src/ui/sidebar.rs` — redesigned navigator and context/overflow entry points.
- Modify: `src/ui/inspector.rs` — Files/Changes tab rendering.
- Modify: `src/lib.rs` — export `project` module.
- Modify: `Cargo.toml` — default-enable or require `ghostty-vt`, add example if needed.
- Modify: `docs/manual-test.md` — terminal workspace acceptance script.
- Test: `tests/workspace_session_tests.rs`
- Test: `tests/action_registry_tests.rs`
- Test: `tests/file_tree_tests.rs`
- Test: `tests/terminal_session_tests.rs`
- Test: `tests/terminal_render_tests.rs`
- Test: `tests/inspector_state_tests.rs`

---

## Task 1: UI Framework Feasibility Gate

**Purpose:** Validate GPUI before committing to deep terminal UI work. The user is open to another Rust UI library if GPUI cannot support terminal-grade behavior.

**Files:**
- Create: `examples/terminal_probe.rs`
- Create: `docs/superpowers/decisions/2026-04-29-ui-framework-feasibility.md`
- Modify: `Cargo.toml` only if Cargo needs an explicit example entry

- [ ] **Step 1: Inspect GPUI capabilities locally**

Run:

```bash
rg -n "on_scroll|ScrollWheelEvent|MouseDownEvent|MouseMoveEvent|ElementInputHandler|handle_input|on_key_down|paint\(" ~/.cargo/registry/src/index.crates.io-*/gpui-0.2* -g '*.rs'
```

Expected: find support for scroll wheel, key down, mouse events, and custom element paint/input hooks.

- [ ] **Step 2: Write the probe example**

Create `examples/terminal_probe.rs` with a small GPUI app that proves the exact primitives needed by the real terminal view: grid-like rendering, key event capture, scroll wheel capture, right-click detection, focus, and periodic repaint.

Use this skeleton and adapt imports to the installed GPUI API if needed:

```rust
use gpui::{App, Application, Context, FocusHandle, IntoElement, KeyDownEvent, Render, Window, WindowOptions, div, prelude::*, rgb};
use std::time::Duration;

struct TerminalProbe {
    focus: FocusHandle,
    last_key: String,
    scroll_events: usize,
    right_clicks: usize,
    ticks: usize,
}

impl TerminalProbe {
    fn new(cx: &mut Context<Self>) -> Self {
        let probe = Self {
            focus: cx.focus_handle(),
            last_key: "none".to_string(),
            scroll_events: 0,
            right_clicks: 0,
            ticks: 0,
        };
        cx.spawn(async move |this, cx| loop {
            cx.background_executor().timer(Duration::from_millis(16)).await;
            if this.update(cx, |probe, cx| { probe.ticks += 1; cx.notify(); }).is_err() {
                break;
            }
        }).detach();
        probe
    }
}

impl Render for TerminalProbe {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let on_key = cx.listener(|probe, event: &KeyDownEvent, _window, cx| {
            probe.last_key = format!("{}", event.keystroke.key);
            cx.notify();
        });

        div()
            .size_full()
            .bg(rgb(0x101216))
            .track_focus(&self.focus)
            .on_key_down(on_key)
            .child(
                div()
                    .p_4()
                    .font_family("monospace")
                    .text_color(rgb(0xe5e7eb))
                    .child(format!("ticks={} last_key={} scrolls={} right_clicks={}", self.ticks, self.last_key, self.scroll_events, self.right_clicks))
            )
    }
}

fn main() {
    Application::new().run(|cx| {
        cx.open_window(WindowOptions::default(), |_, cx| cx.new(TerminalProbe::new)).unwrap();
    });
}
```

If GPUI's high-level `div()` API cannot expose scroll/right-click cleanly, replace the body with a custom `Element` using GPUI's lower-level `Element`/`paint`/`InputHandler` APIs. The probe passes only if all required signals are observable.

- [ ] **Step 3: Run the probe**

Run:

```bash
cargo run --example terminal_probe
```

Manual expected result:

- typing updates `last_key`
- trackpad/mouse scrolling can be captured or a low-level path to capture it is documented
- mouse drag can report enough coordinates/buttons to implement terminal text selection
- clipboard copy can be triggered from keyboard/menu, or a concrete GPUI clipboard API path is documented
- right click can be detected or an overflow-menu fallback can replace native context menus
- repaint counter advances smoothly without pegging CPU
- a custom paint path exists for grid/cell rendering

- [ ] **Step 4: Record the decision**

Create `docs/superpowers/decisions/2026-04-29-ui-framework-feasibility.md`:

```markdown
# UI Framework Feasibility Decision

Date: 2026-04-29

## Decision

Proceed with GPUI for V1. <!-- or: Stop and evaluate replacement UI stack. -->

## Required Capabilities

- Custom terminal grid/cell rendering: PASS/FAIL — evidence
- High-frequency repaint without excessive CPU: PASS/FAIL — evidence
- Keyboard/text input fidelity: PASS/FAIL — evidence
- Trackpad/mouse scroll events: PASS/FAIL — evidence
- Drag selection coordinates and mouse capture: PASS/FAIL — evidence
- Clipboard copy path: PASS/FAIL — evidence
- Right-click or overflow menu support: PASS/FAIL — evidence
- Focus handling for terminal input: PASS/FAIL — evidence

## Notes

If any required capability fails, do not continue the GPUI UI tasks. Preserve the domain/terminal tasks and write a migration plan for a replacement Rust UI stack.
```

- [ ] **Step 5: Commit**

If GPUI passes:

```bash
git add examples/terminal_probe.rs docs/superpowers/decisions/2026-04-29-ui-framework-feasibility.md Cargo.toml
git commit -m "docs: record GPUI terminal feasibility"
```

If GPUI fails: commit only the probe and decision, then stop this plan before UI tasks and ask for a migration-plan update.

---

## Task 2: Require Ghostty VT and Stabilize the Build

**Purpose:** V1 must not silently render raw escape-code text. Make the Ghostty VT path the default and document the native build requirement.

**Files:**
- Modify: `Cargo.toml`
- Modify: `src/terminal/ghostty_adapter.rs`
- Modify: `README.md`
- Test: `tests/terminal_session_tests.rs`

- [ ] **Step 1: Make Ghostty VT default**

Modify `Cargo.toml` so the default feature includes `ghostty-vt`:

```toml
[features]
default = ["ghostty-vt"]
ghostty-vt = ["dep:libghostty-vt"]
```

Keep `libghostty-vt` optional only if needed by Cargo features, but the normal app/test path must enable it.

- [ ] **Step 2: Remove the silent non-VT runtime fallback**

In `src/terminal/ghostty_adapter.rs`, replace the `#[cfg(not(feature = "ghostty-vt"))]` fallback `VtState` implementation with an explicit compile-time error or a runtime constructor error that prevents raw text rendering.

Preferred:

```rust
#[cfg(not(feature = "ghostty-vt"))]
compile_error!("Alas V1 requires the ghostty-vt feature for terminal rendering");
```

Remove fallback code paths that return `Ok(None)` for `snapshot_lines()`.

- [ ] **Step 3: Document native build setup**

Update `README.md` development section:

```markdown
## Ghostty VT build

Alas V1 requires `libghostty-vt`. The crate builds Ghostty's VT library with Zig.

Requirements:
- Zig available on `PATH`
- network access for the crate's pinned Ghostty source, or `GHOSTTY_SOURCE_DIR=/path/to/ghostty` pointing at a checkout containing `build.zig`

If GitHub fetch fails, clone Ghostty separately and run:

```bash
GHOSTTY_SOURCE_DIR=/path/to/ghostty cargo test
```
```

- [ ] **Step 4: Run build check**

Run:

```bash
cargo test --no-run
```

Expected: compile succeeds when Zig and Ghostty source are available. If it fails because the crate cannot fetch Ghostty, set `GHOSTTY_SOURCE_DIR` and re-run. If it fails due API mismatch, fix adapter imports before continuing.

- [ ] **Step 5: Commit**

```bash
git add Cargo.toml README.md src/terminal/ghostty_adapter.rs
git commit -m "build: require Ghostty VT terminal rendering"
```

---

## Task 3: Add Terminal Render Model

**Purpose:** Replace string-only terminal snapshots with styled cell snapshots while keeping compatibility helpers for tests and transitional UI.

**Files:**
- Create: `src/terminal/grid.rs`
- Modify: `src/terminal/mod.rs`
- Modify: `src/terminal/ghostty_adapter.rs`
- Test: `tests/terminal_render_tests.rs`
- Test: `tests/terminal_session_tests.rs`

- [ ] **Step 1: Write render model tests**

Create `tests/terminal_render_tests.rs`:

```rust
use alas::terminal::{TerminalCell, TerminalCellStyle, TerminalColor, TerminalGridSnapshot, TerminalRow, TerminalScreenMode, TerminalSize, TerminalStatus, TerminalViewport};

#[test]
fn plain_lines_are_derived_from_cells() {
    let snapshot = TerminalGridSnapshot {
        size: TerminalSize { cols: 3, rows: 1 },
        rows: vec![TerminalRow { cells: vec![
            TerminalCell::new("a"),
            TerminalCell::new("b"),
            TerminalCell::new(" "),
        ]}],
        cursor: None,
        status: TerminalStatus::Running,
        viewport: TerminalViewport { scroll_offset_rows: 0, visible_rows: 1 },
        scrollback_rows: 0,
        screen_mode: TerminalScreenMode::Main,
    };

    assert_eq!(snapshot.plain_lines(), vec!["ab".to_string()]);
}

#[test]
fn snapshot_tracks_viewport_and_screen_mode() {
    let snapshot = TerminalGridSnapshot {
        size: TerminalSize { cols: 3, rows: 1 },
        rows: vec![TerminalRow { cells: vec![TerminalCell::new("x")] }],
        cursor: None,
        status: TerminalStatus::Running,
        viewport: TerminalViewport { scroll_offset_rows: 5, visible_rows: 1 },
        scrollback_rows: 20,
        screen_mode: TerminalScreenMode::Alternate,
    };

    assert_eq!(snapshot.viewport.scroll_offset_rows, 5);
    assert_eq!(snapshot.scrollback_rows, 20);
    assert_eq!(snapshot.screen_mode, TerminalScreenMode::Alternate);
}

#[test]
fn cell_style_tracks_color_and_attributes() {
    let style = TerminalCellStyle {
        foreground: Some(TerminalColor::rgb(255, 0, 0)),
        background: Some(TerminalColor::rgb(0, 0, 0)),
        bold: true,
        italic: false,
        underline: true,
        inverse: false,
        strikethrough: false,
    };

    assert_eq!(style.foreground, Some(TerminalColor::rgb(255, 0, 0)));
    assert!(style.bold);
    assert!(style.underline);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cargo test --test terminal_render_tests
```

Expected: FAIL because `terminal::grid` types do not exist.

- [ ] **Step 3: Implement render model**

Create `src/terminal/grid.rs`:

```rust
use super::TerminalSize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TerminalColor {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl TerminalColor {
    pub const fn rgb(r: u8, g: u8, b: u8) -> Self { Self { r, g, b } }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TerminalCellStyle {
    pub foreground: Option<TerminalColor>,
    pub background: Option<TerminalColor>,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub inverse: bool,
    pub strikethrough: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalCell {
    pub text: String,
    pub style: TerminalCellStyle,
}

impl TerminalCell {
    pub fn new(text: impl Into<String>) -> Self {
        Self { text: text.into(), style: TerminalCellStyle::default() }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalRow {
    pub cells: Vec<TerminalCell>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalCursorShape { Block, Bar, Underline }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalCursor {
    pub col: u16,
    pub row: u16,
    pub visible: bool,
    pub shape: TerminalCursorShape,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalStatus {
    Running,
    Exited(Option<i32>),
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalViewport {
    pub scroll_offset_rows: usize,
    pub visible_rows: u16,
}

impl TerminalViewport {
    pub fn visible(visible_rows: u16) -> Self { Self { scroll_offset_rows: 0, visible_rows } }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalScreenMode { Main, Alternate }

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalGridSnapshot {
    pub size: TerminalSize,
    pub rows: Vec<TerminalRow>,
    pub cursor: Option<TerminalCursor>,
    pub status: TerminalStatus,
    pub viewport: TerminalViewport,
    pub scrollback_rows: usize,
    pub screen_mode: TerminalScreenMode,
}

impl TerminalGridSnapshot {
    pub fn plain_lines(&self) -> Vec<String> {
        self.rows.iter().map(|row| {
            let mut line = String::new();
            for cell in &row.cells { line.push_str(&cell.text); }
            line.trim_end().to_string()
        }).collect()
    }

    pub fn exited(&self) -> bool { matches!(self.status, TerminalStatus::Exited(_)) }
    pub fn exit_status(&self) -> Option<i32> {
        match self.status { TerminalStatus::Exited(status) => status, _ => None }
    }
}
```

- [ ] **Step 4: Export render model**

Modify `src/terminal/mod.rs`:

```rust
pub mod grid;
pub use grid::{TerminalCell, TerminalCellStyle, TerminalColor, TerminalCursor, TerminalCursorShape, TerminalGridSnapshot, TerminalRow, TerminalScreenMode, TerminalStatus, TerminalViewport};
```

Remove the old `TerminalGridSnapshot` export from `ghostty_adapter.rs` once moved.

- [ ] **Step 5: Update fake backends in tests**

In `tests/terminal_session_tests.rs`, replace old snapshot construction:

```rust
TerminalGridSnapshot {
    size: TerminalSize { cols: 80, rows: 24 },
    lines: Vec::new(),
    cursor: None,
    exited: false,
    exit_status: None,
}
```

with:

```rust
TerminalGridSnapshot {
    size: TerminalSize { cols: 80, rows: 24 },
    rows: Vec::new(),
    cursor: None,
    status: TerminalStatus::Running,
    viewport: TerminalViewport::visible(24),
    scrollback_rows: 0,
    screen_mode: TerminalScreenMode::Main,
}
```

Update assertions from `snapshot.lines.join("\n")` to `snapshot.plain_lines().join("\n")` and `snapshot.exited` to `snapshot.exited()`.

- [ ] **Step 6: Run tests**

Run:

```bash
cargo test --test terminal_render_tests --test terminal_session_tests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/terminal tests/terminal_render_tests.rs tests/terminal_session_tests.rs
git commit -m "feat: add styled terminal render model"
```

---

## Task 4: Add Workspace Session and Multi-Tab Model

**Purpose:** Model multiple named terminal tabs per worktree independently of UI and backend details.

**Files:**
- Create: `src/app/workspace.rs`
- Modify: `src/app/mod.rs`
- Test: `tests/workspace_session_tests.rs`

- [ ] **Step 1: Write workspace tests**

Create `tests/workspace_session_tests.rs`:

```rust
use alas::app::{TerminalTabKind, WorkspaceSession};
use alas::terminal::CommandSpec;
use std::path::PathBuf;

#[test]
fn selecting_worktree_creates_default_tab_once() {
    let mut session = WorkspaceSession::default();
    let cwd = PathBuf::from("/repo/wt");
    let command = CommandSpec::shell_command("$SHELL", cwd.clone());

    let first = session.ensure_default_terminal_tab("repo-1", cwd.clone(), command.clone());
    let second = session.ensure_default_terminal_tab("repo-1", cwd.clone(), command);

    assert_eq!(first, second);
    assert_eq!(session.tabs_for_worktree("repo-1", &cwd).len(), 1);
    assert_eq!(session.active_tab("repo-1", &cwd), Some(first));
}

#[test]
fn worktree_can_have_multiple_named_terminal_tabs() {
    let mut session = WorkspaceSession::default();
    let cwd = PathBuf::from("/repo/wt");

    let shell = session.create_terminal_tab("repo-1", cwd.clone(), "Shell", CommandSpec::shell_command("$SHELL", cwd.clone()), TerminalTabKind::Shell);
    let tests = session.create_terminal_tab("repo-1", cwd.clone(), "Tests", CommandSpec::shell_command("cargo test", cwd.clone()), TerminalTabKind::Command);

    assert_ne!(shell, tests);
    assert_eq!(session.tabs_for_worktree("repo-1", &cwd).len(), 2);
    session.set_active_tab("repo-1", &cwd, shell).unwrap();
    assert_eq!(session.active_tab("repo-1", &cwd), Some(shell));
}

#[test]
fn active_tab_is_scoped_per_worktree() {
    let mut session = WorkspaceSession::default();
    let a = PathBuf::from("/repo/a");
    let b = PathBuf::from("/repo/b");

    let tab_a = session.create_terminal_tab("repo-1", a.clone(), "Shell", CommandSpec::shell_command("$SHELL", a.clone()), TerminalTabKind::Shell);
    let tab_b = session.create_terminal_tab("repo-1", b.clone(), "Shell", CommandSpec::shell_command("$SHELL", b.clone()), TerminalTabKind::Shell);

    assert_eq!(session.active_tab("repo-1", &a), Some(tab_a));
    assert_eq!(session.active_tab("repo-1", &b), Some(tab_b));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cargo test --test workspace_session_tests
```

Expected: FAIL because workspace types do not exist.

- [ ] **Step 3: Implement workspace model**

Create `src/app/workspace.rs`:

```rust
use crate::terminal::{CommandSpec, TerminalBackendSession};
use std::{collections::HashMap, path::{Path, PathBuf}};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TerminalTabId(pub u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalTabKind { Shell, Command, Agent }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalTabStatus { NotStarted, Running, Exited(Option<i32>), Failed }

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct WorktreeKey {
    pub repo_id: String,
    pub path: PathBuf,
}

impl WorktreeKey {
    pub fn new(repo_id: impl Into<String>, path: impl Into<PathBuf>) -> Self {
        Self { repo_id: repo_id.into(), path: path.into() }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalTab {
    pub id: TerminalTabId,
    pub name: String,
    pub kind: TerminalTabKind,
    pub command: CommandSpec,
    pub backend_session: Option<TerminalBackendSession>,
    pub status: TerminalTabStatus,
    pub scroll_offset_rows: usize,
}

#[derive(Debug, Default)]
pub struct WorkspaceSession {
    next_tab_id: u64,
    tabs: HashMap<WorktreeKey, Vec<TerminalTab>>,
    active_tabs: HashMap<WorktreeKey, TerminalTabId>,
}

impl WorkspaceSession {
    pub fn ensure_default_terminal_tab(&mut self, repo_id: impl Into<String>, path: PathBuf, command: CommandSpec) -> TerminalTabId {
        let key = WorktreeKey::new(repo_id, path);
        if let Some(active) = self.active_tabs.get(&key).copied() { return active; }
        self.create_terminal_tab_for_key(key, "Shell".to_string(), command, TerminalTabKind::Shell)
    }

    pub fn create_terminal_tab(&mut self, repo_id: impl Into<String>, path: PathBuf, name: impl Into<String>, command: CommandSpec, kind: TerminalTabKind) -> TerminalTabId {
        let key = WorktreeKey::new(repo_id, path);
        self.create_terminal_tab_for_key(key, name.into(), command, kind)
    }

    fn create_terminal_tab_for_key(&mut self, key: WorktreeKey, name: String, command: CommandSpec, kind: TerminalTabKind) -> TerminalTabId {
        self.next_tab_id += 1;
        let id = TerminalTabId(self.next_tab_id);
        let tab = TerminalTab { id, name, kind, command, backend_session: None, status: TerminalTabStatus::NotStarted, scroll_offset_rows: 0 };
        self.tabs.entry(key.clone()).or_default().push(tab);
        self.active_tabs.insert(key, id);
        id
    }

    pub fn tabs_for_worktree(&self, repo_id: &str, path: &Path) -> &[TerminalTab] {
        self.tabs.get(&WorktreeKey::new(repo_id.to_string(), path.to_path_buf())).map(Vec::as_slice).unwrap_or(&[])
    }

    pub fn active_tab(&self, repo_id: &str, path: &Path) -> Option<TerminalTabId> {
        self.active_tabs.get(&WorktreeKey::new(repo_id.to_string(), path.to_path_buf())).copied()
    }

    pub fn set_active_tab(&mut self, repo_id: &str, path: &Path, tab_id: TerminalTabId) -> anyhow::Result<()> {
        let key = WorktreeKey::new(repo_id.to_string(), path.to_path_buf());
        let exists = self.tabs.get(&key).is_some_and(|tabs| tabs.iter().any(|tab| tab.id == tab_id));
        if !exists { anyhow::bail!("unknown terminal tab"); }
        self.active_tabs.insert(key, tab_id);
        Ok(())
    }
}
```

- [ ] **Step 4: Export workspace types**

Modify `src/app/mod.rs`:

```rust
pub mod workspace;
pub use workspace::{TerminalTab, TerminalTabId, TerminalTabKind, TerminalTabStatus, WorktreeKey, WorkspaceSession};
```

- [ ] **Step 5: Run tests**

Run:

```bash
cargo test --test workspace_session_tests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/app tests/workspace_session_tests.rs
git commit -m "feat: model terminal tabs per worktree"
```

---

## Task 5: Scope Terminal Backend Sessions by Tab

**Purpose:** Ensure each terminal tab maps to its own backend session, not just one session per worktree.

**Files:**
- Modify: `src/terminal/session.rs`
- Modify: `src/terminal/mod.rs`
- Modify: `tests/terminal_session_tests.rs`
- Modify: `src/app/workspace.rs` only if import paths require it

- [ ] **Step 1: Add failing tab-scoped registry test**

Append to `tests/terminal_session_tests.rs`:

```rust
use alas::app::TerminalTabId;

#[test]
fn registry_starts_one_backend_session_per_terminal_tab() {
    let mut registry = TerminalSessionRegistry::default();
    let mut backend = CountingBackend::default();
    let worktree = PathBuf::from("/repo/wt");
    let first_id = TerminalSessionId::new("repo-1", worktree.clone(), TerminalTabId(1));
    let second_id = TerminalSessionId::new("repo-1", worktree.clone(), TerminalTabId(2));

    let first = registry.get_or_start(first_id.clone(), CommandSpec::shell_command("$SHELL", worktree.clone()), &mut backend).unwrap();
    let second = registry.get_or_start(second_id.clone(), CommandSpec::shell_command("cargo test", worktree.clone()), &mut backend).unwrap();
    let first_again = registry.get_or_start(first_id, CommandSpec::shell_command("ignored", worktree), &mut backend).unwrap();

    assert_eq!(first.backend_session, first_again.backend_session);
    assert_ne!(first.backend_session, second.backend_session);
    assert_eq!(backend.start_count(), 2);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cargo test --test terminal_session_tests registry_starts_one_backend_session_per_terminal_tab
```

Expected: FAIL because `TerminalSessionId::new` does not accept a tab id.

- [ ] **Step 3: Update `TerminalSessionId`**

Modify `src/terminal/session.rs`:

```rust
use crate::app::TerminalTabId;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct TerminalSessionId {
    pub repo_id: String,
    pub worktree_path: PathBuf,
    pub tab_id: TerminalTabId,
}

impl TerminalSessionId {
    pub fn new(repo_id: impl Into<String>, worktree_path: PathBuf, tab_id: TerminalTabId) -> Self {
        Self { repo_id: repo_id.into(), worktree_path, tab_id }
    }
}
```

Update all existing tests and production calls to pass `TerminalTabId(1)` temporarily until `WorkspaceSession` wiring creates real ids.

- [ ] **Step 4: Run terminal tests**

Run:

```bash
cargo test --test terminal_session_tests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/terminal src/app tests/terminal_session_tests.rs
git commit -m "feat: scope terminal sessions by tab"
```

---

## Task 6: Add Backend Viewport and Screen Mode API

**Purpose:** Make scrollback, viewport state, and alternate-screen state explicit before rendering UI scroll behavior.

**Files:**
- Modify: `src/terminal/ghostty_adapter.rs`
- Modify: `src/terminal/session.rs` if helper types move
- Modify: `tests/terminal_session_tests.rs`
- Test: `tests/terminal_render_tests.rs`

- [ ] **Step 1: Add failing backend viewport test**

In `tests/terminal_session_tests.rs`, update fake backend implementations to accept a viewport-aware snapshot request. Add:

```rust
use alas::terminal::{TerminalScreenMode, TerminalViewport};

#[test]
fn backend_snapshot_accepts_viewport_request() {
    let mut backend = FakeRuntimeBackend::default();
    let session = backend.start(CommandSpec::shell_command("$SHELL", PathBuf::from("/repo/wt"))).unwrap();
    let snapshot = backend.snapshot(session, TerminalViewport { scroll_offset_rows: 10, visible_rows: 24 }).unwrap();

    assert_eq!(snapshot.viewport.scroll_offset_rows, 10);
    assert_eq!(snapshot.viewport.visible_rows, 24);
    assert_eq!(snapshot.screen_mode, TerminalScreenMode::Main);
}
```

- [ ] **Step 2: Update `TerminalBackend` trait**

Change the trait method in `src/terminal/ghostty_adapter.rs` from:

```rust
fn snapshot(&mut self, session: TerminalBackendSession) -> anyhow::Result<TerminalGridSnapshot>;
```

to:

```rust
fn snapshot(&mut self, session: TerminalBackendSession, viewport: TerminalViewport) -> anyhow::Result<TerminalGridSnapshot>;
```

Update all fake backends and call sites to pass `TerminalViewport::visible(rows)` until UI scroll offset is wired.

- [ ] **Step 3: Implement or block on alternate-screen state**

Add `screen_mode: TerminalScreenMode::Main` to fake snapshots. In the real backend, inspect `libghostty-vt` APIs for alternate-screen state and populate `TerminalScreenMode::Alternate` when the active screen is alternate. This is V1-required because scroll handling differs for `less`, `vim`/`nvim`, and `top`/`htop`.

If `libghostty-vt` cannot expose alternate-screen state, stop this plan and write `docs/superpowers/decisions/2026-04-29-ghostty-alternate-screen-api.md` with a required follow-up design choice: use a lower-level Ghostty API, contribute/expose the missing API, or revise the terminal backend approach. Do not continue to UI tasks while alternate-screen state is unsupported.

- [ ] **Step 4: Implement or block on scrollback viewport extraction**

Inspect `libghostty-vt` row/screen APIs for rendering scrollback with a viewport offset. Implement `VtState::snapshot_rows(viewport)` so `viewport.scroll_offset_rows > 0` returns rows from scrollback and `scrollback_rows` reports the bounded scrollback length. Configure Ghostty with nonzero scrollback, e.g. `max_scrollback: 10_000`, instead of the current `0`.

If `libghostty-vt` cannot expose scrollback rows for rendering, stop this plan and write `docs/superpowers/decisions/2026-04-29-ghostty-scrollback-api.md` with a required follow-up design choice: use a lower-level Ghostty API, contribute/expose the missing API, or revise the terminal backend approach. Do not fake styled scrollback with raw text and do not continue to UI scroll tasks while scrollback is unsupported.

- [ ] **Step 5: Run tests**

Run:

```bash
cargo test --test terminal_session_tests --test terminal_render_tests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/terminal tests/terminal_session_tests.rs tests/terminal_render_tests.rs docs/superpowers/decisions
git commit -m "feat: add terminal viewport snapshot API"
```

---

## Task 7: Extract Styled Ghostty Snapshots

**Purpose:** Feed PTY bytes into Ghostty VT and return styled terminal cells, cursor, and status.

**Files:**
- Modify: `src/terminal/ghostty_adapter.rs`
- Modify: `tests/terminal_session_tests.rs`
- Test: `tests/terminal_render_tests.rs`

- [ ] **Step 1: Add ignored real-backend color test**

Append to `tests/terminal_render_tests.rs`:

```rust
use alas::terminal::{CommandSpec, GhosttyTerminalBackend, TerminalBackend};

#[test]
#[ignore = "requires libghostty-vt native build and PTY timing"]
fn real_backend_extracts_styled_ansi_cells() {
    let dir = tempfile::tempdir().unwrap();
    let mut backend = GhosttyTerminalBackend::new();
    let session = backend.start(CommandSpec::shell_command("printf '\\033[31mred\\033[0m'", dir.path().to_path_buf())).unwrap();

    let snapshot = wait_for_snapshot_text(&mut backend, session, "red");
    let red_cell = snapshot.rows.iter().flat_map(|row| &row.cells).find(|cell| cell.text == "r").expect("red cell");

    assert_eq!(red_cell.style.foreground, Some(alas::terminal::TerminalColor::rgb(255, 0, 0)));
}
```

If Ghostty's palette resolves red to a theme-specific RGB value, assert `red_cell.style.foreground.is_some()` instead and document why.

- [ ] **Step 2: Run ignored test to verify it currently fails or is incomplete**

Run:

```bash
cargo test --test terminal_render_tests real_backend_extracts_styled_ansi_cells -- --ignored --nocapture
```

Expected before implementation: FAIL due snapshot style extraction not implemented.

- [ ] **Step 3: Implement style conversion helpers**

In `src/terminal/ghostty_adapter.rs`, under `#[cfg(feature = "ghostty-vt")]`, add helpers:

```rust
fn convert_rgb(color: libghostty_vt::style::RgbColor) -> TerminalColor {
    TerminalColor::rgb(color.r, color.g, color.b)
}

fn convert_style(cell: &libghostty_vt::render::CellIteration<'_, '_>) -> anyhow::Result<TerminalCellStyle> {
    let style = cell.style().context("read Ghostty cell style")?;
    Ok(TerminalCellStyle {
        foreground: cell.fg_color().context("read Ghostty foreground")?.map(convert_rgb),
        background: cell.bg_color().context("read Ghostty background")?.map(convert_rgb),
        bold: style.bold,
        italic: style.italic,
        underline: !matches!(style.underline, libghostty_vt::style::Underline::None),
        inverse: style.inverse,
        strikethrough: style.strikethrough,
    })
}
```

Adjust exact type paths based on crate exports; inspect `libghostty-vt-0.1.1/src/render.rs` and `style.rs` if needed.

- [ ] **Step 4: Replace text-only snapshot extraction**

Replace `VtState::snapshot_lines` with viewport-aware `VtState::snapshot_rows`. The exact Ghostty call for choosing scrollback rows depends on the available API discovered in Task 6, but the function signature and behavior must be:

```rust
fn snapshot_rows(&mut self, viewport: TerminalViewport) -> anyhow::Result<Vec<TerminalRow>> {
    // Required behavior:
    // - viewport.scroll_offset_rows == 0 renders the visible screen.
    // - viewport.scroll_offset_rows > 0 renders the requested main-screen scrollback window.
    // - alternate-screen mode renders alternate screen rows and does not expose main scrollback as the visible grid.
    let snapshot = self.render_state.update(&self.terminal).context("update Ghostty VT render state")?;

    // Use the Ghostty API identified in Task 6 to select the correct visible/scrollback rows here.
    // If no such API exists, Task 6 must have stopped the plan before this step.
    let mut rows = self.row_iter.update(&snapshot).context("iterate Ghostty VT render rows")?;
    let mut terminal_rows = Vec::new();

    while let Some(row) = rows.next() {
        let mut cells = self.cell_iter.update(row).context("iterate Ghostty VT render cells")?;
        let mut terminal_cells = Vec::new();
        while let Some(cell) = cells.next() {
            let text: String = cell.graphemes().context("read Ghostty cell graphemes")?.into_iter().filter(|ch| *ch != '\0').collect();
            terminal_cells.push(TerminalCell {
                text: if text.is_empty() { " ".to_string() } else { text },
                style: convert_style(cell)?,
            });
        }
        terminal_rows.push(TerminalRow { cells: terminal_cells });
    }

    Ok(terminal_rows)
}
```

Also update `VtState::new` to configure nonzero scrollback:

```rust
TerminalOptions { cols: size.cols, rows: size.rows, max_scrollback: 10_000 }
```

- [ ] **Step 5: Update backend snapshot**

In `BackendSessionState::snapshot`, build the new `TerminalGridSnapshot`:

```rust
let status = if state.exited { TerminalStatus::Exited(state.exit_status) } else { TerminalStatus::Running };
Ok(TerminalGridSnapshot {
    size: state.size,
    rows: state.snapshot_rows(viewport)?,
    cursor: state.cursor()?,
    status,
    viewport,
    scrollback_rows: state.scrollback_rows(),
    screen_mode: state.screen_mode(),
})
```

Convert `cursor()` to return `Option<TerminalCursor>`. Implement `scrollback_rows()` and `screen_mode()` from Ghostty VT APIs when available; otherwise use the decision notes required by Task 6 and keep the fields honest rather than claiming unsupported behavior.

- [ ] **Step 6: Run tests**

Run:

```bash
cargo test --test terminal_render_tests --test terminal_session_tests
cargo test --test terminal_render_tests real_backend_extracts_styled_ansi_cells -- --ignored --nocapture
```

Update any `wait_for_snapshot_text` helper to call `snapshot(session, TerminalViewport::visible(24))` and inspect `snapshot.plain_lines().join("\n")`.

Expected: non-ignored tests PASS; ignored real test PASS when Ghostty native build is available.

- [ ] **Step 7: Commit**

```bash
git add src/terminal tests/terminal_render_tests.rs tests/terminal_session_tests.rs
git commit -m "feat: snapshot styled Ghostty terminal cells"
```

---

## Task 8: Add Action Registry for Repo/Worktree Actions

**Purpose:** Preserve all current actions while moving UI affordances into context/overflow menus and future command palette.

**Files:**
- Create: `src/app/action_registry.rs`
- Modify: `src/app/mod.rs`
- Test: `tests/action_registry_tests.rs`

- [ ] **Step 1: Write action inventory tests**

Create `tests/action_registry_tests.rs`:

```rust
use alas::app::{ActionAvailability, ActionHandlerId, ActionId, ActionRegistry, ActionScope};

#[test]
fn registry_contains_all_current_repo_and_worktree_actions() {
    let registry = ActionRegistry::default();
    let ids: Vec<_> = registry.actions().iter().map(|action| action.id).collect();

    assert!(ids.contains(&ActionId::AddRepository));
    assert!(ids.contains(&ActionId::RemoveRepository));
    assert!(ids.contains(&ActionId::CreateWorktree));
    assert!(ids.contains(&ActionId::RemoveWorktree));
    assert!(ids.contains(&ActionId::ArchiveWorktree));
    assert!(ids.contains(&ActionId::UnarchiveWorktree));
    assert!(ids.contains(&ActionId::PruneWorktrees));
    assert!(ids.contains(&ActionId::ToggleArchivedWorktrees));
    assert!(ids.contains(&ActionId::CommandSettings));
    assert!(ids.contains(&ActionId::SelectWorktree));
}

#[test]
fn destructive_actions_require_confirmation_metadata() {
    let registry = ActionRegistry::default();
    for id in [ActionId::RemoveRepository, ActionId::RemoveWorktree, ActionId::PruneWorktrees] {
        let action = registry.get(id).unwrap();
        assert!(action.destructive);
        assert!(action.requires_confirmation);
    }
}

#[test]
fn actions_are_scoped_for_context_menus() {
    let registry = ActionRegistry::default();
    assert_eq!(registry.for_scope(ActionScope::Repository).iter().filter(|a| a.id == ActionId::CreateWorktree).count(), 1);
    assert_eq!(registry.for_scope(ActionScope::Worktree).iter().filter(|a| a.id == ActionId::ArchiveWorktree).count(), 1);
}

#[test]
fn actions_include_availability_and_handler_identity() {
    let registry = ActionRegistry::default();
    let archive = registry.get(ActionId::ArchiveWorktree).unwrap();
    let unarchive = registry.get(ActionId::UnarchiveWorktree).unwrap();

    assert_eq!(archive.handler, ActionHandlerId::ArchiveWorktree);
    assert_eq!(unarchive.handler, ActionHandlerId::UnarchiveWorktree);
    assert_eq!(archive.availability, ActionAvailability::WhenWorktreeIsNotArchived);
    assert_eq!(unarchive.availability, ActionAvailability::WhenWorktreeIsArchived);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cargo test --test action_registry_tests
```

Expected: FAIL because action registry types do not exist.

- [ ] **Step 3: Implement registry**

Create `src/app/action_registry.rs`:

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ActionId {
    AddRepository,
    RemoveRepository,
    SelectWorktree,
    CreateWorktree,
    RemoveWorktree,
    ArchiveWorktree,
    UnarchiveWorktree,
    PruneWorktrees,
    ToggleArchivedWorktrees,
    CommandSettings,
    OpenPath,
    CopyPath,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ActionScope { Global, Repository, Worktree }

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ActionAvailability {
    Always,
    WhenRepositoryAvailable,
    WhenWorktreeAvailable,
    WhenWorktreeIsArchived,
    WhenWorktreeIsNotArchived,
    WhenWorktreeIsLinked,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ActionHandlerId {
    AddRepository,
    RemoveRepository,
    SelectWorktree,
    CreateWorktree,
    RemoveWorktree,
    ArchiveWorktree,
    UnarchiveWorktree,
    PruneWorktrees,
    ToggleArchivedWorktrees,
    CommandSettings,
    OpenPath,
    CopyPath,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActionDefinition {
    pub id: ActionId,
    pub label: &'static str,
    pub scope: ActionScope,
    pub availability: ActionAvailability,
    pub handler: ActionHandlerId,
    pub destructive: bool,
    pub requires_confirmation: bool,
}

#[derive(Debug, Clone)]
pub struct ActionRegistry { actions: Vec<ActionDefinition> }

impl Default for ActionRegistry {
    fn default() -> Self {
        Self { actions: vec![
            ActionDefinition { id: ActionId::AddRepository, label: "Add Repository", scope: ActionScope::Global, availability: ActionAvailability::Always, handler: ActionHandlerId::AddRepository, destructive: false, requires_confirmation: false },
            ActionDefinition { id: ActionId::RemoveRepository, label: "Remove from Alas", scope: ActionScope::Repository, availability: ActionAvailability::Always, handler: ActionHandlerId::RemoveRepository, destructive: true, requires_confirmation: true },
            ActionDefinition { id: ActionId::SelectWorktree, label: "Open Worktree", scope: ActionScope::Worktree, availability: ActionAvailability::WhenWorktreeAvailable, handler: ActionHandlerId::SelectWorktree, destructive: false, requires_confirmation: false },
            ActionDefinition { id: ActionId::CreateWorktree, label: "Create Worktree", scope: ActionScope::Repository, availability: ActionAvailability::WhenRepositoryAvailable, handler: ActionHandlerId::CreateWorktree, destructive: false, requires_confirmation: false },
            ActionDefinition { id: ActionId::RemoveWorktree, label: "Remove Worktree", scope: ActionScope::Worktree, availability: ActionAvailability::WhenWorktreeIsLinked, handler: ActionHandlerId::RemoveWorktree, destructive: true, requires_confirmation: true },
            ActionDefinition { id: ActionId::ArchiveWorktree, label: "Archive Worktree", scope: ActionScope::Worktree, availability: ActionAvailability::WhenWorktreeIsNotArchived, handler: ActionHandlerId::ArchiveWorktree, destructive: false, requires_confirmation: false },
            ActionDefinition { id: ActionId::UnarchiveWorktree, label: "Unarchive Worktree", scope: ActionScope::Worktree, availability: ActionAvailability::WhenWorktreeIsArchived, handler: ActionHandlerId::UnarchiveWorktree, destructive: false, requires_confirmation: false },
            ActionDefinition { id: ActionId::PruneWorktrees, label: "Prune Worktrees", scope: ActionScope::Repository, availability: ActionAvailability::WhenRepositoryAvailable, handler: ActionHandlerId::PruneWorktrees, destructive: true, requires_confirmation: true },
            ActionDefinition { id: ActionId::ToggleArchivedWorktrees, label: "Show/Hide Archived", scope: ActionScope::Repository, availability: ActionAvailability::Always, handler: ActionHandlerId::ToggleArchivedWorktrees, destructive: false, requires_confirmation: false },
            ActionDefinition { id: ActionId::CommandSettings, label: "Command Settings", scope: ActionScope::Repository, availability: ActionAvailability::WhenRepositoryAvailable, handler: ActionHandlerId::CommandSettings, destructive: false, requires_confirmation: false },
            ActionDefinition { id: ActionId::OpenPath, label: "Open Path", scope: ActionScope::Worktree, availability: ActionAvailability::WhenWorktreeAvailable, handler: ActionHandlerId::OpenPath, destructive: false, requires_confirmation: false },
            ActionDefinition { id: ActionId::CopyPath, label: "Copy Path", scope: ActionScope::Worktree, availability: ActionAvailability::WhenWorktreeAvailable, handler: ActionHandlerId::CopyPath, destructive: false, requires_confirmation: false },
        ]}
    }
}

impl ActionRegistry {
    pub fn actions(&self) -> &[ActionDefinition] { &self.actions }
    pub fn get(&self, id: ActionId) -> Option<&ActionDefinition> { self.actions.iter().find(|a| a.id == id) }
    pub fn for_scope(&self, scope: ActionScope) -> Vec<&ActionDefinition> { self.actions.iter().filter(|a| a.scope == scope).collect() }
}
```

- [ ] **Step 4: Export registry**

Modify `src/app/mod.rs`:

```rust
pub mod action_registry;
pub use action_registry::{ActionAvailability, ActionDefinition, ActionHandlerId, ActionId, ActionRegistry, ActionScope};
```

- [ ] **Step 5: Run tests**

Run:

```bash
cargo test --test action_registry_tests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/app tests/action_registry_tests.rs
git commit -m "feat: define repo and worktree action registry"
```

---

## Task 9: Add File Tree Service for Files Inspector

**Purpose:** Provide a testable Files tab data source rooted at the selected worktree.

**Files:**
- Create: `src/project/mod.rs`
- Create: `src/project/file_tree.rs`
- Modify: `src/lib.rs`
- Test: `tests/file_tree_tests.rs`

- [ ] **Step 1: Write file tree tests**

Create `tests/file_tree_tests.rs`:

```rust
use alas::project::FileTreeService;

#[test]
fn file_tree_lists_directories_before_files_and_skips_git() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir(dir.path().join("src")).unwrap();
    std::fs::create_dir(dir.path().join(".git")).unwrap();
    std::fs::write(dir.path().join("Cargo.toml"), "[package]").unwrap();
    std::fs::write(dir.path().join("src/main.rs"), "fn main() {}").unwrap();

    let tree = FileTreeService::new().load(dir.path(), 2).unwrap();
    let names: Vec<_> = tree.children.iter().map(|node| node.name.as_str()).collect();

    assert_eq!(names, vec!["src", "Cargo.toml"]);
    assert!(tree.children.iter().all(|node| node.name != ".git"));
}

#[test]
fn file_tree_depth_limits_children() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(dir.path().join("a/b")).unwrap();
    std::fs::write(dir.path().join("a/b/file.txt"), "x").unwrap();

    let tree = FileTreeService::new().load(dir.path(), 1).unwrap();
    let a = tree.children.iter().find(|node| node.name == "a").unwrap();

    assert!(a.children.is_empty());
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cargo test --test file_tree_tests
```

Expected: FAIL because `alas::project` does not exist.

- [ ] **Step 3: Implement file tree service**

Create `src/project/mod.rs`:

```rust
pub mod file_tree;
pub use file_tree::{FileTreeNode, FileTreeService};
```

Create `src/project/file_tree.rs`:

```rust
use anyhow::Context;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileTreeNode {
    pub name: String,
    pub path: PathBuf,
    pub is_dir: bool,
    pub children: Vec<FileTreeNode>,
}

#[derive(Debug, Default, Clone, Copy)]
pub struct FileTreeService;

impl FileTreeService {
    pub fn new() -> Self { Self }

    pub fn load(&self, root: &Path, max_depth: usize) -> anyhow::Result<FileTreeNode> {
        load_node(root, root, max_depth)
    }
}

fn load_node(root: &Path, path: &Path, depth_remaining: usize) -> anyhow::Result<FileTreeNode> {
    let metadata = std::fs::metadata(path).with_context(|| format!("read metadata for {}", path.display()))?;
    let is_dir = metadata.is_dir();
    let name = if path == root {
        path.file_name().and_then(|n| n.to_str()).unwrap_or("worktree").to_string()
    } else {
        path.file_name().and_then(|n| n.to_str()).unwrap_or("").to_string()
    };

    let mut children = Vec::new();
    if is_dir && depth_remaining > 0 {
        let mut entries = std::fs::read_dir(path)
            .with_context(|| format!("read directory {}", path.display()))?
            .filter_map(Result::ok)
            .filter(|entry| entry.file_name().to_string_lossy() != ".git")
            .collect::<Vec<_>>();

        entries.sort_by_key(|entry| {
            let is_file = entry.file_type().map(|t| t.is_file()).unwrap_or(true);
            (is_file, entry.file_name().to_string_lossy().to_string())
        });

        for entry in entries {
            children.push(load_node(root, &entry.path(), depth_remaining - 1)?);
        }
    }

    Ok(FileTreeNode { name, path: path.to_path_buf(), is_dir, children })
}
```

- [ ] **Step 4: Export module**

Modify `src/lib.rs`:

```rust
pub mod project;
```

- [ ] **Step 5: Run tests**

Run:

```bash
cargo test --test file_tree_tests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/project src/lib.rs tests/file_tree_tests.rs
git commit -m "feat: load worktree file tree"
```

---

## Task 10: Add Inspector State for Files and Changes Tabs

**Purpose:** Separate right pane state from raw Git inspector rendering.

**Files:**
- Create: `src/app/inspector_state.rs`
- Modify: `src/app/mod.rs`
- Test: `tests/inspector_state_tests.rs`

- [ ] **Step 1: Write inspector state tests**

Create `tests/inspector_state_tests.rs`:

```rust
use alas::app::{InspectorPaneState, InspectorTab};

#[test]
fn files_and_changes_errors_are_independent() {
    let mut state = InspectorPaneState::default();
    state.set_files_error("files failed");

    assert_eq!(state.files_error.as_deref(), Some("files failed"));
    assert!(state.changes_error.is_none());

    state.set_changes_error("git failed");
    assert_eq!(state.files_error.as_deref(), Some("files failed"));
    assert_eq!(state.changes_error.as_deref(), Some("git failed"));
}

#[test]
fn selected_tab_can_switch_between_files_and_changes() {
    let mut state = InspectorPaneState::default();
    assert_eq!(state.selected_tab, InspectorTab::Files);
    state.select_tab(InspectorTab::Changes);
    assert_eq!(state.selected_tab, InspectorTab::Changes);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
cargo test --test inspector_state_tests
```

Expected: FAIL because inspector state types do not exist.

- [ ] **Step 3: Implement state**

Create `src/app/inspector_state.rs`:

```rust
use crate::{git::GitInspectorState, project::FileTreeNode};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InspectorTab { Files, Changes }

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct InspectorPaneState {
    pub selected_tab: InspectorTab,
    pub files: Option<FileTreeNode>,
    pub files_error: Option<String>,
    pub changes: Option<GitInspectorState>,
    pub changes_error: Option<String>,
}

impl Default for InspectorTab {
    fn default() -> Self { Self::Files }
}

impl InspectorPaneState {
    pub fn select_tab(&mut self, tab: InspectorTab) { self.selected_tab = tab; }
    pub fn clear_for_new_worktree(&mut self) {
        self.files = None;
        self.files_error = None;
        self.changes = None;
        self.changes_error = None;
    }
    pub fn set_files_error(&mut self, error: impl Into<String>) { self.files = None; self.files_error = Some(error.into()); }
    pub fn set_changes_error(&mut self, error: impl Into<String>) { self.changes = None; self.changes_error = Some(error.into()); }
}
```

- [ ] **Step 4: Export state**

Modify `src/app/mod.rs`:

```rust
pub mod inspector_state;
pub use inspector_state::{InspectorPaneState, InspectorTab};
```

- [ ] **Step 5: Run tests**

Run:

```bash
cargo test --test inspector_state_tests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/app tests/inspector_state_tests.rs
git commit -m "feat: model files and changes inspector state"
```

---

## Task 11: Wire Workspace Session into Shell

**Purpose:** Replace one active terminal session per worktree with active terminal tab per worktree while preserving current behavior.

**Files:**
- Modify: `src/ui/shell.rs`
- Modify: `src/terminal/session.rs` if needed
- Test: existing `cargo test`

- [ ] **Step 1: Add fields to `AlasShell`**

In `src/ui/shell.rs`, add imports:

```rust
use crate::app::{WorkspaceSession, TerminalTabId, TerminalTabKind};
```

Add fields:

```rust
workspace_session: WorkspaceSession,
active_terminal_tab: Option<TerminalTabId>,
```

Initialize in `AlasShell::new`:

```rust
workspace_session: WorkspaceSession::default(),
active_terminal_tab: None,
```

- [ ] **Step 2: Update `select_worktree`**

Replace direct `TerminalSessionId::new(repo_id, path)` with default tab creation:

```rust
let command = self.resolve_default_command(&repo_id, path.clone());
let tab_id = self.workspace_session.ensure_default_terminal_tab(&repo_id, path.clone(), command.clone());
let id = TerminalSessionId::new(repo_id.clone(), path.clone(), tab_id);
```

Store:

```rust
self.active_terminal_tab = Some(tab_id);
```

- [ ] **Step 3: Keep current UI compiling**

Continue setting `self.active_terminal = Some(session)` as a transitional bridge. Later tasks will render tab strips and multiple tabs.

- [ ] **Step 4: Run tests and app check**

Run:

```bash
cargo test
cargo run
```

Manual expected: selecting a worktree still starts a terminal as before.

- [ ] **Step 5: Commit**

```bash
git add src/ui/shell.rs src/terminal/session.rs
git commit -m "feat: route worktree terminals through workspace session"
```

---

## Task 12: Render Terminal Grid, Cursor, and Scroll View

**Purpose:** Replace raw `snapshot.lines.join("\n")` rendering with a real terminal grid view using styled rows/cells.

**Files:**
- Create: `src/ui/terminal_view.rs`
- Modify: `src/ui/mod.rs`
- Modify: `src/ui/terminal_pane.rs`
- Modify: `src/ui/shell.rs`

- [ ] **Step 1: Create terminal view API**

Create `src/ui/terminal_view.rs`:

```rust
use crate::terminal::{TerminalCell, TerminalGridSnapshot};
use gpui::{IntoElement, ParentElement, SharedString, Styled, div, prelude::*, px, rgb};

pub fn render_terminal_grid(snapshot: &TerminalGridSnapshot) -> impl IntoElement {
    div()
        .flex()
        .flex_col()
        .font_family("monospace")
        .text_sm()
        .line_height(px(18.0))
        .children(snapshot.rows.iter().enumerate().map(|(row_index, row)| {
            div().flex().children(row.cells.iter().enumerate().map(move |(col_index, cell)| {
                render_cell(cell, snapshot.cursor.is_some_and(|cursor| cursor.row as usize == row_index && cursor.col as usize == col_index))
            }))
        }))
}

fn render_cell(cell: &TerminalCell, is_cursor: bool) -> impl IntoElement {
    let mut element = div().child(SharedString::from(cell.text.clone()));
    if let Some(fg) = cell.style.foreground { element = element.text_color(rgb(((fg.r as u32) << 16) | ((fg.g as u32) << 8) | fg.b as u32)); }
    if let Some(bg) = cell.style.background { element = element.bg(rgb(((bg.r as u32) << 16) | ((bg.g as u32) << 8) | bg.b as u32)); }
    if is_cursor { element = element.bg(rgb(0xe5e7eb)).text_color(rgb(0x111827)); }
    element
}
```

This is a first pass. If GPUI performance requires a custom painted element, keep this public function but replace internals with the lower-level element from the feasibility gate.

- [ ] **Step 2: Export module**

Modify `src/ui/mod.rs`:

```rust
pub mod terminal_view;
```

- [ ] **Step 3: Replace raw terminal body**

In `src/ui/terminal_pane.rs`, import `render_terminal_grid` and replace:

```rust
snapshot.map(|snapshot| snapshot.lines.join("\n"))
```

with:

```rust
snapshot.map(render_terminal_grid)
```

If `when` type inference gets awkward, split terminal body into helper functions returning `AnyElement`.

- [ ] **Step 4: Add scroll offset plumbing**

Add a `terminal_scroll_offset_rows: usize` field to `AlasShell` or store the offset on the active `TerminalTab`. On scroll wheel events, update the offset and request a fresh backend snapshot with `TerminalViewport { scroll_offset_rows, visible_rows: terminal_size.rows }`. Clamp the offset to `snapshot.scrollback_rows`. In alternate-screen mode, scroll events should be forwarded to the PTY when appropriate instead of moving main-screen scrollback.

- [ ] **Step 5: Run tests and manual check**

Run:

```bash
cargo test
cargo run
```

Manual expected:

- terminal output renders without raw escape sequences
- cursor is visible
- color cells show color from Ghostty snapshot
- app remains responsive with long output

- [ ] **Step 6: Commit**

```bash
git add src/ui src/terminal
git commit -m "feat: render styled terminal grid"
```

---

## Task 13: Add Terminal Tab Strip and Command-Based New Tabs

**Purpose:** Expose multiple named terminal tabs per selected worktree in the center workspace.

**Files:**
- Create: `src/ui/workspace.rs`
- Create: `src/ui/command_picker.rs`
- Modify: `src/ui/mod.rs`
- Modify: `src/ui/shell.rs`
- Modify: `src/ui/terminal_pane.rs`

- [ ] **Step 1: Create workspace renderer**

Create `src/ui/workspace.rs`:

```rust
use crate::{app::{TerminalTab, TerminalTabId}, terminal::TerminalGridSnapshot};
use gpui::{App, ClickEvent, IntoElement, ParentElement, SharedString, Styled, Window, div, prelude::*, rgb};

pub fn render_workspace(
    tabs: &[TerminalTab],
    active_tab: Option<TerminalTabId>,
    snapshot: Option<&TerminalGridSnapshot>,
    terminal_error: Option<&str>,
    on_select_tab: impl Fn(TerminalTabId, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_new_tab: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    terminal_body: impl IntoElement,
) -> impl IntoElement {
    div()
        .id("workspace-card")
        .flex()
        .flex_col()
        .flex_1()
        .m_4()
        .rounded_lg()
        .border_1()
        .border_color(rgb(0x34363a))
        .bg(rgb(0x1e1f22))
        .child(render_tab_bar(tabs, active_tab, on_select_tab, on_new_tab))
        .child(terminal_body)
}

fn render_tab_bar(
    tabs: &[TerminalTab],
    active_tab: Option<TerminalTabId>,
    on_select_tab: impl Fn(TerminalTabId, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
    on_new_tab: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
) -> impl IntoElement {
    div()
        .flex()
        .items_center()
        .gap_3()
        .px_4()
        .h(gpui::px(48.0))
        .border_b_1()
        .border_color(rgb(0x303238))
        .children(tabs.iter().map(|tab| {
            let tab_id = tab.id;
            let active = Some(tab_id) == active_tab;
            let on_select_tab = on_select_tab.clone();
            div()
                .id(SharedString::from(format!("terminal-tab-{}", tab.id.0)))
                .py_3()
                .text_color(if active { rgb(0xffffff) } else { rgb(0xa7abb3) })
                .border_b_2()
                .border_color(if active { rgb(0x2d9cff) } else { rgb(0x1e1f22) })
                .child(SharedString::from(tab.name.clone()))
                .on_click(move |event, window, cx| on_select_tab(tab_id, event, window, cx))
        }))
        .child(div().ml_auto().text_color(rgb(0xa7abb3)).child("+").on_click(on_new_tab))
}
```

- [ ] **Step 2: Create command picker renderer**

Create `src/ui/command_picker.rs` with a minimal V1 picker that lists configured commands from `ResolvedRepoConfig` and emits the selected command name/command string. The picker can be a simple in-app popover/panel if GPUI native menus are not available.

```rust
use crate::config::CommandEntry;
use gpui::{App, ClickEvent, IntoElement, ParentElement, SharedString, Styled, Window, div, prelude::*, rgb};
use indexmap::IndexMap;

pub fn render_command_picker(
    commands: &IndexMap<String, CommandEntry>,
    on_select: impl Fn(String, String, &ClickEvent, &mut Window, &mut App) + Clone + 'static,
) -> impl IntoElement {
    div()
        .id("terminal-command-picker")
        .flex()
        .flex_col()
        .rounded_md()
        .border_1()
        .border_color(rgb(0x34363a))
        .bg(rgb(0x27282b))
        .children(commands.iter().map(|(name, entry)| {
            let name = name.clone();
            let command = entry.command.clone();
            let on_select = on_select.clone();
            div()
                .px_3()
                .py_2()
                .child(SharedString::from(format!("{name} — {command}")))
                .on_click(move |event, window, cx| on_select(name.clone(), command.clone(), event, window, cx))
        }))
}
```

- [ ] **Step 3: Export modules**

Modify `src/ui/mod.rs`:

```rust
pub mod command_picker;
pub mod workspace;
```

- [ ] **Step 4: Add tab selection and command picker handlers in shell**

In `src/ui/shell.rs`, add listeners for:

- selecting a tab: update `WorkspaceSession::set_active_tab`, start/reuse backend session for that tab, update `active_terminal`
- pressing `+`: open command picker populated from `ResolvedRepoConfig::commands()` for the selected repository
- selecting a command: create a tab named from the command key and launch `CommandSpec::shell_command(entry.command, selected_worktree.path.clone())`

Do not implement the old “next configured command” shortcut; the V1 requirement is an explicit command choice.

- [ ] **Step 5: Replace center pane composition**

In `AlasShell::render`, obtain selected worktree tabs:

```rust
let workspace_tabs = self.model.selected_worktree()
    .map(|selected| self.workspace_session.tabs_for_worktree(&selected.repo_id, &selected.path))
    .unwrap_or(&[]);
```

Render `render_workspace(...)` around the terminal body.

- [ ] **Step 6: Run manual multi-tab check**

Run:

```bash
cargo run
```

Manual expected:

- selecting a worktree shows at least one terminal tab
- pressing `+` opens a command picker with configured commands
- selecting a command creates a named tab for that command
- switching tabs preserves each tab's output/process
- switching worktrees and returning preserves tab list and active tab

- [ ] **Step 7: Commit**

```bash
git add src/ui src/app
git commit -m "feat: add terminal tabs to workspace"
```

---

## Task 14: Redesign Sidebar with Action Registry Menus

**Purpose:** Preserve all repo/worktree actions while replacing chip clutter with a cleaner navigator and overflow/context entry points.

**Files:**
- Modify: `src/ui/sidebar.rs`
- Modify: `src/ui/shell.rs`
- Uses: `src/app/action_registry.rs`

- [ ] **Step 1: Simplify visible row layout**

In `src/ui/sidebar.rs`, change worktree row rendering to show:

- branch/worktree name
- archived/unavailable indicator
- main/linked indicator if useful
- diff counts if currently available; otherwise leave space for future data
- one overflow glyph `⋯` for actions

Remove always-visible `Open`, `Archive`, and `Remove` chips from each row.

- [ ] **Step 2: Add right-click/overflow menu state in shell**

If GPUI has stable popover/context menu support, use it. If not, implement a simple in-app overflow panel anchored near the sidebar row with the action registry entries.

Add state to `AlasShell`:

```rust
sidebar_menu: Option<SidebarMenuState>,
```

where `SidebarMenuState` records repository id, optional worktree path, and scope.

- [ ] **Step 3: Route menu actions to existing handlers**

Map `ActionId` to current shell methods:

- `RemoveRepository` -> `confirm_remove_repository`
- `CreateWorktree` -> `open_create_worktree_dialog`
- `CommandSettings` -> `open_command_settings_dialog`
- `PruneWorktrees` -> `confirm_prune_worktrees`
- `ToggleArchivedWorktrees` -> `set_show_archived`
- `ArchiveWorktree` -> `archive_worktree`
- `UnarchiveWorktree` -> `unarchive_worktree`
- `RemoveWorktree` -> `confirm_remove_worktree`
- `SelectWorktree` -> `select_worktree`

- [ ] **Step 4: Run existing tests**

Run:

```bash
cargo test
```

Expected: PASS.

- [ ] **Step 5: Manual action inventory check**

Run:

```bash
cargo run
```

Manual expected:

- all actions from `ActionRegistry` are reachable
- destructive actions still prompt
- archived toggle still works
- no row is cluttered with multiple action chips

- [ ] **Step 6: Commit**

```bash
git add src/ui/sidebar.rs src/ui/shell.rs
git commit -m "feat: redesign worktree navigator actions"
```

---

## Task 15: Render Files and Changes Inspector Tabs

**Purpose:** Replace the right Git-only inspector with Files and Changes tabs.

**Files:**
- Modify: `src/ui/inspector.rs`
- Modify: `src/ui/shell.rs`
- Uses: `src/app/inspector_state.rs`
- Uses: `src/project/file_tree.rs`

- [ ] **Step 1: Replace inspector renderer signature**

Change `render_git_inspector(...)` to `render_project_inspector(...)`:

```rust
pub fn render_project_inspector(
    selected_worktree: Option<&SelectedWorktree>,
    state: &InspectorPaneState,
    on_select_tab: impl Fn(InspectorTab, &gpui::ClickEvent, &mut gpui::Window, &mut gpui::App) + Clone + 'static,
) -> impl IntoElement
```

- [ ] **Step 2: Render tab bar**

Add a Files / Changes tab row. Active tab should use the same dark theme tokens as the rest of the shell.

- [ ] **Step 3: Render Files tree**

Add recursive helper:

```rust
fn render_file_node(node: &FileTreeNode, depth: usize) -> impl IntoElement {
    div()
        .pl(gpui::px((depth * 12) as f32))
        .text_sm()
        .child(format!("{} {}", if node.is_dir { "▸" } else { "☰" }, node.name))
}
```

Render loading, empty, and error states from `InspectorPaneState`.

- [ ] **Step 4: Render Changes tab**

Reuse changed files and branch data from `GitInspectorState`, but remove recent commits from V1 right pane unless you intentionally keep it below Changes. The spec only requires Files + Git changes.

- [ ] **Step 5: Load file tree on selection**

In `AlasShell::select_worktree`, clear inspector state and spawn both:

- existing Git inspector refresh into `InspectorPaneState::changes`
- new file tree load into `InspectorPaneState::files`

Make failures independent.

- [ ] **Step 6: Run tests and manual check**

Run:

```bash
cargo test
cargo run
```

Manual expected:

- right pane defaults to Files
- Files tree loads for selected worktree
- Changes tab shows changed files
- Files failure does not clear Changes and vice versa

- [ ] **Step 7: Commit**

```bash
git add src/ui/inspector.rs src/ui/shell.rs src/app/inspector_state.rs
git commit -m "feat: add files and changes inspector tabs"
```

---

## Task 16: Apply Dark Theme and Superconductor-Inspired Layout

**Purpose:** Polish the app shell into the desired three-pane dark layout.

**Files:**
- Create: `src/ui/theme.rs`
- Modify: `src/ui/mod.rs`
- Modify: `src/ui/shell.rs`
- Modify: `src/ui/sidebar.rs`
- Modify: `src/ui/terminal_pane.rs`
- Modify: `src/ui/workspace.rs`
- Modify: `src/ui/inspector.rs`

- [ ] **Step 1: Create theme tokens**

Create `src/ui/theme.rs`:

```rust
use gpui::{Rgba, rgb};

pub const APP_BG: Rgba = rgb(0x202124);
pub const SIDEBAR_BG: Rgba = rgb(0x27282b);
pub const PANEL_BG: Rgba = rgb(0x1e1f22);
pub const PANEL_BORDER: Rgba = rgb(0x34363a);
pub const TEXT: Rgba = rgb(0xe8eaed);
pub const TEXT_MUTED: Rgba = rgb(0x9aa0a6);
pub const ACCENT: Rgba = rgb(0x2d9cff);
pub const DANGER: Rgba = rgb(0xff6b7a);
pub const SUCCESS: Rgba = rgb(0x6ee08d);
```

- [ ] **Step 2: Export theme**

Modify `src/ui/mod.rs`:

```rust
pub mod theme;
```

- [ ] **Step 3: Apply shell layout**

In `src/ui/shell.rs`, set root background to `APP_BG`. Use left width around 280px, right width around 320px, center flex workspace with margins and rounded card.

- [ ] **Step 4: Apply theme to sidebar**

Use `SIDEBAR_BG`, `TEXT`, `TEXT_MUTED`, `PANEL_BORDER`, `ACCENT`, `DANGER`. Active worktree row should have clear selected border/background. Unavailable/archived states should be visible but subdued.

- [ ] **Step 5: Apply theme to workspace and inspector**

Use `PANEL_BG` for cards, `PANEL_BORDER` for borders, `ACCENT` for active tabs, and muted text for secondary metadata.

- [ ] **Step 6: Add bottom status bar**

In shell root, add a bottom bar showing:

- active repo/worktree branch/path summary
- active terminal tab name
- terminal status: running/exited/failed

- [ ] **Step 7: Manual visual pass**

Run:

```bash
cargo run
```

Manual expected:

- app resembles the Superconductor-inspired three-pane shell but remains distinct
- no large white/light panes remain in normal state
- sidebar is no longer a trainwreck of action chips
- center terminal card is visually dominant

- [ ] **Step 8: Commit**

```bash
git add src/ui
git commit -m "style: apply dark terminal workspace shell"
```

---

## Task 17: Improve Terminal Input, Resize, and Lifecycle UI

**Purpose:** Make v1 terminal behavior usable for shell basics, TUIs, and AI-agent sessions.

**Files:**
- Modify: `src/ui/shell.rs`
- Modify: `src/ui/terminal_view.rs`
- Modify: `src/ui/terminal_pane.rs`
- Modify: `src/terminal/ghostty_adapter.rs`
- Test: `tests/terminal_session_tests.rs`

- [ ] **Step 1: Expand key mapping tests if feasible**

If `terminal_input_bytes` can be made public to tests without leaking UI internals, move it into `src/terminal/input.rs` and test:

- enter -> `\r`
- backspace -> `0x7f`
- arrows -> CSI sequences
- Ctrl-C -> `0x03`
- escape -> `0x1b`

If GPUI keystroke construction is difficult, keep this as manual acceptance and document in `docs/manual-test.md`.

- [ ] **Step 2: Handle Option/Alt consciously**

Current code ignores `alt`. Decide during implementation:

- If GPUI exposes enough modifier/text data, map Option/Alt to terminal escape-prefix behavior for common keys.
- If not, document Option/Alt as a known V1 limitation in `docs/manual-test.md` and do not pretend it works.

- [ ] **Step 3: Improve resize calculation**

Replace hard-coded window subtraction with terminal view bounds if GPUI exposes them. Use measured terminal body size, not total window size. Keep conservative monospace cell metrics until custom measurement is available.

- [ ] **Step 4: Improve lifecycle rendering**

In terminal pane/workspace:

- startup failure: show command, cwd, cause, Retry, Edit Command
- process exit: keep final screen, show subtle status and Restart
- write/read failure: mark tab failed, do not kill other tabs

- [ ] **Step 5: Manual terminal acceptance smoke test**

Run:

```bash
cargo run
```

Verify:

- prompt editing works
- arrows/history work
- Ctrl-C works
- resize changes shell `stty size`
- failed command tab can be restarted

- [ ] **Step 6: Commit**

```bash
git add src/ui src/terminal docs/manual-test.md tests/terminal_session_tests.rs
git commit -m "feat: improve terminal input resize and lifecycle states"
```

---

## Task 18: Update Manual Acceptance Script

**Purpose:** Capture the v1 terminal and UI acceptance checks from the spec.

**Files:**
- Modify: `docs/manual-test.md`

- [ ] **Step 1: Replace manual test script**

Update `docs/manual-test.md` with sections:

```markdown
# Alas Manual Test Script

## Repository and Worktree Management

1. Start Alas with `cargo run`.
2. Add an existing Git repository.
3. Confirm main and linked worktrees appear in the left navigator.
4. Create a worktree.
5. Archive/unarchive it from the row menu.
6. Remove a linked worktree and confirm destructive prompt.
7. Prune stale worktrees and confirm destructive prompt.
8. Open command settings and configure at least two commands.

## Terminal Tabs

1. Select a worktree.
2. Confirm default terminal tab starts in that worktree.
3. Create a second terminal tab from configured commands.
4. Switch tabs and confirm output/process state is preserved.
5. Switch worktrees and return; confirm tabs still exist for the original worktree.

## Terminal Emulator Behavior

1. Shell basics: type, edit prompt, arrows/history, backspace/delete, Ctrl-C.
2. ANSI colors: run a 16/256/truecolor color script and confirm no raw escape sequences.
3. Scrollback: run `yes | head -1000`, scroll with trackpad/mouse.
4. Alternate screen: run `less README.md` and quit.
5. Editor: run `vim` or `nvim`, type text, quit without saving.
6. Live TUI: run `top` or `htop`, then quit.
7. AI agent: run `claude` or `codex` if installed; confirm long output survives tab/worktree switches.

## Files and Changes Inspector

1. Files tab shows worktree files.
2. Changes tab shows modified/untracked files.
3. File loading errors do not break terminal input.
```

- [ ] **Step 2: Commit**

```bash
git add docs/manual-test.md
git commit -m "docs: expand terminal workspace manual tests"
```

---

## Task 19: Final Verification and Cleanup

**Purpose:** Ensure the redesigned app is ready for review.

**Files:**
- Any files touched by formatting or final fixes.

- [ ] **Step 1: Format**

Run:

```bash
cargo fmt
```

Expected: no errors.

- [ ] **Step 2: Run full tests**

Run:

```bash
cargo test
```

Expected: PASS. If `libghostty-vt` native build requires environment setup, use documented `GHOSTTY_SOURCE_DIR` and record it in the final response.

- [ ] **Step 3: Run ignored terminal integration tests**

Run when Ghostty native build is available:

```bash
cargo test --test terminal_session_tests -- --ignored --nocapture
cargo test --test terminal_render_tests -- --ignored --nocapture
```

Expected: PASS or documented environment limitation.

- [ ] **Step 4: Run manual app acceptance**

Run:

```bash
cargo run
```

Follow `docs/manual-test.md`. Record any known limitations as TODOs in the final response or a follow-up issue doc.

- [ ] **Step 5: Commit final cleanup**

Only if formatting/fixes changed files:

```bash
git add -A
git commit -m "chore: finalize terminal workspace redesign"
```

---

## Notes for Implementers

- Do not begin broad UI migration unless Task 1 records a GPUI failure.
- Keep domain models testable without GPUI.
- Keep `TerminalBackend` as the boundary around PTY/Ghostty details.
- Do not reintroduce raw escape-code rendering as a fallback.
- Prefer small commits after every task.
- If a task reveals a serious unknown in `libghostty-vt` scrollback/alternate-screen APIs, stop and write a short decision note before improvising; do not claim scrollback or alternate-screen support without evidence.
