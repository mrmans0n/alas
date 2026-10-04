# Plugin API v12

> Message reference. The runtime, limits and the rest of the manifest are in
> [api-v4.md](api-v4.md), and APIs 5 to 11 in [api-v5.md](api-v5.md) to
> [api-v11.md](api-v11.md); everything there still applies.
>
> API 12 is still being built. Alas does not load `"api": 12` plugins until all
> of it has landed.

API 12 adds web tabs: a tab whose content is a page the plugin ships, shown in
a sandboxed web view. Use it for what native view trees can't draw, such as
charts, graphs and diagrams. Prefer view trees when they fit: they are themed,
accessible and cheaper.

## The manifest

```json
{
  "api": 12,
  "entry": "plugin.js",
  "web": "ui.js",
  "contributes": { "tabs": [{ "id": "usage", "title": "Usage", "kind": "web" }] }
}
```

- `web` names the page script, a file in the plugin folder, with the same rules
  as `entry`: a relative path with no `..`, not a symlink, UTF-8, at most
  8 MiB, and not the entry itself.
- A tab with `"kind": "web"` shows that page. A web tab without `web`, or
  `web` without a web tab, is refused, and so is either one below `"api": 12`.
- The plugin doesn't ship HTML. Alas serves a fixed page that loads `ui.js` as
  a classic script at the end of `<body>`. Bundle your framework (React,
  Svelte, Chart.js, D3, …) into one IIFE with esbuild, as for `plugin.js`, and
  inline images and fonts as `data:` URLs.
- `ui.js` is covered by the approval, like the manifest and the entry:
  changing any byte of it asks for approval again. The approval sheet says
  "Show its own web content, with no network access".

A catalog release with a page publishes `ui.js` as a third asset; its record's
`web` URL points at it, and its `hash` uses the framed v2 trust hash.

## The page

`ui.js` gets one global, `window.alas`:

```js
alas.post(value)          // send any JSON value to the plugin
alas.onMessage((value) => { … })  // receive what the plugin sends; replaces the previous handler
alas.context              // { tab, theme: "light" | "dark" }, updated when Alas's theme changes
alas.onThemeChange((context) => { … })  // called with the new context; replaces the previous handler
```

- Messages a page posts reach the plugin in the order it posted them.
- `alas.post` throws a `TypeError` for a value `JSON.stringify` can't encode,
  a `RangeError` when the message would be too large, and an `Error("busy")`
  when 32 earlier messages from this page are still waiting for the plugin.
- The page can't call any Alas method, not even ones the plugin was granted.
  Everything goes to the plugin, which decides what to do.
- The page shell sets `color-scheme: light dark`, the system font, and these
  CSS variables from the Alas theme, updated when it changes: `--alas-text`,
  `--alas-dim`, `--alas-accent`, `--alas-background`, `--alas-line`,
  `--alas-tone-danger`, `--alas-tone-success`, `--alas-tone-warning`,
  `--alas-tone-info`.

The page lives while its tab is on screen. When the tab is hidden (another tab
is selected), closed, or the plugin stops, the page goes away; a hidden web tab
reloads its page from scratch when it is shown again.
So have the page post a "ready" message when it starts, and answer it with the
state to show.

## Messages

| Direction | Message |
|---|---|
| Alas → plugin | `web/message {tab, message}` notification: a page of `tab` called `alas.post(message)` |
| plugin → Alas | `web/post {tab, message}`: delivers `message` to every live page of `tab` |

`web/post` may be a notification or a request; a request is answered with
`{}`. A `web/post` to a web tab with no live page is dropped. One to a tab
that isn't a web tab stops the plugin when sent as a notification, and is
answered `-32602` as a request.

`tab/visible` (API 9) is sent for web tabs as for the others.

```js
globalThis.handle = (text) => {
  const msg = JSON.parse(text);
  if (msg.method === "web/message" && msg.params.message.ready) {
    alas.send(JSON.stringify({ jsonrpc: "2.0", method: "web/post",
      params: { tab: msg.params.tab, message: { points: [3, 1, 4] } } }));
  }
};
```

## Limits

| Limit | Value | When exceeded |
|---|---|---|
| `ui.js` size | 8 MiB | The plugin is refused. |
| A message, either direction | 1 MiB for the whole JSON-RPC message, envelope included | Page: `alas.post` throws. Plugin: it stops, as for any oversized send. |
| Page → plugin queue | 32 messages per page not yet handled (a tab shown in two worktrees has two pages) | `alas.post` throws `"busy"`. Each delivery is a normal call under the 250 ms limit. |
| Plugin → page | counts towards the 64 sends per call | as for any send |
| Live web tabs per plugin | 4, across its projects | A fifth shows a placeholder, which opens its page as soon as another closes. |

## Security model

The page is untrusted, even though it ships with the plugin: it may render
data from anywhere, such as an issue body. Alas keeps it in a box:

- **No network.** The page can't reach any host, so it can't get around the
  plugin's `network` list. A Content Security Policy, sent as a response
  header the page can't remove, allows only `ui.js` as script, inline styles,
  and `data:`/`blob:` images and `data:` fonts. A content blocker refuses
  every load except the page's own files and inline `data:`/`blob:` data, and
  DNS prefetching is off.
  WebRTC is removed before the page's script runs. Frames and workers are
  blocked, so the page can't get a fresh copy of what was removed. If the page
  needs data from the network, the plugin fetches it with `http/fetch` and
  posts it.
- **No inline script.** Script injected into the page (`<script>` tags,
  `onerror=` attributes, `eval`) doesn't run.
- **Nothing kept.** Each page has its own private storage: no cookies, local
  storage or cache shared with Alas, web previews, other plugins, or the next
  time the tab opens. Keep state in the plugin with `storage/set`.
- **No navigation.** The page can't leave its shell, open windows, download
  files, or use the camera, microphone or location. `alert`, `confirm` and
  `prompt` return at once. A link the user actually clicks opens in the
  default browser if it is `https`; links the page clicks by script do
  nothing.
- **Only messages to its own plugin.** The bridge between the page and Alas
  lives in a separate script world the page can't see or touch. It checks
  every message's size and the queue before passing it on, and Alas checks
  them again. Messages to the page are passed as data, never run as code.
- **Its own process.** The page runs in a separate WebKit process. If it
  crashes, Alas reloads it; if it spins, it blocks only itself.

What remains: a page can still measure timing, and it can draw a convincing
fake dialog inside its own tab, as a canvas can. The tab always names the
plugin.

Web Inspector is available for web tabs only in Debug builds of Alas.

## Usage history

Alas records every finished agent turn, in every project: who ran it, when,
how it ended, the tokens it used and what it cost. It also records each
provider usage limit that stopped a session. A plugin with `usage.read` reads
that history.

```json
{ "api": 12, "capabilities": ["usage.read"], "events": ["turn.finished"] }
```

### The `usage.read` capability

The approval sheet shows *Read your agents' token usage, cost and usage-limit
history across all projects*. Requests read the plugin's own project by
default, and every project with `"scope": "all"`; the capability covers both,
so the sheet names the wider one. There is no separate grant for `all`: usage
numbers carry no code, prompts or replies, only session and worktree ids,
agent ids, model names, times, token counts and cost.

### What a turn is

```json
{
  "id": 42,
  "session": "8f0c…",
  "project": "p-1", "worktree": "w-3",
  "agent": "claude", "model": "claude-opus-4",
  "startedAt": 1767000000000, "endedAt": 1767000042000,
  "result": "completed",
  "tokens": { "total": 5120, "input": 1200, "cachedInput": 3600, "cachedWrite": 0, "output": 300, "reasoningOutput": 20 },
  "cost": { "amount": 0.031, "currency": "USD" }
}
```

- Times are epoch milliseconds. `startedAt` is when the prompt went to the
  agent, after any checkpoint, attachments and plugin context were prepared;
  `endedAt` when Alas saw the turn end. `endedAt` is never before `startedAt`.
- `result` is `completed`, `failed`, `cancelled` or `limited` (stopped by a
  usage limit). A prompt replaced by a newer one (steering) is recorded as
  `cancelled` when its result arrives, with the tokens the agent reported for
  it, and sent as `turn.finished` like any other turn.
- `tokens` is the turn's own usage as the agent reported it, or absent when it
  reported none. When the agent reports only per-model counts, they are
  summed. Turns that fail or are cancelled before the agent answers have none.
- `cost` is what the turn added to the session's cost: the growth of the
  cumulative cost the agent reports since the session's previous turn that
  had one. It is absent when no cost update arrived during the turn (often a
  failed or cancelled one), and then the next turn that sees an update is
  given all the growth since. It is also absent when the currency changed. If
  the agent restarts its count, the first turn after it counts the whole new
  total. The first cost-bearing turn recorded for a session has no per-turn
  cost, since its total may include turns from before Alas recorded them; it
  becomes the baseline for the next. The same holds once the session's earlier
  turns have passed the retention.
- `model` is the model that answered when the agent named exactly one, and
  otherwise the session's selected model, if any.
- `project` and `worktree` are absent for sessions of a multi-project
  workspace; only `"scope": "all"` returns those.
- `id` grows with each recorded turn.

Alas keeps 400 days of history.

### `usage/turns`

```json
{ "jsonrpc": "2.0", "id": 7, "method": "usage/turns",
  "params": { "since": 1767000000000, "until": 1767600000000, "limit": 200, "scope": "project" } }
```

→ `{ "turns": [ … ], "truncated": true, "next": { "before": 1767400000000, "beforeId": 40 } }`

- Turns whose `endedAt` is at or after `since` and before `until` (absent: no
  end), newest first.
- `limit` is 1 to 1000, 200 when absent. `truncated` is true when older turns
  in the window were left out. Then `next` is present: ask again with the same
  params and `"cursor"` set to it, and the page continues right after the last
  turn you got, even among turns that ended in the same millisecond.
- `scope` is `project` (the default) or `all`.
- The answer comes in a later delivery and counts towards the 4 requests in
  flight.

### `usage/limits`

Same params, `cursor` included; `since` and `until` apply to `detectedAt`.

→ `{ "limits": [ { "session", "project", "worktree", "agent", "detectedAt", "resetsAt", "resetSource" } ], "truncated": false }`, with `next` when truncated.

One entry per limit episode, from its first detection. A session that hits
the same limit again keeps its entry, with the latest reset time. `resetsAt`
is absent when the reset time is not known; `resetSource` is `structured`
(the agent said), `parsed` (read from its message) or `unknown`.

### `turn.finished`

```json
{ "jsonrpc": "2.0", "method": "turn/finished",
  "params": { "session": "8f0c…", "worktree": "w-3", "turn": { … } } }
```

Sent after each turn of the plugin's project is recorded, with the turn as
`usage/turns` returns it. It needs `usage.read`. Turns of other projects, and
of multi-project workspaces, are not sent; read them with `"scope": "all"`.

### Errors

| Code | When |
|------|------|
| `-32601` | The manifest's `api` is below 12 |
| `-32001` | `usage.read` is not granted |
| `-32602` | `since` missing, `limit` outside 1 to 1000, or an unknown `scope` |
| `-32003` | Alas could not open or read its usage history |
