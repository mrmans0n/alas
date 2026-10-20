# What's new card — design

## Intent

Some Alas releases ship something worth showing off (symbols in the chat
composer, plugins, …). Today those land silently: users only see them if they
read the changelog. After an update, Alas should be able to put a small,
hand-picked highlight in front of the user — similar to Cursor's post-update
card — but only when the maintainer decided the release earned one. Many
releases, especially patches, show nothing.

This is curation, not a changelog. The changelog already exists and stays the
complete record.

## Goals

- On the first launch after updating to a stable release that has an entry,
  show a corner card with one headline feature and up to two secondary ones.
- Make picking what goes in a quick step of the existing release process,
  driven from the changelog that was just curated.
- Ship the entry inside the app so it works offline and its "try it" action
  always matches the shipped code.

## Non-goals

- Not a changelog viewer. The full notes stay in `CHANGELOG.md`, the GitHub
  release, and the existing update sheet.
- No editing of shipped entries after release (that would need a remote
  fetch; not worth losing offline first-launch).
- No nightly-build support. Nightlies never show the card.
- No onboarding / first-install tour. Fresh installs never show the card.
- No Remote web client or `alas-host` surface.

## Anti-goals (failure even if it works)

- Showing a card for a release without a curated entry, or auto-generating
  one from commits.
- Stealing focus, dimming the window, or interrupting typing in a terminal or
  chat.
- Auto-hiding on a timer, so it vanishes while the user is mid-task.
- Showing the same card again after the user dismissed or acted on it.
- Stacking several cards after a multi-version jump.

## User experience (decided)

Corner card, bottom-right of the main window, floating over the workspace.
Non-modal, does not take keyboard focus, no backdrop.

Layout ("hero + and more"):

```
┌──────────────────────────────────┐
│ ✨ New in 0.22                 ✕ │
│ ┌──────────────────────────────┐ │
│ │      media (GIF / image)     │ │   ← optional
│ └──────────────────────────────┘ │
│ Plugins                          │   ← headline title
│ Extend Alas with your own panes  │   ← one line of copy
│ and commands.                    │
│ ──────────────────────────────── │
│ Also: @ symbols in composer ·    │   ← 0–2 short secondary titles
│       faster worktrees           │
│ [Try plugins]   Release notes    │
└──────────────────────────────────┘
```

- **Primary button** runs the headline's action (see Actions). Omitted when
  the headline has no action.
- **Release notes** opens the GitHub release page for that version.
- **✕** dismisses.
- Any of the three marks the entry as seen. The card stays until one of them
  happens; it does not time out.
- Without media, the card is text only (no placeholder box).
- The header ("New in X.Y") and the Release notes link use the **entry's**
  version, not the running one, so 0.22.1 showing 0.22.0's entry reads
  "New in 0.22" and links to the 0.22.0 release. *(my call)*
- **Help → What's New…** reopens the most recent shipped entry at any time.
  Hidden/disabled when the running build has no entry at or below its version.

## When it shows (decided, with my calls marked)

- Stable track only (`BuildIdentity.track == .stable`).
- Alas stores the last version the user has "seen" in profile user defaults.
- **First launch ever** (no stored version): store the current version, show
  nothing. *(my call)*
- **Existing users on the first release that ships this feature** have no
  stored version either. Treat an install as existing, not fresh, when the
  update controller's defaults (`io.nlopez.alas.updates.lastCheckedAt`) are
  already present, and run the normal update rule with an implicit stored
  version just below current, so they see the current version's entry.
  *(my call)*
- **Nightly builds** neither read nor write the seen-version key, so a detour
  through nightly doesn't swallow the next stable card. *(my call)*
- **Launch after an update** (stored < current): find the newest bundled entry
  whose version is in `(stored, current]`. If there is one, show it; either
  way, advance the stored version to current once the card is dealt with, or
  immediately if there is no card. *(my call: newest in range rather than
  exactly-current, so 0.21 → 0.22.1 still shows 0.22.0's entry when 0.22.1
  has none.)*
- Downgrade or same version: show nothing.
- If the app quits while the card is open and unanswered, show it again next
  launch. *(my call)*
- Show it once the main window is up and the workspace has loaded, not over a
  launch-time sheet such as the update sheet or a migration prompt. *(my call;
  exact sequencing left to the builder.)*

## Entry format (decided)

One JSON file per version, in the repo and bundled into the app:

```
WhatsNew/
  0.22.0.json
  media/
    0.22.0-plugins.gif
```

```json
{
  "version": "0.22.0",
  "headline": {
    "title": "Plugins",
    "body": "Extend Alas with your own panes and commands.",
    "media": "media/0.22.0-plugins.gif",
    "action": "openPluginSettings",
    "actionLabel": "Try plugins"
  },
  "also": [
    { "title": "@ symbols in composer" },
    { "title": "Faster worktrees" }
  ]
}
```

- `media`, `action`, `actionLabel`, `also` are optional. `also` holds at most
  two items.
- Copy is short marketing tone, not the changelog sentence. The headline
  `body` is one sentence.
- `version` must equal the filename stem.

Placement of the folder in the repo, and how it is copied into the bundle, are
left to the builder (via `project.yml` resources; regenerate with
`xcodegen`).

## Actions (decided: fixed list)

Entries cannot contain arbitrary URLs or commands. `action` must be one of a
fixed set of identifiers the app implements, for example
`openPluginSettings`, `focusComposer`, `openSettings:<pane>`. The initial set
is whatever the first real entry needs; adding one is a small app change made
alongside the feature it showcases. The list of valid identifiers is
documented in `RELEASING.md`.

## Validation (decided: hard fail before publish)

A release must not publish with a broken entry. Fail the release when any
bundled entry:

- does not parse, or its `version` does not match its filename,
- references a `media` file that does not exist,
- uses an `action` the app does not know,
- has more than two `also` items.

The check must run before signing/notarizing work is wasted, or at least before
the GitHub release is published, mirroring the existing "no CHANGELOG section"
hard-fail. Whether this is a script in `release.yml`, a check in the regular
CI build, or a core test that loads every bundled entry, is left to the
builder; the action-ID list must come from the app's own source of truth, not
a second hand-maintained copy.

## Release process (decided)

Picking happens at release time, from the curated changelog. New step in
`RELEASING.md`, between promoting the changelog and bumping the version:

1. List the `✨ Features` bullets of the new version's `CHANGELOG.md` section.
2. The maintainer picks one headline and 0–2 "also" items, or "none".
3. Write `WhatsNew/<version>.json` with rewritten short copy; add media if
   the maintainer recorded any.
4. Maintainer approves; the file goes into the same release commit.
   "None" means no file.

`RELEASING.md` also gains a "What's new entries" section: file format, media
location, the valid action identifiers, and the validation rule.

The maintainer runs releases through a skill on an external bot (Hermes).
That skill is updated by the maintainer afterwards, using the new
`RELEASING.md` as its reference. Deliverable here: the doc change, plus a
short drafted skill-step text the maintainer can paste in.

## First entry (decided)

The release that ships this feature also ships its first real entry, so the
whole path (bundling, media rendering, the primary action, release
validation) is exercised end to end from day one. The headline is picked at
that release through the normal step above. The implementation must ship at
least one working action; *(my call)* start with `openPluginSettings`, since
plugins are a likely headline, and add whatever the picked headline needs if
it differs.

## Constraints

- Entry decoding and the "which entry to show" decision are UI-free and belong
  in `Packages/AlasCore` (likely next to `Updates/`), public, tested with Swift
  Testing. The card view lives in the app.
- Tests per `AGENTS.md` policy: pin the show/no-show decision (fresh install,
  update with/without entry, multi-version jump, downgrade, nightly) and entry
  validation. No view-composition tests.
- Media must stay small; bundle size grows with every entry. *(my call: keep
  GIFs under ~2 MB; builder may prune media of entries older than the last few
  minors, since only the newest entry in range ever shows.)*
- English UI strings.

## Left to the builder

- Card styling, animation, exact sizing, and how it floats over the window.
- How media is rendered (animated GIF vs. MP4/HEVC loop) as long as it
  autoplays silently and loops.
- Where the seen-version key lives in defaults and its name.
- Validation mechanism (see above).
- Exact Help menu wiring.
