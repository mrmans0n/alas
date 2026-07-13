# Remote Helper Protocol v1

`alas-helper serve` runs on a remote host as a long-lived stdio process launched
over batch SSH:

```text
ssh <batch opts> <host> /bin/sh -c '... "$HOME/.alas/bin/alas-helper" serve'
```

The app speaks JSON-RPC 2.0 using one newline-delimited JSON object per frame on
stdin/stdout. Stderr is diagnostic-only. The helper binds to no socket and opens
no listening port.

## Lifecycle

The app owns one `RemoteHelperClient` actor per SSH host through
`RemoteHelperClientPool`. A client starts lazily on the first request and shuts
down after ten idle minutes when there are no active subscriptions. Active
subscriptions keep the helper alive; if a helper crash forces a restart, the
client replays those subscriptions before sending the next caller request. If
the SSH channel exits with status `255`, the app reports a host connection
failure through `RemoteHostStatusStore`. Other exits are treated as helper
crashes: in-flight requests fail with a fallback-capable client error, but the
host is not marked offline. Watch consumers are notified immediately so they
resume their pre-helper polling cadence; the next retry starts a new helper
channel and replays the active subscriptions.

## Handshake

Request:

```json
{"jsonrpc":"2.0","id":1,"method":"hello","params":{"clientName":"Alas","protocolVersion":1}}
```

Result:

```json
{
  "name": "alas-helper",
  "protocolVersion": 1,
  "binaryVersion": "0.3.0",
  "capabilities": {
    "watchKinds": ["files", "git"],
    "fs": {"read": true, "write": true, "stat": true},
    "ping": true
  }
}
```

`alas-helper version` prints the same `{name, protocolVersion, binaryVersion}`
handshake used by capability probing and installer checks.

## Methods

`ping`

Params: `{}`  
Result: `{"ok": true}`

`watch/subscribe`

Params: `{"root": "/srv/repo", "kinds": ["files", "git"]}`  
Result: `{"subscriptionId": "1"}`

The helper canonicalizes `root`, registers it as an allowed containment root,
and starts a native recursive watcher. Linux uses inotify and macOS uses
FSEvents through `notify`. For git subscriptions the helper also resolves and
watches the common git directory, including when it lives outside the worktree.

`watch/unsubscribe`

Params: `{"subscriptionId": "1"}`  
Result: `{"ok": true}`

`watch/event`

Notification:

```json
{
  "jsonrpc": "2.0",
  "method": "watch/event",
  "params": {
    "subscriptionId": "1",
    "root": "/srv/repo",
    "kind": "files",
    "paths": ["/srv/repo/README.md"]
  }
}
```

`files` events contain changed paths under the worktree root. `git` events are
limited to state that invalidates project or changes-pane data: main or linked
worktree HEAD and index changes, merge/rebase/cherry-pick/revert state, worktree
topology changes, branch refs, and packed refs. Transient lockfiles and
unrelated git metadata are ignored. Events are grouped by subscription and kind
for 250 ms before the helper sends one notification.

`fs/read`

Params: `{"path": "/srv/repo/README.md", "offset": 0}`  
Result: `{"kind":"file","contentBase64":"Li4u","mtime":1783940000.25}`

File bytes are base64 encoded so images and other binary files use the same
operation. Non-file results use `kind` values `missing`, `directory`, `symlink`,
or `unreadable`.

`fs/write`

Params:

```json
{"path":"/srv/repo/README.md","content":"...","expectedMtime":1783940000.25}
```

Result: `{"mtime": 1783940100.5}`

`expectedMtime` is optional. When provided and the existing file mtime differs,
or the target file no longer exists, the helper returns an error instead of
writing.

`fs/stat`

Params: `{"paths": ["/srv/repo/README.md"]}`  
Result:

```json
{
  "entries": [{
    "path": "/srv/repo/README.md",
    "exists": true,
    "isDirectory": false,
    "isFile": true,
    "size": 1234,
    "mtime": 1783940000.25
  }]
}
```

`fs/line-counts`

Params: `{"root":"/srv/repo","paths":["README.md","src/main.swift"]}`
Result: `{"entries":[{"path":"README.md","lineCount":42}]}`

Missing and non-regular files are omitted. The request is not subject to the
exec fallback's argv cap.

`fs/list`

Params: `{"path":"/srv/repo/src"}`
Result: `{"entries":[{"name":"main.swift","isDirectory":false}]}`

`search/start`

Params:

```json
{
  "root": "/srv/repo",
  "query": "needle",
  "caseSensitive": false,
  "wholeWord": false,
  "regex": false
}
```

Result: `{"searchId":"1"}`

The helper runs `rg --json` and emits each output line as a `search/event`
notification. It finishes with `search/complete`, including ripgrep's exit code,
bounded stderr, and whether the operation was cancelled.

`search/cancel`

Params: `{"searchId":"1"}`
Result: `{"ok":true}`

Cancellation kills the server-side ripgrep child without closing the helper
channel.

## Security

The helper only serves paths under registered roots. `watch/subscribe` resolves
the requested root with the remote host filesystem. Reads, stats, listings,
line counts, and searches
resolve existing target paths and require them to be under a registered root.
`fs/write` resolves the parent directory and requires that parent to be under a
registered root before writing. If the final path already exists as a symlink,
the helper resolves the symlink target and rejects writes outside registered
roots. Writes use a sibling temporary file plus rename, preserving the existing
target mode when replacing a file, so hardlinks inside a registered root are
replaced instead of mutating an outside shared inode. This catches symlink and
hardlink escapes on the host that lexical path checks cannot see.

## Errors

JSON-RPC parse errors use `-32700`; invalid requests and params use `-32600` and
`-32602`; missing methods use `-32601`. Helper-specific errors use the `-320xx`
range:

| Code | Meaning |
| --- | --- |
| `-32010` | invalid subscription root |
| `-32020` | filesystem operation failed |
| `-32021` | path does not exist |
| `-32022` | no containment roots have been registered |
| `-32023` | path is outside registered roots |
| `-32025` | path is not a regular file |
| `-32030` | `expectedMtime` did not match |
