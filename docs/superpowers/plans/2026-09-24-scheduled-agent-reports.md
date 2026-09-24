# Scheduled agent reports and safe cleanup implementation plan

Design: `docs/superpowers/specs/2026-09-24-scheduled-agent-reports-design.md`.

## Goal and execution rules

Add opt-in, ACP-only scheduled-task completion, a durable report independent of the session/worktree and 20-entry schedule history, and safe automatic removal after a verified success. Keep existing launch-only schedules unchanged. Implement in dependency order; each step has a focused behavior check. Do not run the full Xcode test plan by default. Worktree deletion must never be inferred from an accepted asynchronous CLI request.

`project.yml` includes the source and test directories, but new Swift files still require `xcodegen` to refresh `Alas.xcodeproj`; commit the regenerated project with those files. If `project.yml` changes, commit it with the generated project as required. Do not enable a partial feature in the editor: wait until end-to-end behavior is verified.

## 1. Configuration and immutable occurrence identity

Files: `Alas/Sources/Schedules/RunSchedule.swift`, `RunScheduleDraft.swift`, `RunScheduler.swift`, `Alas/Sources/Right/RunScheduleEditorView.swift`; `AlasTests/RunSchedulerTests.swift`, `AppStateRunScheduleTests.swift`.

- [ ] Add a Codable composition `afterExecution` enum with absent-key default `keep`. Keep existing composition initializer call sites working by defaulting the new parameter; remove any interim aliases.
- [ ] Preserve the selected policy in draft loading/saving. Require an auto-submitted nonblank prompt for cleanup. Explain ACP requirements in the editor; do not promise support for unresolved project defaults that may resolve to terminal agents.
- [ ] Mint a firing/occurrence ID at dispatch, pass it through the runner and per-target work, and use it for `RunScheduleFiring.id` instead of minting a second ID at settlement. Preserve IDs across fan-out and cancellation. Extend the runner result with target report IDs; persist report links in firing history with backward-compatible decoding.
- [ ] Focused checks: old schedule JSON decodes as `keep`; draft round trip; no prompt/auto-send disallows cleanup; occurrence identity remains stable while waiting; old firing JSON decodes; fan-out keeps distinct target IDs.

## 2. Durable report store and recovery

Files: new `Alas/Sources/Schedules/ScheduledAgentReportStore.swift` and `ScheduledAgentReport.swift`, plus existing `RunHistoryStore.swift` and `AlasTests/RunHistoryStoreTests.swift` as storage conventions; add `AlasTests/ScheduledAgentReportStoreTests.swift`.

- [ ] Implement an actor-backed SQLite store at a new `Paths` Application Support URL. Schema indexes immutable target-run ID, occurrence ID and schedule ID. Include schedule/project/branch snapshots, base commit, request, script reference, session/worktree IDs, agent/model, started/finished times, structured completion body and distinct task/cleanup states. Enforce a documented finite size for user/agent text and links; reject invalid/oversized submissions without deleting their session.
- [ ] Implement atomic create/update/finalize and explicit delete operations. Failed writes propagate; never return success on an unwritten report. Add query by project and schedule, and a startup reconciliation that marks orphaned running reports interrupted and pending cleanup retained without reattempting deletion; preserve a previously recorded task success.
- [ ] Focused tests: round-trip in a temporary SQLite database, fresh instance reopening, duplicate/invalid transitions, write failure, size limit, reconciliation after simulated crash, reports retained when schedule JSON history drops beyond 20 entries or schedule is removed. Do not duplicate transcript or script output.

## 3. Session-bound completion tool

Files: `AlasCLI/crates/alas/src/mcp.rs`, `AlasCLI/crates/alas-client/src/lib.rs`, `Alas/Sources/Harness/AlasCLIRequest.swift`, `Alas/Sources/App/AlasCLICommandRouter.swift`, the existing authenticated socket/gateway command handler, `Alas/Sources/ACP/Session/ACPMCPPromptPreamble.swift`; Rust MCP tests and `AlasTests/AlasCLIRequestTests.swift`, `AlasCLICommandRouterTests.swift`.

- [ ] Add `schedule_complete` to built-in Alas MCP with schema for status (`succeeded`, `failed`, `needs_attention`), concise report body, checks/results, output links. Map it through the existing Rust client wire request and Swift request parser/router. Keep it unavailable to ordinary sessions by returning an explicit non-scheduled-session error at the app handler, not by trusting client input.
- [ ] Resolve the authenticated caller session/worktree from the socket origin and an in-memory active run registration, verify ownership against persisted session/target IDs, and accept at most one completion per target. A caller-provided ID or worktree path is never sufficient. Require the built-in MCP injection to be active for eligible ACP runs; if disabled, overridden, or unavailable, retain the worktree and explain why.
- [ ] Do not expose completion text in logs. Ensure a late submission after timeout, cancellation, or schedule deletion is refused. Add Rust unit tests for schema/argument validation/wire mapping and Swift tests for origin isolation, duplicate/late submissions and size boundaries. Run `cargo test` in `AlasCLI` and focused Xcode tests after the slice is integrated.

## 4. Scheduled ACP completion lifecycle

Files: `Alas/Sources/App/AppState+RunSchedules.swift`, `Alas/Sources/Schedules/RunScheduler.swift`, `Alas/Sources/ACP/Session/ACPSessionManager.swift` only if a prompt-settlement observation API is missing; `AlasTests/AppStateRunScheduleTests.swift`, `RunSchedulerTests.swift`.

- [ ] For opted-in runs, create the report before worktree creation; record the branch base, worktree ID and prepared ACP session ID as they become available. Preserve the current script-first rule. Register completion before prompt delivery so fast agents cannot race registration. Inject a completion instruction into the scheduled prompt without altering the persisted user-authored prompt.
- [ ] Wait for a valid completion and the corresponding scheduled prompt turn to end, with no queued work, approval or input request. A prompt dispatch acknowledgment is not a finished task. Bound this wait to four hours from prompt dispatch. On cancellation, timeout, disconnection, rejected tool availability, script/launch failure or missing completion, finalize a non-success report and retain resources. Existing non-opt-in schedules still settle on launch.
- [ ] Return each target's settled outcome and report ID to scheduler history; combine fan-out outcomes without holding one target's launch behind another. Make an opted-in schedule display running until its task settles. Test task-state transitions, prompt-turn races, competing sessions, timeout, cancellation and mixed fan-out independently using controllable clocks/continuations, not fixed sleeps.

## 5. Preflight and removal with a settled result

Files: `Alas/Sources/App/AppState.swift` around `performDeleteWorktree`, `Alas/Sources/App/AppState+RunSchedules.swift`, relevant worktree deletion/preflight helpers and focused tests under `AlasTests/`; `Alas/Sources/ACP/Session/ACPSessionPersistence.swift` if independent persisted-row deletion needs an API.

- [ ] Factor a noninteractive awaited deletion entry using the existing operation-state claim and `performDeleteWorktree(... force: false, deleteBranchIfMerged: false, promptsForForce: false)`. Do not use `cliDeleteWorktree`, which returns `.ok` before removal settles. Keep ownership, checkpoint and content-race checks; release claims on every refusal.
- [ ] Validate the target-run worktree still matches the captured creation identity and base commit, no other sessions/terminal work or pending input/permission exists, no unsaved editor buffer or uncommitted/untracked/submodule changes exist, and no new commits are solely local. For new commits, test actual remote reachability; unknown reachability means retain. Repeat volatile checks under the deletion claim immediately before removal. An ordinary Git removal failure is a failed cleanup, never a force retry.
- [ ] Persist the completed report before deletion. Await the worktree removal result; worktree teardown disposes the ACP manager, so delete the scheduled session's persisted row via a separate persistence path after teardown. Record partial cleanup if session row deletion fails. Persist `removed` only when both removals settle. On preflight refusal, record `retained(reason)` and keep session/worktree openable. On storage error, do not delete anything further.
- [ ] Tests with disposable temporary Git repositories cover dirty/clean trees, local-only commits, missing tracking information, remote-reachable commits, workspace ownership, other active sessions, changed worktree identity, checkpoint gate and removal failure. Verify completion and cleanup results separately; verify report survives actual removal and relaunch.

## 6. Report browsing and schedule presentation

Files: `Alas/Sources/Right/SchedulesTabView.swift`, `RunScheduleEditorView.swift`, `Alas/Sources/Schedules/RunSchedulePresentation.swift`, a focused report detail/list view under `Alas/Sources/Right/`, plus `AlasTests/RunSchedulePresentationTests.swift`.

- [ ] Add project-level report browsing independent of active schedule cards, with a report detail view and explicit report deletion. Snapshot names remain readable when schedule/worktree is gone. Keep script-run links when present and resolvable; offer session/worktree navigation only while they exist. History links target durable reports after worktree deletion.
- [ ] Display distinct task success/failure/attention and cleanup removed/retained/failed statuses. Notify on failure/retention with the report reference; do not claim success from launch. Ensure fan-out entries link every target, including those deleted successfully.
- [ ] Focused presentation tests for outcomes and link availability. Exercise the rendered schedule editor, history and report list in the running app; tests of string generation alone are not UI proof.

## 7. Final checks and docs

- [ ] Run affected Xcode suites, `cargo test` for the new MCP tool, and a build if affected UI paths lack focused coverage. Do not run the entire Xcode suite by default. Report exactly what ran.
- [ ] In a disposable local repository, manually fire an opted-in ACP schedule, submit a bound completion, observe that the run stays active until the prompt ends, then inspect the saved report and actual worktree/session removal. Relaunch and open the report. Repeat with a dirty worktree and verify both resources remain. If the ACP adapter/runtime is unavailable, use a disposable integration harness covering real store, prompt/command and Git deletion paths, and report the live-UI limit.
- [ ] Update user-facing scheduling documentation for eligibility, report retention, safe cleanup refusals, and terminal-agent limitations. Review changes for obsolete code, unexercised paths and generated-project changes before committing implementation.
