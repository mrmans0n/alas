# Repo-shared startup hooks design

Date: 2026-09-23

## Purpose

Alas stores a project's session-open and worktree-create scripts as inline, per-user values in `ProjectConfig`. Teams cannot commit those scripts with the repository, so each teammate must recreate them and keep them in sync.

Repositories may define both scripts as files under `.alas/hooks/`. Alas reads them as team-provided defaults while preserving the existing global and per-project controls. The files remain source-controlled inputs. The create/edit project dialogs show and approve them but never write them.

## Goals

- Share the existing session-open and worktree-create behavior through the repository.
- Support local and SSH-hosted projects in the first implementation.
- Apply the worktree-create hook when a project is created as a Workspace Checkout member.
- Keep global scripts and explicit per-user project overrides working.
- Require per-user approval for the exact repo hook content before execution.
- Read and execute the hook from the worktree whose revision governs the action.
- Keep `.alas/scripts/` reserved for manually launched run scripts.

## Non-goals

- Writing, exporting, or modifying repo hook files from Alas.
- Configurable hook paths or hook modes in `.alas/config.json`.
- New lifecycle events.
- File watchers.
- Changes to run-script discovery or `.alas/scripts/`.
- A redesign of shell exit, output, or worktree setup failure handling.
- General SSH support for the other `.alas/config.json` keys.

## Repository layout

A repository may contain either or both fixed files:

```text
.alas/
  config.json
  hooks/
    session-open.sh
    worktree-create.sh
  scripts/
    build.sh
```

The names are conventions, not entries in `.alas/config.json`:

| Event | Relative path |
|---|---|
| Open a terminal session | `.alas/hooks/session-open.sh` |
| Create a worktree | `.alas/hooks/worktree-create.sh` |

The files contain UTF-8 shell source. They do not need an executable bit. Alas reads their contents and composes them with the existing global and per-project shell snippets. It does not execute the file path. This preserves environment changes and working-directory state across the combined program.

`.alas/hooks/` is relative to the repository checkout. It is unrelated to the legacy user-home path `~/.alas/hooks/` handled by `LegacyHookSweep`.

## Hook source

The action determines which checkout supplies the hook.

### Session open

Alas reads `.alas/hooks/session-open.sh` from the worktree receiving the new terminal. A branch may therefore change its own session setup without changing other worktrees.
The hook participates only in launch paths that already set `includeUserStartupScript` to true. Agent-auth and other internal terminals that suppress the existing global/project startup script also suppress the repo hook and do not request approval.

### Worktree create

Alas first creates the new checkout. It then reads `.alas/hooks/worktree-create.sh` from that checkout before running setup. The selected base revision supplies the content. Alas must not read the hook from the project's primary checkout before creation because that file may differ from the new worktree.

If the user disables startup execution for a worktree-creation action, Alas does not load, approve, or run the repo hook.

### Workspace Checkout member

A Workspace Checkout may create up to four member worktrees concurrently. Each member loads its own `.alas/hooks/worktree-create.sh` after that member's checkout exists. A member awaiting approval pauses before setup while unrelated members continue.

The approval presenter serializes pending decisions so concurrent members do not open competing sheets. The Workspace Checkout remains in its creating state until every member reaches a terminal checkpoint. If Alas exits while a member waits, its durable `worktreeCreated` checkpoint remains. Resume reloads the file and requests a new decision before setup.

Workspace-root terminals have no single owning repository and do not run a project `session-open.sh`. A terminal opened for a concrete member worktree follows the normal session-open flow.

## Loading and confinement

A `RepoHookEvent` value owns the fixed relative path and stable trust identity for each event. A repo-hook loader accepts an event, a concrete worktree root, and an optional SSH host. It returns one of these outcomes:

- missing,
- loaded bytes plus source metadata,
- failed with a user-facing reason.

The loader enforces these rules for local and remote files:

- The resolved target must stay inside the concrete worktree.
- The target must be a regular file. A symlink is allowed only when its resolved target remains inside the worktree.
- The maximum size is 256 KiB. A file of exactly 262,144 bytes is valid; a larger file is rejected before a full read.
- The bytes must decode as UTF-8.
- An empty or whitespace-only file contributes no script and requires no approval.

Local loading uses canonical path confinement before reading. Remote loading uses the existing SSH path-containment facilities and a bounded remote read. SSH failures remain distinct from a missing file.

Dialog inspection may cache a result for presentation, but execution always performs a fresh read. Alas never executes stale dialog content.

## Resolution and precedence

The repo hook is an inherited default between the global script and the explicit per-user project policy.

First, Alas builds the inherited script:

```text
inherited = non-empty(global, repo hook), joined in that order with a newline
```

It then applies the existing `ProjectStartupScriptMode`:

| Persisted mode | Dialog label | Effective script |
|---|---|---|
| `useGlobal` | Use inherited | inherited |
| `appendToGlobal` | Append to inherited | inherited + per-user project snippet |
| `overrideGlobal` | Override inherited | per-user project snippet |
| `disabled` | Disabled | empty |

Each part keeps the resolver's current leading/trailing whitespace trimming. Empty parts are omitted. Existing enum raw values and stored project snippets do not change.

A repo hook only needs trust approval when it is part of the effective script. `overrideGlobal` and `disabled` bypass the repo file, so those modes neither prompt nor approve it.

Workspace Checkout setup has one additional policy layer. Alas first applies the project mode to `global + repo hook`, then applies the Workspace member's setup mode. A Workspace member Override or Disabled setting removes the repo hook and requires no approval. Inherit and Append retain it when the project mode does.

When no repo hook exists, resolution matches current behavior.

## Trust model

Repo hooks can execute when a terminal opens or after Alas creates a worktree. They require approval independent of MCP-server trust.

For every non-empty loaded hook, Alas computes SHA-256 over a canonical byte sequence containing:

1. a format marker and trust-format version,
2. the stable event identity,
3. the exact file bytes.

The event identity prevents approval of one event from authorizing the same bytes for another event. Alas does not normalize line endings or source text before hashing.

`ProjectConfig` stores the approved digests for that registered project. The collection is per user and persists in `projects.json`. It is shared across the project's worktrees, branches, and SSH host. Identical content for the same event prompts once. Changed bytes produce a new digest and require approval. If a branch later returns to previously approved bytes, the existing approval applies again.

A one-time skip is not persisted. There is no repository-controlled way to grant approval.

Approval persistence is part of the decision. If saving the approval fails, Alas reports the error and does not run the hook as approved.

## Approval flow

Alas hashes the loaded bytes and checks project trust before composing the final shell program. Hashing and execution use the same in-memory bytes. Alas never approves one read and then executes a second read from the file path.

The decision UI shows:

- event name,
- repo-relative path,
- SSH host when applicable,
- read-only source content,
- the fact that later content changes require another approval.

### Session open

An unapproved effective hook pauses terminal creation. The user may:

- **Approve and continue**, which persists approval and launches the terminal with the repo hook;
- **Continue without repo hook**, which launches once with the applicable global and per-user parts only;
- **Cancel**, which does not launch the terminal.

### Worktree create

Alas creates the checkout before it can read the branch-correct hook. An unapproved effective hook then pauses setup. The user may:

- **Approve and continue**, which persists approval and runs setup with the repo hook;
- **Finish without repo hook**, which completes the action once with applicable global and per-user parts only.

The UI must not describe the second action as cancellation because the checkout already exists. If the app terminates before the user decides, Alas leaves the checkout in place and does not execute the hook on relaunch.

### Workspace Checkout member

An unapproved effective worktree-create hook pauses only that member's setup. The serialized decision sheet offers **Approve and continue** or **Finish member without repo hook**. Other members may keep creating worktrees or running approved setup.

The coordinator keeps the loaded bytes alive while the decision is pending, then executes those same bytes after approval. If the task is interrupted, resume performs a fresh read and approval check. It never persists hook source in Workspace state or executes a pre-interruption buffer.

## Create/edit project dialogs

The startup-script section remains a per-user policy editor. It does not become a repo-file editor.

For each event, the dialog shows:

- the renamed mode picker labels from the precedence table;
- a compact inherited-source row;
- the repo-relative path and SSH host when a hook exists;
- one of `Approved`, `Approval required`, `Unreadable`, or `Not found`;
- a **Review...** action for a readable hook.

The review sheet displays the same read-only source and trust context as the execution prompt. It may approve the current digest. It cannot create, edit, rename, or delete the repo file.

The existing text editor appears only for Append and Override. Its contents remain the per-user `ProjectConfig` snippet.

Some create-project flows cannot inspect the repository until clone or registration finishes. In that state, the dialog states that Alas will check repo hooks when the repository becomes available. It must not show a guessed `Not found` or approval status.

Remote inspection is asynchronous and must not block the main actor.

## Runtime data flow

Session opening uses this sequence:

```text
open request
  -> load session-open hook from the target worktree
  -> validate, hash, and check project trust
  -> obtain a decision when required
  -> resolve global + repo + per-user policy
  -> pass final shell content to the existing terminal launch path
```

Worktree creation uses this sequence:

```text
create checkout
  -> load worktree-create hook from the new worktree
  -> validate, hash, and check project trust
  -> obtain a decision when required
  -> resolve global + repo + per-user policy
  -> pass final shell content to the existing setup execution path
```

Workspace Checkout member setup uses this sequence:

```text
create member checkout
  -> load worktree-create hook from that member worktree
  -> apply project and Workspace member policies
  -> validate, hash, and check project trust when the hook remains effective
  -> pause only that member when a decision is required
  -> compose the frozen Workspace shared script and resolved member script
  -> pass final shell content to the existing member setup runner
```

Filesystem and SSH work stay outside `StartupScriptResolver`. The resolver remains pure and accepts optional repo-hook content as input.

## Error behavior

A missing hook is normal and contributes no repo script.

An unreadable, oversized, non-UTF-8, escaping, non-regular, or SSH-unavailable hook never executes. The action pauses with the exact failure. The user may retry, continue the ordinary action without the repo hook, finish a Workspace member without the repo hook, or cancel a session opening.

Continuing without the repo hook removes only that layer. The global script and any applicable per-user Append snippet still run.

The design preserves current runtime behavior after execution begins. Terminal startup output remains in the terminal. Worktree-create script exit and output handling remain unchanged by this feature.

## Persistence and compatibility

`ProjectConfig` gains optional per-user hook-trust storage. Decoding old `projects.json` files defaults it to empty. Encoding should be deterministic so saving an unchanged project does not reorder approval records.

`ProjectStartupScripts`, its raw enum values, and existing inline scripts remain compatible. No migration rewrites user settings.

`RepoConfig` and `.alas/config.json` do not change. Repo hooks use fixed conventions rather than config-declared paths.

Workspace configuration snapshots currently persist an already-resolved member setup script before the checkout exists. New snapshots also retain the frozen project startup policy and Workspace member setup policy needed to insert a branch-specific repo hook after checkout creation. Older snapshots decode through their existing resolved-script fallback and do not acquire repo hooks retroactively.

Existing repositories without `.alas/hooks/` behave exactly as before except for the clearer `Use inherited` and `Append to inherited` labels.

## Verification

Focused Swift Testing suites cover:

1. Event-to-path mapping.
2. Local loading for missing files, exact bytes, strict UTF-8, regular-file checks, symlink confinement, and the 256 KiB boundary.
3. Remote loading through injected file-access operations, including containment, bounded reads, missing files, and SSH failures. Tests do not require a live SSH host.
4. Trust digests for event separation, identical-content reuse, changed content, reverted content, and per-project isolation.
5. Resolver behavior for every project mode with empty and non-empty global, repo, and per-user parts.
6. Trust policy that bypasses prompts for Override and Disabled and does not persist a one-time skip.
7. Session orchestration that waits for a trust decision, suppresses repo hooks when `includeUserStartupScript` is false, and passes the approved or skipped composition to terminal launch.
8. Worktree orchestration that loads only after checkout creation and uses that checkout's bytes.
9. Workspace orchestration that pauses only the affected member, serializes concurrent approval sheets, resumes from `worktreeCreated`, and respects project plus Workspace member overrides.
10. Dialog presentation policy for source status, Review visibility, and per-user editor visibility.

Manual smoke verification uses one local project and one SSH project:

1. Add a hook and trigger its event.
2. Confirm the action pauses and source is readable.
3. Approve and confirm execution.
4. Trigger again and confirm no prompt.
5. Change one byte and confirm another prompt.
6. Skip once and confirm global/per-user content still runs without the repo hook.
7. Select Override and Disabled and confirm no repo-hook prompt or execution.
8. Create a Workspace Checkout with two members, approve one repo hook, skip the other, and confirm both members finish with the selected setup.

## Documentation

Update the README's repo-local `.alas/` section with the two fixed paths, precedence, approval rule, and local/SSH support. Add an unreleased changelog entry. The docs must distinguish `.alas/hooks/` lifecycle hooks from `.alas/scripts/` manually launched run scripts.

## Acceptance criteria

- A committed `session-open.sh` or `worktree-create.sh` works in local and SSH projects without per-user duplication.
- Alas executes the file from the concrete worktree revision governing the action.
- The exact event and content require per-user approval before first execution and after any byte change.
- Skipping once does not persist trust and does not suppress global or applicable per-user script layers.
- Explicit per-user Override and Disabled settings prevent repo-hook prompts and execution.
- Workspace Checkout members load their hooks after checkout creation, pause independently for approval, and apply both project and Workspace member script policies.
- The project dialogs show inherited source and trust state without modifying repository files.
- Repositories with no hook files keep their current startup behavior.
