# Plugin API v13

> Message reference. The runtime, limits and the rest of the manifest are in
> [api-v4.md](api-v4.md), and APIs 5 to 12 in [api-v5.md](api-v5.md) to
> [api-v12.md](api-v12.md); everything there still applies.

API 13 lets a button say what kind of action it is: a view tree's `button`
draws its `tone`, and a new `success` tone covers positive actions and states.
[API 14](api-v14.md) adds progress bars and centered rows.

## The `api` field

Alas loads plugins with `"api": 4` to `13`. A plugin of an older API that uses
the `success` tone breaks its message, like an unknown tone: a `view/render`
shows the invalid tree, and a `decorations/set` stops the plugin.

## The `success` tone

`success` joins `normal`, `dim`, `accent`, `warn` and `danger` wherever a tone
is allowed: `text`, `badge`, `card`, `button` and decoration items. It draws in
the theme's green, the color of added lines.

## Button tones

```json
{ "kind": "button", "id": "merge", "label": "Squash & merge", "style": "primary", "tone": "success" }
```

A `button`'s `tone` colors it: a `primary` button fills with the tone instead of
the accent, and a `normal` or `plain` one draws its label and icon in it.
Without `tone`, buttons look as before.

| Action | Suggested look |
|---|---|
| Safe, expected next step | `"style": "primary", "tone": "success"` |
| Neutral | `"style": "normal"`, no tone |
| Risky, but allowed | `"style": "normal", "tone": "warn"` or `"danger"` |

Older Alas versions already accept `tone` on a button and ignore it, so a
plugin can send `warn` or `danger` on a button at any API; only `success` needs
`"api": 13`.
