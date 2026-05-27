# Worktree Empty State Agent Entrypoints Design

Date: 2026-05-27
Status: Approved for implementation planning

## Goal

Update the center-pane empty state for a selected worktree so users can start work through three clear entrypoints:

- a normal terminal,
- an agent terminal,
- an agent chat session.

The agent-specific entrypoints should reuse the existing searchable agent launcher instead of introducing separate menus.

## User Experience

When a worktree has no open center tabs, the empty state remains centered but replaces the single `New terminal` button with a compact command list.

The header reads `No tabs open`. The subtitle reads `Choose how to start working in this worktree.`

The command rows are:

- `New Terminal`: opens a normal shell in the selected worktree.
- `New Agent Terminal`: opens the agent launcher in Terminal mode.
- `New Agent Chat`: opens the agent launcher in Chat mode.

Each row includes a leading icon, a primary label, a short secondary description, and a trailing shortcut chip when the corresponding shortcut has an effective binding. Shortcut chips are right-aligned so the labels form a stable left column and the keyboard hints scan as a separate right column.

## Launcher Behavior

The existing `AgentLauncherDialog` remains the only agent picker. Empty-state rows and global shortcuts open that dialog with a requested launch mode:

- Terminal mode filters to enabled terminal agents and launches `openAgentTerminalTab(for:agentId:)`.
- Chat mode filters to enabled ACP-capable agents and launches `openNewACPSession(agentID:)`.

The requested mode should be the initial mode for that invocation, but the dialog should keep its Terminal/Chat segmented control available. Users can still switch modes inside the dialog if they entered through the wrong row or shortcut.

The configured default launcher mode still applies to generic launcher openings that do not specify a mode.

## Shortcuts

The empty-state rows use the effective bindings from `AppState.binding(for:)`, so user overrides and unbound shortcuts are reflected in the UI.

Existing shortcuts stay unchanged:

- `New Terminal Tab`: `Command-T`
- `Launch Agent Terminal`: `Command-Option-T`

Add a new rebindable global shortcut action:

- `Launch Agent Chat`: `Command-Option-Shift-T`

The new action opens the agent launcher in Chat mode. It should appear in Settings > Shortcuts with the other Global actions and participate in existing shortcut conflict detection and terminal-reservation behavior.

## Components

### EmptyTabView

`EmptyTabView` should accept separate callbacks for normal terminal, agent terminal launcher, and agent chat launcher. It should also accept optional shortcut display strings or bindings for the three rows.

The row component should be local unless another nearby view already has a reusable command-row pattern. It should use the current theme colors and avoid card-heavy styling; these rows are commands, not content cards.

### CenterPaneView

`CenterPaneView` wires the empty-state rows to `AppState`:

- normal terminal calls the existing `openTerminal()` helper,
- agent terminal opens the launcher with `.terminal`,
- agent chat opens the launcher with `.acp`,
- shortcut strings come from the current effective shortcut bindings.

### AppState and Launcher Model

Add an API that opens the agent launcher with an optional requested mode. This should replace ad hoc mutation from views and preserve the current behavior of closing other overlays before showing the launcher.

The launcher model should distinguish the one-shot requested mode from its normal reset state. Opening with a requested mode should not permanently overwrite `config.agents.defaultLauncherMode`.

## Data Flow

1. User clicks `New Agent Terminal` or presses the terminal launcher shortcut.
2. `AppState` opens `AgentLauncherDialog` with requested mode `.terminal`.
3. The launcher filters enabled agents for terminal launch.
4. User selects an agent.
5. The launcher calls `openAgentTerminalTab(for:agentId:)` for the selected worktree.

Chat follows the same flow, except the requested mode is `.acp`, the list filters to ACP-capable enabled agents, and launch calls `openNewACPSession(agentID:)`.

Normal terminal launch bypasses the agent launcher and creates a standard terminal tab immediately.

## Error and Empty States

The existing launcher empty states remain responsible for missing agents:

- Terminal mode shows `No enabled agents`.
- Chat mode shows `No ACP-capable agents enabled` and the existing Settings guidance.

If there is no selected worktree when a launcher action fires, no launcher should open and no tab should be created. If the selected worktree changes while the launcher is open, launch uses the current selected worktree, matching existing behavior.

## Tests

Add focused Swift Testing coverage for:

- the new `ShortcutAction.launchAgentChat` label, group, default binding, and shortcut classification,
- shortcut conflict detection with the new action,
- opening the launcher with an explicit Terminal mode,
- opening the launcher with an explicit Chat mode,
- generic launcher opening still using `config.agents.defaultLauncherMode`,
- empty-state row configuration using effective shortcut bindings where practical.

Existing agent terminal and ACP launch tests should continue to cover the actual tab creation paths.

## Out of Scope

This change does not add separate per-row menus, direct default-agent launching, new ACP provider support, or persistence changes for ACP sessions.
