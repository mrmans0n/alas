# Writing plugins

Practical guidance for building a plugin: how to structure one, how to test it
without Alas, how to stay inside the limits, and how to use TypeScript.

## The shape of a plugin

A plugin is one script that assigns `globalThis.handle`. Alas calls it with one
JSON-RPC message as a string per delivery, and the plugin answers by calling
`alas.send` with JSON strings. The sample in
[`plugins/samples/hello-workspace`](../../plugins/samples/hello-workspace) is
the whole pattern in about 45 lines of plain JavaScript, with no SDK:

```js
let nextId = 1;
const pending = new Map();

function send(message) {
  alas.send(JSON.stringify({ jsonrpc: "2.0", ...message }));
}

function request(method, params, onReply) {
  const id = nextId++;
  pending.set(id, onReply);
  send({ id, method, params });
}

function log(level, message) {
  send({ method: "log", params: { level, message } });
}

globalThis.handle = (json) => {
  const message = JSON.parse(json);
  if (message.method === "alas/activate") {
    send({ id: message.id, result: {} });  // must be answered in this call
    log("info", `activated for ${message.params.project.name}`);
  } else if (message.method === "workspace/changed") {
    log("info", `${message.params.snapshot.worktrees.length} worktrees`);
  } else if (message.method === undefined && pending.has(message.id)) {
    const onReply = pending.get(message.id);
    pending.delete(message.id);
    onReply(message);
  }
};
```

- Top-level code runs once, when the instance activates. Module variables such
  as `pending` live until the instance stops.
- `handle` receives a string. Parse it; Alas does not guarantee key order.
- `alas.send` takes a string. Passing an object stops the plugin.
- A reply has no `method`. It has `result` or `error`, and the `id` of your
  request.

The full list of globals and host functions is in
[API v4 → The script](api-v4.md#2-the-script).

## Testing without Alas

`alas` is the only thing a plugin needs from Alas, so you can run the script in
Node with a fake one. Put a recorder on `globalThis.alas`, evaluate the plugin,
then call `handle` and read what it sent:

```js
// plugin.test.mjs — run with: node --test
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

function load() {
  const sent = [];
  const context = vm.createContext({ alas: { send: (json) => sent.push(JSON.parse(json)) } });
  vm.runInContext(readFileSync(new URL("./plugin.js", import.meta.url), "utf8"), context);
  return { handle: (message) => context.handle(JSON.stringify(message)), sent };
}

test("answers activation first", () => {
  const plugin = load();
  plugin.handle({ jsonrpc: "2.0", id: 0, method: "alas/activate",
                  params: { api: 4, project: { id: "p", name: "demo" }, grants: [] } });
  assert.deepEqual(plugin.sent[0], { jsonrpc: "2.0", id: 0, result: {} });
});
```

A `vm` context starts with only the ECMAScript built-ins, which is close to what
Alas gives a plugin. Node itself has more (`console`, `setTimeout`, `fetch`), so
code that runs under plain Node can still fail in Alas. Keep the plugin away
from them.

## TypeScript and bundling

Alas loads one file, so anything with imports has to be bundled first. esbuild
does it in one step:

```bash
esbuild src/plugin.ts --bundle --format=iife --target=es2022 --outfile=plugin.js
```

The bundle just has to end up assigning `globalThis.handle`. Do not depend on
packages that need Node or browser APIs; they fail at run time, not when you
bundle.

The TypeScript SDK, `@alas/plugin`, is in progress in
[alas-plugins](https://github.com/mrmans0n/alas-plugins). It will provide typed
messages, request ids and reply matching, the activation handshake, and a test
host. Until then, the sample's pattern above is all a plugin needs.

## Working with requests and replies

- **Answer `alas/activate` first, in the same call.** Requests sent before the
  activation response stop the plugin. A `log` may come first.
- **Remember what each request id was for.** Match replies by `id`. A reply has
  `result` or `error: {code, message}`. Replies come back in the order you asked.
- **Do not answer every reply with a new request.** Alas stops a plugin that needs
  more than 64 calls to settle a single delivery. Ask again on the next
  `workspace/changed` instead.
- **You get the snapshot without asking.** `workspace/changed` arrives shortly
  after activation, so most plugins never need to send `workspace/snapshot`.
- **State does not survive a restart.** A restarted plugin is a fresh instance
  with empty memory and receives `alas/activate` again. Rebuild anything you need
  from the next snapshot, or keep it in [storage](api-v3.md#storage).
- **Promises settle within the call.** Their callbacks run before `handle`
  returns. If you wrap requests in promises, resolve them from the reply's
  `handle` call, as `pending` does with callbacks above.

## Canvas tabs

A plugin that declares canvas tabs gets `alas.present(tab, pixels, width)`: hand
it a `Uint8Array` of RGBA8 pixels. `canvas/regions` publishes clickable,
accessible regions, and `tick {dt}` and `canvas/click {tab, region}` drive
animation and input. Frame and region rules are in [API v2](api-v2.md) and
[API v4](api-v4.md#alaspresenttab-pixels-width).

Reuse one pixel buffer across frames instead of allocating a new one per tick.
Alas copies the frame during the call, so the buffer is yours again as soon as
`present` returns.

## Reading the snapshot

The [snapshot](api-v1.md#snapshot) always contains the whole project, so the
simplest plugin is a pure function of the latest one. If you need to react to a
*transition*, such as a session finishing, keep the previous snapshot and
compare. Alas does not send differences.

- Treat `id` values as opaque strings and compare them for equality only.
- Do not rely on worktree order.
- `dirty` and `plan` may be absent. Handle both.
- Treat a session `state` you do not recognize as `unknown`.

## Logging and debugging

- There is no `console`. Send `log` messages, and read them in
  **Settings → Plugins** under each project's instance. In Debug builds of Alas,
  **Debug → Plugins…** also has **Messages** on each row, with the raw JSON in
  both directions.
- **A call that fails loses its own output**, `log` included. If a plugin throws,
  the lines it logged during that same message are gone. The stop reason keeps
  the first line of the exception's message (`plugin threw: TypeError: …`).
  Look at the last **Messages** entry to see which message was being handled.

## Staying within the limits

Read the full [limits table](api-v4.md#4-limits). What matters day to day:

- **Work per message.** Each call gets 250 ms of CPU time, and the same
  limit applies in Debug and Release builds of Alas. Alas runs JavaScriptCore
  without the JIT, so code runs in an interpreter: parsing a snapshot or
  rendering a board takes well under a millisecond, but sorting large lists or
  walking history on every message adds up.
- **Activation.** Evaluating the script gets 1 s; the `alas/activate` call itself
  gets the usual 250 ms. Keep top-level code to setup.
- **Memory.** Not capped, but not free either. Do not keep every snapshot you
  ever received.
- **Messages.** At most 64 sends per call, each at most 1 MiB. Send one
  `view/render` per change, not one per node.
