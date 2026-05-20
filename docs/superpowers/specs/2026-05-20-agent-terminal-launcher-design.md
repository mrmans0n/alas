# Agent Terminal Launcher Design

Date: 2026-05-20
Status: Approved for implementation planning

## Goal

Make it quick to launch an enabled CLI agent in the selected worktree without going through the new-worktree dialog. The existing new-terminal flow stays intact: `Command-T` and the tab-bar plus button continue to create a plain terminal tab.

## User Experience

The center tab bar gains a separate sparkle button beside the existing plus button. The plus button remains "New terminal". The sparkle button opens a compact native SwiftUI menu listing enabled agents from `state.agentRegistry.enabled()`. Selecting an agent opens a new terminal tab in the selected worktree and starts that agent inside the terminal session.

A new shortcut action defaults to `Command-Option-T`. It opens a small Cmd-K-style agent chooser. The chooser supports filtering enabled agents by display name. Pressing Return launches the selected agent in a new terminal tab. Escape dismisses the chooser without launching.

Both mouse and keyboard entry points perform the same launch action. They do not split the current terminal pane, reuse an existing terminal, or launch agents in the background.

## Empty State

If there are no enabled agents, the sparkle menu shows a disabled item such as "No enabled agents". The keyboard chooser shows an empty state explaining that no enabled agents are available. Neither entry point attempts to open a terminal when no agent is selected.

## Launch Behavior

Add one shared `AppState` API for manual agent launch:

```swift
func openAgentTerminalTab(for worktree: Worktree, agentId: String) throws -> Tab
```

The method resolves the agent from `agentRegistry.enabled()`, builds the startup command, and calls the existing terminal creation path with `startupScriptSuffix`.

Manual launches reuse the same bypass-permissions decision that new-worktree auto-launch uses:

- If the project agent mode is `.disabled`, do not append the bypass flag.
- If the project uses the global setting, use `config.agents.worktreeAutoLaunch.useBypassPermissions`.
- If the project overrides or appends to the global setting, use `project.startupScripts.worktreeAgentUseBypassPermissions`.
- Only append a bypass flag when the selected agent defines `bypassPermissionsFlag`.

Command construction should be centralized so worktree auto-launch and manual launch cannot drift.

## UI Components

### Tab Bar

`TabBarView` should accept the enabled agents and an agent-launch callback, or a compact view model that contains both. It renders:

- Existing split buttons when a terminal tab is active.
- Existing plus button for plain terminal creation.
- New sparkle menu button for enabled-agent launch.

The sparkle button should use the app's existing icon and menu style conventions. Built-in logos can be shown where practical, but display names are sufficient for the first implementation.

### Shortcut Chooser

Add a lightweight dialog or overlay similar in spirit to the existing file/repository pickers:

- Query field focused on appear.
- Filtered list of enabled agents.
- Keyboard navigation with Return and Escape.
- No persistence of the last query.

The chooser is opened by a new `ShortcutAction`, defaulting to `Command-Option-T`, and exposed in Settings > Shortcuts like other configurable actions.

## Data Flow

1. User clicks sparkle menu item or selects an agent in the shortcut chooser.
2. UI calls the shared `AppState` launch method with the selected `Worktree` and `agentId`.
3. `AppState` validates that the worktree's project still exists and the agent is still enabled.
4. `AppState` builds the command with the existing bypass-permissions rules.
5. `AppState.openTerminalTab(for:startupScriptSuffix:)` creates the terminal session and tab.
6. The new tab becomes selectable through the existing tab manager flow.

## Error Handling

If the project or agent disappears before launch, do nothing and avoid creating a terminal. If terminal creation throws, show a user-visible error through the existing app alert/error mechanism and leave the current selection unchanged.

The chooser should refresh from current `agentRegistry.enabled()` state each time it opens, so disabled or missing agents do not remain launchable.

## Tests

Add focused tests for:

- `ShortcutAction` contains the new action and defaults to `Command-Option-T`.
- Existing shortcut conflict detection handles the new action.
- Manual agent command construction matches worktree auto-launch bypass behavior.
- Launching an enabled agent appends a terminal tab with the expected startup suffix.
- Unknown, disabled, or missing agents do not launch.
- Empty enabled-agent lists produce no launchable action and do not crash.

No Xcode project regeneration is needed unless the implementation adds new source files and the project generator requires updates.
