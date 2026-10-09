# Plugin API v15

> Message reference. The runtime, limits and the rest of the manifest are in
> [api-v4.md](api-v4.md), and APIs 5 to 14 in [api-v5.md](api-v5.md) to
> [api-v14.md](api-v14.md); everything there still applies.

API 15 lets a right-pane panel show any kind of content: a view tree as
before, a canvas, or a web page. Rail buttons get badges, commands can open a
panel, and web pages may show images from the plugin's own hosts.

## The `api` field

Alas loads plugins with `"api": 4` to `15`. Below 15, a panel `kind` other
than `view` and a command that `opens` a panel refuse the manifest;
`panel` on the messages below is refused like an unknown target. A
`panel/badge` request is answered `-32601`, and a `panel/badge` notification is
ignored.

## Panel kinds

```json
{
  "api": 15,
  "web": "ui.js",
  "contributes": {
    "panels": [
      { "id": "usage", "title": "Usage", "icon": "chart.bar", "location": "right", "kind": "web" },
      { "id": "office", "title": "Office", "location": "right", "kind": "canvas" }
    ]
  }
}
```

| `kind` | `right` | `changes.section`, `run.report.section`, `configure` |
|---|---|---|
| `view` (default) | yes | yes |
| `canvas` | yes | refused |
| `web` | yes | refused |

A `web` panel needs the manifest's `web` page, like a web tab. A plugin has one
page script for its tabs and panels; `alas.context` says which one it is
drawing: `{ "panel": "usage", "theme": "dark" }` for a panel,
`{ "tab": 0, "theme": "dark" }` for a tab.

Panels keep the rules of [API 5](api-v5.md#panels): `panel/visible` says when
one is shown, a stopped plugin's panel offers Restart, and the pane shows only
the selected panel. So a web panel's page closes when the pane collapses or
another rail item is picked, and loads from scratch when shown again: post
"ready" from the page and answer with the state. Web panels count toward the 4
live pages per plugin.

A canvas panel is at least 240 points wide. Draw at most that, or the frame
is clipped at scale 1. It ticks while it is shown.

## Messages that name a panel

Each message that names a `tab` takes `panel` instead, with exactly one of
the two:

| Message | For a panel |
|---|---|
| `alas.present(target, pixels, width)` | `target` is the panel id string |
| `canvas/regions` | `{ "panel": "office", "regions": [ … ] }` |
| `canvas/click` (Alas → plugin) | `{ "panel": "office", "region": "desk-1" }` |
| `web/post` | `{ "panel": "usage", "message": … }` |
| `web/message` (Alas → plugin) | `{ "panel": "usage", "message": … }` |

A frame, region list or `web/post` for a panel of another kind stops the
plugin (as a notification) or is answered `-32602` (as a request), as for
tabs.

## Rail badges

```json
{ "jsonrpc": "2.0", "method": "panel/badge", "params": { "panel": "inbox", "count": 2, "tone": "danger" } }
{ "jsonrpc": "2.0", "method": "panel/badge", "params": { "panel": "inbox", "dot": true } }
{ "jsonrpc": "2.0", "method": "panel/badge", "params": { "panel": "inbox" } }
```

- `panel` names a `right` panel of any kind. No capability is needed.
- `count` is 1 to 9,999 and shows as "99+" above 99, or `dot: true` draws a
  dot; not both. With neither, the badge clears.
- `tone` is a view-tree tone. `normal`, the default, draws the grey of the
  built-in counts; the others fill the badge with their color.
- The badge shows whether the pane is open or collapsed, and clears when the
  plugin stops or restarts, so set it again on activation.
- A notification or a request (answered `{}`). Bad params stop the plugin as
  a notification and are answered `-32602` as a request. Below API 15 a
  request is answered `-32601` and a notification is ignored.

## Commands that open a panel

A command's `opens` may name a `right` panel. Running the command selects the
worktree it ran in, as for a tab, makes the panel the right pane's selected
item and opens the pane.

### Remembered selection

The panel a user or a command picked stays selected when the right pane
remounts, such as when switching worktrees and back. The choice is kept in
memory, per worktree, and is lost when Alas quits. If the panel is no longer
offered any more, the pane falls back to its default item.

## Images in web pages

From API 15 a plugin's pages may load images over `https` from the hosts in
its `network` list, and nowhere else: `<img src="https://avatars.example.com/u/1">`.
Every other load stays blocked, so fetch data with `http/fetch` and post it as
before. Requests carry no cookies. The approval sheet says *Show its own web
content, with images from avatars.example.com*.

Images can still carry data out in their URL, but only to hosts the user
approved for this plugin, which it could already reach with `http/fetch`.

## Errors

| Code | When |
|------|------|
| `-32601` | `panel/badge` request from a plugin below API 15 (a notification is ignored) |
| `-32602` | `panel/badge` with bad params, or `web/post` to a panel that is not a web panel, as a request |
