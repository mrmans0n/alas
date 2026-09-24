# Scheduled agent reports and safe cleanup

## Goal

A scheduled agent can finish unattended, leave a readable, durable account of its work, and remove the session and worktree created for that occurrence when doing so is safe. A failed, blocked, or uncertain run stays inspectable. Reports remain available after the schedule, session, worktree, or short schedule history is removed.

The opt-in cleanup setting applies to ACP agents launched in worktrees created by schedules. Existing script-only schedules and terminal-agent launches keep their current behavior. The user chooses whether to retain the resources or save a report and clean up on success; retaining them is the default. This extends the existing scheduled-runs design rather than introducing another scheduler.

## Current boundaries

- `RunScheduler` dispatches an occurrence and waits for `AppState.runSchedule` to return. `RunScheduleFiring` stores the result and script-run references, capped at 20 entries per schedule in `run-schedules.json`.
- A composed schedule creates a worktree, optionally waits for a script, then launches an ACP chat or terminal agent. Today an agent's `.succeeded` means launch succeeded, not task completion. It cannot authorize cleanup.
- Script output lives in `RunHistoryStore` under the worktree. A schedule history link can become unavailable after the worktree goes away. Reports therefore need separate storage and navigation.
- ACP has persisted sessions and a prompt lifecycle, but an idle session or successful prompt transport does not certify task success. No reusable general-purpose session summarizer exists in the current source. The scheduled agent supplies the human-readable account as part of an explicit completion submission.
- Existing worktree removal has operation-state claims, workspace ownership checks, dirty-buffer and Git preflight checks. Automated cleanup must reuse the same removal and state-cleanup path, not implement a second destructive path or silently invoke an asynchronous CLI deletion that reports acceptance rather than settlement.

## Chosen approach

An explicit, session-bound completion submission is required. Inferring success from final chat text or an idle transition is unsafe for deletion. Requiring a separate summarizer adds a second agent turn and still does not establish success; no new general-purpose summarization service is part of this change.

### Configuration and eligibility

Add an `afterExecution` option to the composition, with `keep` as the decode default for existing schedules and `reportAndCleanupOnSuccess` as the opt-in value. The editor explains that cleanup is available only for a configured ACP-capable agent with an automatically submitted, nonblank prompt. A project-default agent may change between edit and fire time, so eligibility is checked again at launch. If the resolved agent is not ACP-capable or cannot receive the session-scoped completion tool, do not enable automated cleanup for that target; record why and retain its resources. Never silently change a terminal run into an ACP run or discard a scheduled prompt. Script failure before agent launch retains the newly created worktree.

An explicit Run Now obeys the same selected policy. For `allProjects`, each project is an independent target with its own report and cleanup result; the parent firing uses the existing worst-of outcome rule and links to all target reports.

### Run identity and completion

Create an occurrence ID before dispatch and a distinct target-run ID per resolved target. Persist the target-run record before creating its worktree or sending a prompt. Associate the created worktree ID and ACP session ID with that record as each becomes available. The scheduled prompt tells the agent to submit a completion result at the end of its task, with status `succeeded`, `failed`, or `needsAttention`, a concise account, checks actually run and their results, and durable output links/identifiers. The completion tool uses the authenticated ACP session origin to find its active target run. It rejects submissions from other sessions, other targets, duplicate final submissions, and runs already canceled or settled. No caller-supplied run ID is trusted on its own. Text, links, and declared checks are report content, not proof that deletion is safe.

The runner waits for both the completion submission and the scheduled prompt turn to settle, with no pending queue item, approval, question, or input request. A transport failure, disconnect, cancel, missing submission, or agent request for attention cannot become success. A four-hour deadline from prompt dispatch prevents a silent run from blocking the schedule indefinitely; on timeout the run is marked `needsAttention` and its resources remain. Keep the existing launch-only outcome behavior for schedules that did not opt in. Schedule deletion cancels running targets but never initiates cleanup; already persisted reports remain.

For a script followed by an agent, the script's settlement remains the prerequisite to launching the agent. A target's final result reflects both steps. The report references the existing script run without copying its full output. Its persisted request, agent account, checks, links, and outcome stand alone when that reference is no longer openable.

### Durable reports

Use a separate SQLite-backed schedule report store under Application Support rather than add report text to the JSON scheduler file, which is rewritten on each update and caps history at 20. Index reports by immutable target-run ID, occurrence ID, and schedule ID; retain a snapshot of schedule name, project, branch, worktree ID, agent ID/model, request, fire/finish times, script-run reference, declared result, and cleanup result/reason. The report body is a bounded, plain-text or Markdown snapshot; reject oversized submissions with an explicit retained/error state rather than truncate silently and delete the source. Do not copy secrets from environment or entire transcripts. Writes are atomic and awaited; only a successfully committed final report may proceed to deletion.

Report state distinguishes `running`, `succeeded`, `failed`, `needsAttention`, and `interrupted`; cleanup state distinguishes `notRequested`, `pending`, `removed`, `retained(reason)`, and `failed(reason)`. A completed task whose cleanup is refused remains a task success, with a visible cleanup reason. On startup, reconcile orphaned running reports as interrupted and pending cleanup as retained, preserving the already recorded task result; restart never infers success or resumes automatic deletion. If persistence fails, keep the resources and show a failure notification. Report records do not expire with the schedule's 20-entry history and are not removed when a schedule is deleted. Explicit report deletion is a separate user action, never an effect of schedule or worktree removal.

### Cleanup safety and order

On an explicitly successful, settled ACP run, first persist the complete report with cleanup pending. Claim the worktree for removal before asynchronous checks so new sessions cannot be admitted between inspection and deletion. Verify it still belongs to the target run, is not the main worktree or owned by another workspace checkout, has no other active sessions or terminal work, pending approvals or input, unsaved editor buffers, uncommitted changes including untracked files or submodules, or commits made since the branch point that exist only locally. Record the base commit at creation; if there are new commits but their remote reachability cannot be established, retain the worktree. Recheck volatile state at deletion time. Never force-delete; never auto-delete a branch based only on the agent's claim. Keep the branch after worktree removal. Follow the existing worktree teardown path and await actual filesystem/state removal before recording `removed`; if removal fails or is partial, record the error and leave the report available for inspection. Worktree teardown disposes its ACP manager, so remove the scheduled session's persisted row through a persistence path independent of that manager after worktree removal settles. A session deletion failure is recorded as partial cleanup, not success. No report state transition is allowed to imply a session or worktree was removed before that operation settled.

If any guard fails, release the removal claim, record `retained(reason)`, and leave the session and worktree openable. Completion and cleanup are per target, so one unsafe target does not block another project's successful cleanup. Manual user changes to the schedule during an active firing do not relax that firing's captured policy.

### Presentation

Add the option and its ACP/prompt requirements to the schedule editor. A running opt-in schedule remains marked running until task completion, not merely launch. History rows link to each target's durable report and distinguish `Succeeded · cleaned up`, `Succeeded · retained`, `Needs attention`, and cleanup failure; script-run links remain where available. The report view shows the request, agent account, checked evidence, output links, timings, and cleanup state. When resources remain, offer Open Session and Open Worktree where they still exist.

Expose a project-level schedule reports list independent of active schedule cards, including reports for deleted schedules. It should identify schedule and project snapshots and allow opening a report after its worktree has gone. Removing a report requires an explicit user action. A notification for a failed or retained cleanup includes the reason and a report link; a normal success need not interrupt the user.

## Verification

Focused Swift Testing suites cover legacy configuration decoding, ACP eligibility at fire time, identity-bound single completion, prompt-turn settlement and pending-input cases, timeout/disconnect/cancellation, restart reconciliation, atomic report retention after schedule deletion and beyond 20 firings, independent fan-out reports, and each cleanup refusal. Integration tests exercise the existing worktree deletion path without forcing and confirm that success is recorded only after removal settles. Run only affected suites or build if no focused suite applies. Finally, manually fire an ACP schedule against a disposable repository, submit an explicit success, observe the durable report and worktree/session removal, relaunch Alas and reopen the report; repeat with a dirty worktree and observe retention. Do not run destructive smoke checks against a user's working repository.
