# Worktree GG Mode

Date: 2026-07-22
Status: Approved design

## Context

Alas currently stores `Off`, `Auto`, or `On` for each project. That setting
only controls the first three GG gates: the app-wide switch, GG installation,
and repository configuration. The Changes pane additionally requires a commit
with a `GG-ID:` trailer before it asks `gg ls --json` for the current stack.

This makes GG presentation unstable and incorrectly hides it for a valid empty
stack created with `gg co`. A transient `gg ls` failure also clears the stack
and silently restores the ordinary review-loop affordances. The user sees the
workflow change without a visible policy change or an explanation.

The existing manual project setting is only available in Settings. It cannot
express the common policy that linked worktrees use GG while the repository's
main worktree does not.

## Goals

- Make GG mode an explicit worktree policy with a repository-level default.
- Default GG-capable linked worktrees to GG mode and the main worktree to
  ordinary mode.
- Let each worktree explicitly inherit, enable, or disable GG mode.
- Recognize an eligible, empty GG stack without requiring a `GG-ID` commit.
- Keep GG presentation stable through empty results and transient refresh
  failures.
- Use one effective-mode decision for the Changes pane, sidebar, ACP context,
  and built-in `gg-mcp` attachment.
- Keep ordinary changes and review-loop behavior unchanged for worktrees where
  GG mode is not effective.

## Non-goals

- Changing GG's branch naming convention or stack metadata.
- Making GG available for registered remote projects; GG execution remains
  local-only.
- Replacing the app-wide stacked-diffs switch.
- Adding a permanent mode picker to the Changes header.
- Reworking stack actions, mutation coordination, or the GG Inbox workflow.

## Policy Model

The app-wide stacked-diffs switch remains the top-level availability control.
When it is off, no worktree may enter GG mode or attach GG-specific agent
context.

The existing project `Off`, `Auto`, and `On` setting becomes the default policy
for linked worktrees:

- `Off`: a linked worktree with no override resolves to Off.
- `Auto`: a linked worktree with no override resolves to On when the repository
  has local GG configuration; otherwise it resolves to Off.
- `On`: a linked worktree with no override resolves to On whenever the remaining
  GG prerequisites are available.

The main worktree has an implicit default of Off regardless of the project
default. This prevents the primary checkout from unexpectedly adopting stack
workflows. The user may still explicitly enable it.

Each worktree stores one of these overrides:

- `Inherit`: use the implicit main-worktree default or the linked-worktree
  project default.
- `On`: resolve the worktree policy to On, even when the project default is Off.
- `Off`: resolve the worktree policy to Off, even when the project default is
  Auto or On.

The override is persisted in `ProjectConfig` by the worktree's stable,
path-derived identity. Missing override data decodes as `Inherit`. Overrides
are removed when their worktrees are deleted, so recreating a worktree at the
same path starts from current defaults rather than reviving stale intent.

## Effective GG Context

A single resolver computes a worktree's effective GG context. It receives:

- The app-wide stacked-diffs setting.
- GG installation and supported capabilities.
- Whether the project is local or remote.
- The project default and worktree override.
- Whether the worktree is the project's main checkout.
- The live current branch.
- The effective GG `branch_username` from repository or global config.

The resolver separates policy from runtime status. It reports either an active
GG context or an inactive reason suitable for presentation and tests.

A worktree enters GG mode only when:

1. The app-wide integration is enabled, GG is installed, and the project is
   local.
2. The resolved worktree policy is On.
3. `branch_username` is available.
4. The live branch is `<branch_username>/<non-empty stack name>`.

Nested stack names remain valid. For example, username `nacho` accepts both
`nacho/feature` and `nacho/team/feature`, but rejects `main`, `other/feature`,
and `nacho/`.

This effective context is the shared source of truth for:

- GG versus ordinary Changes presentation.
- Sidebar GG status.
- ACP first-prompt GG context.
- Built-in `gg-mcp` attachment.

The project-wide GG Inbox remains capability-driven. Its availability does not
depend on the override of the worktree that happens to host the inbox tab.

## Stack Loading And Presentation

Once the effective context is active, Alas remains in GG mode independently of
whether stack metadata has loaded. `RightPaneState` calls `gg ls --json`
without requiring a stack-shaped commit list first.

The presentation state distinguishes:

- Loading stack metadata.
- An eligible branch with no returned stack metadata or zero commits.
- A loaded stack.
- A failed stack refresh.

An empty result renders the GG preparation workflow and a zero-commit stack
drawer state. This covers the period immediately after `gg co` and before the
first commit.

A refresh failure clears metadata that belongs to an older branch but retains
GG presentation. The drawer shows the classified error and a Retry action.
Authentication, network, command, and unsupported-schema failures therefore do
not silently swap the user into the ordinary review loop.

Existing async generation and snapshot-invalidation checks continue to reject
late results from an earlier branch or refresh. `GG-ID` trailers may contribute
to cache invalidation or stack-data validation, but they are not an eligibility
or presentation gate.

When the live branch changes, the resolver runs again. A matching branch entered
through `gg co` activates GG mode immediately. A nonmatching branch uses the
ordinary Changes workflow even when the worktree override is On, and the UI
explains that the branch does not meet GG's naming requirement.

## User Interface

### Settings

In **Settings > Changes > Stacked diffs**, keep the per-project segmented
control but label and describe it as the default for linked worktrees. The copy
states that main worktrees default Off and that individual overrides are in the
sidebar.

### Worktree menu

Each local worktree's existing sidebar context menu gains a **GG Mode** submenu:

- `Inherit repository default`
- `On`
- `Off`

The current override has a checkmark. For the main worktree, the Inherit item
still resolves to Off. When GG cannot become active, the menu includes a concise
disabled explanation such as `Branch must start with nacho/`, `gg is not
installed`, or `GG is unavailable for remote projects`.

### Status

An effectively active worktree receives the existing GG identity and summary
treatment in the sidebar. A compact GG indication remains available for an
empty stack, where there is no commit-derived summary yet.

The Changes pane reuses existing Alas preparation and drawer components rather
than adding a permanent settings control to its header:

- Empty stack: GG preparation UI and zero-commit drawer state.
- Loaded stack: existing stack-aware UI.
- Refresh failure: GG drawer with error details and Retry.
- Inactive context: existing ordinary Changes and review-loop UI.

Exact spacing, typography, colors, icons, and menu styling follow existing Alas
components. The brainstorming wireframe established placement only and is not a
visual specification.

## Configuration Migration

Older project files have no worktree override map and decode every worktree as
`Inherit`. The existing project `ggMode` value is preserved:

- Linked worktrees resolve through that value.
- Main worktrees resolve Off until explicitly enabled.

No eager override entries are written during migration. This preserves the
difference between inherited behavior and a deliberate user choice, including
when the project default changes later.

## Error Handling

- Global disablement, missing GG, remote projects, missing `branch_username`,
  and branch-prefix mismatch return explicit inactive reasons.
- A missing username fails closed because Alas does not reimplement GG's forge
  identity lookup.
- `gg ls` returning no current stack on an otherwise eligible branch is an
  empty GG state, not a reason to enter ordinary mode.
- A transient or classified `gg ls` error retains GG mode and exposes Retry.
- Stale stack identity and summary data are cleared before presenting an empty
  or failed state for a different branch.
- Changing any relevant setting reevaluates cached right-pane states
  immediately.

## Testing

Focused Swift Testing coverage includes:

- The policy matrix across the app-wide switch, GG availability, local versus
  remote projects, project mode, main versus linked worktrees, and every
  worktree override.
- Branch eligibility for simple and nested stack names, an empty stack name,
  the wrong username prefix, a missing username, and live branch switches.
- An eligible empty stack entering GG mode without any `GG-ID` commit.
- Empty `gg ls` output and refresh failures retaining GG presentation.
- Retry, stale-result rejection, and clearing metadata from a previous branch.
- Tolerant Codable migration and deleted-worktree override cleanup.
- Sidebar submenu selection, inherited/effective state, inactive explanations,
  and the zero-commit GG indicator.
- Updated Settings copy and project-default bindings.
- Matching decisions across Changes, ACP prompt context, and GG MCP injection.
- Regression coverage for ordinary review-loop presentation in opted-out or
  branch-ineligible worktrees.

## Acceptance Criteria

- After `gg co my-new-stack`, an opted-in eligible worktree shows GG Changes UI
  before the first commit exists.
- Returning to an eligible GG worktree does not show ordinary affordances merely
  because stack metadata is loading or refresh failed.
- GG-capable linked worktrees inherit GG On in project Auto mode, while the main
  worktree inherits Off.
- Users can override any worktree On or Off from its sidebar menu, including the
  main worktree and a worktree in a project whose default is Off.
- Switching an opted-in worktree to a branch outside the configured username
  prefix restores ordinary mode and provides a clear inactive reason.
- UI presentation, ACP context, and `gg-mcp` attachment agree on effective GG
  mode for the same worktree.
