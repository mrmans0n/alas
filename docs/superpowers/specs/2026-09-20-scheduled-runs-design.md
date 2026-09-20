# Scheduled Runs Design

Issue: #1162 "Add scheduled run scripts and agent launches".

## Goal

Let a user tell Alas *when* a run script should start, optionally in a
freshly created worktree with an agent launched on it, without adding a
second execution path. A scheduled run is a manual run whose start button was
pressed by a timer.

## Scope

- Interval and time-of-day schedules for run scripts.
- Targets: a specific worktree, a project's main worktree, or every project's
  main worktree.
- Missed-run policy per schedule (`skip` or `runLatest`); sleep and
  app-not-running gaps are recorded and shown, never replayed as a burst.
- Optional composition: create a worktree (running the worktree-create
  script), run the script there, then launch an agent in a terminal on it.
- A Settings pane listing schedules with target, host, last outcome, next
  fire time, enable/disable, run now, edit, delete, plus per-project and
  global pause.
- Persistence across relaunch.

Out of scope: external triggers, natural-language entry, ACP chat sessions as
the launched surface, running while the app is quit, a generic cron daemon.

## Decisions

| Concern | Decision |
| --- | --- |
| Storage | JSON at `Paths.runSchedulesFile` (`run-schedules.json`) via `PersistenceStoreProtocol`, same as projects/spaces |
| Tick | One `Timer` at 30 s while the app runs; `NSWorkspace.didWakeNotification` forces an immediate evaluation |
| Firing decision | Pure `RunSchedulePlanner` over `(schedule, state, now)`; at most one run per schedule per evaluation |
| Interval anchor | `lastFiredAt ?? createdAt`; first fire is one interval after creation |
| Time of day | Local calendar, optional weekday set; next occurrence strictly after the reference date |
| Catch-up grace | A due occurrence older than 120 s counts as missed; within grace it fires normally |
| Execution | The existing `launchScript` path with a per-run settlement callback; composition uses `createWorktreeAndWait` + `launchWorktreeSurface(.terminal(agentId))` |
| Attribution | The run record, history entry, notifications and failure queue all name the worktree the script ran in; composed runs name the new worktree |
| Host | Comes from the target project's `host`; the run record's `RunExecutionTarget` already carries it |

## Model (`Alas/Sources/Schedules/RunSchedule.swift`)

```swift
enum RunScheduleTarget: Codable, Equatable {
    case allProjects                 // main worktree of every project
    case project(id: String)         // that project's main worktree
    case worktree(projectId: String, worktreeId: String)
}

enum RunScheduleTrigger: Codable, Equatable {
    case interval(seconds: TimeInterval)              // >= 60
    case timeOfDay(hour: Int, minute: Int, weekdays: Set<Int>)  // 1 = Sunday … 7 = Saturday
}

enum RunScheduleMissedRunPolicy: String, Codable { case skip, runLatest }

struct RunScheduleComposition: Codable, Equatable {
    var branchTemplate: String   // {name}, {date}, {time}
    var agentId: String?         // nil = project/repo/global default agent
}

struct RunSchedule: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var target: RunScheduleTarget
    var scriptKey: String?       // nil only when composition is set
    var trigger: RunScheduleTrigger
    var missedRunPolicy: RunScheduleMissedRunPolicy
    var composition: RunScheduleComposition?
    var isEnabled: Bool
    let createdAt: Date
}

enum RunScheduleOutcome: Codable, Equatable {
    case succeeded
    case failed(exitCode: Int32)
    case stopped
    case unknown
    case skipped(reason: String)     // already running, worktree missing, script missing
    case launchFailed(String)        // worktree creation or agent launch failed
}

struct RunScheduleState: Codable, Equatable {
    var lastFiredAt: Date?
    var nextFireAt: Date?
    var lastOutcome: RunScheduleOutcome?
    var lastOutcomeAt: Date?
    var lastMissed: RunScheduleMissedOccurrences?   // count + when + policy applied
}

struct RunScheduleGap: Codable, Equatable {
    enum Reason: String, Codable { case asleep, appNotRunning }
    let start: Date; let end: Date; let reason: Reason
}

struct RunSchedulesFile: Codable, Equatable {
    var version = 1
    var schedules: [RunSchedule]
    var states: [String: RunScheduleState]
    var pausedProjectIDs: Set<String>
    var isPausedGlobally: Bool
    var lastEvaluatedAt: Date?
}
```

## Planner (`RunSchedulePlanner.swift`, pure)

- `nextFireDate(for trigger, after: Date, anchor: Date, calendar:) -> Date`
- `decide(schedule, state, now, grace) -> Decision` where
  `Decision = .wait(next) | .fire(next, missed: Int) | .skip(next, missed: Int)`.
  - Not due → `.wait`.
  - Due within grace → `.fire(missed: 0)`.
  - Due and older than grace → count occurrences in `(nextFireAt, now]`;
    `runLatest` → `.fire(missed: n - 1)`; `skip` → `.skip(missed: n)`.
  - `next` is always the first occurrence strictly after `now`, so a burst is
    impossible by construction.
- `renderBranch(template:, name:, now:)` for composition branch names, slugged
  to a valid ref segment.

## Scheduler (`RunScheduler.swift`, `@MainActor @Observable`)

Owns the file, the timer, and the wake observer. Injected: store, file URL,
`now: () -> Date`, calendar, tick interval, sleep threshold, and a
`runner: (RunSchedule) async -> RunScheduleOutcome` set by AppState.

- `load()` on init; `start()` / `stop()` for the timer + observer.
- `evaluate(now:)`:
  1. If `lastEvaluatedAt` is older than `sleepThreshold` (2 × tick + 30 s),
     record `lastGap` (`.asleep` while running, `.appNotRunning` for the first
     evaluation after launch) so the UI can say so.
  2. For each enabled, unpaused schedule apply the planner; persist
     `nextFireAt` / `lastFiredAt` / `lastMissed` before dispatch.
  3. Dispatch one runner task per fired schedule; a schedule with a task
     still in flight is skipped with reason "previous run still in progress".
  4. On completion store `lastOutcome` / `lastOutcomeAt` and persist.
- CRUD: `add`, `update`, `remove`, `setEnabled`, `setProjectPaused`,
  `setPausedGlobally`, `runNow(id)` (bypasses trigger and pause, still one at
  a time). Every mutation persists and recomputes `nextFireAt`.

## Execution (`AppState+RunSchedules.swift`)

`runSchedule(_:) async -> RunScheduleOutcome`:

1. Resolve targets to `[(ProjectConfig, Worktree)]`. Missing project or
   worktree → `.skipped("…no longer exists")`.
2. Per target, if composition is set: branch from template, base from
   `NewWorktreeDialog.preferredBaseBranch`, destination from the path template,
   then `createWorktreeAndWait(runStartup: true)` (delegated, so the user's
   selection is untouched; the worktree-create script runs as today).
   Failure → `.launchFailed(message)`.
3. If `scriptKey` is set: discover scripts for the run worktree through
   `RunScriptStore.discoverScripts(worktreeRoot:remoteHost:)`, look the key
   up, and start it through the existing launch path
   (`startScriptLaunch` returning `.started(runID)` / `.alreadyRunning` /
   `.refused(message)`). Wait for settlement through a per-run handler
   invoked from `archiveFinalizedRun` and from the launch-failure rollback.
   The monitor already posts the system notification, in-app toast, failure
   queue entry, attention event and durable history entry.
4. If composition is set and the script (if any) succeeded, resolve the agent
   (`composition.agentId ?? defaultAgentID(projectId:worktreeRoot:)`) and call
   `launchWorktreeSurface(.terminal(agentId), worktree:, project:)`. Failure
   → `markWorktreeLaunchFailed` (so the sidebar offers retry) and
   `.launchFailed(message)`.
5. Composition-level failures post an in-app error toast on the affected
   worktree and a system notification through `notifyAlas`.
6. Fan-out targets combine outcomes: any failure/launch failure wins over
   skipped, which wins over succeeded.

`launchScript` refactor: split into `startScriptLaunch(_:in:) -> RunScriptLaunchStart`
(no UI) and the existing `launchScript` wrapper that shows the error. Nothing
else about the launch path changes.

## UI

- `SettingsSection.schedules` ("Schedules", icon `clock`) → `SchedulesPane`.
  - Header text: "Schedules only fire while Alas is running. Nothing runs
    while the app is quit."
  - Gap banner when `lastGap` is set: "Alas was asleep / not running from X
    to Y."
  - Global pause toggle. Per-project pause toggles for projects that own
    schedules.
  - One row per schedule: name, target label, host label ("This Mac" or the
    SSH host), trigger summary, last outcome + relative time, next fire
    time, enable toggle, Run Now, Edit, Delete (confirmation).
  - "New Schedule" opens `RunScheduleEditorView` as a sheet.
- `RunScheduleEditorView`: name, project picker, target segment (main
  worktree / specific worktree / all projects), script picker from the target
  worktree's discovered scripts (async; remote goes through SSH discovery),
  trigger segment with interval (value + unit) or time (hour, minute,
  weekday checkboxes), missed-run policy, composition toggle with branch
  template and agent picker. Save is disabled until valid.
- Projects menu gains "Schedules…" opening that settings section.
- `RunSchedulePresentation` holds the pure label formatting so the tests can
  cover it without SwiftUI.

## Error handling

| Condition | Behavior |
| --- | --- |
| Target worktree/project gone | `.skipped`, schedule stays enabled, row shows the reason |
| Script not found in target | `.skipped("Script … not found")` |
| Script already running there | `.skipped("… is already running")`, no second launch |
| Launch refused (shell, remote global script) | `.launchFailed(message)`, no alert popup |
| Script exits non-zero | `.failed(exitCode)`; agent is not launched |
| Worktree create fails | `.launchFailed`, sidebar keeps the failed row for retry |
| Agent unavailable | `.launchFailed`, worktree keeps `launchFailed` state for retry |
| Store write fails | Reported through the persistence error handler; in-memory state continues |
| App quit | Timer stops; in-flight runs are settled by the existing termination flush |

## Verification

Swift Testing suites:

- `RunSchedulePlannerTests`: interval anchoring, time-of-day across day and
  week boundaries with weekday filters, DST-safe calendar math, grace,
  `skip` vs `runLatest` counts, never more than one fire, branch rendering.
- `RunSchedulerTests`: file round-trip through a memory store, enable /
  pause / global pause gating, relaunch with missed occurrences follows the
  policy and records an `appNotRunning` gap, sleep gap detection, in-flight
  run is not doubled, `runNow` ignores pause.
- `AppStateRunScheduleTests`: local and SSH targets produce run records with
  the right host, exit code propagates to `lastOutcome`, missing script and
  already-running are skipped, composition creates a worktree in a temp git
  repo, runs the script there and launches the agent terminal attributed to
  the new worktree, agent-unavailable leaves `launchFailed`.
- `SettingsSectionTests`: the new section sorts with the others.
- `RunSchedulePresentationTests`: labels for targets, triggers, outcomes.

Local checks: the suites above plus a `-quiet build`.
