# Files Tab Show All Files Design

## Context

The right pane Files tab currently builds its tree from `git ls-files --cached --others --exclude-standard`. That shows tracked files and normal untracked files, but omits ignored files and entries excluded by Git. The goal is to make the Files tab capable of surfacing those non-Git entries without making large generated directories expensive to browse.

Untracked files are already represented in the app as normal files with the existing `A` status badge. This design preserves that behavior. The new visual treatment applies only to ignored or excluded entries.

## User Experience

The Files tab shows tracked, untracked, ignored, and excluded paths in one tree.

Tracked and untracked rows keep their current density, icon treatment, and status badges. Modified, added, deleted, and renamed status badges continue to use the existing `badge` behavior.

Ignored and excluded rows use the selected "ghost rail" affordance:

- dimmed file or folder icon and filename,
- a subtle left rail for ignored or excluded subtrees,
- a trailing pill that says `ignored` or `excluded`,
- regular tree placement so paths remain where users expect them.

The design does not introduce a separate "Not on git" group. Keeping ignored/excluded entries in place is more useful for navigation and avoids breaking the mental model of a filesystem tree.

## Lazy Enumeration

Initial Files tab refresh must not recursively walk ignored or excluded directories. Large directories such as `.build/`, `DerivedData/`, `node_modules/`, and `.swiftpm/` should be visible if present, but their children should be unknown until the user expands the directory.

The initial tree should include:

- the current Git-visible files from `git ls-files --cached --others --exclude-standard`,
- status badges from the existing status refresh,
- top-level ignored and excluded entries that are direct children of the worktree root.

When the user expands any directory, Alas may reconcile that directory's immediate filesystem children with the Git-visible tree. This is how ignored or excluded files nested under otherwise normal tracked directories become visible. Child directories remain lazy and enumerate one level at a time when expanded. This keeps expensive generated trees browseable without front-loading their full cost.

Normal tracked or untracked files can keep the existing eager tree behavior because Git already returns those paths cheaply. Directory expansion adds only missing ignored or excluded entries.

## Data Model

`FileTreeNode` should grow explicit metadata instead of overloading `badge`.

Proposed additions:

- `visibility`: `tracked`, `untracked`, `ignored`, or `excluded`.
- `childrenState`: `loaded`, `notLoaded`, or `loading`, only meaningful for directories.

`badge` remains the source for Git status badges such as `A`, `M`, `D`, and `R`. A plain untracked file continues to have `visibility == untracked` and `badge == "A"`.

Ignored/excluded files normally have no Git status badge. Their non-Git state is represented by `visibility` and rendered by the Files tab row. Classification should use Git's own ignore/exclude rules so the tree matches command-line behavior. Paths matched by repository `.gitignore` files are `ignored`; paths matched by `.git/info/exclude` or the user's global excludes file are `excluded`.

## Data Flow

`RightPaneState.refresh()` continues to fetch Git status and commits as it does today. Its file-tree call changes from "Git-visible files only" to "Git-visible files plus lazy filesystem entries."

The initial file tree service should:

1. Run the existing Git-visible listing for tracked and untracked files.
2. Merge status badges into those paths.
3. Enumerate only the worktree root's immediate filesystem children.
4. Use Git ignore/exclude classification for root children not present in the Git-visible set.
5. Add ignored/excluded root children as lazy directory nodes or leaf file nodes.

When a user expands a directory with `childrenState == notLoaded`, `FilesTabView` asks `RightPaneState` to load that path. `RightPaneState` delegates to `GitService`, which enumerates the immediate children and classifies missing non-Git entries as ignored or excluded before merging them into the existing tree.

## Rendering

`FilesTabView` remains responsible for recursive row rendering and expand/collapse state. It should add a row style branch for `visibility == ignored || visibility == excluded`.

For ignored/excluded rows:

- keep the same row height and monospace filename as normal rows,
- dim the icon and name using existing theme colors,
- draw a subtle vertical rail for ignored/excluded subtree rows,
- show a compact trailing pill with the visibility reason,
- show a loading affordance only while a lazy directory expansion is in flight.

The selected design should avoid a separate group header, because grouping would move paths away from their filesystem location.

## Errors

If lazy expansion fails for one ignored/excluded directory, the failure should stay local to that directory. The rest of the Files tab should remain usable. A small inline row under the directory can indicate that children could not be loaded.

If the initial ignored/excluded root scan fails, the app should still show the current Git-visible tree. The failure should be logged, matching the current right-pane refresh behavior.

## Tests

Add focused Swift Testing coverage for:

- tree building keeps current tracked and untracked status badge behavior,
- ignored and excluded nodes are represented distinctly from untracked `A` nodes,
- ignored/excluded directories can be present with children not loaded,
- loading one lazy directory adds only its immediate children,
- expanding a tracked directory can reveal an ignored/excluded child that was absent from the initial Git-visible tree,
- file and directory path collisions remain preserved with the expanded metadata.

Manual verification should include:

- ignored root directories such as `.build/` appear in the Files tab,
- expanding an ignored directory loads its first-level children without recursively walking the full tree,
- untracked files still render with the existing `A` badge,
- ignored/excluded rows use the ghost-rail affordance.
