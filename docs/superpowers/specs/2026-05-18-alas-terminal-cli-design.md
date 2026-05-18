# Alas Terminal CLI Design

## Summary

Add an `alas` command that exists only inside terminal sessions spawned by Alas. The first supported command is:

```sh
alas open <path> [path...]
```

Each path resolves from the terminal process's current working directory, not the worktree root. Files inside any visible Alas worktree open as normal editor or image tabs for that worktree. Files outside all visible worktrees are allowed and open as external editor tabs owned by the originating worktree.

## Goals

- Make `alas open myfile.txt` open `myfile.txt` in the Alas editor from an Alas terminal.
- Keep the command private to Alas-spawned terminals. Do not install a global CLI or mutate the user's shell config.
- Resolve relative paths from the shell's current `$PWD`.
- Allow absolute and relative paths that point outside the worktree.
- Reuse the existing terminal environment and UNIX socket infrastructure where practical.

## Non-Goals

- No globally installed `/usr/local/bin/alas` or bundled command-line target in this first version.
- No support yet for editing ranges such as `file:line:column`, directories, search, tab management, or project/worktree commands.
- No external application integration beyond the existing Alas editor tab system.

## User Experience

Every new Alas terminal starts with an `alas` shell function available in supported shells. The command accepts `open` and one or more file paths:

```sh
alas open README.md
alas open Sources/App.swift ../notes.txt /tmp/debug.log
```

For each argument, the function resolves the path relative to `$PWD`, sends a request to the Alas app, and prints a short error only when the request cannot be delivered or the app rejects it. Successful opens stay quiet so the command feels like an editor command.

Unknown commands print a compact usage message. Running `alas open` without paths prints usage and exits non-zero.

## Architecture

Use the existing `ALAS_SOCKET_PATH`, `ALAS_SESSION_ID`, `ALAS_WORKTREE`, and terminal startup injection path.

The implementation should add a small CLI command envelope alongside harness hook events. The app's socket server will decode both message families:

- Harness activity events keep their current behavior.
- CLI command requests route to an app-level command handler.

The terminal side is a shell function injected into every Alas terminal session by the same startup-script mechanism that already wraps user startup scripts. This keeps the command scoped to Alas terminals and avoids writing executable files into user-visible paths.

## Components

### Terminal Injection

Add `TerminalCLIInjection` under `Alas/Sources/Terminal`. It returns the shell snippet that defines `alas()` and is prepended to the effective per-session startup script before the user's configured startup script content.

The function should:

- Require `ALAS_SOCKET_PATH` and `ALAS_SESSION_ID`.
- Support `alas open <path> [path...]`.
- Resolve each path against `$PWD` using the shell's current directory.
- Send JSON to the UNIX socket with `/usr/bin/nc -U -w1`.
- Return non-zero when usage is invalid or socket delivery fails.

The first implementation targets the shells that already receive startup script injection: zsh and bash. Unsupported shells will not receive the function until startup injection supports them.

### Socket Protocol

Introduce a versioned CLI request shape distinct from harness events:

```json
{
  "v": 1,
  "kind": "cli",
  "command": "open",
  "session_id": "<ALAS_SESSION_ID>",
  "paths": ["/absolute/path"]
}
```

Keep responses simple:

```json
{"ok": true}
{"ok": false, "error": "Message"}
```

The socket server should continue to ignore unknown harness events as it does today, but malformed CLI requests should get an error response.

### App Command Routing

Add `AlasCLICommandHandler`, a main-actor service owned by `AppState`, for CLI command routing.

For each requested absolute path:

1. Find the terminal session by `session_id`.
2. Use the session's `worktreeId` as the originating context.
3. If the path is inside a visible known worktree, open it using the existing worktree-relative `openFile` flow.
4. If it is outside all visible worktrees, open an external editor tab in the originating worktree with `tabs.openExternalEditor`.
5. Bring Alas to the foreground after handling at least one path.

The existing image-preview behavior should apply only for files inside a worktree, because external image preview ownership is not currently modeled.

### Path Handling

The shell function should send standardized absolute paths. The app should still normalize paths before matching against worktree roots.

Worktree matching must compare path components rather than raw string prefixes so `/repo-a` does not match `/repo-a-copy`. The app should reject paths that do not exist or are directories for this first version, returning a clear error to the CLI.

### Error Handling

Terminal-side errors:

- `alas`: print usage.
- `alas open`: print usage.
- Missing Alas environment: print that the command is only available in Alas terminals.
- Socket send failure: print that Alas is not reachable.

App-side errors:

- Unknown session id.
- Missing originating worktree.
- Path does not exist.
- Path is a directory.
- Malformed request.

When opening multiple paths, the app should attempt all valid paths and report aggregate failure if any path fails. The first version can use one response with a combined error string.

## Testing

Add focused Swift Testing coverage for:

- CLI request decoding accepts the supported `open` shape.
- CLI request decoding rejects malformed requests.
- Command routing opens an in-worktree file through the normal editor tab path.
- Command routing opens an out-of-worktree file as an external editor tab owned by the originating worktree.
- Path containment does not use unsafe string-prefix matching.
- The injected shell function text includes the environment guard, `open` usage handling, `$PWD`-based path resolution, and socket send command.

Manual verification:

```sh
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Then launch Alas, open a terminal, and verify:

- `type alas` reports a shell function.
- `alas open README.md` opens the file from the current `$PWD`.
- `cd subdir && alas open file.txt` resolves from `subdir`.
- `alas open /tmp/some-file.txt` opens as an external editor tab.
- A normal terminal outside Alas does not have the injected command.

## Decisions

- Do not support line or column suffixes in the first implementation.
- Do not add a real executable until there are enough commands to justify a dedicated CLI target.
- Keep successful command output quiet.
