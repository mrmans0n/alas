# ACP background work spike

Issue: [#1744](https://github.com/mrmans0n/alas/issues/1744).
Inspected on 2026-10-04. The focused implementation proposal below was approved.

## Evidence and limits

The installed packages were Claude Agent ACP 0.85.1, Codex ACP 2.1.1, and
Pi ACP 0.0.34. The spike inspected their distributed JavaScript and exercised
the Claude and Codex task runtimes with in-memory publishers and provider
inputs. It made no model calls and started no background shell. These results
prove the adapters' translation and cancellation routing, not live provider
delivery or successful termination of a real process.

Reproduce the runtime probes against those exact installed versions:

```sh
node scripts/probes/acp-background-work.mjs "$(npm root -g)" \
  > /tmp/alas-background-work-probe.json
```

The script is a throwaway spike, outside the app and CI. It refuses a different
adapter version so changed bundles require a fresh inspection.

| Adapter | Start and progress | Completion and output | Cancellation |
|---|---|---|---|
| Claude 0.85.1 | `async_task_spawned`, `async_task_progress`; shell, monitor and other non-agent background tasks | `async_task_state_update`; optional summary and output-file path; existing Bash terminal metadata remains separate | `_session/async_task/stop` calls SDK `query.stopTask`, returns `{stopped: Bool}` |
| Codex 2.1.1 | `async_task_spawned` for background shells, correlated with a command tool call; no separate progress event found | `async_task_state_update`; output remains on the existing command/terminal reports | The same Stop request calls `thread/backgroundTerminals/terminate` |
| Pi 0.0.34 | Ordinary `tool_execution_start/update/end` become tool calls; no async-task lifecycle or native-child update handling found | Bash terminal output and exit describe the tool execution, not an extension-owned background process | `session/cancel` calls Pi RPC `abort`; no task-specific Stop handler found |

Native agents have a separate lifecycle: `subagent_spawned`, child-addressed
transcript updates, and `subagent_state_update`. Alas already decodes, renders,
and persists these. A child can be cancelled only when its announced
capabilities permit it. The inspected Claude runtime announces empty child
capabilities, so child-specific cancellation cannot be inferred from the
presence of a native-agent row.

## Negotiation

The async-task events are gated on this extension marker in
`initialize.clientCapabilities._meta`:

```json
{
  "terminal_output_delta": true,
  "jetbrains": {
    "air": {
      "version": 1,
      "capabilities": ["asyncTasks"]
    }
  }
}
```

Before this change, Alas sent no such marker. The adapters therefore did not
publish the task lifecycle, and Alas decoded these event kinds as `unknown`.
`session/cancel` and a task-specific Stop are separate operations.

The implementation also advertises `terminal_output_delta`: Codex's AIR
renderer suppresses fallback terminal output without an explicit output
capability. The probe exercises that negotiated shape, including terminal
output and exit metadata. Only `asyncTasks` is advertised in the AIR capability
list; patch rendering and other optional AIR formats stay off.

The marker also selects AIR presentation for ordinary tool calls, even when
only `asyncTasks` is listed. In the captured Claude Bash example the terminal
output and exit still arrived, but the final report omitted the `content`
terminal reference already sent at start. Codex likewise switches its ordinary
tool renderer when the AIR object is present. Regression coverage must check
partial tool updates, terminal output, message phase, diffs, permissions and
native-child routing before enabling this marker. Advertising unrelated AIR
capabilities would expand the compatibility obligation further.

## Captured runtime behavior

- Claude emitted a shell spawn with `asyncTaskId`, `taskType: "shell"`,
  `canStop: true`, `toolCallId`, and `outputFilePath`. A progress event carried
  `summary` and usage. Completion carried `state: "completed"` and a summary.
- Claude emitted a monitor spawn and a `state: "stopped"` event after the
  runtime claimed its Stop. The adapter's request handler calls the SDK before
  publishing that state; this spike did not invoke the real SDK.
- Codex reconciled a listed background terminal into a spawn with
  `taskType: "shell"`, `showInTranscript: false`, and `canStop: true`. It also
  marked the originating tool call as backgrounded.
- Codex Stop called the fake provider with the exact owning thread and process
  id. A successful provider response produced `state: "stopped"`. A separate
  completed-command notification produced `state: "completed"`.
- Claude has a session-long SDK consumer and handles task-notification
  follow-ups internally. An additional host prompt on each completion could
  duplicate that work. Codex's inspected background-task runtime publishes
  state but contains no completion prompt or steering call.

These are observations about the inspected versions. Unstructured shell
backgrounding, arbitrary Pi extensions and adapters without the negotiated
extension remain outside reliable task tracking.

## Implementation

1. Decode the three async-task updates, tolerating missing or unfamiliar
   optional fields. Keep task identity scoped to its owning root or native child.
2. Persist task snapshots on synthetic transcript tool-call rows, following
   Alas's existing native-subagent and compaction row pattern. This reuses
   persistence, hydration and mirroring without another database schema.
3. Show active tasks in a compact session list with their name, state, latest
   summary and task-specific Stop when supported. Preserve the independence
   of foreground turns and background work so a typed prompt can still Send.
   Esc and session Stop should reach supported background work after a turn
   ends. Failed or rejected Stop must leave the task running until confirmed.
   Foreground Stop cancels only the root turn; it does not send separate Stop
   requests to unrelated background tasks or native children.
4. Deduplicate terminal transitions and replay. Queue a completion wake for
   Codex through the existing prompt queue, respecting permissions, input
   blockers, ownership and foreground work. For Claude, retain provider-owned
   follow-ups and show the completion in the session without an extra prompt.
5. Reconcile recovery against the actual attach outcome. An app restart or tab
   reopen can adopt a surviving broker and must preserve its running work.
   When the adapter process was replaced, mark remaining tasks as lost
   observation and tell the agent which ids and names lost their live owner.
   Do not claim a shell was killed merely because its connection disappeared.
6. Cover partial updates, duplicate/replayed terminal events, child-scoped
   tasks, Stop after an idle turn, cancellation failure, queue ordering and
   surviving versus replaced processes with focused Swift Testing suites.

Pi remains unsupported for extension-owned background work in this change.
A reliable Pi implementation needs an extension-to-ACP task lifecycle and a
task-specific cancellation contract first. Text matching or process scanning
cannot establish task ownership or completion.

The AIR opt-in is limited to the built-in Claude and Codex adapters. Stop is
enabled only after the adapter advertises async tasks and the task says it can
be stopped. Unknown task states remain active. `showInTranscript: false` hides
the synthetic row in the native transcript; the task still appears in the
active-work list and its original tool call carries output.

Completion and loss notifications carry a persistent UUID shared with their
queue item. Delivery state and queue removal are saved in one transaction.
The item remains in memory until that transaction commits. A failed save
retains a visible, delivery-uncertain entry for explicit retry, restores the
undelivered task state, and prevents automatic replay. Concurrent Stop and
prompt completion cannot consume the same wake twice.
Identical task replays re-save the current snapshot before acknowledgement,
so an earlier failed write cannot leave only an in-memory completion behind.
Confirmation reconciles the cached session even after its runner stops or is
replaced, while preserving a newer retry attempt. Retired runners do not
dispatch successor work or issue recovery writes.
Native steering and interruption fallback retain the wake identity and use
the same delivery transaction, including the owned continuation when an
adapter requires a prompt. Failed wakes offer Retry and Send now. Generic
Remove, Edit, and Clear preserve them in both native and remote queues so
those actions cannot discard only the queue half of a pending notification.
Remote snapshots and deltas carry cancellable background-work state for web
and native-peer Stop controls, including state-only changes and federation.
Older frames default to no background cancellation. Hidden task rows become
empty visibility markers remotely, preserving pagination indices while
removing a previously visible row from client rendering.
Replayed spawns cannot reopen completed work. A successful attach to a
surviving broker retains running tasks; replacement marks only prior tasks
that the new adapter has not reported again as lost observation.
Sparse progress reopens lost work without reopening a completed task.
A wake consumed before a usage limit uses the same task/queue confirmation
transaction, with its continuation retained and failed confirmation held for
explicit retry.

## Verification boundaries

Local validation passed:

- After rebasing on `origin/main`, the focused Xcode test selection ran
  **394 tests in 10 suites**:
  `ACPSessionUpdateTests`, `ACPConnectionTests`, `ACPPermissionFSTests`,
  `ACPSessionTests`, `ACPSessionRunnerQueueTests`, `ComposerActionTests`,
  `ACPSubagentRoutingTests`, `ACPSessionManagerHydrationTests`,
  `ACPSessionTerminalRoutingTests`, and `ACPToolCallGroupingTests`.
- Before rebasing, an `ACPSessionTests` rerun verified the additional
  Claude/Codex completion-policy variant: **126 tests in one suite** passed.
- The review fixes passed **248 tests in four suites**. After integrating the
  updated base branch, **396 tests in six suites** passed:
  `ACPSessionRunnerQueueTests`, `ACPSessionRunnerTests`,
  `ACPSessionManagerAttachRestoreTests`, `ACPSubagentRoutingTests`,
  `ACPTranscriptRowWindowTests`, and `ACPToolCallGroupingTests`. The new
  regressions failed before the fixes: buffered task reannouncements must
  drain before loss reconciliation, and hidden snapshots must create no
  rendered row or anchor. Idle cancellation also reports denied leases and
  transport errors accurately through the new MCP session controls.
- The pending-notification review fix passed **214 tests in two suites**:
  `ACPSessionRunnerQueueTests` and `ACPSessionRunnerTests`. Its regression
  reproduced stale summary and terminal-state data before the fix. Pending
  notifications now retain their delivery identity while refreshing their
  persisted text; sending, failed, and uncertain deliveries keep their snapshot.
- The late-reannouncement race fix passed **223 tests in two suites**:
  `ACPSessionTests` and `ACPSessionRunnerQueueTests`. The existing in-flight
  loss test now also reannounces the task before completion; that variant
  failed before the fix because the completion notification was consumed
  under the earlier loss notification's identity.
- Foreground cancellation scope passed **242 tests in three suites**:
  `ACPSessionRunnerQueueTests`, `ACPSessionRunnerTests`, and
  `ACPSubagentRoutingTests`. The existing queue-drain test now covers live
  background tasks and native children; it failed before the fix because
  foreground Stop also cancelled that independent work.
- Delivery-save failure handling passed **225 tests in three suites**:
  `ACPSessionRunnerQueueTests`, `ACPSessionRunnerTests`, and
  `ACPSessionPersistenceTests`. A SQLite trigger reproduced the lost retry
  entry after successful or cancelled delivery. A gated Stop during
  confirmation also reproduced duplicate consumption before its guard.
  All variants retain a durable, visible entry without automatic replay.
- Teardown confirmation handling passed **226 tests in three suites**:
  `ACPSessionRunnerQueueTests`, `ACPSessionRunnerTests`, and
  `ACPSessionPersistenceTests`. Gated successful and failed transactions
  reproduced stale cached state after stop or replacement before the fix.
  Committed responses are acknowledged, consumed attempts are removed, and
  newer retries retain their identity and data.
- The pinned adapter-runtime probe, `node --check` for that probe, and
  `git diff --check` passed.
- Integration with `origin/main` at `63be43c2` and the steering/queue-action
  fixes passed **312 tests in six suites**: `ACPSessionRunnerQueueTests`,
  `ACPSessionRunnerTests`, `ACPSessionPersistenceTests`,
  `ACPSessionQueueAPITests`, `ACPSessionManagerHydrationTests`, and
  `RemoteQueueProjectionTests`. The new regressions first reproduced lost
  delivery state in native steering and fallback, and generic mutations
  dropping retry-held wakes. Success and SQLite failure variants now cover
  durable task/queue state, response acknowledgement, and replay.
- Remote projection fixes passed **203 tests in four suites**:
  `RemoteSessionGatewayTests`, `RemoteProtocolTests`,
  `NativePeerTranscriptTests`, and `NativePeerSessionsTests`. The regressions
  first reproduced hidden rows appearing in snapshots/deltas and missing
  idle cancellation state. They cover hidden-page cursor progress, state-only
  flag changes, federation and decoding frames from older peers.
  A Node probe of the web functions passed the composer-action matrix and
  hidden-row insertion/removal checks; JavaScript syntax and SwiftFormat lint
  also passed.
- Failed-write replay recovery passed **228 tests in three suites**:
  `ACPSessionRunnerQueueTests`, `ACPSessionRunnerTests`, and
  `ACPSessionPersistenceTests`. A SQLite trigger reproduced acknowledgements
  advancing without repairing the task row or queuing its wake. Repeated
  failed replays now remain unacknowledged; successful replay repairs durable
  state and queues the original wake identity exactly once.
- Sparse progress and usage-limit delivery passed **357 tests in four suites**:
  `ACPSessionRunnerQueueTests`, `ACPSessionRunnerTests`,
  `ACPSessionPersistenceTests`, and `ACPSessionTests`. Existing parameterized
  regressions first reproduced lost tasks remaining terminal after progress
  and consumed wakes being recreated after a limit. They now cover late
  reobservation, completed replay, successful continuation, and SQLite failure
  retaining the notification and resume state.
- Queue bypass and interrupted-wake recovery passed **271 tests in four suites**:
  `ACPSessionRunnerQueueTests`, `ACPSessionQueueAPITests`,
  `ACPSessionRunnerTests`, and `ACPSessionPersistenceTests`. The regressions
  first reproduced hidden payloads becoming recordable after bypass and
  interrupted wakes disappearing during fallback steering. They cover direct
  fallback and rejected native steering, successful atomic confirmation, and
  SQLite failure retaining the wake for explicit retry.

The recorded Xcode runs used the local `.build/xcode/DerivedData` directory,
`-skipPackagePluginValidation`, and `-skipMacroValidation`. The existing
Ghostty build script populated its artifact from the shared cache, and
`xcodegen generate` registered the two new Swift source files.
The final delivery-save selection used `COMPILER_INDEX_STORE_ENABLE=NO`
after local disk-space and signing failures, clearing only unused generated
compiler caches from this worktree before the successful rerun.
The teardown selection also used `-collect-test-diagnostics never` after
Xcode's failed-run system-log archive exhausted the disk; assertion output
remained in the test log.

The adapter-runtime probe and Swift tests exercise translation, ordering,
persistence and routing with in-memory provider inputs. No authenticated model
turn was used. Live-provider checks still needed are:

- Claude shell and monitor completion after `end_turn`, including provider-owned
  follow-up and a real `query.stopTask` cancellation.
- Codex shell completion, output, and task-specific termination, including a
  shell owned by a native child.
- App restart with a surviving broker, followed by intentional adapter
  replacement, verifying live task reannouncement and the loss notification.

Repository-wide CI is outside these local validation results.

## Other supported agents

Alas also supports Gemini, OpenCode, Cursor, Copilot and OMP. They were checked
for comparable contracts before limiting negotiation to Claude and Codex:

- OpenCode: Alas already negotiates `opencode/child-session-updates` and
  normalizes child updates into the native-subagent lifecycle. This is
  version-dependent native-child visibility, not a background-shell contract.
  No async-task events were found in the installed OpenCode 1.18.34 binary.
- Cursor: [the ACP documentation](https://prod.cursor.com/docs/cli/acp)
  documents `cursor/task` as a subagent completion notification. This does not
  establish a start/progress/task-specific cancellation contract. No installed
  Cursor adapter was available for a wire probe.
- Gemini: the [shell tool](https://github.com/google-gemini/gemini-cli/blob/main/docs/tools/shell.md)
  supports background execution. The inspected
  [ACP session source](https://github.com/google-gemini/gemini-cli/blob/main/packages/cli/src/acp/acpSession.ts)
  exposes ordinary tool updates and foreground cancellation, without a
  dedicated background-task lifecycle found in this inspection.
- OMP: installed version 18.2.11 has internal async-job types. The current
  [ACP event mapper](https://github.com/can1357/oh-my-pi/blob/main/packages/coding-agent/src/modes/acp/acp-event-mapper.ts)
  maps ordinary messages and tool execution, without async-job lifecycle
  events. Its cancel handler only aborts a pending prompt. These source
  observations do not prove the behavior of every OMP extension.
- Copilot: [upstream report #4743](https://github.com/github/copilot-cli/issues/4743)
  reproduces background-shell follow-ups after `end_turn` on CLI 1.0.84-1,
  without an advertised completion extension. This is a report about that
  version, not verification of a newer installed adapter.
- Pi: Alas's separate `PiInstaller` hooks bridge `subagent:async-started` and
  `subagent:async-complete` into coarse activity signals. They do not provide
  the task detail, durable lifecycle or Stop request needed here.

## Sources inspected

Package paths below are relative to the installed npm package directory:

- Claude: `dist/async-tasks.js`, `dist/async-tasks.d.ts`,
  `dist/acp-subagents.d.ts`, `dist/acp-agent.js`, `dist/air-extension.js`,
  `dist/native-subagents.js`, and `dist/tool-calls/renderer.js`.
- Codex: `dist/index.js`, specifically the bundled `CodexBackgroundTerminalTasks`,
  `AsyncTaskExtension`, `AirExtension`, `AcpToolCallRenderer`, and
  `CodexAcpServer` source sections.
- Pi: `dist/index.js`, its `handlePiEvent`, `cancel`, and extension UI handlers.
- Alas: `ACPSessionUpdate.swift`, `ACPConnection.swift`, `ACPSessionRunner.swift`,
  `ACPSessionManager.swift`, `ACPSubagentRowDescriptor.swift`,
  `ACPTerminalHost.swift`, `ComposerAction.swift`, and `ACPTabView.swift`.

Public adapter references:
[Codex background terminal tasks](https://github.com/agentclientprotocol/codex-acp#background-terminal-tasks)
and [Codex request handling](https://github.com/agentclientprotocol/codex-acp/blob/main/src/CodexAcpServer.ts).
