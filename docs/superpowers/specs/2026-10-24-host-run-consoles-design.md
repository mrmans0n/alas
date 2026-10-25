# Run consoles on a headless host — phase 3 design (part 2)

## Intent

Phase 3 part 1 (#2193) let a paired Mac open shells on a headless `alas-host`. Each shell runs in a zmx session listed by `HostConsoles`. Run scripts on a headless host are still plain processes (`HeadlessRunLauncher`), so you can't watch or interact with a run from the Mac, and the Run tab only shows output after the run finishes. The user wants runs on the mini to behave like runs on a Mac running the app: watchable live, attachable, and following the script's console settings.

## Current state

- `HeadlessRunLauncher` (`AlasCoreContext+Runs.swift`) runs the captured command with `RunService.runInShell`. That writes the `script` transcript and the `.done` file, and `observeRun` / `RunScriptCompletionMonitor` record the outcome. It returns `.local(…)`, not `.hosted`.
- On a Mac running the app, `AppRunLauncher` hosts each run in a zmx-backed terminal tab and returns `.hosted(sessionID: leafId)`. That leaf id equals the peer console id, so `RunRecord.sessionID` already names the run's console for peers.
- `HostConsoles` (#2193) is the headless registry of zmx shells. It is persisted, restored at boot, and pruned by socket. It also holds the lifecycle hooks (worktree removal, project busy) and serves `PeerConsoleHost`. Session names use the `alashost-` prefix, and launches go through `HostShellLaunch` with all three standard streams on `/dev/null`.
- The peer Run tab (#2187) lists rows from `PeerRuns`, each carrying the `RunRecord`. The peer console viewer can attach to any listed console id.

## Goals

1. **Headless runs in zmx.** When the host's zmx is available, a run launches inside a new zmx session.
   - The session runs the same captured command the app uses: transcript, `.done` file, cwd, env, and the agents' environment as for shells.
   - The launcher returns `.hosted(sessionID: consoleId)`, so `RunRecord.sessionID` names the run's console, as on an app host.
   - Completion, history and the report work unchanged. Stopping a run (`endRunHost`) kills the session. `hostSessionExists` and `hostSessionIsIdle` reflect the session.
2. **Run consoles in the registry.**
   - `HostConsoles` records run consoles alongside shells. Each entry gets a kind (shell or run), the script key, and the script name as title.
   - Run consoles are listed to peers and attachable like shells, with resize as for shells.
   - All lifecycle guarantees from #2193 apply: deleting a worktree stops its runs' consoles, project removal counts them as busy, they survive host restarts, and entries are kept when zmx can't answer.
3. **On-exit behaviour follows the script.** The script's `onExit` (keep / close, from `RunScriptMetadata`) decides what happens when the command ends, matching the app.
   - **Keep:** the console stays with its output until terminated.
   - **Close:** it goes away.
   - The builder verifies how zmx behaves when the session's command exits, and chooses the mechanism, e.g. wrapping the command so the session waits until it's closed.
4. **Run tab "Open Console".**
   - A run row whose record has a `sessionID` that the host lists as a console gets an **Open Console** action. It selects that console in the peer view and attaches to it.
   - It works for hosts running the app too, whose run consoles are already peer consoles; that's existing behaviour.
5. **Fallback.** Without zmx, headless runs stay plain processes as today, and no console is listed.

## Non-goals

- Live output inside the Run tab's report sheet. Open Console covers watching a run.
- Runs for SSH-project worktrees on the headless host. They are refused as today.
- Changes on hosts running the app, beyond the Open Console action on the Mac side.

## Anti-goals

- No change to how runs behave locally in the app.
- No undiscoverable daemons. Every run session the host starts is registered before it can outlive the launch, or killed. Reuse #2193's kill-then-forget helper.
- No regression for older peers. Run consoles are ordinary consoles to them.

## Constraints

- AGENTS.md:
  - Swift Testing;
  - the testing policy applies: extend the existing suites (`HostConsolesTests`, run tests in AlasHostTests and AlasCoreContextTests);
  - no UI imports in the package;
  - Conventional Commits with no attribution.
- The app target can't be built on the dev machine, so CI is the first build. The app-side change is only the Run tab action, so keep it small.
- Verify the real zmx behaviour, both on exit and on kill, on the binary at `/Applications/Alas.app/Contents/Resources/zmx/zmx` in a temporary `ZMX_DIR`. A manual smoke on the mini follows the implementation.

## Left to the builder

- How the launcher is structured: a zmx mode of `HeadlessRunLauncher`, or a new launcher chosen at boot when zmx is available.
- The session naming scheme for runs (keeping the `alashost-` prefix) and the registry schema change (kind and script key) with backward-compatible decoding of #2193's file.
- The keep/close mechanism on zmx.
- Where "Open Console" appears on the row: a row action or the row's menu.
