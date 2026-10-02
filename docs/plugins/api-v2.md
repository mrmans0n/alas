# Plugin API v2

> Message reference. Plugins target API 4; see [api-v4.md](api-v4.md) for the runtime.

API 2 added canvas tabs: a plugin draws pixels into a tab and declares click
regions. Everything in the [API v1 reference](api-v1.md) still applies.

## Tabs and frames

A plugin whose manifest declares no tabs has no `alas.present`, never receives
`tick`, and is stopped if it sends `canvas/regions`.

## Manifest: `contributes.tabs`

```json
{
  "api": 4,
  "capabilities": ["workspace.read", "worktree.switch", "session.focus"],
  "contributes": { "tabs": [{ "id": "office", "title": "Office" }] }
}
```

- At most 4 tabs per plugin.
- `id` uses the plugin id character rules (no dot needed) and is unique within
  the manifest.
- `title` is 1 to 40 characters.

A violation rejects the manifest. Tabs open from **View → Plugins**, which lists
the tabs of the current project's active plugins. A tab is identified by its
index in `contributes.tabs`.

## Capability: `session.focus`

Approval text: "Open agent sessions in this project". Required for
`session/focus`.

## `alas.present(tab, pixels, width)`

Draws a frame: RGBA8 pixels in a `Uint8Array`, non-premultiplied, row-major,
top-left origin. The argument rules and what happens when they are broken are in
[API v4 → `alas.present`](api-v4.md#alaspresenttab-pixels-width). If a tab is
presented more than once in one call, the last frame wins. Frames from a call
that fails are discarded.

Alas draws the latest frame at the largest whole-number scale that fits (at
least 1x, clipped if the tab is smaller), nearest-neighbour, centred. Until the
first frame, the tab shows a spinner.

## `tick {dt}`

Host to plugin notification. `dt` is whole milliseconds since the previous tick
of this instance.

- 15 fps.
- Sent only while at least one of the plugin's tabs in that project is visible
  (selected, window not occluded).
- If the previous delivery is still running, the tick is dropped, not queued.
- `dt` is `0` for the first tick after ticking resumes.
- No capability needed. A plugin without tabs never receives ticks.

## `canvas/regions` and `canvas/click`

Plugin to host notification
`canvas/regions {tab, regions: [{id, label, rect: [x, y, w, h]}]}` replaces the
tab's click regions. Coordinates are frame pixels.

- At most 256 regions are kept; extras are dropped.
- `id` is truncated to 64 bytes and `label` to 200 Unicode scalars. A truncated id
  will not round-trip in `canvas/click`, so keep ids short.
- The host does not range-check `rect` values. Keep them inside the frame.
- A `tab` out of range, or params that do not decode (including a `rect` that is
  not exactly 4 integers), is malformed and stops the plugin.
- Regions stay as they are when a frame of a different size arrives, until you
  send new ones.

Every region is an accessibility button with its label, a pointing-hand cursor
and a tooltip. Activating one (click, or Return/Space when focused) sends host
to plugin `canvas/click {tab, region}`. Clicks outside every region are ignored;
there are no raw coordinates or hover events.

## `session/focus`

Request `session/focus {id}` returns `{}`. `id` is a session id from the
snapshot; Alas switches to its worktree and focuses its session tab.

| Error | When |
|---|---|
| `-32001` | `session.focus` not granted |
| `-32003` | the session does not belong to this project |
| `-32602` | missing or invalid params |

## Limits

| Limit | Value |
|---|---|
| Frame width and height | 1 to 1024 |
| Frame bytes | at most 4 MiB, a multiple of `width * 4` |
| Tabs per manifest | 4 |
| Tab title | 40 characters |
| Regions per tab | 256 |
| Region `id` | 64 bytes (truncated) |
| Region `label` | 200 Unicode scalars (truncated) |
| Tick rate | 15 fps |
