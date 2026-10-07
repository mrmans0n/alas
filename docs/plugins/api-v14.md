# Plugin API v14

> Message reference. The runtime, limits and the rest of the manifest are in
> [api-v4.md](api-v4.md), and APIs 5 to 13 in [api-v5.md](api-v5.md) to
> [api-v13.md](api-v13.md); everything there still applies.

API 14 adds a `progressBar` view node for work made of steps, and lets an
`hstack` center its items vertically.

## The `api` field

Alas loads plugins with `"api": 4` to `14`. A plugin of an older API that sends
a `progressBar` shows the invalid tree, like an unknown kind.

## Progress bars

```json
{ "kind": "progressBar", "id": "ci", "done": 4, "running": 2, "total": 10, "text": "4/10" }
```

A short bar split in three: `done` steps in the node's `tone` (`success` when
unset), `running` ones in the warning color, and the rest in the line color.
`total` is 1 to 10,000; `done` and `running` default to 0, and together are at
most `total`. The optional `text` is a dim caption after the bar and its
accessibility label.

## Centered rows

```json
{ "kind": "hstack", "id": "row", "align": "center", "children": [] }
```

An `hstack` lines its items up on their first text baseline, so a button beside
a two-line column sits level with the first line. `"align": "center"` centers
them vertically instead; `"baseline"` is the default. Older Alas versions ignore
`align`, so a plugin may send it at any API.
