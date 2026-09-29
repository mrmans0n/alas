# Plugin canvas tabs and Pixel Office (#1560 phases 3–4, first slice)

## Goal

Ship the first user-facing plugin: a **Pixel Office** center tab that shows one
character per agent session of the current project, animated by what each
agent is doing, with clicks that jump to the session or worktree.

To get there this slice:

1. Takes plugins out of the Debug menu: Release builds, behind an
   off-by-default setting, with a Settings pane.
2. Adds plugin API 2: a canvas tab contribution, a frame clock, framebuffer
   presentation, accessible hit regions, and `session/focus`.
3. Builds the office itself, with original hand-made pixel art, plus a small
   Rust SDK crate shared with the existing sample.

**Exit condition:** with Plugins enabled in Settings, a user builds and installs
Pixel Office, approves it, opens **View → Plugins → Office**, and watches
characters react as agents run, wait for input, ask for permission and go idle.
Clicking a character focuses its session. The tab survives an app restart, and
it shows a clear placeholder when the plugin fails, is disabled or is removed.

## Decisions already made

- Runtime, ABI, JSON-RPC framing, trust and limits are unchanged from
  `2026-09-28-plugin-contract-v1-design.md` unless stated here.
- **Rendering model:** the plugin draws its own RGBA framebuffer and hands it to
  the host (approach A). A host-rendered sprite scene and a vector scene were
  rejected: both grow the contract around one plugin's needs, while a
  framebuffer serves any plugin that has to draw something native
  contributions can't.
- **Surface:** a center tab, not a sidebar section or a separate window.
- **Art:** original PNGs made for this repo. No third-party packs.

## 1. Plugins in Release builds, behind a setting

**Gate.** Settings → Advanced → Experimental gets a "Plugins" toggle, off by
default. When it is off, no `PluginManager` exists: nothing is scanned, loaded
or run. Turning it off at runtime deactivates every host and drops the manager;
turning it on creates the manager and runs a rescan.

**Ownership.** `PluginManager` moves from `PluginsWindowController` onto
`AppState`. `AppState+Plugins.swift` keeps building the per-project
`PluginHostActions`. The Debug → Plugins… window stays in Debug builds as the
message-trace inspector and reads from the same manager.

**Settings → Plugins pane.** It appears only while the setting is on and lists
every discovered plugin with:

- name, version, id and state: active, failed with its reason, disabled, or not
  approved;
- **Approve…**, which opens a sheet listing each requested capability in plain
  language (the text the Debug window shows today), with Approve and Cancel;
- an **Enabled** toggle, **Restart**, and **Show Log**, which shows the host's
  existing bounded `log` for each project;
- **Revoke Approval**.

The pane also has **Reveal Plugins Folder** and **Rescan**. Invalid folders
are listed with their reason.

**Disable versus revoke.** Disabling adds the id to `disabledPluginIDs`, a
string set in `UserDefaults`, and keeps the approval. Revoking removes the
approval. Either one deactivates every host for that plugin, and neither
deletes files.

**Host lifecycle.** One host per (plugin, project), started for every project
while the plugin is approved and enabled, as today. The existing 500 ms
snapshot loop also reconciles hosts against the project list: it starts hosts
for added projects and deactivates hosts for removed ones. This replaces the
"projects added later need another reload" limitation. An idle host costs only
snapshot deliveries, because `tick` only runs while its tab is visible.

**Not in this slice:** watching the plugins folder (Rescan and Restart are
manual), sending `alas/deactivate` on app quit (no plugin state needs flushing
until there is a storage API), and installing from a zip or URL.

## 2. Plugin API 2: canvas tabs

### Versioning

The host's supported set becomes `{1, 2}`. API 2 is API 1 plus everything in
this section. A plugin that uses any of it declares `"api": 2`. On an Alas that
only supports 1, such a plugin fails with the existing
`requires plugin API 2; this Alas supports 1`. API 1 plugins behave exactly as
before, including an inert `contributes`.

The `alas.present` import is accepted only from API 2 plugins. An API 1 module
that imports it fails instantiation as an unknown import, as today.

### Manifest

```json
{
  "api": 2,
  "capabilities": ["workspace.read", "worktree.switch", "session.focus"],
  "contributes": { "tabs": [{ "id": "office", "title": "Office" }] }
}
```

Each `contributes.tabs` entry is a canvas tab. `id` follows the same character
rules as plugin ids but needs no dot, and it must be unique within the
manifest. `title` is non-empty and at most 40 characters. A plugin can have at
most 4 tabs. Violations reject the manifest, reported through the existing
"first failure wins" path.

New capability: `session.focus`. The plain-language approval text is "Open
agent sessions in this project".

### Tab model

```swift
case plugin(PluginTabState)

struct PluginTabState: Codable, Equatable, Identifiable {
    let id: TabID            // "plugin:<pluginID>/<contributionID>"
    let pluginID: String
    let contributionID: String
    var title: String        // last known title, for placeholders
}
```

- Tabs belong to a worktree and the host belongs to the worktree's project.
  Every instance of the same contribution, in any worktree of the project,
  shows the same host's frame.
- The tab restores with the tab set. The title is stored so that a placeholder
  can still name a plugin that has been removed.
- **Opening:** a **View → Plugins** submenu lists the tab contributions of the
  current project's active plugins. Choosing one opens the tab, or focuses it if
  it is already open in the current worktree.

### Frames: `alas.present`

New import: `alas.present(tab: i32, ptr: i32, len: i32, width: i32)`.

- `tab` is an index into `contributes.tabs`.
- The runtime validates the call during the plugin call and copies the pixels
  out immediately, like `alas.send`:
  - `tab` is in range;
  - `width` is between 1 and 1024;
  - `len` is a multiple of `width × 4`, and the resulting height is between 1
    and 1024;
  - `len` is at most 4 MiB;
  - the guest range `ptr..ptr+len` is inside linear memory.

  A violation fails the host with a specific reason.
- Pixels are RGBA8, non-premultiplied, row-major, top-left origin.
- If a tab is presented more than once in one call, the last frame wins. Frames
  are delivered to the host with the call's other output, and the host applies
  them after the call returns.
- The host keeps the latest frame for each tab. The view draws it at the
  largest whole-number scale that fits (at least 1×, with the frame clipped if
  the tab is smaller than the frame), using nearest-neighbour filtering,
  centred on the theme background.
- Until a tab has a first frame, the view shows a small spinner.

### Clock: `tick`

Host → plugin notification: `tick {dt}`, where `dt` is the whole milliseconds
since the previous tick of this host (0 for the first tick after ticking
resumes).

- Sent at a fixed 15 fps in Release and 5 fps in Debug builds, and only while
  at least one instance of any of the plugin's tabs in that project is visible,
  meaning it is the selected tab and its window is not occluded.
- If the previous delivery to the host is still running, the tick is dropped,
  not queued. A slow plugin loses frames instead of building up a backlog.
- Each tick is one `alas_handle` call with the normal fuel budget.
- No capability is required. A plugin without tab contributions never receives
  ticks.

### Regions and input

Plugin → host notification:
`canvas/regions {tab, regions: [{id, label, rect: [x, y, w, h]}]}`.

- It replaces the tab's region set. Coordinates are frame pixels.
- At most 256 regions are kept, and any beyond that are dropped. `id` is
  bounded to 64 bytes and `label` to 200 scalars, truncated rather than failed.
  A tab index out of range, or a message that isn't well-formed, is a protocol
  violation and fails the host.
- When a new frame is presented with a different size, the regions stay as
  they are until the plugin sends new ones.

Host behaviour for regions:

- **Pointer:** hovering a region shows a pointing-hand cursor and a tooltip
  with its label.
- **Accessibility:** every region is an accessibility element with the button
  role, its label, and a frame mapped through the current scale. Regions are
  reachable with Tab in list order, and the focused region gets a focus ring.
- **Activation:** a click, or Return/Space on the focused region, sends host →
  plugin `canvas/click {tab, region}`. Clicks outside every region are ignored.
  There are no raw coordinates or hover events, so every interaction is
  available to keyboard and VoiceOver users.

### New action: `session/focus`

Plugin → host request `session/focus {id}` → `{}`. It requires `session.focus`.

- `id` is a session id from the snapshot. The host switches to the session's
  worktree and focuses its session tab.
- An id that doesn't belong to this project returns `-32003`. Missing params
  return `-32602`. Without the grant the request returns `-32001`.

### Placeholders

The tab's content is picked by one pure function of (setting on, plugin found,
approved, enabled, host state, has frame):

| Condition | Content |
|---|---|
| Plugins setting off, plugin not found, not approved, or disabled | "<title> isn't available" + **Open Plugin Settings** (Settings → Plugins, or Settings → Advanced while the setting is off) |
| Host `failed(reason)` | "<title> stopped: <reason>" + **Restart** |
| Host loading or activating, or active with no frame yet | spinner |
| Active with a frame | the canvas |

A restored tab is never removed on its own; it shows the placeholder until the
plugin comes back.

**Not in this slice:** tab resize events, raw pointer and hover events,
plugin-chosen frame rates, and more than one frame per tab per call.

## 3. Pixel Office

### Crates

- **`plugins/alas-plugin`**: a small Rust SDK for `wasm32-unknown-unknown`.
  It contains the ABI glue (`alas_alloc`, `alas_handle`, imports), JSON-RPC
  message types for API 2, request/reply correlation, and
  `present(tab, &[u8], width)`. It uses only `serde` and `serde_json`.
  `hello-workspace` moves onto it.
- **`plugins/pixel-office`**: the office. `api: 2`; capabilities
  `workspace.read`, `worktree.switch` and `session.focus`; one tab,
  `office` / "Office".
- **Art:** PNG sprite sheets in `plugins/pixel-office/assets/`, drawn for this
  project with a fixed palette of about 24 colours and editable in Aseprite.
  `build.rs` decodes them (using the `png` crate as a build dependency only)
  into palette-indexed byte arrays that are embedded with `include_bytes!`. The
  wasm does no PNG decoding and reads no files.
- `plugins/pixel-office/build.sh` builds the plugin and installs it into the
  plugins folder, like `hello-workspace`.

### Sprites

- **Characters:** 16×24. Walking in 4 directions (4 frames each), sitting,
  typing (2 frames), hand raised, sleeping. Skin, hair and shirt are separate
  palette ramps, so the look is chosen with a palette swap instead of extra
  sheets.
- **Furniture:** 16×16 and 32×32 tiles for desks, monitors, chairs, lamps, the
  coffee machine, couch, water cooler, door, walls and floor.
- **Overlays:** "?" and "!" bubbles, "z z", paper piles (3 sizes), a red warning
  sign, a plan progress bar, and "+N" badges.
- **Font:** a built-in 4×6 bitmap font (ASCII 32–126) for labels.

### Scene

- **Room:** 320 pixels wide. It starts at 180 pixels high and grows downward by
  one desk row per 4 worktrees, up to the 1024-pixel frame limit. Worktrees that
  don't fit are summarised on a "+N more" sign by the door.
- **Desk pods:** one per worktree, ordered as in the snapshot, with up to 4
  seats and the branch name in the bitmap font, truncated with "…" to fit.
  - The current worktree's desk lamp is on.
  - A paper pile shows the dirty-file count in steps: none, 1–5, 6–20, 20+.
  - `conflicts > 0` adds the red warning sign.
  - No dirty data (status unknown) means no pile.
- **Characters:** one per session in the snapshot.
  - The look is deterministic: skin and hair ramps come from a stable hash of
    the session id, and the shirt ramp from the agent id (known agents get fixed
    colours, others hash).
  - Sessions past a pod's 4 seats show as "+N" on the desk and get no character.
- **Lounge:** coffee machine, couch and water cooler along one wall, each with
  a few standing or sitting spots.

### Behaviour

| Snapshot `state` | Behaviour |
|---|---|
| `running` | Seated and typing, monitor flickering. If there's a plan, a progress bar above the monitor shows `completed / total`. |
| `awaiting_input` | Seated, turned toward the viewer, hand raised, bobbing "?" bubble. |
| `permission_request` | Same as `awaiting_input`, with a "!" bubble that blinks red. |
| `idle` | Walks to a free lounge spot, stays a random 8–20 s, then either wanders to another spot or walks back to its desk and sits for a while. After 5 continuous minutes idle, it goes to the couch and sleeps ("z z"). |
| `unknown` | Seated, still, drawn dimmed. |

- **Arrivals and departures:** a session new to the snapshot enters through
  the door and walks to its seat. A session gone from the snapshot walks out and
  disappears.
- **Movement:** characters walk at a fixed speed along a fixed aisle through
  waypoints (door, aisle points, desk seats, lounge spots). There is no
  pathfinding and no collision avoidance, so characters may overlap.
- **Timing and randomness:** everything runs on `tick.dt`. Random choices use
  a deterministic PRNG seeded from the session id, so a session's routine is
  reproducible in tests.
- **Changes mid-walk:** a state change while walking re-routes from the
  current position.

### Interaction

- **Characters:** each is a region labelled
  `"<agent>: <title>, <state in words>"`, for example
  `"claude: Fix login flow, awaiting input"`. Clicking one sends `session/focus`.
- **Desks:** each desk pod is a region labelled
  `"Worktree <branch>, <n> changed files"`, plus ", conflicts" when there are
  conflicts. Clicking one sends `worktree/switch`.
- **Region updates:** regions are sent again only on ticks where a region
  moved, appeared or disappeared.
- **Errors:** error replies (such as a session that ended between the snapshot
  and the click) are logged at `warn` and otherwise ignored.

### Rendering

- **Background layer:** floor, walls, furniture and desk labels are drawn into
  a cached background buffer, rebuilt only when a snapshot changes the layout,
  lamp, piles or warnings.
- **Each tick:** for every sprite drawn last frame, copy the background back
  over its previous bounds. Update the simulation, draw the sprites at their new
  positions (sorted by y), and present the frame.
- **Full redraws:** when the background changes or the frame size changes, the
  whole frame is redrawn.

## 4. Errors and testing

### Failure containment

New `failed` causes, all using the existing path (drop the instance, log the
reason, show "stopped" with Restart):

- an invalid `alas.present`: bad tab index, width or height out of range, `len`
  not a multiple of `width × 4`, over 4 MiB, or a guest range out of bounds;
- a malformed `canvas/regions`: an envelope or params that don't decode, or a
  tab index out of range.

A failed or stopped host drops its stored frames and regions and stops ticking.
Restart creates a fresh instance, and its first present replaces the
placeholder. Region-count and label overflow truncate instead of failing.

### Swift tests

Tests follow the AGENTS.md testing policy: extend existing suites, parameterise
variants, and use WAT fixtures with real WasmKit.

- **`PluginRuntimeTests`:**
  - a valid present is copied out with its dimensions;
  - one parameterised test covers the invalid presents listed above.
- **`PluginHostTests`:**
  - `tick` is delivered only while a tab is visible;
  - a tick is dropped, not queued, while a delivery is in flight;
  - `canvas/click` reaches the plugin;
  - one parameterised `session/focus` test: no grant returns `-32001`, an
    unknown id returns `-32003`;
  - a failed host clears its frames.
- **`PluginManifestTests`:**
  - extend the parameterised failure test with the tab rules (duplicate id, too
    many tabs, empty title) and `api: 3`;
  - an API 1 manifest with `contributes.tabs` gets no tabs.
- **`PluginManagerDiscoveryTests`**, extended rather than a new file:
  - reconciliation starts hosts for an added project and stops them for a
    removed one;
  - disabling a plugin deactivates its hosts.
- **Pure functions, extracted and tested (one small test each, parameterised
  where it helps):**
  - the integer-scale fit;
  - mapping a point to a region;
  - the placeholder decision table.
- No view tests.

### Rust tests

These run with `cargo test` on the host target, with no wasm toolchain.

- **`pixel-office`:**
  - desk layout from a snapshot: rows, the 4-seat cap and "+N", the height cap
    and "+N more";
  - the state-to-behaviour table;
  - idle-to-sleep after 5 minutes of `dt`;
  - dirty-rect rendering produces the same pixels as a full redraw after a
    scripted sequence of ticks.
- **`alas-plugin`:** request/reply correlation, and message encoding and
  decoding round trips for the API 2 types.
- **CI:** add both crates to the existing Rust test matrix in
  `.github/workflows/build.yml`, which runs `cargo test --locked` per project.
  There is still no wasm build in CI.

### Docs

- `docs/plugins/api-v2.md` documents the additions relative to v1: versioning,
  the tab manifest, `alas.present`, `tick`, regions, `canvas/click`,
  `session/focus`, and the limits.
- `getting-started.md` covers enabling the setting and the Settings pane
  instead of the Debug window.
- `writing-plugins.md` switches to the `alas-plugin` crate.

## Risks

- **Debug frame rate.** Even at 5 fps with dirty rects, unoptimized WasmKit may
  stutter. The fallback is a lower Debug frame rate, not a contract change.
- **WasmKit pinned to `main`.** Shipping to Release makes this pressing. This
  is a blocker to review before the setting is announced: move to a tagged
  release with fuel metering, or accept and document the pin.
- **`resourceLimiter` is SPI**, and **a WasmKit crash takes down Alas.** Both
  are unchanged from v1. The setting being opt-in is the mitigation for now.

## Out of scope

- Shipping Pixel Office prebuilt, whether bundled in the app or as a release
  asset. Installing it needs `build.sh` and a Rust toolchain.
- Plugin storage, `session/start` and other task-starting actions, native view
  contributions, command contributions, and network access. These are the
  later roadmap steps toward the kanban board and dashboards.
- Folder watching, install from zip/URL, partial grants, signing, remote
  workspaces, Component Model.
