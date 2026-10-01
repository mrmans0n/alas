# Troubleshooting

Find your symptom, read the cause, apply the fix. Start in **Settings → Plugins**:
it lists every plugin, anything under **Not loaded** with the reason, and per
project the instance's state with its log lines in a disclosure. In Debug builds
of Alas, **Debug → Plugins…** also shows, under **Messages**, the JSON that went
in each direction.

For the full list of stop reasons, see
[Why a plugin stops](api-v4.md#5-why-a-plugin-stops). For request errors, see
[Errors](api-v1.md#6-errors).

## The plugin is not listed, or is under "Not loaded"

Anything under **Not loaded** shows the folder name and the reason.

| You see | Cause | Fix |
|---|---|---|
| A file error mentioning `plugin.json` | The folder has no readable `plugin.json`. | Put `plugin.json` directly inside the plugin folder, not in a sub-folder. |
| `plugin.json is not a valid JSON object` | Syntax error in the manifest. | Validate the JSON, for example with `python3 -m json.tool plugin.json`. |
| `plugin.json is missing "<field>"` | A required field is absent or blank. | Add `id`, `name`, `version`, `api` and `entry`. |
| `invalid plugin id "…"` | The id is not reverse-DNS. | Use lowercase letters, digits and `-`, in at least two dot-separated segments, such as `com.example.my-plugin`. |
| `built for plugin API 3, the WebAssembly runtime, which Alas no longer supports; rebuild it for API 4` | An API 1 to 3 plugin: a WebAssembly module. | Rewrite it as JavaScript and set `"api": 4`. See [Migrating](api-v4.md#6-migrating-from-api-1-to-3). |
| `requires plugin API 5; this Alas supports 4` | `api` is newer than this Alas. | Update Alas, or set `"api": 4` if the plugin does not need anything newer. |
| `unknown capability "…"` | A typo, or a capability this Alas does not have. | Use `workspace.read`, `worktree.switch`, `session.focus`, `session.read` or `tasks.start`. |
| `invalid tab contribution: …` | A tab in `contributes.tabs` breaks a rule. | See [API v2](api-v2.md#manifest-contributestabs) and [API v3](api-v3.md#manifest-tab-kind). |
| `entry "…" must be a relative path inside the plugin folder` | `entry` is absolute, uses `..`, or **the file does not exist, is a symlink, or resolves outside the folder**. | Check the path, and that `build.sh` copied `plugin.js`. |
| `duplicate plugin id …` | Two folders declare the same `id`. | Remove or change one. Neither loads until you do. |

Nothing at all, not even under **Not loaded**? The folder is not in
`~/Library/Application Support/Alas/Plugins/`, or you have not clicked **Rescan**
since adding it.

## "Approve…" appears again

Expected after any change to `plugin.json` or the script. Approval is tied to
the exact bytes of both, so every edit or rebuild asks again. See
[Concepts → Trust](concepts.md#trust-and-approval).

If it keeps asking for a plugin you have not changed, your bundler is probably
non-deterministic and embeds something like a timestamp or absolute path. Each
build then produces different bytes, so each one needs approving.

## The plugin stops as soon as it starts

The instance shows `Stopped: <reason>`.

| Reason | Cause | Fix |
|---|---|---|
| `could not load plugin: script is not UTF-8` | The entry file is not UTF-8 text. | Point `entry` at the JavaScript file, saved as UTF-8. |
| `could not load plugin: script of … bytes exceeds the size limit` | The script is over 8 MiB. | Bundle with minification, and drop dependencies you do not need. |
| `plugin threw: SyntaxError: …` | The script does not parse. JavaScriptCore does not accept TypeScript or JSX. | Bundle or compile to plain JavaScript first. Check with `node --check plugin.js`. |
| `plugin threw: ReferenceError: Can't find variable: …` | The script uses a global Alas does not provide, such as `console`, `setTimeout`, `require` or `process`. | Remove the use, or the dependency that makes it. See [Globals](api-v4.md#globals). |
| `plugin does not define globalThis.handle` | After evaluation, `handle` is missing or not a function. A bundle that keeps `handle` inside a module scope causes this. | Assign it explicitly: `globalThis.handle = (json) => { … }`. |
| `plugin took longer than 1000 ms` | Top-level code ran past the 1 s evaluation limit. | Do less at load. Build expensive state lazily. |
| `plugin did not respond to alas/activate` | No reply to `alas/activate` in the first call. | Send `{"jsonrpc":"2.0","id":<the id you received>,"result":{}}` from inside `handle`. Check under **Messages** that a message went out (`←`). |
| `plugin sent a request before answering alas/activate` | The plugin asked for something (a snapshot, a worktree switch) before it replied to activation. | Send the `alas/activate` response first; requests come after it. |
| `plugin rejected activation: …` | You replied to `alas/activate` with an error. | Return a `result` unless you really mean to refuse. |
| `plugin sent a malformed message` | A message was not valid JSON-RPC 2.0. | Check the `"jsonrpc": "2.0"` field, and that each message has a `method` or an `id`. Send one object per `alas.send`, not an array. |

## The plugin stops while running

| Reason | Cause | Fix |
|---|---|---|
| `plugin took longer than 250 ms` | One call ran past the time limit, often an endless loop. | Do less per message. See [Staying within the limits](writing-plugins.md#staying-within-the-limits). |
| `plugin threw: …` | An uncaught exception in `handle`. A missing field (`TypeError: undefined is not an object`) is the usual cause. | Find what threw. Logs sent in the failing call are lost, so look at the last **Messages** entry. |
| `alas.send expects one string` | `alas.send` got an object or another non-string. | Call `alas.send(JSON.stringify(message))`. |
| `message of … bytes exceeds the size limit` | A message was larger than 1 MiB. | Send less data per message. |
| `plugin sent a request id longer than 256 bytes` | A request used a string `id` over the limit. | Use short ids: a counter is enough. |
| `plugin sent more than 64 messages in one call` | Too many `alas.send` calls in one `handle` call. | Combine work into fewer messages. |
| `plugin exceeded 64 round trips in one delivery` | The plugin keeps requesting and each reply triggers another request. | Break the chain. Ask again on the next `workspace/changed` instead of immediately. |
| `plugin presented an invalid frame: …` | `alas.present` got an undeclared tab, a width outside 1 to 1024, something other than a `Uint8Array`, or a length that is not a whole number of rows. | Check the [frame rules](api-v4.md#alaspresenttab-pixels-width). |
| `plugin presented a frame to view tab …` | `alas.present` targeted a tab whose `kind` is `view`. | Present only to canvas tabs; view tabs use `view/render`. |

A refused `alas.send` or `alas.present` throws into the script, but catching
that exception does not save the call: the plugin is stopped anyway.

After fixing the cause, click **Restart** on the instance. If you changed the
plugin, click **Rescan**, and approve it again.

## A request comes back with an error

The plugin keeps running. The error is in the response, visible under **Messages**.

| Code and message | Cause | Fix |
|---|---|---|
| `-32001 capability not granted: worktree.switch` | The plugin was not granted that capability. | Add it to `capabilities` in `plugin.json`, then **Rescan** and **Approve…** again. Changing the manifest resets approval, so an old approval never covers a new capability. |
| `-32601 method not found: …` | A typo in the method name, or a method this Alas does not have. | Compare with the [method list](api-v4.md#3-methods-and-notifications). |
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
- **A promise never settles.** A promise only settles within the call that
  resolves it, and there are no timers to resolve it later. Drive time-based work
  from `tick` (canvas tabs) or `workspace/changed`.
- **State is missing after a restart.** Expected. A restart is a fresh instance
  with empty memory. See [Working with requests and replies](writing-plugins.md#working-with-requests-and-replies).

## Starting over

- **Forget every approval:** `defaults delete io.nlopez.alas pluginApprovals.v1`
  and relaunch Alas.
- **Remove a plugin:** delete its folder from
  `~/Library/Application Support/Alas/Plugins/`, then click **Rescan**.
