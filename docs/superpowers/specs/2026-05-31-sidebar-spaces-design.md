# Sidebar Spaces Design

## Summary

Add Arc-style spaces to the left sidebar. A space is a named, emoji-backed view over the global Alas project list. Spaces let users organize repositories thematically, such as work, personal, client, or experiment groups, without creating separate project records or duplicating worktree state.

The current application behavior becomes the default single `Main` space. Existing users should see no visual sidebar change until they customize spaces.

## Goals

- Let a repository appear in one or more spaces.
- Scope the left sidebar project list to the active space.
- Keep search, repo selector, and keyboard jump surfaces global.
- Preserve existing project, worktree, tab, watcher, startup-script, and settings behavior.
- Keep the sidebar visually quiet by default.
- Support trackpad or mouse horizontal paging between spaces.
- Provide a compact bottom indicator modeled after Arc's space affordance.

## Non-Goals

- Do not duplicate project records per space.
- Do not scope tabs, agents, search indexes, or recents per space in v1.
- Do not add a permanent space title row to the top of the sidebar.
- Do not delete repositories or worktrees when removing a repo from a space.

## User Experience

Spaces are an organization layer over the sidebar. The active space controls which project groups appear in the left sidebar and in what order. Worktrees remain nested under their projects as they are today.

The bottom of the sidebar can show a centered emoji rail:

- The active space emoji is shown in full color.
- Inactive space emoji are shown grayscale and muted.
- When the active space changes, the space title appears above the emoji rail for a few seconds, then fades out.
- The rail is hidden while there is exactly one default space with the default name and emoji.
- The rail becomes visible if the user adds another space, renames the default space, or changes its emoji.

Users switch spaces with a horizontal paging gesture over the sidebar. The gesture changes to the previous or next space and updates the sidebar contents. Gesture handling should attach to the sidebar container rather than individual rows so project drag/drop, row context menus, and scrolling remain intact.

Each space remembers its last selected worktree. When switching spaces, Alas selects that remembered worktree if it still exists and is visible in the destination space. Otherwise it falls back to the first visible worktree in that space. If the destination space has no visible worktrees, the center pane uses the existing empty-state pattern.

Search and repo selector remain global. A user can jump to any project or worktree regardless of the active space. If the target project is not in the current space, Alas switches to a space that contains that project before selecting the target worktree. Prefer the most recently active containing space if available; otherwise use the first containing space in space order.

## Space Management

Space management lives in Settings, not as a permanent sidebar control. Settings should provide create, rename, emoji selection, reorder, delete, and membership review.

Project context menus get a membership submenu for adding or removing that project from spaces. The submenu shows checked spaces for the project. Toggling a check changes only membership, not the underlying project.

A project must belong to at least one space. If a project belongs to only one space, the UI should prevent unchecking its final membership and direct destructive removal through the existing global remove-project action.

The existing Add repository button adds the new project to the active space only. The project remains globally known to Alas and can later be added to other spaces from the project context menu or Settings.

Deleting a space removes only the space and its memberships. It does not delete projects, worktrees, tabs, or files. The final remaining space cannot be deleted. If the active space is deleted, Alas switches to a neighboring space.

Removing a project from Alas remains global. It removes the canonical project and strips the project id from every space.

## Data Model

Projects remain canonical in `ProjectConfig`. Space membership references project IDs.

Add a new persisted spaces file:

```swift
struct SpacesFile: Codable, Equatable {
    var version: Int
    var activeSpaceId: String
    var spaces: [SpaceConfig]
}

struct SpaceConfig: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var emoji: String
    var projectIds: [String]
    var lastSelectedWorktreeId: String?
    var createdAt: Date
}
```

The default migrated state is one space named `Main` with a default emoji and every existing project ID in current project order.

Space-level project ordering is represented by `SpaceConfig.projectIds`. Worktree ordering remains in `ProjectConfig.worktreeOrder`. Project settings such as name, color, path, hidden worktrees, startup scripts, and launcher defaults remain shared wherever the project appears.

Missing project IDs in spaces should be ignored and pruned on save. A missing `lastSelectedWorktreeId` should fall back to the first visible worktree in that space.

## Architecture

Add a `SpacesManager` responsible for:

- Loading and holding spaces.
- Exposing the active space.
- Computing active-space projects from canonical projects.
- Adding, removing, and toggling project memberships.
- Reordering spaces and projects within a space.
- Tracking last selected worktree per space.
- Determining whether the bottom affordance should be visible.
- Pruning stale project IDs from spaces.

Keep `ProjectsManager` responsible for canonical project records, project ordering where it still matters globally, worktree refresh, worktree visibility, and worktree operations.

`AppState` coordinates between managers:

- Load projects and spaces at startup.
- Save spaces separately from projects.
- Add new projects to the active space.
- Remove global projects from every space.
- Switch spaces and update selected worktree.
- Update a space's last selected worktree when selection changes inside that space.

`SidebarView` should render active-space projects rather than all projects. The view owns the gesture attachment and renders a `SpacePagerIndicator` at the bottom only when `SpacesManager` says the affordance should be visible.

Settings should reuse existing settings row/list patterns. The spaces UI should avoid introducing a large new architecture: a focused pane or section is enough for v1.

## Migration

On first launch with no spaces file:

1. Read existing projects as today.
2. Create one default space containing all project IDs in existing order.
3. Set it as the active space.
4. Do not show the bottom affordance because the space is still at default values.

This preserves today's sidebar for existing users.

## Testing

Add focused Swift Testing coverage for:

- Migration creates one default space containing all existing projects.
- A single default space hides the bottom affordance.
- Renaming the default space, changing its emoji, or adding another space shows the affordance.
- A project can belong to multiple spaces without duplicating `ProjectConfig`.
- Adding a repository adds membership to the active space only.
- Removing a project globally prunes it from every space.
- Deleting a space does not delete projects and cannot delete the final space.
- Switching spaces restores last selected worktree or falls back to the first visible worktree.
- Active-space sidebar ordering is independent from worktree ordering.
- Search/repo selector environment remains global.

Manual validation should cover:

- Horizontal paging on the sidebar does not interfere with vertical scrolling, project drag/drop, row context menus, or worktree drag/drop.
- The title fade feels calm and does not overlap sidebar content.
- Emoji grayscale treatment is legible across bundled themes.
