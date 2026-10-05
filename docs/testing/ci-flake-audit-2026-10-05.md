# Swift CI flake audit — 2026-10-05

The audit covered 317 failed Build runs created from September 21 through
October 5, including 53 runs on main. Job logs identify failed selectors;
the retained test-log artifacts provide the assertions and ordering evidence.
Failures on an older PR head are compared with current main before changing code.

## Corrections in this change

| Behavior | Evidence | Cause and correction |
| --- | --- | --- |
| Claude usage limit announced through agent text | [main run 37245761108](https://github.com/mrmans0n/alas/actions/runs/37245761108) | The prompt error can overtake its update stream. A flushed prefix is also discarded when a suffix remains buffered. Wait for the captured update watermark and combine transcript and buffered text without forcing a coalescer flush. Preserve buffered-only detection when ordinary output precedes a complete limit message. |
| A replacement inference request suppresses the old result | [main run 37284721334](https://github.com/mrmans0n/alas/actions/runs/37284721334) | Creating the replacement task does not mean it has preempted the first evaluation. Wait for the cancellation event before releasing the old evaluation. |
| GG land cancellation reaches the runner | [main run 37219179665](https://github.com/mrmans0n/alas/actions/runs/37219179665) | One yield does not establish that consumption started; a fixed yield count does not establish termination. Await both events. |
| Fork takeover prevents context delivery | [main run 37238120628](https://github.com/mrmans0n/alas/actions/runs/37238120628) | The takeover polling task can run after delivery. A fixture SQLite trigger seizes the fork during the source lease claim. |
| Canceling one Mermaid consumer preserves a shared render | [main run 37173884550](https://github.com/mrmans0n/alas/actions/runs/37173884550) | The second task was not guaranteed to register before cancellation. Register it under service isolation, await cancellation processing, then finish the fake backend. |
| Suggestions resume after delegated child work ends | [main run 37250999275](https://github.com/mrmans0n/alas/actions/runs/37250999275) | A queued `.unloading` projection can reject and permanently consume a completed turn even after readiness is established. Enabled, verified suggestions may queue behind a native drain; unavailable and retry-required states still deny work. |
| Lease observation invalidates a suggestion synchronously | [PR run 37094727634](https://github.com/mrmans0n/alas/actions/runs/37094727634) | The automatic heartbeat competes with the explicit test tick. Cancel and drain the automatic heartbeat before driving takeover. |
| Attach restart and transcript recovery ordering | [main run 36636676214](https://github.com/mrmans0n/alas/actions/runs/36636676214), [main run 36761036683](https://github.com/mrmans0n/alas/actions/runs/36761036683) | Two-second overrides and a 500 ms gate wait were shorter than the suite's shared deadline. Reuse its bounded condition waits. |
| Field-editor undo, binding, and submit | [PR run 36951198633](https://github.com/mrmans0n/alas/actions/runs/36951198633) | The harness allows SwiftUI to reapply a stale binding after synchronous undo. Assert undo first, then submit and verify the synchronized binding. |
| Inlay retention during an unanswered refresh | [main run 35980534936](https://github.com/mrmans0n/alas/actions/runs/35980534936) | The real two-second presentation watchdog can expire during a slow test. Inject the expiry clock; advance it explicitly in the existing expiry tests. Production still expires after two seconds. |
| Loopback HTTP/WebSocket setup | [PR run 37140341740](https://github.com/mrmans0n/alas/actions/runs/37140341740) | `connectx` reports `EADDRINUSE`, leaving the connection waiting for a path change that does not occur. Use an OS-assigned loopback source endpoint and bounded restarts for that specific setup error; surface other waiting errors immediately. |

Only one new test definition is added, parameterized over runtime availability
states. The text-ordering regression extends an existing test. Other changes
correct fixture synchronization or replace wall-clock expiry with a controlled clock.
No suite is newly serialized, quarantined, or moved into a subprocess.

## Earlier failures already addressed on main

| Failure family | Current-main evidence |
| --- | --- |
| Git template copies lose `objects/maintenance.lock` | CI disables auto-maintenance, auto-GC, and receive auto-GC since `9246476ef2`. |
| Process memory can shrink despite a new allocation | The process-wide growth assertion was removed in `e9294eb28`. |
| Local model locks survive forked children; settings removal hangs | `ac91e70b7` explicitly unlocks the lease before closing its descriptor. |
| Run-record assertions race launch/monitor completion | `ac91e70b7` awaits lifecycle completion instead of short sleep budgets. |
| Mermaid attachment request detection; remote restored persistence; peer rollback; browser fragment history | Event/deadline/persistence corrections are in `ac91e70b7` and `2df330221`. |
| Terminal descendants and streamed GG process termination | Tracked-orphan waiting and blocking-work isolation are in `1b5c8b2aa` and `df1f69964`; GG collection also uses a deadline. |
| Broker extension replies and restored queue expectations | Specific reply IDs are awaited in `657001d78`; the changed uncertainty behavior is reflected in current queue tests. |
| Expensive workspace deletion fixtures | Template reuse is in `5b2aaa916`; the historical unowned-deletion case passed locally on current main. |
| Inline mention alignment | The old selector was replaced by the baseline-alignment change in `f52257eb7`. |
| Soft diff-output cap and remote web controls | Current main contains `5fe595115`: the cap test accepts intentional refusal, and web assertions match the current controls. |
| Mounted inlay edits, external rename, detached tabs, and plugin reply/file traces | Current tests contain the later synchronization and trace corrections, including `a7aa894f2`, `5635f2e64`, `cefd429d0`, and `5e47ddfff`. |
| Remote launch/attach fixtures using obsolete host routing | Current fixtures use virtual remote paths and the resolved host identity. |

The adapter-release PR's missing-executable failures are deterministic fixture
failures, including the subsequent gated-test hangs. Current main contains the
corrected package fixtures. `AlasTests/S0/test()` in workflow-contract output is
an intentional failure fixture, not an app test to repair.

## Validation

The strengthened baseline ran 219 tests in six suites and failed exactly the
split usage-limit message and runtime-drain eligibility cases. After the fixes,
430 tests in seven affected suites passed. A separate selection of 121 tests in
six suites passed, including the historical workspace-deletion and inlay-layout
cases. The final clock/socket selection passed 50 tests in three suites.
Review extended the usage-limit regression to ordinary flushed output before a
complete buffered limit: 102 queue tests failed only that variant before its
fallback was added. The corrected queue, runner, and inference suites then
passed in a selection of 251 tests across three suites.
SwiftFormat lint and `git diff --check` passed. Configured CI remains a separate
verification gate.

The local Network framework probe ran 1,000 connections each with default,
explicit loopback source, and address-reuse parameters. All passed; the probe
did not reproduce the CI collision. The collision diagnosis comes from the CI
`connectx` errors. The fixture recovery uses Apple's documented
[restart of a waiting connection](https://developer.apple.com/documentation/network/nwconnection/restart%28%29).

No local whole-plan run substitutes for configured CI. A green historical run,
a canceled run, or a build-only pass does not establish that the current Swift
shards passed.
