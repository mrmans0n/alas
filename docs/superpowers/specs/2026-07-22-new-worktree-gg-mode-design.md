# New Worktree GG Mode

Date: 2026-07-22
Status: Approved design

## Context

The new-worktree dialog currently exposes a Boolean **Create as gg stack**
toggle. That toggle only changes creation mechanics: when enabled, Alas builds
the branch using gg's `<branch_username>/<stack-name>` convention and pins the
base to gg's configured default. The selected value is not persisted as the
new worktree's `GGWorktreeMode`.

Every newly discovered linked worktree therefore starts with the sparse
`.inherit` policy. In an `Auto` project whose repository has gg configuration,
that inherited policy resolves to On. A regular branch can consequently show
GG immediately after creation when its name also happens to match gg's branch
prefix, even though **Create as gg stack** was left unchecked.

The creation control should express both the requested creation behavior and
the policy the worktree keeps afterward.

## Goals

- Replace the ambiguous Boolean with the existing three-state worktree GG
  policy: `Inherit`, `On`, or `Off`.
- Make the selected raw policy determine both worktree creation mechanics and
  the persisted worktree override.
- Preserve sparse persistence for `Inherit`.
- Let users explicitly enable GG while the project default is Off and
  explicitly disable it while the project default is Auto or On.
- Explain the effective inherited behavior before the worktree is created.
- Ensure any auto-launched ACP session observes the persisted policy from its
  first GG context evaluation.

## Non-goals

- Changing project-level `Off`, `Auto`, or `On` semantics.
- Changing the sidebar worktree **GG Mode** menu.
- Changing gg's branch naming convention or configured stack base.
- Running a new gg command as part of creation; the existing branch/base
  creation mechanics remain authoritative.
- Adding GG support for remote projects.

## User Interface

For local repositories where the app-wide integration and gg installation make
GG creation available, replace **Create as gg stack** with a segmented picker
labeled **GG mode**:

- **Inherit**
- **On**
- **Off**

The raw selection defaults to `Inherit` each time the dialog is presented and
resets to `Inherit` when the selected repository changes. This prevents an
explicit choice made for one repository from silently carrying into another.

The dialog renders concise helper text below the picker. It states the effective
mode and, when effective On, previews the branch and pinned base. Examples:

> Uses repository default: On  
> Branch: `nacho/my-feature`, based on `main`

> GG disabled for this worktree. Creates a regular Git branch.

`Inherit` always remains visibly selected as the raw policy even when its
effective result is On or Off. The helper text communicates that result; the
picker must not replace `Inherit` with the resolved value.

If the selected policy resolves to GG On but `branch_username` is unavailable,
the dialog explains what is missing and disables confirmation until the user
chooses `Off` or resolves the configuration. The control must still allow an
explicit `On` selection when the project default is Off, so its visibility
cannot be gated by the project default itself. Remote projects retain their
existing regular-worktree flow without this control.

## Effective Creation Behavior

The dialog derives a Boolean `createsGGStack` from the raw selection and the
repository default for a new linked worktree:

| Raw selection | Effective creation behavior |
|---|---|
| `Off` | Regular Git worktree |
| `On` | GG branch naming and configured GG base |
| `Inherit` + project `Off` | Regular Git worktree |
| `Inherit` + project `Auto` | GG when repository GG config exists; otherwise regular |
| `Inherit` + project `On` | GG |

App-wide disablement, a missing gg installation, and a remote project remain
hard availability stops. `branch_username` is a creation prerequisite only
when `createsGGStack` is true.

When `createsGGStack` is true, the dialog uses the existing stack-name field,
branch composition, and pinned-base behavior. When false, it uses the existing
regular branch field and freely selected base. Separate `branch` and
`stackName` draft values remain intact while the selection changes, so toggling
the mode does not destroy text the user already entered.

`Inherit` is deliberately dynamic. It records no promise that the effective
mode will stay equal to its value at creation time. Later project-default or
repository-configuration changes continue to affect the worktree exactly as
they do today.

## Persistence And Creation Flow

The dialog passes the raw `GGWorktreeMode` into the worktree-creation request.
The creation path retains ownership of applying it because successful creation,
topology refresh, persistence, selection, and launch already happen there.

The creation path applies the raw mode in memory to the optimistic worktree
before its immediate selection:

- `Inherit`: remove or omit the worktree entry in `ggWorktreeModes`.
- `On`: persist `.on` under the worktree's stable identity.
- `Off`: persist `.off` under the worktree's stable identity.

This in-memory phase ensures the selected optimistic row never evaluates GG
using a policy other than the one chosen in the dialog. After Git creation and
the successful topology refresh identify the final worktree, but before
auto-launching a terminal or ACP session, the creation path reapplies the raw
mode to the reconciled identity and saves the project file when the mode is an
explicit override. The affected right-pane GG gate is then reevaluated.

If creation fails, the unpersisted in-memory override is removed. A failed
worktree creation therefore does not leave an override behind.

Applying the override before selection and auto-launch prevents a newly opened
ACP session from attaching GG context based on a transient inherited policy.

## Testing

Focused Swift Testing coverage should include:

- The creation-behavior matrix for all three raw modes and all project modes,
  including `Auto` with and without repository GG configuration.
- `On` remaining selectable when the project default is Off.
- `Off` producing the regular branch and freely selected base in a GG-capable
  repository.
- `Inherit` in a GG-capable `Auto` repository producing the GG branch and base.
- Raw `Inherit` remaining selected while helper text reports effective On or
  Off.
- Repository changes resetting the raw selection to `Inherit` without leaking
  the previous repository's draft choice.
- Missing `branch_username` blocking only modes whose creation behavior is GG.
- Successful creation persisting `.on` and `.off`, while `Inherit` remains
  absent from `ggWorktreeModes`.
- Creation failure leaving no stale worktree override.
- Persistence occurring before an auto-launched ACP session resolves GG
  context.
- Regression coverage for current regular-branch validation, GG branch
  composition, and pinned-base behavior.
