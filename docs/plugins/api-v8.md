# Plugin API v8

> Message reference. The runtime, limits and the rest of the manifest are in
> [api-v4.md](api-v4.md), and APIs 5 to 7 in [api-v5.md](api-v5.md),
> [api-v6.md](api-v6.md) and [api-v7.md](api-v7.md); everything there still
> applies.

API 8 lets a command open the plugin's tab, and adds two view nodes: a spinner
for loading states and a link that opens in the browser.
[API 9](api-v9.md) adds configure screens, plugin-scoped storage, runtime
prompts and tab visibility.

## The `api` field

Alas loads plugins with `"api": 4` to `8`. Everything below needs `"api": 8`:

- A command's `opens`. An older manifest that uses it is refused.
- The `progress` and `link` nodes. An older plugin that renders them sends an
  invalid tree, which stops it like any other.

## Commands that open a tab

```json
"contributes": {
  "tabs": [{ "id": "inbox", "title": "PR Inbox", "kind": "view" }],
  "commands": [{ "id": "open", "title": "PR Inbox", "slots": ["repo.menu", "palette"], "opens": "inbox" }]
}
```

`opens` names one of the manifest's own tabs, of either kind; any other value
refuses the manifest. When the user runs the command from any slot, Alas opens
that tab, or focuses it if it is open, then sends `command/run` as usual.

The tab opens in a worktree of the project the command ran in: the worktree it
acts on, else the selected one if it belongs to that project, else the
project's main worktree. Alas selects that worktree first, so running the
command from another project's row switches to it.

## Nodes

| Kind | Fields | Shows |
|---|---|---|
| `progress` | `text?` | A small spinner, with `text` as a dim caption beside it. |
| `link` | `label`, `url` | `label` styled as a link. Clicking it opens `url` in the default browser. |

- `url` must be an absolute `https` URL of at most 2048 bytes; anything else
  makes the tree invalid.
- A link opens without telling the plugin: there is no `view/event`.

```json
{ "id": "loading", "kind": "progress", "text": "Loading pull requests…" }
{ "id": "open-123", "kind": "link", "label": "#123", "url": "https://github.com/acme/app/pull/123" }
```
