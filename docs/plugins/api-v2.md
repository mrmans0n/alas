# Plugin API v2

API 2 is API 1 plus canvas tabs: a plugin draws pixels into a tab and declares
click regions. Everything in the [API v1 reference](api-v1.md) still applies.

## What's new in API 2

Declare `"api": 2` in `plugin.json` to use anything on this page. An Alas that
only supports API 1 refuses such a plugin with
`requires plugin API 2; this Alas supports 1`. API 1 plugins are unchanged,
including an inert `contributes`. The `alas.present` import is accepted only
from API 2 plugins; an API 1 module importing it fails to instantiate. An
API 1 plugin that sends `canvas/regions` is stopped, because it has no tabs.

## Manifest: `contributes.tabs`

```json
{
  "api": 2,
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

## `alas.present(tab, ptr, len, width)`

Import `alas.present(tab: i32, ptr: i32, len: i32, width: i32)` draws a frame.

- Pixels are RGBA8, non-premultiplied, row-major, top-left origin.
- `tab` is in range; `width` is 1 to 1024; `len` is a multiple of `width * 4`
  and the height `len / (width * 4)` is 1 to 1024; `len` is at most 4 MiB;
  `ptr..ptr+len` is inside linear memory.
- Alas copies the pixels during the call. If a tab is presented more than once
  in one call, the last frame wins.
- Frames from a call that fails are discarded.
- Any violation stops the plugin with a specific reason.

Alas draws the latest frame at the largest whole-number scale that fits (at
least 1x, clipped if the tab is smaller), nearest-neighbour, centred. Until the
first frame, the tab shows a spinner.

## `tick {dt}`

Host to plugin notification. `dt` is whole milliseconds since the previous tick
of this instance.

- 15 fps in Release builds, 5 fps in Debug builds.
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
| Frame `len` | at most 4 MiB, a multiple of `width * 4` |
| Tabs per manifest | 4 |
| Tab title | 40 characters |
| Regions per tab | 256 |
| Region `id` | 64 bytes (truncated) |
| Region `label` | 200 Unicode scalars (truncated) |
| Tick rate | 15 fps Release, 5 fps Debug |
