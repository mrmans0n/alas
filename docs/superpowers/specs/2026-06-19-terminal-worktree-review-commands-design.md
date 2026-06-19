# Terminal Worktree And Review Commands Design

## Context

Alas currently injects two commands into Alas-owned terminal sessions:

- `alas open <path> [path...]`
- `ao <path> [path...]`, a shortcut for `alas open`

The injected `alas` command is terminal-only. It requires `ALAS_SOCKET_PATH` and
`ALAS_SESSION_ID`, sends a JSON request to the running app over the existing
socket, and lets Swift resolve the request against the originating terminal
session. This keeps command behavior scoped to the active Alas worktree instead
of creating a second workspace model in shell.

This design extends that model with worktree and review commands.

## Goals

- Add terminal commands for common worktree actions: list, switch, create, and
  delete.
- Add terminal commands for opening the current worktree's review surfaces.
- Keep commands available only inside Alas terminals for this pass.
- Keep Swift as the source of truth for projects, visible worktrees, tabs,
  review sessions, and safety checks.
- Preserve `alas open` and `ao` behavior.

## Non-Goals

- Running these commands from arbitrary external shells.
- Replacing `git worktree` as a standalone CLI.
- Adding agent launch/resume commands in this pass.
- Starting review-loop automation, publishing reviews, or posting comments from
  `alas review`.
- Adding archive/hidden-worktree management to the first CLI surface.

## Command Surface

```sh
alas open <path> [path...]
alas wt list
alas wt switch <name-or-branch>
alas wt new <branch> [--base <ref>]
alas wt delete <name-or-branch> [--force] [--keep-branch]
alas review
alas review <pr-number-or-url>
```

`ao` remains an alias for `alas open`.

## Architecture

The injected shell script remains a thin request builder. It validates that the
command is running inside an Alas terminal, resolves shell-relative path
arguments where needed, sends a typed JSON request to the app socket, formats
simple command output, and exits with the status implied by the app response.

The app-side `AlasCLICommandRouter` becomes a small dispatcher instead of an
`open`-only handler. Each request still carries `session_id`, and the router
uses the same session-to-worktree lookup already used by `alas open`. If the
session cannot be mapped to a worktree, the command fails with a clear error.

All project/worktree/review decisions stay in Swift. The shell script should not
inspect Git state directly, mutate worktrees, or infer app state beyond argv and
environment variables.

## Worktree Commands

### `alas wt list`

Lists visible worktrees in the originating worktree's current project. The
output should be compact and useful in a terminal:

```text
* main                 /path/to/repo
  feature/review-cli   /path/to/repo-feature-review-cli
```

The current/originating worktree is marked with `*`. Hidden or archived
worktrees are not included in the first version.

### `alas wt switch <name-or-branch>`

Focuses an existing visible worktree in the current project and activates Alas.

Matching order:

1. Exact branch/name match.
2. Exact path basename match.
3. Unique prefix/fuzzy match.

If no worktree matches, the command returns an error. If multiple worktrees
match, the command returns an ambiguity error listing the candidates. The
command does not create a worktree implicitly.

### `alas wt new <branch> [--base <ref>]`

Starts the existing app-owned worktree creation flow and focuses the optimistic
worktree row when creation is accepted. The destination path follows the same
convention the app uses for worktrees created from the UI.

If `--base` is omitted, the command uses the same default base behavior as the
UI creation path for the originating worktree. If `--base` is present, it is
passed through to the existing worktree creation service as the base ref.

On success, the command may print the accepted branch/path. Creation errors
come from the app's existing validation and Git error handling.

### `alas wt delete <name-or-branch> [--force] [--keep-branch]`

Deletes a visible worktree matched by the same resolver as `wt switch`.

The command reuses the existing delete flow and preflight safety rules. Without
`--force`, dirty worktrees or worktrees with initialized submodules fail with a
message explaining why force is needed. With `--force`, the delete request maps
to the app's forced delete path. `--keep-branch` maps to the existing
branch-retention option.

The command is intentionally named `delete`, not `remove`, to keep the action
plain and explicit.

## Review Commands

### `alas review`

Opens or focuses the current worktree's Review Changes tab. This is equivalent
to using the existing app action from the selected worktree. It activates Alas
and leaves the terminal session intact.

### `alas review <pr-number-or-url>`

Opens a provider-backed review session for the originating worktree.

For a bare number, Alas resolves it as a pull request or merge request number
for the current worktree's configured code host remote. For a URL, Alas infers
the provider and review target from the URL when the provider supports it.

If no code host remote can be resolved, or the URL/provider is unsupported, the
command returns a terminal-readable error. It should not fall back to opening a
browser, because the command's purpose is to open an Alas review surface.

The command uses the existing review session/store/launcher path. It does not
start review-loop automation, publish comments, submit verdicts, or mutate code
host state.

## Responses And Output

The app response should grow beyond the current simple `{ "ok": true }` shape so
commands can return structured payloads.

Suggested response cases:

- success with no output
- success with text lines
- success with structured worktree rows for `wt list`
- failure with a single message

The shell wrapper formats command output to stdout and prints errors to stderr.
Action commands can stay quiet on success unless they naturally produce useful
confirmation, such as `wt new`.

Examples:

```text
alas: unknown worktree "foo"
alas: ambiguous worktree "feat"; matches: feat/a, feat/b
alas: worktree has local changes; rerun with --force to delete
alas: no code host remote found for this worktree
alas: unsupported review URL
```

Exit codes remain simple:

- `0` for successful commands.
- `1` for app-level request failures.
- `2` for usage errors or commands run outside Alas terminals.

## Testing

Focused tests should cover:

- Request decoding for all new commands and flags.
- Shell script command parsing, usage output, and socket request shape.
- `ao` continuing to delegate to `alas open`.
- Router dispatch for `open`, `wt`, and `review` commands.
- Worktree list formatting and current-worktree marking.
- Worktree matching behavior: exact branch/name, path basename, unique prefix,
  unknown target, and ambiguity.
- `wt switch` app-state wiring and app activation.
- `wt new` argument mapping to the existing create-worktree path.
- `wt delete` preflight failure, `--force`, and `--keep-branch` mapping.
- `review` without arguments opening/focusing Review Changes.
- `review <number-or-url>` routing into provider-backed review session loading.
- Terminal-only failure behavior when required environment variables are absent.

## Future Extensions

- External-shell support once app instance routing and repository discovery are
  designed.
- Agent commands, likely under a separate grouped namespace.
- Hidden/archived worktree listing and restore commands.
- Review-loop automation commands, if they can map cleanly onto existing review
  readiness state without surprising side effects.
