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
