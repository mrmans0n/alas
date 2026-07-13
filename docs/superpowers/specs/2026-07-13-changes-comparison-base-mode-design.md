# Changes tab: comparison-base mode

## Problem

The Changes tab compares the current worktree's `HEAD` against a base ref to
list "commits ahead" and drive per-file range diffs. Today there are two
behaviors, toggled by a single `Bool` (`changes.trackUpstreamForCommits`):

- **Checkbox OFF** (default): compare against **local `<base>`** — resolution
  prefers `refs/heads/<base>`, only falling back to `origin/<base>` when no
  local ref exists. Fragile across rebases: after rebasing your branch onto a
  moved `origin/main`, a stale local `main` makes other people's merged commits
  appear as "your work."
- **Checkbox ON**: compare against the branch's own upstream `@{u}`
  (`origin/<this-branch>`) once pushed, falling back to `origin/<base>` before
  the branch is pushed. Hides your work once it's pushed — the opposite of
  "always show what this worktree did."

Neither reliably answers "show me the work actually done in this worktree,
regardless of rebases." We want a third behavior that always compares against
the canonical remote base and is stable across rebases, plus a clearer settings
control than a single checkbox.

## Goals

- Add an **Auto** comparison mode that always shows the branch's own work versus
  the canonical remote base, stable across rebases.
- Replace the checkbox with a three-way segmented control: **Auto · Branch
  upstream · Manual**.
- Make **Auto** the new default; migrate existing configs without surprising
  users who explicitly opted into upstream tracking.
- Keep the per-worktree base override (`BaseBranchSelector`) working as the
  natural "Manual" path.

## Non-goals

- Persisting the per-worktree manual base override across app restarts (stays
  in-session, as today).
- Changing the diff computation itself (two-dot vs three-dot / merge-base
  behavior is unchanged).
- Reworking the global `worktrees.baseBranch` setting UX.

## Behavior model

Resolution is a **per-worktree effective mode**:

- If the worktree has a manual base override (the user picked a branch in
  `BaseBranchSelector`, i.e. `userOverrodeBaseBranch == true`) → **Manual**
  against that branch, regardless of the global mode.
- Otherwise → the **global mode** from settings.

The three modes resolve the comparison ref used for `git log <ref>..HEAD`:

| Mode | Resolution | Shows |
|---|---|---|
| **Auto** *(new default)* | `origin/<base>` if it resolves, else local `<base>`. Never consults the branch's own upstream `@{u}`. | The branch's full work vs the canonical remote base; stable across rebases. |
| **Branch upstream** | `@{u}` (`origin/<this-branch>`) if the branch is pushed, else `origin/<base>`. *(= today's checkbox ON)* | Only unpushed commits once the branch is pushed. |
| **Manual** | The configured / per-worktree-selected base, **local-first** (local `<base>`, else `origin/<base>`). *(= today's checkbox OFF)* | Everything since the local base. |

`<base>` is `config.worktrees.baseBranch` (default `main`) for the global modes,
or the branch chosen in `BaseBranchSelector` for a per-worktree override.

Rebase-robustness rationale: after rebasing a pushed branch onto a moved
`origin/main`, comparing two-dot against `origin/main` (Auto) yields exactly the
branch's own commits, whereas comparing against a stale local `main` also lists
the newly-merged upstream commits.

## Config schema and migration

In `AppConfig.Changes` (`Alas/Sources/Persistence/AppConfig.swift`), replace:

```swift
var trackUpstreamForCommits: Bool   // default false
```

with:

```swift
enum ChangesComparisonMode: String, Codable {
    case auto
    case branchUpstream
    case manual
}

var comparisonMode: ChangesComparisonMode   // default .auto
```

The custom `Codable` conformance for `Changes` (decoder around
AppConfig.swift:661) migrates:

1. If the new `comparisonMode` key is present → use it.
2. Else if the legacy `trackUpstreamForCommits` key is present:
   - `true`  → `.branchUpstream`
   - `false` → `.auto`
3. Else (neither key) → `.auto`.

Effect: users who never touched the setting, or explicitly had it OFF, silently
upgrade to Auto; users who opted into upstream tracking keep it. Update the
default factory (AppConfig.swift:433) and both decoder branches (661, 683) to
the enum.

## Git resolution

Replace the boolean parameter on `commitsAhead` with an explicit strategy enum
so the three base flavors are first-class rather than encoded in a `Bool`.

In `Alas/Sources/Git/GitService.swift`:

```swift
enum BaseResolution {
    case upstreamThenBase   // existing ignoreUpstream: false path
    case baseOriginFirst    // NEW: skip @{u}, resolve origin/<base> first
    case baseLocalFirst     // existing ignoreUpstream: true path (local-first)
}

func commitsAhead(
    at worktree: URL,
    baseBranch: String? = nil,
    resolution: BaseResolution
) async throws -> (commits: [CommitInfo], comparisonRef: String?)
```

`commitsAhead` internals map to today's cascade (GitService.swift:1191):

- `.upstreamThenBase`: Step 1 resolves `@{u}`; Step 2 base fallback unchanged.
- `.baseLocalFirst`: skip Step 1; Step 2 resolves local `<base>` first, then
  `origin/<base>` (today's `ignoreUpstream: true` behavior).
- `.baseOriginFirst` **(new)**: skip Step 1; Step 2 resolves `origin/<base>`
  first (via the existing `refs/remotes/origin/<base>` probe used by
  `resolveEffectiveBaseBranch`), falling back to local `<base>`.

The resolved `comparisonRef` is stored on `RightPaneState` and already drives
per-file `rangeDiff` and the review-loop base, so diffs follow automatically.
The separate review-loop base call (RightPaneState.swift:564, currently
`ignoreUpstream: true`) mirrors the mode's base flavor — `.baseOriginFirst` for
Auto, `.baseLocalFirst` for Manual, and `.baseOriginFirst` for Branch upstream
(so the review base is a stable remote base, never the branch's own upstream).

## Deriving `BaseResolution` per worktree

Central mapping (used at each call site that currently derives `ignoreUpstream`):

```
effectiveMode = userOverrodeBaseBranch ? .manual : config.changes.comparisonMode

BaseResolution:
  .manual         -> .baseLocalFirst
  .auto           -> .baseOriginFirst
  .branchUpstream -> .upstreamThenBase
```

This replaces `let ignoreUpstream = userOverrodeBaseBranch || !trackUpstreamForCommits`
at RightPaneState.swift:553 and the equivalent derivations elsewhere.

## UI

In `Alas/Sources/Settings/ChangesPane.swift`, replace the `AlasToggle` row
(currently inside the "Commits section" group) with a segmented `Picker`
(`.pickerStyle(.segmented)`, matching `ReviewScopePicker` /
`RemoteServerPane`), bound to `state.bind(\.changes.comparisonMode)`:

- Segments: **Auto · Branch upstream · Manual**.
- Group title: "Comparison base".
- A description line below the control updates per selection, explaining what
  each mode compares against (mirrors the table above in plain language).

## Call-site threading

Thread `comparisonMode` (deriving `BaseResolution` via the mapping above)
through every site that currently touches `trackUpstreamForCommits`:

- `Alas/Sources/Persistence/AppConfig.swift` — schema, default, `Codable`
  (schema :312, keys :319, default :433, decode :661/671/683).
- `Alas/Sources/Right/RightPaneState.swift` — mirror property (:175), the
  `ignoreUpstream` derivation (:553), both `commitsAhead` calls (:559, :564).
- `Alas/Sources/Right/RightPaneStore.swift` — `state(for:...)` signature and
  the change-detection / assignment sites (:64, :69, :121, :137).
- `Alas/Sources/Right/RightPaneView.swift` — `.task(id:)` key (:188) and the
  `state(for:...)` call (:195).
- `Alas/Sources/Center/CenterPaneView.swift` — `.task(id:)` key (:306) and the
  `state(for:...)` call (:314).
- `Alas/Sources/App/AppState.swift` — two `state(for:...)` calls (:3211,
  :3575) and the direct `commitsAhead` call (:4408).
- `Alas/Sources/Center/Commit/CommitEditorTabView.swift` — the direct
  `ignoreUpstream` derivation (:375).

The per-worktree override (`userOverrodeBaseBranch`, set by
`RightPaneState.selectBaseBranch(_:)`) forces `.baseLocalFirst` regardless of
global mode. Its lifetime is unchanged (in-session).

## Testing (Swift Testing)

- **Config migration**: decode legacy configs with `trackUpstreamForCommits`
  `true` → `.branchUpstream`, `false` → `.auto`, and absent → `.auto`; decode a
  config with an explicit `comparisonMode` and confirm it wins.
- **`BaseResolution` ref resolution** against a fixture repo:
  - `.baseOriginFirst` picks `origin/<base>` when present, local `<base>`
    otherwise.
  - `.baseLocalFirst` picks local `<base>` first.
  - `.upstreamThenBase` picks `@{u}` when the branch is pushed, else the base.
  - Rebase scenario: a pushed branch rebased onto a moved `origin/main` lists
    only its own commits under `.baseOriginFirst`.
- **Per-worktree override** forces Manual (`.baseLocalFirst`) even when the
  global mode is Auto or Branch upstream.

## Rollout / compatibility

Purely local config + git-resolution change; no schema versioning bump beyond
the additive migration. Old builds reading a config written by a new build will
ignore the unknown `comparisonMode` key and fall back to their own
`trackUpstreamForCommits` default — acceptable for a personal-tool config.
