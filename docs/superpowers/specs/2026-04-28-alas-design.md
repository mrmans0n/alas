# Alas Design Spec

Date: 2026-04-28
Status: Draft for review

## Overview

Alas is a local native desktop app for managing Git repositories, their worktrees, and persistent embedded terminals. It is inspired by Supacode's worktree-oriented workflow, but will follow Rust/native app conventions rather than cloning Supacode's UI exactly.

Alas v1 targets macOS and Linux. It will be built in Rust using GPUI, the UI framework used by Zed, and will embed terminal functionality through `libghostty-rs` behind an internal terminal adapter.

## Goals

- Let users configure repositories from the app UI.
- Show configured repositories in a left sidebar.
- Show each repository's Git-discovered worktrees below it.
- Let users create worktrees from a selected repository with branch-aware options.
- Keep one terminal session alive per selected worktree while the app is running.
- Show the selected worktree's terminal in the main center pane.
- Run a configurable default command when opening a worktree terminal.
- Provide a small read-only Git inspector for the selected worktree.
- Support archive/hide, remove, and prune workflows for worktrees with safe confirmations for destructive actions.

## Non-goals for v1

- Full Git client functionality such as staging, committing, stash management, branch management, or file diff browsing.
- Persistent terminal restoration across app restarts.
- Multiple top-level windows, though the architecture should not block this later.
- Tabs or multiple terminal sessions per worktree, though the terminal layer should leave room for this later.
- Cross-device sync or remote/shared configuration.
- Windows support.

## Recommended Architecture

Use a GPUI shell with separate domain services and a terminal adapter.

Top-level layers:

1. **GPUI app shell**
   - Renders the single main window, sidebar, terminal area, right Git inspector, dialogs, and context menus.
   - Requests actions from the app model and services.
   - Does not contain Git command logic, config precedence logic, or raw Ghostty handling.

2. **App model/state**
   - Tracks configured repositories.
   - Tracks selected repository and selected worktree.
   - Tracks visible and archived worktrees.
   - Tracks terminal session handles.
   - Tracks loading, error, and Git inspector state.

3. **Repository/config service**
   - Manages user-local app config.
   - Manages optional per-repository `.alas/config.toml` files.
   - Resolves configuration precedence.
   - Writes `.alas/config.toml` automatically when the user changes repo-specific settings.

4. **Git/worktree service**
   - Validates repositories.
   - Discovers worktrees.
   - Creates, removes, and prunes worktrees.
   - Gathers branch, status, changed-file, and recent-commit information.
   - Uses a hybrid implementation: Git CLI for worktree operations and behavior-sensitive commands, Rust Git libraries where useful for validation or status.

5. **Terminal service/adapter**
   - Owns persistent per-worktree terminal sessions.
   - Hides `libghostty-rs` details from GPUI components.
   - Provides a future extension point for tabs, multiple sessions, and session restoration.

6. **Command runner/process boundary**
   - Executes Git commands and configured terminal commands.
   - Applies cwd and environment isolation.
   - Returns structured success and error results.

## UI Structure

The main window uses a three-pane layout.

### Left sidebar: repositories and worktrees

- Shows configured repositories.
- Each repository has its own `+ Worktree` action.
- Worktrees are discovered from Git, not from separate app-maintained worktree records.
- Repository options include:
  - Add/remove repository from Alas. Removing a repository only removes it from app config; it never deletes the repository directory or its worktrees.
  - Show archived worktrees for that repository.
  - Prune stale worktrees.
  - Edit repo command settings.
- Worktree context menu includes:
  - Open/select.
  - Archive/hide from sidebar.
  - Unarchive/restore when archived worktrees are being shown.
  - Remove worktree for linked worktrees.
- The repository's main worktree can be selected and archived, but remove is disabled for it because Git does not treat the primary checkout like a removable linked worktree.
- Archived worktrees are stored in app-level config as local UI state and hidden unless the repository's hidden show-archived option is enabled.

### Center pane: embedded terminal

- Selecting a worktree shows its persistent terminal session.
- If no terminal session exists for that worktree, Alas creates one in the worktree directory and runs the repo's default command.
- Switching worktrees preserves existing sessions in memory.
- Closing the app terminates sessions normally in v1.

### Right inspector: Git details

- Shows selected worktree branch and path.
- Shows changed files.
- Shows a short recent commit list.
- May show simple ahead/behind or dirty status when cheap to compute.
- Remains small and read-only in v1.

## Dialogs

### Add repository

- Opens a folder picker.
- Validates that the selected folder is a Git repository.
- Saves the repository path/name to app-level config.
- Refreshes Git worktree discovery.

### Create worktree

- Opened from a specific repository's `+ Worktree` action.
- Lets the user choose:
  - Base branch or commit.
  - New branch name.
  - Target path/name.
- After successful creation, Alas selects the new worktree and launches the repository's default command. Per-worktree command overrides are out of scope for v1 because worktree existence is Git-discovered and Alas does not maintain separate authoritative worktree records.

### Command settings

- Supports named commands per repository with one default command.
- Also supports a single-command shorthand for simple repositories.

## Configuration Model

Alas uses two config scopes.

### App-level config

User-local app config stores:

- Configured repository paths and display names.
- Local UI preferences.
- Archived worktree paths per repository.
- Potential global defaults or shared command presets later.

The app-level config is local to the user and is not committed to project repositories by default.

### Per-repository config

Per-repository config lives at:

```text
.alas/config.toml
```

Alas writes this file automatically when the user changes repo-specific settings.

Example named-command form:

```toml
[commands]
default = "claude"

[commands.entries.claude]
command = "claude"

[commands.entries.codex]
command = "codex"

[commands.entries.shell]
command = "$SHELL"
```

Simple shorthand form:

```toml
default_command = "claude"
```

### Configuration precedence

- App-level config records that a repository exists and stores local-only UI state.
- `.alas/config.toml` overrides repository behavior where present.
- If no command is configured, Alas falls back to the user's default shell.

## Core Domain Objects

- `RepositoryConfig`
  - Repository id, path, display name, command settings, and optional repo overrides.
- `WorktreeInfo`
  - Path, branch/head, main/bare marker if relevant, and archived visibility from app config.
- `TerminalSessionId`
  - Derived from repository identity plus worktree path.
- `GitInspectorState`
  - Changed files, recent commits, branch/status summary, refresh state, and errors.

## Main Data Flows

### Add repository

1. User clicks `+ Add Repository`.
2. Alas opens a folder picker.
3. Git service validates the selected folder as a Git repository.
4. Config service saves the repository path/name in app-level config.
5. Git service discovers worktrees.
6. Sidebar updates.

### Create worktree

1. User clicks `+ Worktree` on a specific repository.
2. Dialog asks for base branch/commit, new branch name, and target path/name.
3. Git service runs the appropriate `git worktree add` flow.
4. App state refreshes; Git discovery picks up the new worktree.
5. Alas selects the new worktree.
6. Terminal service creates a terminal session in that worktree and runs the repo default command.

### Select worktree

1. User selects a worktree in the sidebar.
2. App model sets selected worktree.
3. Terminal service returns an existing session or creates a new one.
4. Center pane renders that terminal.
5. Git inspector refreshes changed files and recent commits for that worktree.

### Archive or unarchive worktree

1. User right-clicks a worktree and selects archive.
2. App-level config stores that repo/worktree path as archived.
3. Sidebar hides it unless that repository's show-archived option is enabled.
4. When archived worktrees are shown, the same context menu offers unarchive/restore.
5. Unarchive removes the path from the app-level archived list.
6. No Git filesystem state changes.

### Remove or prune worktrees

1. User chooses remove or prune from contextual or repository actions.
2. Alas shows a confirmation with exact paths and a destructive/non-destructive explanation.
3. Remove is available only for linked worktrees, not the repository's main checkout.
4. Git service runs `git worktree remove` or `git worktree prune`.
5. Sidebar refreshes from Git discovery.

### Terminal lifecycle

- Terminal sessions are persistent while the app is running.
- Switching worktrees does not terminate sessions.
- Closing the app terminates sessions normally in v1.
- Persistent terminal restoration across app restarts is out of scope.

## Error Handling

- **Invalid repository**: show a validation error and do not save the repository.
- **Missing or moved repository**: show the repository as unavailable with options to locate it again or remove it from app config.
- **Git command failure**: show command summary, stderr, and refresh discovery; do not assume state changed.
- **Existing branch/path conflicts**: validate obvious conflicts before running Git and show Git's exact error if it still fails.
- **Archived worktree no longer exists**: ignore the archive entry when Git discovery no longer returns the path; cleanup can happen opportunistically.
- **Per-repo config write failure**: show an error if `.alas/config.toml` cannot be written; app-level config remains unchanged unless the operation explicitly targets it.
- **Terminal launch failure**: center pane shows a retryable terminal error for that worktree; selecting other worktrees remains possible.
- **Terminal process exits**: terminal pane shows exit status and offers restart using the repo default command.
- **Git inspector refresh failure**: right panel shows stale or empty state with a non-blocking warning; terminal remains primary and usable.

Destructive Git actions such as remove and prune require confirmation showing affected paths. Removing a repository from Alas is not a destructive Git action and only removes local app configuration. Archive never deletes anything and must be reversible through the repository's show-archived option.

## Testing Strategy

### Config tests

- App config can add and remove repositories.
- `.alas/config.toml` is read and written correctly.
- Config precedence works.
- Missing command falls back to shell.
- Archived worktrees are app-local and do not require repo config changes.

### Git/worktree service tests

- Use temporary Git repositories.
- Discover worktrees with `git worktree list --porcelain`.
- Create a worktree from a base branch or commit.
- Remove worktree and prune stale entries.
- Handle branch/path conflict errors predictably.

### Terminal adapter tests

- Unit-test session registry behavior without requiring real Ghostty rendering.
- Verify one persistent session per selected worktree.
- Verify command and cwd selection.
- Keep libghostty integration behind an adapter so rendering-specific behavior can be tested separately or manually where automation is difficult.

### UI/model tests

- Selecting a worktree updates selected state and asks terminal service for the right session.
- Archive/hide filtering works per repository.
- Create-worktree success path selects and launches the new worktree.
- Git inspector refresh errors do not block terminal use.

### Manual acceptance tests

- Add repository, create worktree, and verify the terminal opens in the correct cwd.
- Switch between two worktrees and confirm terminals stay alive.
- Archive and unarchive visibility works.
- Removing a repository from Alas does not delete repository files or worktrees.
- Linked worktree removal is available with confirmation, while main worktree removal is disabled.
- Remove/prune confirmations prevent accidental destructive actions.
- Smoke-test on macOS and Linux.
