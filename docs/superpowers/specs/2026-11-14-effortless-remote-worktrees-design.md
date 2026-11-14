# Effortless Remote Worktrees

## Context

Today a repository on an SSH host is a separate Alas project with its own
sidebar group. You add it with the New Project dialog, typing the host and
the repository path. Nothing records the machines you use, and the New
Worktree dialog cannot place a worktree anywhere except where its project
already lives.

The plumbing underneath is already host-agnostic. A remote path is carried as
`/.alas-remote/<host><realPath>` (`RemotePath`), and nearly every call site
resolves the host from the worktree path (`RemoteHostRegistry.host(forPath:)`),
not from the project. `ProjectConfig.host` marks a project as remote.
`AppState.createWorktree(projectId:…)` already creates worktrees in SSH
projects end to end: `WorktreeLifecycle.preparedCreateWorktreeDestination`
renders the local path template, swaps in the remote home, and returns a
virtual path.

So placing a worktree on another machine mostly means picking a different
`projectId` at creation time and drawing the result in the right sidebar
group. The missing pieces are a machine list, a link between the same
repository on two machines, on-demand setup on a machine, and the UI.

Paired Macs (peers) are a different feature, "remote controlling another full
instance". This design does not touch them, the Peers sidebar section, or peer
views.

## Goals

- Choosing where a new worktree runs is part of creating it. The choice is a
  single picker that defaults to what you used last for that project.
- A remote worktree looks and behaves like a local one, inside the same
  project group in the sidebar, with a small machine badge.
- Settings has a managed list of SSH machines.
- Your first worktree on a machine needs no setup dialog. Alas finds an
  existing clone in the machine's projects folder or clones one there.
- An unpushed base is one click to fix, not a dead end.

## Non-goals (v1)

- Peers and federation.
- Moving uncommitted local changes to another machine. Only pushed work
  travels.
- Repositories with no git remote on another machine.
- Adding a second machine to an SSH-only project, one with no local clone
  (see Open questions, settled).
- Workspaces whose members span machines.
- Editing SSH options (user, port, identity, jump host) inside Alas.
  `~/.ssh/config` stays the source of truth.

## Approaches

**A. Link records (chosen).** Keep Project as "one repository on one
execution location". The existing SSH `ProjectConfig` does the job of Orca's
per-machine "host setup" (project, host, path). Add a link from it to the
local project with the same git origin. A linked record gets no sidebar group
of its own. Its worktrees are listed under the local project, and it takes its
settings from there.

- Every worktree keeps a `projectId` whose record has exactly one path and one
  host, so git refresh, watchers, operation claims, the host APIs, and the
  ~45 path-keyed call sites keep working unchanged.
- No migration of saved projects is needed beyond one new optional field.
- The cost is a set of read sites that must treat a linked record as hidden
  (listed under Hidden linked records).

**B. One Project owning a clone per host (rejected).** `ProjectConfig` would
gain `locations: [host: path]`. It is the cleaner model, but it redefines
Project. It touches everything keyed on a project's single `path` and `host`:
refresh, watchers, Workspaces preflight, the host snapshot, and settings. It
needs a migration of saved projects, and it gives the same visible result as
A. We can move to B later if A's hidden-record exceptions grow out of hand.

## Concepts

- **Machine**: a user-managed SSH destination with a label and a projects
  folder. It is the UI name for an SSH execution location.
- **Primary project**: the project a sidebar group stands for. In v1 it is
  always a local project.
- **Linked project**: an SSH project whose `linkedProjectId` names a primary.
  It is the primary's checkout on one machine. It has no sidebar group of its
  own and uses the primary's settings.

## Data model

All of the following lives in `Packages/AlasCore`.

### `AppConfig.machines: [Machine]`

```swift
public struct Machine: Codable, Equatable, Identifiable, Sendable {
    public var id: String { destination }
    /// SSH destination exactly as passed to ssh: an alias or user@host.
    /// It is the identity used in RemotePath, so it cannot change once saved.
    public let destination: String
    public var label: String          // defaults to the alias
    /// Real path on the machine where clones go, e.g. "~/code".
    public var projectsFolder: String
}
```

- The decoder tolerates a missing key, like the rest of `AppConfig`.
- The destination must pass `RemotePath.isValidHost`.
- The label and projects folder can be edited. Changing the destination means
  removing the machine and adding it again, because every virtual path and
  worktree id embeds it.
- The default projects folder is the local `repositoryCloneRootPath` with the
  local home swapped for `~`, reusing `destinationPathReplacingLocalHome`. If
  that path is empty or outside home, the default is `~/code`.
- Seeding: on load, every distinct `host` of an existing SSH project that is
  not yet in the list is added with label = host. This makes Run on show
  machines people already use, with no setup.

### `ProjectConfig.linkedProjectId: String?`

- Persisted, omitted when nil.
- Valid only when `host != nil`, `kind == .git`, and the target exists and is
  local.
- There is at most one linked record per (primary, host).
- The link is persisted rather than computed on each launch, so an offline
  machine's rows still group correctly. Reading a remote origin needs the
  machine to be online.

### `ProjectConfig.lastRunOnHost: String?`

- Stored on the primary. nil means This Mac.
- Written after a successful create.
- If the machine has since been removed, preselection falls back to This Mac
  in the picker. Nothing is created until the user confirms, so the
  never-silently-fall-back rule still holds.

## Linking

- **Identity.** Two projects match when
  `GitRemoteIdentity.normalized(originURL)` is equal and non-nil.
  `GitRemoteIdentity` already exists in `AlasFoundation`.
- **New links.** Run on creates a link directly when it sets up a machine for
  a primary.
- **Existing SSH projects (approved).** Each SSH git project without a link is
  checked when its host is reachable. The check reads `origin` with one
  `RemoteExec` call and matches it against local projects' origins. Exactly
  one match sets the link. No match leaves the record standalone, exactly as
  today. More than one local match, meaning two local clones of the same repo,
  also leaves it standalone: we do not guess. The check repeats on later
  launches while the record stays unlinked, so a local clone added later
  picks it up.
- **Removing the primary.** Every record linked to it has its link cleared and
  becomes a standalone project again. Nothing on the machine is deleted.
- **Removing a linked record** (from the machine badge menu, "Remove <host>
  checkout from Alas"). This behaves like removing a project today: its
  worktree rows go, and the files on the machine stay.

## Settings inheritance (my call)

One sidebar group means one set of settings. `ProjectsManager` gains
`settingsProject(for projectId:) -> ProjectConfig?`, which returns the primary
for a linked record and the project itself otherwise.

- **Inherited from the primary:** the read sites keyed by `worktree.projectId`
  that the inventory found. These are `mcpServers` (`AppState.swift`
  ~12791–13049), `startupScripts` (`AlasCoreContext+RepoHooks.swift:209`),
  shepherd (`ACPShepherdButton.swift:256`, `ACPStackShepherdPopover.swift:80`),
  runs (`AlasCoreContext+Runs.swift:172,453`), gg context
  (`AppState.swift:6073`), name, icon, `worktreeBranchTemplate`,
  `worktreeLaunchPreference`, and `ggMode`. Each switches to
  `settingsProject(for:)`.
- **Kept per record:** `path`, `host`, `cachedWorktrees`,
  `hiddenWorktreePaths`, `ggWorktreeModes`, `issueAttachments`,
  `pendingAutoBranchNames`, and `legacyWorktreeIDs`. All of these are keyed by
  worktree or describe the checkout itself.
- **Kept per record for safety:** `repoMCPTrust`, `approvedRepoHookHashes`,
  and `disabledRepoMCPServers`. Approving a repo hook on the Mac must not
  approve it on a machine.
- **Ignored for linked records:** `vmForNewWorktrees` and
  `vmGuestSetupScript`, which only apply locally.
- **Remote caveat:** startup scripts run on the machine. A script that assumes
  local paths will fail there, and the failure is reported as it is today.
- The project settings sheet of a linked record is not reachable, because the
  record has no group to open it from.

## Sidebar

```
▾ alas
    main
    fix/sidebar-jank
    feat/remote-stack        ⌁ mini
    spike/host-grouping      ⌁ devbox ○
```

- `SidebarView.projectRow` builds the group from
  `projectsManager.visibleWorktrees(projectId:)`. Add
  `visibleWorktrees(includingLinkedTo primaryId:)`, which concatenates the
  primary's worktrees with those of every record linked to it. `projectRow`
  and `filteredWorktreeIds()` (`SidebarView.swift:428`) use it.
- **Ordering.** Use the primary's `worktreeOrder` and `worktreeOrderIsManual`
  over the merged set. Worktree ids are unique across hosts, because remote
  ids are virtual paths. Drag reorder writes the primary's order. Default
  sort modes apply to the merged list as usual.
- **Badge.** Linked rows show `⌁ <machine label>`. The state comes from
  `RemoteHostStatusStore.reachability(for:)`: online shows plain, unknown is
  dimmed, offline shows `○`. The decision (label, state, whether to show) goes
  in a plain function on `WorktreeRowPresentation`.
- **Offline.** Rows render from `cachedWorktrees`, as SSH projects already do.
  The context menu gains "Reconnect to <label>", which runs the existing
  reconnect / connection-assistant path for that host.
- **Main checkout.** When Alas cloned a repository on a machine, the clone's
  main worktree path goes into that record's `hiddenWorktreePaths`, so the
  sidebar does not show a stray `main ⌁ mini` row. An existing SSH project
  that gets folded keeps its rows as they are.
- **Spaces.** A linked record is never a space member of its own.
  `AppState.swift:1880` (auto-add unassigned projects to a space) skips linked
  records. When a record becomes linked, it is removed from any space. Its
  rows appear wherever the primary appears.

## Hidden linked records

Places that list projects must treat a linked record as part of its primary,
not as a project of its own. Add `ProjectsManager.primaryProjects` (projects
where `linkedProjectId == nil`) and use it in the following places:

- **Sidebar tree and Spaces pane:** `WorkspaceSidebarTree.swift:64`,
  `SpacesPane.swift:41`.
- **Pickers:** `worktreeProjects` (`AppState.swift:5814`), `ProjectPicker`,
  `RepoSelectorModel` (`AppState.swift:3274` env), Workspace dialogs,
  `RunScheduleEditorView`, `AttachIssueDialogModel`, `WorktreesPane`, and
  `ChangesPane`.
- **Repo selector worktree list** (`RepoSelectorModel`): use
  `visibleWorktrees(includingLinkedTo:)`, so remote worktrees are findable
  under their project.
- **Repo selector recents:** these stay keyed by real `projectId`. A recent
  remote worktree records its linked record's id. That is still correct for
  selection, and the selector maps it to the primary when it shows the
  project name.
- **Search `allWorktrees`** (`AppState.swift:10305`): no change. It already
  iterates every project and sets `executionLocation` from `project.host`, so
  remote worktrees stay searchable. Only the displayed project name maps to
  the primary.
- **`alas` CLI / MCP `worktree_*`** (`AlasCLICommandRouter.swift:280–303`):
  - `list` and `switch` filter by `projectId == origin.projectId`. Change the
    filter to "same primary", so an agent in a local worktree sees the remote
    ones and the other way round.
  - `new` keeps creating on the caller's own record, so an agent on mini
    creates on mini. Run on for the CLI is out of scope for v1.
- **Host APIs and iOS** (`ProjectsAPI.list`, `ProjectSnapshot`): add
  `linkedProjectId` to `ProjectSnapshot` and keep listing every record. The
  wire format stays additive. The iOS and Mac remote clients fold linked
  records the same way. Clients that predate the field show them as today,
  as separate projects, which is acceptable.
  `HeadlessSessionPresenter.swift:169` (local only) is unchanged.
- **Workspaces:** unchanged. `WorkspaceDefinitionDialogModel` already
  restricts members to one execution location by `project.host`. Linked
  records are not offered as members (they are not in `primaryProjects`). An
  existing Workspace that already references an SSH project keeps resolving
  it by id. Workspace Checkouts across machines are out of scope.

## Machines pane (Settings)

A new `MachinesPane` sits in `Alas/Sources/Settings/` and is registered in
`SettingsNavView`.

- **List:** one row per machine, showing the label, `destination`, the
  projects folder, a reachability dot, and "N projects" (count of SSH
  projects on that host).
- **Add machine…:** a sheet reusing `SSHHostPicker`, which lists
  `~/.ssh/config` aliases via `SSHConfigParser` and accepts a typed
  `user@host`. It also has a label field and a projects folder field, then
  Test and Save.
- **Test:** runs the existing `SSHConnectionAssistant` flow from
  `NewProjectDialog`. That is the interactive first contact (host key,
  password or 2FA) plus helper bootstrap. It reports success or the error, and
  then checks that the projects folder exists or can be created
  (`mkdir -p`). Extract the assistant from `NewProjectDialog` so both places
  share it. Do not copy it.
- **Edit:** label and projects folder only.
- **Remove:** takes the machine off the list only. Projects on that host keep
  working, because they only need the host string. Badges fall back to the
  host string. The machine still appears in Run on as ready for projects that
  have a linked record on it.
- **"Open ~/.ssh/config":** a link for user, port, identity and jump host.
- The empty state lists the `~/.ssh/config` aliases not yet added, each with
  an Add button.

## New Worktree dialog: Run on

The project picker keeps listing only primary projects. Below it, a **Run on**
type-ahead picker shows:

1. **This Mac**, showing the primary's path.
2. **Ready machines:** hosts with a linked record for this project, showing
   `label` and `host:path`, with a reachability dot.
3. **Needs setup:** machines in the list with no linked record, showing
   "Will set up in `<projectsFolder>`".
4. **Add machine…**, which opens Settings → Machines.

Behavior:

- **Preselection** uses `lastRunOnHost`, then This Mac.
- **Primary without an origin, or one that does not normalize:** only This
  Mac is enabled. The other rows are disabled with "No git remote: only this
  Mac can run it" (my call).
- **Choosing a ready machine** sets the create target to the linked record's
  id. Everything downstream already handles that: the agent list
  (host-scoped per the SSH agent environments design), the path subtitle
  (`host:path`), the gg stack availability (`isRemoteProject`), and the
  auto-name collision check (`isLocal`).
  - The branch list for the base field still comes from the primary, which is
    the repository the user knows.
  - The auto-name collision check also runs against the target record's
    branches.
- **Never fall back.** If the chosen machine is offline or setup fails, the
  dialog shows the error inline and keeps the selection. It never creates
  somewhere else.
- **Pure decision function.** The rows, their order, enablement and
  preselection come from a plain function in `AlasCore`:
  `RunOnOptions.make(primary:, linked:, machines:, reachability:)`. It is
  tested there.

### Base must be pushed

This check runs only when the target is a machine. It runs locally in the
primary:

- The base resolves to `origin/<b>` if the user picked a remote-tracking
  branch.
- Otherwise the base counts as pushed when `refs/remotes/origin/<b>` exists
  and `git rev-list --count origin/<b>..<b>` is 0.

If the base is not pushed, an inline notice appears ("`<b>` has N commits that
aren't on origin", or "`<b>` isn't on origin") with a **Push `<b>` and
continue** button.

- The button runs `git push -u origin <b>` through the push operation that
  `CommitPublishOperations` already uses, then continues the create.
- No force push. A rejected push shows git's message and the dialog stays
  open.
- Uncommitted local changes are never mentioned or moved.

### Creating on a machine

On the machine, creation always fetches first, whatever
`config.worktrees.fetchRemoteBeforeCreate` says. It then creates from
`origin/<b>`, not from the clone's own `<b>`, which may be stale.

- This is a new `WorktreeCreateRequest` flag, `createsFromFetchedOrigin`,
  which `finishCreate` honors. Local creation does not change.
- After that, the existing optimistic-row flow takes over and the dialog
  closes as it does today.

### First use of a machine: find or clone (approved: no setup dialog)

When the selected machine needs setup, pressing Create keeps the dialog open
and shows a progress line under Run on. The steps:

1. **Reach the machine.** Use the same connect and helper-bootstrap path as
   today. If this is first contact, the connection assistant appears in the
   dialog's existing assistant sheet.
2. **Find.** One `RemoteExec` call lists
   `git -C <dir> remote get-url origin` for each direct child of the projects
   folder. A child whose normalized origin matches is used. If several match,
   prefer the one named after the repository, otherwise the first by name.
3. **Clone.** Otherwise run
   `git clone --progress <origin URL> <projectsFolder>/<repo>` on the machine,
   using the first free name among `<repo>`, `<repo>-2`, and so on. Progress
   lines stream into the dialog.
   - The URL is the primary's origin URL as-is. If it uses an alias from the
     Mac's `~/.ssh/config` (`github-work:owner/repo`), it may not resolve on
     the machine. We do not rewrite URLs in v1. We show git's error and
     offer Choose folder….
   - The machine needs its own credentials for origin. An auth failure shows
     git's message plus "The machine needs access to <host>."
4. **Record.** Create the SSH `ProjectConfig` with host, virtual path,
   `linkedProjectId`, and the primary's name. A fresh clone's main path goes
   into `hiddenWorktreePaths`. Save it, and start the record's refresh and
   watcher as `addProject` does for SSH projects today.
5. **Continue** into the normal create on that record.

Cancel during the clone stops the remote process. git removes a partial clone
when it is interrupted. No record is written until step 4.

**Choose folder…** is an escape hatch next to the progress line. It takes a
typed remote path, the same field as `NewProjectDialog`'s SSH path, and checks
it with `RemoteRepoValidator`. The path must also have a matching origin
identity; otherwise it is refused with "This clone's origin is X, not Y".

The core of steps 2–4 lives in `AlasCore` as a
`RemoteCheckoutSetup.ensure(primary:, machine:)` service. Its decision parts
are pure and tested: choosing a matching child from the listing output, and
picking a free name.

## CONTEXT.md changes

- Keep **Project** as written: one repository on one execution location.
- Add:

> **Machine**: A user-managed SSH execution location with a label and a
> projects folder, offered when creating worktrees. _Avoid_: Host, peer
>
> **Linked Project**: A Project on a Machine connected to a primary local
> Project with the same git origin identity. It has no navigation entry of its
> own: its worktrees are listed under the primary, and it resolves Project
> settings from the primary. _Avoid_: Remote project, host setup
>
> **Run On**: The choice, made when creating a worktree, of the Project's
> location (this Mac or a Machine) the worktree is created in. An explicit
> choice never falls back to another location. _Avoid_: Target, environment

- Amend **Execution Location**: "In the UI, an SSH execution location is a
  Machine."

## Testing

These follow the repo's testing policy: pure decisions only, plus one git
integration test.

- Link matching: one match, none, or ambiguous; non-git and remote-less
  projects. Parameterized.
- `settingsProject(for:)` resolution, and its inherited vs per-record split,
  for one representative field from each group.
- `RunOnOptions.make`: order, enablement without an origin, preselection, and
  a removed last-used machine.
- `RemoteCheckoutSetup` decisions: matching child selection and free-name
  selection.
- Merged sidebar order: manual order across the primary and linked ids, and
  ids missing from the order.
- Base-pushed check: one real-git integration test against a template repo
  covering pushed, ahead, and never pushed.

No view tests. No tests for `Machine` decoding defaults.

## PR slicing

Each PR stands alone and is reviewable.

1. **`feat(remote): manage SSH machines in Settings`.** Adds the `Machine`
   model, seeding from existing SSH projects, `MachinesPane`, and the
   connection assistant extracted from `NewProjectDialog`.
2. **`feat(remote): fold SSH projects under their local project`.** Adds
   `linkedProjectId`, auto-linking, `primaryProjects` at the listed sites,
   `settingsProject(for:)`, the merged sidebar group with badge and
   reconnect, the snapshot field, CLI list/switch, and the `CONTEXT.md`
   update. This is the first user-visible change for existing SSH users.
3. **`feat(remote): choose where a new worktree runs`.** Adds Run on with
   This Mac and ready machines, `lastRunOnHost`, the pushed-base check and
   push button, and `createsFromFetchedOrigin`.
4. **`feat(remote): set up a machine on first use`.** Adds needs-setup rows,
   `RemoteCheckoutSetup` (find or clone), progress, cancel, and Choose
   folder….
5. **iOS/remote client folding**, if it is not small enough to ride along
   with 2.

## Open questions

**Settled here:**

- **SSH-only projects** do not gain a second machine in v1. They keep today's
  behavior, and their dialog shows no Run on choice. The link field does not
  preclude it later: a primary could be any project, and a local clone would
  reuse `RepositoryImportService.clone`.
- **Workspaces** are unchanged in v1 (see Hidden linked records).

**For Nacho:**

1. **Machine fields.** This design keeps only label, destination and projects
   folder, and defers user, port, identity and jump host to `~/.ssh/config`.
   Orca stores them per target. Is `~/.ssh/config` as the source of truth
   fine, or should the pane edit those fields?
2. **Main checkout row.** When Alas clones on a machine, the clone's main
   worktree is hidden from the sidebar. Folded existing SSH projects keep
   theirs. Agree?
