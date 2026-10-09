# Run activity pill and hidden runs

## Goal

Show what a run script is doing without opening its terminal, and let a run
start without a visible console tab. You only need the console when something
breaks or when you ask for it.

Two parts:

1. An activity pill next to the ▶ button in the tab bar, in the style of
   Xcode's activity view (mockup option B).
2. Hidden runs. A `# alas-console: hidden` header sets a script's default, and
   holding ⌥ runs it the other way once (mockup option C).

## Decisions

- **Indicator:** a pill to the right of ▶. It exists only while a run in the
  selected worktree is starting or running, has just succeeded, or failed and
  hasn't been dismissed. Clicking the pill opens a popover with the run list.
- **Hidden mode default:** `# alas-console: hidden | shown` in the script
  header. A missing or unknown value means `shown`, which is today's behavior.
- **One-off flip:** holding ⌥ in the ▶ menu swaps each script item to its
  alternate ("Run X in Background" or "Run X with Console"). ⌥↩ does the same
  in the ⌘R palette.
- **Applies to every launch path:** menu, palette, Run tab Start/Rerun, and
  scheduled runs all honor the header default. Only the menu and the palette
  offer the ⌥ flip.
- **Reveal is one-way:** "Output" un-hides the run's tab and focuses it. From
  then on it is an ordinary run tab.
- **Failure doesn't steal focus:** a failed hidden run turns the pill red until
  dismissed, and fires the existing failure banner, Attention entry, and
  notification. The console does not open on its own.
- **Not persisted:** the hidden flag lives in memory only. A run tab restored
  after relaunch comes back visible, as it does today.

## Hidden run tabs

A hidden run still opens a terminal session. Capture, completion monitoring,
stop and restart depend on that session. `SessionRegistry` owns the session
whether or not a view mounts it (`TerminalSession.swift`,
`SessionRegistry.swift`), so an unmounted, hidden tab keeps running exactly
like an inactive tab does today.

Only the tab is hidden:

- `TerminalTabState.isHidden: Bool`, default `false`. It is not in
  `CodingKeys`, so it is never encoded and decodes as `false`.
- `TabsManager.appendTerminal(…, isHidden:)` appends without activating when
  hidden (`append(_:to:activate:)` already takes `activate`).
- `TabsManager.reveal(tabId:worktreeId:)` clears the flag and activates the tab.
- `CenterTabComposition` filters out hidden tabs in both initializers. The
  strip, ⌘1–9, previous/next, close-other/left/right plans, and the empty
  center state all read the composition, so this one filter covers them.
- When the active tab closes, `TabsManager` picks the nearest neighbor that is
  not hidden. Without this, the composition would fall back to the first tab
  instead of the neighbor.
- Closing a hidden tab does not add a `ClosedTabEntry`. Reopening a run tab
  already drops its run markers, so ⌘⇧T would bring back a bare shell for a
  console the user never saw.
- The full-list close wrappers in `AppState` (close-others/all/left/right)
  skip hidden tabs. "Close All Tabs" must not kill a background dev server.
- Unchanged: sidebar harness badges, Attention session lookup, Terminate All
  and worktree cleanup counts. They still see hidden sessions, which is
  correct because those processes are real.

### Launch flow

`RunScript` gains `console: RunScriptConsole` (`.shown`, `.hidden`), parsed by
`RunScriptMetadata` from `alas-console`.

`launchScript`, `startScriptLaunch`, `restartScript` and `runOrFocusScript`
take `console: RunScriptConsole?`. `nil` means use `script.console`. The value
goes through `openTerminalTabPreparingRemoteZmxIfNeeded` and `openTerminalTab`
to `appendTerminal(isHidden:)`.

`runOrFocusScript` today focuses any run tab whose shell is alive. With
hidden runs:

| Existing run tab | Record | Run does |
|---|---|---|
| none | any | launch with the resolved console |
| visible | any | focus it (today's behavior) |
| hidden | active | reveal and focus it (an explicit click on a running script means "show me") |
| hidden | finished (`alas-on-exit: keep` shell idle) | restart with the resolved console, replacing the hidden tab |

`focusScriptTerminal`, used by the Run tab's "Terminal" action, reveals before
activating.

`alas-on-exit: close` behaves as today: the shell exits with the command, the
tab is removed, and only the run report is left. The pill offers "Report" for
those runs.

## Activity pill

### Presentation (pure)

`RunActivityPresentation` lives in `Alas/Sources/RunScripts/`. Its input is
the selected worktree's `RunRecord`s, the undismissed `RunScriptFailure`s for
that worktree, and `now`. Its output is one of:

- `hidden`: nothing to show.
- `starting(name)`
- `running(name, startedAt, canStop)`: exactly one active run.
- `runningMany(count)`
- `succeeded(name, duration)`: the newest finished record is `.succeeded`,
  finished within the last 4 s, and no run is active.
- `failed(name, exitCode)`: the newest undismissed failure, when no run is
  active.

Precedence: active runs, then an undismissed failure, then a recent success.
When runs are active and a failure is also undismissed, the pill shows the
active state with a red leading dot (`hasUndismissedFailure`).
`.stopped` and `.unknown` outcomes produce no pill.

The popover rows come from the same input: active runs first (newest start
first), then undismissed failures (newest first). Each row lists its actions:

- Active: Output (only when the run tab is live), Restart, Stop.
- Failed: Report, Rerun.

### View

`RunActivityPill` lives in `Alas/Sources/Center/`. It sits in
`TabBarView.trailingControls` right after `RunScriptMenu`.

- The pill body is a button that opens a SwiftUI popover with the rows above.
- In the single-run state, a trailing ■ button stops the run directly.
- In the failed state, a trailing × calls `dismissRunScriptFailure`. That is the
  same dismissal the banner uses, so the pill and the banner never disagree.
  Opening the report does not dismiss either one; `openRunReport` only
  acknowledges the Attention entry, and that stays as it is.
- Elapsed time comes from `TimelineView(.periodic(from:by: 1))`, only while
  the pill is in a running state.
- The success fade is a 4 s timer that drops the pill to `hidden`. The
  presentation decides visibility from `now`; the view schedules one refresh
  for the 4 s cutoff.
- The script name truncates first. The pill caps at 160 pt.
- Spinner, dot and colors use the existing theme tokens (`accent`, `fg-muted`,
  and the error/success tokens used by `InAppNotificationBanner`).

`CenterPaneView` passes `state.runRecords.records(worktreeID:)`,
`state.runScriptFailures(in:)` and the action closures into `TabBarView`, next
to the existing run-menu closures.

### ▶ menu changes

- Each script item gets `.modifierKeyAlternate(.option)` with the flipped
  console label. macOS 15 is the deployment target, so the API is available.
- The `circle.fill` running marker and "Restart X" stay.

### ⌘R palette

`RunScriptDialog.handleKey`: Return with `.option` and without `.command`
activates the selection with the flipped console. ⌘↩ (restart) is unchanged.
The palette has no hint row today. The selected row gets a trailing hint with
the flipped action ("⌥↩ in background" or "⌥↩ with console"), always visible,
since `onKeyPress` can't observe ⌥ being held on its own.

## Writing help

Add `# alas-console: hidden` to the header reference in
`RunScriptWritingHelp` with one line: "Use hidden for scripts you don't need
to watch, such as dev servers; ⌥ runs them with a console once." Templates and
the stack catalog stay unchanged; no script becomes hidden unless someone
opts in.

## Out of scope

- A run indicator for worktrees other than the selected one.
- Detecting a hidden run that waits on stdin.
- Persisting the hidden flag across relaunch.
- ⌥-click in the Run tab.

## Testing

Only behavior that could break without anyone noticing, per the AGENTS testing
policy:

- `RunScriptMetadataTests`: one parameterized test over `alas-console` values
  (`hidden`, `shown`, unknown → `shown`, missing → `shown`).
- `RunActivityPresentation`: one parameterized test over precedence (active
  over failure over success, the red dot when both, stopped/unknown → hidden)
  and one for the 4 s success cutoff at the boundary.
- `CenterTabComposition` / `TabsManager` (extend the existing suites):
  - hidden tabs are excluded from the composition;
  - closing the active tab never selects a hidden neighbor;
  - reveal makes the tab visible and active;
  - an encode/decode round trip drops the hidden flag.
- `AppState` run tests (extend `AppStateRunRecordTests` or the existing run
  launch suite with the fake `terminalSessionOpener`):
  - a hidden launch leaves the active tab unchanged;
  - Run on a hidden tab whose record is finished relaunches instead of
    revealing.

The pill view, popover layout and menu alternates get a manual smoke run in
the app, not tests.
