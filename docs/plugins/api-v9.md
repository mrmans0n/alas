# Plugin API v9

> Message reference. The runtime, limits and the rest of the manifest are in
> [api-v4.md](api-v4.md), and APIs 5 to 8 in [api-v5.md](api-v5.md),
> [api-v6.md](api-v6.md), [api-v7.md](api-v7.md) and [api-v8.md](api-v8.md);
> everything there still applies.

API 9 gives a plugin a configure screen in Settings → Plugins, storage shared by
all of its projects, slash prompts it sets while running, word of when its tabs
are on screen, and a Markdown view node. Snapshots also mark the project's main
worktree.

## The `api` field

Alas loads plugins with `"api": 4` to `9`. Everything below needs `"api": 9`:

- A panel with `"location": "configure"`. An older manifest that uses it is
  refused.
- `prompts/set`. An older plugin that sends it gets `-32601` method not found.
- `storage/*`'s `scope`. An older plugin's `scope` is ignored, so its requests
  keep using project storage.
- `tab/visible` and `storage/changed` are sent only to API 9 plugins.
- The `markdown` node. An older plugin that renders it sends an invalid tree,
  which stops it like any other.

The snapshot's `main` field is sent to every plugin.

## Configure screen

```json
"contributes": {
  "panels": [{ "id": "setup", "title": "Linear Setup", "location": "configure" }]
}
```

- At most one panel per manifest has `"location": "configure"`; it counts
  toward the panel limit. `icon` is ignored.
- For an approved plugin that declares one, Settings → Plugins shows
  **Configure…** on the plugin's row. It opens a resizable sheet titled with the
  panel's `title`, closed with **Done** (or Escape).
- The sheet is rendered by the plugin's instance in the selected project when
  it runs there, otherwise by any running instance. With none running, the
  button is disabled: "Open a project to configure this plugin".
- It works like any panel: Alas sends `panel/visible {panel, visible: true}`
  when the sheet opens and `visible: false` when it closes, the plugin draws it
  with `view/render {panel, root}` (no `worktree` or `run`; sending either stops
  the plugin), and its nodes send `view/event {panel, id, kind, value}`. A
  plugin that restarts while the sheet is open gets `panel/visible` again.
- A configure panel never shows in the right pane or inline.

Plain settings stay in the manifest's `settings`. A configure screen suits what
those cannot express, such as picking from a list the plugin fetched; keep
what it saves in plugin-scoped storage (below) so every project sees it.

## Plugin-scoped storage

`storage/get`, `storage/set` and `storage/keys` take an optional `scope`:

| `scope` | Store |
|---|---|
| `"project"`, or omitted | The project's, as before |
| `"plugin"` | The plugin's own, shared by its instances in every project |

```json
{ "jsonrpc": "2.0", "id": 4, "method": "storage/set", "params": { "scope": "plugin", "key": "team", "value": "ENG" } }
```

- Same capability (none), keys, values, errors and limits as project storage
  ([api-v3.md](api-v3.md#storage)), with its own 1 MiB.
- Any other `scope` is refused with `-32602` "unknown storage scope".
- Stored at `PluginData/<pluginID>/storage` under Alas's application support
  folder, next to the plugin's settings.

After a plugin-scoped `storage/set` succeeds, deletions included, Alas sends
every other running instance of the plugin a notification; the instance that
wrote gets none:

```json
{ "jsonrpc": "2.0", "method": "storage/changed", "params": { "scope": "plugin", "key": "team" } }
```

Read the new value with `storage/get`.

## Runtime prompts

```json
{ "jsonrpc": "2.0", "id": 5, "method": "prompts/set", "params": { "prompts": [{ "name": "eng-123", "description": "Fix the login bug" }] } }
```

- Replaces the instance's runtime prompts and replies `{}`. An empty list
  clears them. No capability.
- At most 32. `name` and `description` follow the manifest's prompt rules
  ([api-v7.md](api-v7.md#slash-prompts)). A name that repeats in the list or
  is also one of the manifest's prompts is refused with `-32602`, and nothing
  changes.
- They appear in the composer's slash picker after the manifest's prompts and
  are expanded with `prompt/expand`, exactly like them.
- They belong to the instance: a restart, a failure or turning the plugin off
  clears them.

## Tab visibility

Alas sends the notification `tab/visible {tab, visible}` when the first view
of one of the plugin's tabs appears in the project and when the last one goes,
for canvas and view tabs alike. `tab` is the tab's index, as in `view/render`
and the canvas messages.

```json
{ "jsonrpc": "2.0", "method": "tab/visible", "params": { "tab": 0, "visible": true } }
```

A tab counts as shown while it is open in a window that is not hidden. A
plugin that starts or restarts while a tab is shown gets `tab/visible` with
`visible: true` right after activation, as for `panel/visible`.

## Markdown node

| Kind | Fields | Shows |
|---|---|---|
| `markdown` | `text` | `text` rendered as Markdown, selectable. |

```json
{ "id": "notes", "kind": "markdown", "text": "## Release notes\n\n- Fixed **login**\n- See [#123](https://github.com/acme/app/pull/123)" }
```

- `text` is required and at most 32 KiB of UTF-8, its own bound in place of
  the 4,000-character limit on other strings. The tree's other limits apply.
- Headings, paragraphs, emphasis, inline code, code blocks, quotes, task lists
  and tables render as in agent chat. HTML is not rendered.
- Images are not loaded; their alt text is shown instead.
- Clicking an absolute `https` link opens it in the default browser; links with
  any other scheme, or relative ones, do nothing. As for `link`, there is no
  `view/event`.

## Main worktree

Each worktree in `workspace/snapshot` and `workspace/changed` carries
`"main": true` when it is the project's main worktree; the field is omitted on
the others.

```json
{ "id": "…", "branch": "main", "current": false, "main": true, "sessions": [] }
```
