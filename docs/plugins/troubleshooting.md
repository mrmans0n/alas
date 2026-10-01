# Troubleshooting

Find your symptom, read the cause, apply the fix. Start in **Settings → Plugins**:
it lists every plugin, anything under **Not loaded** with the reason, and per
project the instance's state with its log lines in a disclosure. In Debug builds
of Alas, **Debug → Plugins…** also shows, under **Messages**, the JSON that went
in each direction.

For the full list of messages and what triggers them, see
[Errors](api-v1.md#6-errors).

## The plugin is not listed, or is under "Not loaded"

Anything under **Not loaded** shows the folder name and the reason.

| You see | Cause | Fix |
|---|---|---|
| A file error mentioning `plugin.json` | The folder has no readable `plugin.json`. | Put `plugin.json` directly inside the plugin folder, not in a sub-folder. |
| `plugin.json is not a valid JSON object` | Syntax error in the manifest. | Validate the JSON, for example with `python3 -m json.tool plugin.json`. |
| `plugin.json is missing "<field>"` | A required field is absent or blank. | Add `id`, `name`, `version`, `api` and `entry`. |
| `invalid plugin id "…"` | The id is not reverse-DNS. | Use lowercase letters, digits and `-`, in at least two dot-separated segments, such as `com.example.my-plugin`. |
| `requires plugin API 4; this Alas supports 1, 2, 3` | `api` is not `1`, `2` or `3`. | Set `"api"` to `1`, `2` for canvas tabs, or `3` for view tabs, tasks and storage. |
| `unknown capability "…"` | A typo, or a capability this Alas does not have. | Use `workspace.read`, `worktree.switch`, `session.focus`, `session.read` or `tasks.start`. |
| `entry "…" must be a relative path inside the plugin folder` | `entry` is absolute, uses `..`, or **the file does not exist, is a symlink, or resolves outside the folder**. | Check the path, and that the build actually copied the wasm file. |
| `duplicate plugin id …` | Two folders declare the same `id`. | Remove or change one. Neither loads until you do. |

Nothing at all, not even under **Not loaded**? The folder is not in
`~/Library/Application Support/Alas/Plugins/`, or you have not clicked **Rescan**
since adding it.

## "Approve…" appears again

Expected after any change to `plugin.json` or the wasm file. Approval is tied to
the exact bytes of both, so a rebuild asks again. See
[Concepts → Trust](concepts.md#trust-and-approval).

If it keeps asking for a plugin you have not changed, your build is probably
non-deterministic and embeds something like a timestamp or path. Each build then
produces different bytes, so each one needs approving.

## The plugin stops as soon as it starts

The instance shows `Stopped: <reason>`.

| Reason | Cause | Fix |
|---|---|---|
| `could not load plugin: … import …` | The module imports something other than `alas.send`. The usual culprit is a WASI target, or a JavaScript bridge such as `wasm-bindgen`. | Build for `wasm32-unknown-unknown`. Remove `wasm-bindgen`. List the imports with `wasm-tools print plugin.wasm \| grep import` if you have it. |
| `plugin does not export memory` (or `alas_alloc`, `alas_handle`) | An export is missing or named differently. | Rust exports `memory` by default in a `cdylib`. Check that both functions are `#[no_mangle] pub extern "C"`. Other toolchains may need an export flag. |
| `plugin export alas_alloc has the wrong signature` | Types do not match `(i32) -> i32`. | In Rust: `alas_alloc(len: usize) -> *mut u8`. It must take one integer and return one. |
| `plugin export alas_handle has the wrong signature` | Types do not match `(i32, i32) -> ()`. | `alas_handle(ptr: *mut u8, len: usize)` must return nothing. |
| `plugin did not respond to alas/activate` | No reply to `alas/activate` in the first call. | Send `{"jsonrpc":"2.0","id":<the id you received>,"result":{}}` from inside `alas_handle`. Check under **Messages** that a message went out (`←`). |
| `plugin sent a request before answering alas/activate` | The plugin asked for something (a snapshot, a worktree switch) before it replied to activation. | Send the `alas/activate` response first; requests come after it. |
| `plugin rejected activation: …` | You replied to `alas/activate` with an error. | Return a `result` unless you really mean to refuse. |
| `plugin sent a malformed message` | A message was not valid JSON-RPC 2.0. | Check the `"jsonrpc": "2.0"` field, and that each message has a `method` or an `id`. Send one object per `alas.send`, not an array. |

## The plugin stops while running

| Reason | Cause | Fix |
|---|---|---|
| `Trap: out of fuel` | One message took more than the execution budget. | Do less per message, or optimize. Build with `opt-level = "s"`. See [Staying within the limits](writing-plugins.md#staying-within-the-limits). |
| `Trap: unreachable` | A Rust panic (with `panic = "abort"`), or an `unreachable` instruction. | Find what panicked: an `unwrap` on a missing field is the usual cause. The panic message is not shown, and logs sent in the failing call are lost, so look at the last **Messages** entry. |
| `Trap: out of bounds memory access` | A bug in the plugin, or unsafe code. | Review pointer arithmetic and `unsafe` blocks. |
| `Trap: call stack exhausted` | Unbounded recursion. | Iterate instead, or limit depth. |
| `plugin passed an invalid memory range (ptr …, len …)` | `alas.send` got a pointer and length that are not inside `memory`, or `alas_alloc` returned a buffer that does not fit. | Send from a buffer that is still alive at the moment of the call. Grow memory inside `alas_alloc` if you need more. |
| `message of … bytes exceeds the size limit` | A message was larger than 1 MiB. | Send less data per message. |
| `plugin sent a request id longer than 256 bytes` | A request used a string `id` over the limit. | Use short ids: a counter is enough. |
| `plugin sent more than 64 messages in one call` | Too many `alas.send` calls in one `alas_handle`. | Combine work into fewer messages. |
| `plugin exceeded 64 round trips in one delivery` | The plugin keeps requesting and each reply triggers another request. | Break the chain. Ask again on the next `workspace/changed` instead of immediately. |

After fixing the cause, click **Restart** on the instance. If you rebuilt the plugin,
click **Rescan**, and approve it again.

## A request comes back with an error

The plugin keeps running. The error is in the response, visible under **Messages**.

| Code and message | Cause | Fix |
|---|---|---|
| `-32001 capability not granted: worktree.switch` | The plugin was not granted that capability. | Add it to `capabilities` in `plugin.json`, then **Rescan** and **Approve…** again. Changing the manifest resets approval, so an old approval never covers a new capability. |
| `-32601 method not found: …` | A typo in the method name, or a method this Alas does not have. | Compare with the [method list](api-v1.md#summary). |
| `-32602 invalid params for worktree/switch` | `params.id` is missing or not a string. | Send `{"id": "<worktree id from the snapshot>"}`. |
| `-32003 unknown worktree …` | The id is not a worktree of this plugin's project. | Take the id from the latest snapshot. Worktrees can be removed while you hold an old id. |

## Nothing happens after the plugin is active

- **No `workspace/changed` arrives.** The plugin needs the `workspace.read`
  capability, granted at approval. Check the plugin's `grants` in the
  `alas/activate` message under **Messages**. Then remember that changes are
  checked twice a second, and only *differences* are sent.
- **You do not see your `log` lines.** Alas keeps the latest 200 per instance
  (the Debug window shows only the latest five). A
  `log` needs a `level` of `debug`, `info`, `warn` or `error` and a string `message`, or it is dropped silently. And a
  call that fails discards the log lines it sent.
- **State is missing after a restart.** Expected. A restart is a fresh instance
  with empty memory. See [Working with requests and replies](writing-plugins.md#working-with-requests-and-replies).

## Building the sample

| You see | Cause | Fix |
|---|---|---|
| `can't find crate for core` | The wasm target is missing, or a Homebrew `rustc` earlier on `PATH` is being used. | Run `rustup target add wasm32-unknown-unknown`. The sample's `build.sh` already prefers rustup's toolchain; if you run `cargo` yourself, put it first on `PATH`. |
| `expected exactly one .wasm …` | `build.sh` found zero or several wasm files in `target/wasm32-unknown-unknown/release`. | Make sure the crate builds one `cdylib` and delete stale files under `target/`. |

## Starting over

- **Forget every approval:** `defaults delete io.nlopez.alas pluginApprovals.v1`
  and relaunch Alas.
- **Remove a plugin:** delete its folder from
  `~/Library/Application Support/Alas/Plugins/`, then click **Rescan**.
