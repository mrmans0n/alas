# Plugin view tabs, tasks, storage and Kanban (#1560, next phase)

## Goal

Let a plugin build a real, native UI and do real work in a project, and ship the
first plugin that needs both: a **Kanban board** whose cards start agents in
new worktrees and then follow those agents on their own.

This phase adds, as plugin API 3:

1. **View tabs:** the plugin describes a small declarative view tree, and Alas
   renders it with native SwiftUI controls and sends the plugin events.
2. **`task/start`:** create a worktree and start an agent with a prompt.
3. **Storage:** a small private key-value store per plugin and project.
4. **`plugins/kanban`:** the reference plugin.

**Exit condition:** with Plugins on, a user installs and approves the Kanban
plugin and opens **View → Plugins → Board**. They add a card with a title and a
prompt and press Start. A new worktree appears with an agent working on the
prompt, the card moves to Running, then to Needs you when the agent asks for
input, and to Review when it goes idle. Clicking the card opens its session.
The board survives an app restart.

## Decisions already made

- Everything from `2026-09-28-plugin-contract-v1-design.md` and
  `2026-09-29-plugin-canvas-tabs-and-pixel-office-design.md` (API 1 and 2)
  still holds unless stated here.
- **UI model:** the plugin sends the whole tree for a tab each time it changes
  (approach A). Patch operations were rejected: both sides would have to track
  state, and a lost or out-of-order patch corrupts the UI. Host-side templates
  were rejected: every new kind of plugin would need a new template in Alas.
- **Starting a task** creates a new worktree and launches the project's
  default agent with the card's prompt, reusing the scheduled-run launch path.
- **Card movement** follows the agent's session state automatically, except
  Done, which is manual.

## 1. View tabs

### Versioning and manifest

The host supports `{1, 2, 3}`. API 3 is API 2 plus everything in this document.

`contributes.tabs[].kind` is `"canvas"` (the default) or `"view"`. It is only
accepted with `api >= 3`; an API 2 manifest with `kind` fails as an invalid
tab. `session.focus` stays an API 2 capability; `tasks.start` is API 3.

View tabs share everything canvas tabs have: the `Tab.plugin` case, the
**View → Plugins** menu, the placeholder decision, and tab restoration. They
receive no `tick`.

### Rendering: `view/render`

Plugin → host notification: `view/render {tab, root}`. `tab` is the index into
`contributes.tabs` and must be a view tab. `root` replaces the tab's whole tree.
The host keeps the last tree per tab and renders it; SwiftUI diffs by node
`id`, so focus, scroll position and text being typed survive a re-render.

Every node has `id` (a string, unique within the tree, at most 64 bytes) and
`kind`:

| Kind | Fields | Events |
|---|---|---|
| `vstack`, `hstack` | `children`, `spacing?` (0–32) | – |
| `scroll` | `child`, `axis: "vertical" \| "horizontal"` | – |
| `text` | `text`, `style?: body \| caption \| title \| monospaced`, `tone?: normal \| dim \| accent \| warn \| danger` | – |
| `badge` | `text`, `tone?` | – |
| `button` | `label`, `icon?` (SF Symbol name), `style?: normal \| primary \| plain`, `disabled?` | `click` |
| `textField` | `value`, `placeholder?`, `multiline?` | `submit` with `value` |
| `menu` | `label`, `items: [{id, label}]` | `select` with the item's `id` as `value` |
| `card` | `children`, `tone?`, `clickable?` | `click` when clickable |
| `divider`, `spacer` | – | – |

- Colours, fonts and spacing come from the Alas theme; a plugin chooses only
  the semantic `style` and `tone`.
- `textField` keeps its editing state on the host. `value` is the initial text,
  applied when the node first appears or when its `value` changes between two
  renders; a re-render with the same `value` does not overwrite typing.
  `submit` is Return, or ⌘Return when `multiline`.
- Unknown optional fields are ignored so newer plugins still render on this
  host; an unknown `kind` is an error.

### Events: `view/event`

Host → plugin notification: `view/event {tab, id, kind, value?}`, where `kind`
is `click`, `submit` or `select`. Events are only sent for nodes in the tree the
host is currently showing, the same rule canvas clicks follow.

### Limits and validation

- At most 2,000 nodes and 16 levels deep per tree.
- Strings at most 4,000 Unicode scalars; ids at most 64 bytes; at most 64 menu items.
- Duplicate ids, an unknown `kind`, a missing required field, a field of the
  wrong type or an out-of-range value, a tree over the limits, or a `tab` that
  is not a view tab is a protocol violation: the host stops the plugin with the
  reason, like a malformed `canvas/regions`.
- `alas.present` and `canvas/regions` for a view tab, and `view/render` for a
  canvas tab, are also violations.

Validation lives in a pure decoder, `PluginViewTree`, that turns the JSON into a
typed tree or a reason, so the view only ever sees valid trees.

### Accessibility

Every node renders as a real SwiftUI control, so VoiceOver, keyboard focus and
Full Keyboard Access work without plugin effort. Buttons, menus and clickable
cards take their accessibility label from their visible text.

### Lifecycle

- The tab keeps its last tree while the plugin restarts and until a new tree
  arrives.
- It shows the existing placeholders when there is nothing to show: unavailable,
  stopped with Restart, or loading until the first tree.
- A failed or stopped host drops its trees, like its canvas frames.

## 2. Host actions and storage

### `task/start`

Plugin → host request: `task/start {title, prompt, branch?, agent?}` →
`{sessionId, branch}`. It requires the new capability `tasks.start`, approval
text "Create worktrees and start agents in this project".

- **Branch:** `branch` if given, otherwise derived from `title`. The host
  normalises it to a valid branch name and makes it unique by appending a
  number, checking both the branch and the destination path the way
  `ScheduledWorktreeDestination` does. The base is the project's configured
  default base branch; the destination is where the New Worktree dialog would
  put it.
- **Agent:** `agent` must be an installed ACP agent id; without it, the
  project's default agent is used. An unknown agent returns `-32602`; a project
  with no usable agent returns `-32003`.
- **Launch:** the host generates the session id first and replies at once with
  `{sessionId, branch}`. It then creates the worktree and starts the agent with
  the prompt in the background, on the path scheduled runs use
  (`createWorktree` with an ACP launch surface carrying a prepared prompt).
- **No focus change:** starting a task does not change the selected worktree
  or open a tab.
- **Failure:** if the background launch fails, the host sends
  `task/failed {sessionId, reason}` and records the failure on the worktree the
  way scheduled runs do.
- **Rate limit:** one start in flight per plugin and project. A second request
  while one is launching returns `-32003` "a task is already starting".
- `title` and `prompt` are required and non-empty (`-32602` otherwise); `prompt`
  is at most 32 KiB.

The plugin then follows its session through `workspace/changed`, and opens it
with the existing `session/focus`.

### Storage

Plugin → host requests, no capability needed (the data is the plugin's own):

- `storage/get {key}` → `{value}`, `null` when the key is not set.
- `storage/set {key, value}` → `{}`; a `null` value deletes the key.
- `storage/keys` → `{keys: [String]}`.

- Keys are 1–128 bytes. Values are any JSON.
- The total encoded size per plugin and project is at most 1 MiB. A `set` that
  would exceed it returns `-32003` "storage full" and writes nothing.
- Persisted as one JSON file per plugin and project at
  `PluginData/<pluginID>/<projectID>.json` under the profile root
  (`Paths.appSupportRoot`), written atomically on every change.
- The data survives disabling, revoking approval and removing the plugin, so a
  reinstall keeps a board. Deleting the folder resets it.

## 3. The Kanban plugin (`plugins/kanban`)

**Manifest:** `api: 3`; capabilities `workspace.read`, `session.focus`,
`tasks.start`; one view tab, `board` / "Board".

**Data:** cards `{id, title, prompt, column, sessionId?, branch?, error?,
seen, order}`, saved as the storage key `board` after every change. `seen`
records that the card's session has appeared in a snapshot at least once.

**Layout:** a horizontal `scroll` with five columns, Backlog, Running, Needs
you, Review and Done, each with a count badge.

- Backlog starts with an add-card form: a title `textField` and a multiline
  prompt `textField`; ⌘Return in the prompt (or an Add button) adds the card.
- A card shows its title, a dim preview of the prompt, and once started the
  branch in monospace and the agent state as a badge.
- Backlog cards have **Start** and **Delete** buttons. Started cards are
  clickable and open their session. Every card has a **Move to** menu.
- A failed start leaves the card in Backlog with a danger-toned "Start failed:
  <reason>" line; Start retries.

**Automatic movement** for cards with a `sessionId` that follow their session:

| Session state | Column |
|---|---|
| `running` | Running |
| `awaiting_input`, `permission_request` | Needs you |
| `idle` | Review |
| not in the snapshot, after it has been seen | Review |
| not in the snapshot, never seen yet | unchanged (still starting) |
| `unknown` | unchanged |

- A card moved by hand to Done or Backlog stops following its session.
- A card moved by hand to Running, Needs you or Review keeps following, so the
  next state change moves it again.

**Out of scope:** drag-and-drop, editing a card after it is created, multiple
boards, and choosing the agent per card.

## 4. Errors and testing

### Failures

New `failed` causes use the existing path (the tab shows "stopped" with
Restart): a malformed `view/render` as listed above, and cross-kind messages
(`alas.present` or `canvas/regions` to a view tab, `view/render` to a canvas
tab). Everything else is an error reply and the plugin keeps running:
`task/start` and storage errors, and unknown keys.

### Swift tests

Extend the existing suites and use WAT fixtures.

- **`PluginManifestTests`:** API 3 accepted; `kind` defaults to canvas; unknown
  `kind` rejected; `kind` with API 2 rejected; `tasks.start` requires API 3.
- **`PluginViewTree` decoder (new, pure):** one parameterised test over the
  violations (duplicate id, unknown kind, missing field, wrong type, too deep,
  too many nodes, string too long) and one test that a valid tree decodes with
  unknown optional fields ignored.
- **`PluginHostTests`:** a valid `view/render` replaces the tab's tree; a
  malformed one stops the plugin; cross-kind messages stop the plugin; a
  `view/event` only reaches ids in the current tree; `task/start` without the
  grant returns `-32001`; a second start in flight returns `-32003`; storage
  get, set, delete and keys round-trip, and the size limit returns `-32003`.
- **`PluginStorage` (new, small):** file round-trip in a temporary folder, and a
  failed size check leaves the file unchanged.
- **`task/start` in `AppState`:** one integration test with a real template git
  repository: the branch is normalised and made unique, a worktree is created,
  and the selected worktree does not change.
- No view tests.

### Rust tests

- **SDK (`alas-plugin`):** typed `View` builders encode to the wire shape;
  `view/event` and `task/failed` decode; `task_start` and the storage helpers
  send the documented requests.
- **Kanban:** pure board reducers: state to column, manual Done and Backlog
  stop following, "seen" gates Review, a failed start returns the card to
  Backlog, add and delete; render tests that the tree has the expected columns
  and card nodes.
- Both new or changed crates in the CI Rust matrix and the workflow contract.

### Docs

`docs/plugins/api-v3.md` (manifest `kind`, `view/render`, node kinds and
limits, `view/event`, `task/start`, `task/failed`, storage) and
`plugins/kanban/README.md`.

### Live check

In an isolated profile (`ALAS_APP_SUPPORT_DIR`, the recipe saved in project
memory): install the plugin, approve it, add a card, start it, and watch the
card move through Running to Review; click it to open the session; restart the
app and see the board restored.

## Risks

- **Fuel on large boards:** a board is re-rendered only on changes, but a
  100-card board is a larger tree than the office's frames were. Measure one
  render of a 200-card board with the fuel probe; the target is under 12.5M.
- **Branch names from free text:** titles can contain anything. The
  normaliser must produce a valid, non-empty ref for any input (fallback:
  `task-<n>`).
- **Worktree sprawl:** each Start creates a worktree. The rate limit stops
  runaway creation; cleaning up finished cards' worktrees is left to the
  existing worktree cleanup.

## Out of scope

Patch-based view updates, custom colours or fonts, images in views, drag and
drop, per-card agent choice, network access, and dashboards beyond what the
node set already allows.
