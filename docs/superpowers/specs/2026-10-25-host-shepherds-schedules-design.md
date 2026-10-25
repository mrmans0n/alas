# PR shepherd, stack shepherd and run schedules on a headless host — design

## Intent

A Mac mini running the headless `alas-host` is meant to be the always-on machine: agents keep working there while the laptop sleeps. Two app features that matter most for that are dead on the host today:

- **The PR and stack shepherds** watch a worktree's PR (CI, reviews, merge state), queue fix prompts to its agent, auto-merge, and archive after merge.
- **Run schedules** fire scripts or agent prompts on a timer.

On the host:
- `pr_create`, `pr_status` and `stack_ship` fail with "The Alas PR shepherd is not running yet", although `docs/headless-host.md` says host agents can create PRs.
- Schedules saved in the profile never fire while `alas-host` holds it.

The user also wants to see shepherd state for a host worktree on the paired Mac, the way the app shows it for a local one ("should be part of it").

## Current state (from recon, origin/main 866e26a7f)

- **All three engines are core types already built at boot** (`AlasCoreContext.swift:195-197`). They do nothing because their effects or runner are never installed and `start()` is never called. Only the app wires them:
  - `Alas/Sources/App/AppState+Shepherd.swift` (PR shepherd `Effects`);
  - `AppState+StackShepherd.swift` (stack shepherd `Effects`);
  - `AppState+RunSchedules.swift` (`runScheduler.runner`).
- **Effects the app supplies.** Mostly plain logic over core types:
  - `worktreeContext`, `sessionState`, `deliverPrompt` (hydrate, reattach, backfill, `enqueueDelegatedPrompt`) and `rules` (`ShepherdRulesResolver`);
  - stack `loadStack`;
  - archive-after-merge.
- **UI-bound pieces:**
  - the base branch read from the right pane (with a config fallback);
  - `refreshPaneIfCached`;
  - in-app banners;
  - the unsaved-tabs check before archiving;
  - stack sync and rebase going through `RightPaneState`. The real work is core's `GGMutationCoordinator`.
- **The scheduler's runner** resolves the target, creates the worktree (core already has `withFreeName` and `createWorktree`), and then either:
  - runs a script through the app's tabs (core has `startRun(_:in:onSettled:)`);
  - launches an ACP agent through `launchWorktreeSurface` (core has `SessionsAPI.create` and `send`);
  - or types into a terminal agent, which is app-only.
- **Turn completion.** `turnCompleted` for both shepherds and `ScheduledAgentTurns` is fed from the app's `onTurnCompleted`. The headless `sessionManagerFactory` sets none.
- **Persistence.** State lives under the profile: `Paths.reviewShepherdsFile`, `stackShepherdsFile`, `runSchedulesFile`. It is loaded at init and saved on change. The app and host never run at once (`DataDirectoryLock`), so they hand off.
- **Notifications.** Core's `NotificationService` default adder calls `UNUserNotificationCenter`, which fails in a bundle-less binary. On a headless host, `notify` already relays to Macs as `HostEvent.notice` (#2199).
- **What the peer sees today.** No shepherd state at all: `HostEvent` has no shepherd case, and `WorktreeSnapshot` carries no review state. The host already serves per-worktree *review status* to followers (`followReviewStatus`, `AlasHost+Events.swift:384`). The builder checks what that carries and whether the peer view shows it.
- **The local UI.** The shepherd control is `ACPShepherdButton` (pill state) in the session toolbar. Ship is gated by `offersShip`.

## Goals

1. **The shepherds run on the host.**
   - `alas-host` installs default PR and stack shepherd effects from core and starts both shepherds after projects load. It stops them on shutdown.
   - Host agents' `pr_create`, `pr_status` and `stack_ship` work.
   - Watched PRs get the same polling, fix prompts, auto-merge and archive-after-merge as in the app, following the project's shepherd rules.
   - Stack sync and rebase go straight to core's `GGMutationCoordinator`.
   - Archive-after-merge refuses unsaved edits, as core archive already does.
2. **Schedules fire on the host.**
   - `alas-host` installs a default schedule runner from core and starts the scheduler.
   - A schedule creates its worktree when configured to, then either runs its script through core runs (so it gets a run console on the host, as in #2195) or starts an ACP agent session and sends the prompt.
   - Scheduled agent turns are tracked through the headless session manager's turn completion.
   - A schedule that targets a terminal agent fails with a clear reason, recorded where the app records schedule failures. It must not silently never fire.
3. **Turn completion is wired on the host.** The headless session-manager factory feeds `onTurnCompleted` to both shepherds and the scheduler.
4. **Alerts reach the paired Mac.**
   - Shepherd, schedule and run notifications on a headless host relay to Macs: PR ready, merged or closed, escalations, schedule failures, and script outcomes. The exact rule is in the decisions below.
   - The Mac shows them as banners, and clicking one opens that peer session where there is one.
   - The host never calls `UNUserNotificationCenter`.
   - Attention history keeps recording on the host as today.
5. **The peer view shows shepherd state.**
   - For a host worktree, the paired Mac shows the same shepherd/PR state the app shows for a local one: the shepherd pill state, PR status, and whether a shepherd is watching.
   - It updates live as the host's shepherd moves.
   - It uses whatever the host already serves for review status, plus a capability-gated addition for shepherd state if needed.
   - Older hosts and Macs keep working: without the capability the Mac shows nothing, as today.
6. **Setup checks `gh`.** `alas-host setup` reports whether `gh` (and `glab`, when a project uses GitLab) is logged in for the host's user, with the command to fix it. A host that isn't logged in still boots; the shepherd's existing auth-failure escalation covers it at runtime.
7. **Docs.** `docs/headless-host.md` describes shepherds and schedules on the host, the `gh` requirement, and the terminal-agent limit. It fixes the current PR claim.

## Non-goals

- Editing or creating schedules from the paired Mac. The peer view's Schedules tab stays out ("schedules belong to this Mac"). Schedules come from the profile, i.e. set up in the app on the mini before it was headless, or from the CLI if one exists.
- Starting, pausing or stopping a shepherd from the paired Mac. The pill is read-only on the peer in this step; agents and `alas` CLI calls on the host still control it.
- Terminal-agent schedules on the host.
- Wake-from-sleep handling. The 30-second ticks resume on their own.
- Live config reload. Shepherd and schedule settings are read at boot, so a change needs `alas-host restart`.

## Anti-goals

- No behaviour change in the app. The app keeps its own effects, including its UI-bound pieces. Core gains defaults; the app's installs still win.
- No double-running. The app and host already never share a profile at once; keep it that way.
- The host never prompts and never shows system UI.
- No regression for older peers. New state is capability-gated, and older decoders ignore it.

## Constraints

- AGENTS.md:
  - Swift Testing;
  - testing policy: test the moved decision logic (prompt delivery choice, runner target resolution, terminal-agent refusal, notice mapping, peer pill presentation), not wiring;
  - no UI imports in the core package;
  - Conventional Commits, no attribution.
- The app target can't be built locally, so CI is its first build. Moving effects into core must keep the app's call sites compiling; keep app edits mechanical.
- Shepherd and stack tests that touch git stay real git, using template repos.

## Decisions (my calls; the user confirmed scope, including the pill)

- **Effects move into core as defaults** (`AlasCoreContext.installDefaultShepherdEffects()`, `installDefaultRunScheduleRunner()` or similar). The app overrides the UI-bound parts.
  - Base branch: from config on the host, from the pane in the app.
  - `refreshPaneIfCached`: a no-op on the host.
  - In-app banners: notices on the host.
- **Notices.** Shepherd and schedule notifications go through the same `relaysNotices` path as `notify` (`HeadlessHostEnvironment`). They don't get a separate channel.

## Decisions from the builder check (my calls)

- **Records and schedules the host can't serve stay untouched.** The host refuses sessions in SSH-project worktrees, so for them:
  - **Shepherd records** are skipped. The host never removes, escalates or changes them, because they are the app's and must survive the handoff back. Core needs a "not served here" outcome, separate from "ineligible" (which removes).
  - **Schedules targeting an SSH worktree** are treated like terminal-agent schedules: each due fire records a failure with a clear reason ("runs only in the app") and moves to the next due time, the same as a normal failure.
- **Which notifications relay.** The host relays exactly what the app sends to Notification Center (`harness.notifications`). That covers shepherd ready, merged and closed, escalations, schedule failures, and run-script outcomes. The app's in-app toasts (`inAppNotifications`: "launched", "model not accepted", "kept branch", "queued") are logged on the host, not relayed. One rule, no per-message list.
- **Notices without a session.** Schedule failures before a session exists, and script outcomes, have no session. The host sends them as a worktree notice:
  - A new opt-in host event kind carries `worktree` plus optional `sessionID`.
  - Only Macs that subscribe to that kind receive it, so older Macs never see it and nothing on the existing `notice` wire changes.
  - Clicking it selects the session when there is one, else the peer worktree.
- **Prompts not sent automatically.** A schedule with `sendsPromptAutomatically == false` leaves its prompt for the user to review, and the host has no composer. On the host it fails with a clear reason ("leaves its prompt for review; runs only in the app"), like terminal-agent schedules. The host never sends a prompt the user meant to review. Cost if wrong: a later draft surface on the peer.
- **Run-script outcomes relay.** A scheduled, or any, script run's outcome, which the app shows through the run monitor's notification, relays as a worktree notice on a headless host instead of calling `UNUserNotificationCenter`.

## Left to the builder

- Exact core API names and where the moved effects live, e.g. `AlasHostCore/Core/Shepherd/` and `.../Runs/`.
- How shepherd state reaches the peer: reuse and extend the review-status follow, or add a `HostEvent` case plus a capability. Also which pieces of the app's pill state are carried.
- Where the pill shows on the peer: the peer session toolbar, mirroring `ACPShepherdButton`, and/or the peer worktree row.
- How a terminal-agent schedule failure is recorded and surfaced.
- Whether `alas-host setup` checks `glab` only when a project's remote is GitLab.
