# CI flake audit: November 5–12, 2026

## Scope and evidence

The audit window is November 5 at 06:51 UTC through November 12 at 06:51 UTC.
It includes main and every pull-request branch, including failed attempts of
runs whose latest attempt succeeded. Cancelled runs were inspected for failures
that occurred before cancellation.

The window contains 524 workflow runs: 321 Build, 191 Test growth, seven Nightly
Build and five Release Artifacts runs. Build outcomes at the snapshot were 147
successes, 38 failures, 129 cancellations, one startup failure and six unfinished
runs. These outcomes are not counts of distinct flakes.

Job metadata was collected for all 195 failed, retried or cancelled runs, with
every attempt included. It contains 270 failed jobs, of which 192 are downstream
coverage-audit failures. The audit also checked all 13,950 available workflow
records for older runs retried during the window; none added failures.

Original attempt-qualified native test diagnostics were inspected when available.
Source comparisons use the actual checkout commit printed by the job, including
synthetic PR merges, rather than the Actions metadata's branch head.
The compact `swift-test-reports-N` artifacts are overwritten by reruns and cannot
establish an earlier attempt's result. One earlier steer failure's original
diagnostic artifact was no longer listed; its job log still names the failing
selector. Test growth run 42673864390 failed without any listed jobs, so there is
no test failure to attribute from that run.

## Repairs in this change

| Cause | CI evidence | Repair and local evidence |
| --- | --- | --- |
| Stdio termination before child publication | Seven `contentLengthFailureEndsConsumersWhileChildIsStillWaiting` failures, including [43115442021](https://github.com/mrmans0n/alas/actions/runs/43115442021) | Preserve termination requests under the process-publication lock and apply them as soon as the child is published. The original transport hung in 3 of 1,280 launches; forced early framing failure hung in all 16 attempts. A deterministic regression failed with the original 60-second hang and passed after the repair for both termination scopes. The original 1,280-launch check then had zero hangs. |
| Delayed callbacks use a reused tunnel address | Recurring proxy failures, including [43112430618](https://github.com/mrmans0n/alas/actions/runs/43112430618) | Give every admitted tunnel a UUID instead of its object's address. A callback from a retired tunnel can no longer close a later tunnel at the same address. An actual-module 6,400-connection workload changed from 287 empty replies to zero. The existing eight-test egress suite passed 30 repetitions. |
| Proxy fixture delays its first request until the test executor resumes | Empty initial half-close replies and resolution-cap waits in [43112430618](https://github.com/mrmans0n/alas/actions/runs/43112430618) | Send initial protocol bytes on the network-ready callback. A controlled six-second caller delay produced an empty reply with the old fixture and the expected 407 reply when sending on readiness. The production five-second header deadline remains unchanged. |
| Rust cancellation fixture observes an unrelated startup message | [43156875888](https://github.com/mrmans0n/alas/actions/runs/43156875888), [42674814935](https://github.com/mrmans0n/alas/actions/runs/42674814935) | Carry the cancellation request in the fixture event instead of reading the last recorded request. Gate the existing test so `mcp_hello` arrives after cancellation. The original assertion failed with `Null` versus `computer_cancel`; the repair passed 30 exact repetitions and three complete ten-test target runs. |
| Native hover observation uses a fixed delay | [43071796011](https://github.com/mrmans0n/alas/actions/runs/43071796011) | Await the dwell and request tasks before checking the popover and request count, including after movement within the symbol. Passed in the final native run. |
| Next steer waits for persistence longer than the fixture's observation budget | [43011388583](https://github.com/mrmans0n/alas/actions/runs/43011388583), [42590703292](https://github.com/mrmans0n/alas/actions/runs/42590703292) | Await the next submission callback, retaining the refusal, queue and dispatch assertions. A controlled actual-runner persistence gate makes the old one-second predicate fail while the eventual accepted dispatch succeeds. Passed in the final native run. |
| Remote fixture assumes a released preferred port stays free | [42344370202](https://github.com/mrmans0n/alas/actions/runs/42344370202), [42332990408](https://github.com/mrmans0n/alas/actions/runs/42332990408) | Await the listener's port callback and use its actual bound port. An actual-server occupied-port probe confirms fallback to a different working port. Passed in the final native run. |
| Broker fixture reorders ordered publications while recording them | [42072987208](https://github.com/mrmans0n/alas/actions/runs/42072987208) | Yield directly into a stream on the callback stack, then await cursor 0 and cursor 5. A controlled actual-client probe makes the old count predicate permanently false after delayed recording; direct stream recording preserves the expected sequence. Passed in the final native run. |
| Optional telemetry uploads fail the build | [43090228648](https://github.com/mrmans0n/alas/actions/runs/43090228648), [43090151304](https://github.com/mrmans0n/alas/actions/runs/43090151304) | Make only build measurements and the compact build summary uploads nonfatal. Test plans, compiled products and coverage reports remain required. The workflow contract failed before the change and passed afterward. |
| Broker ACK mirror races detach and publishes the wrong terminal status | [42704412114](https://github.com/mrmans0n/alas/actions/runs/42704412114) | Recheck transport and ownership authority before classifying a rejected mirror as failure. The fifth local full run reproduced the original preview-loss timeout. Minimized fixtures exposed `failed("invalidated")` with an already invalid intake. The deterministic regression failed before repair, then passed transport-loss, ownership-loss and genuine-attached-failure variants. The fixed actual-fixture loop passed 2,000 iterations after the old implementation failed twice in 1,000. |

Dependency acquisition now has at most three attempts for the observed SwiftPM
HTTP 400, missing shared-checkout and rustup DNS errors. Missing-cache recovery
bypasses the shared cache without deleting it. Unknown errors and interruption
statuses return immediately. Resolution is separate from the single test
invocation; compilation and tests are never retried. Exact Xcode 26.6 help and a
cold pinned-package resolution verified the flags. The fixture harness failed
before implementation and passes, including explicit 130/143 and real SIGTERM
cases.

The required test-plan upload has one official-action fallback after an initial
failure, replacing any partial artifact with the same name and contents. The
fallback remains fatal. The workflow contract failed before this fallback was
added and passes with the required product/report/coverage gates preserved.
No assertion, coverage exclusion or production deadline is relaxed by these
repairs.

The output-cap launch regression now forces the early-termination window with
two real children instead of launching 400 writers concurrently. A task-local
factory controls the launch observation while retaining real pipes, signals and
reaping. Removing only the existing post-launch checks makes both variants hit
the original 15-second watchdog; restoring them produces the expected capped
output. The overlapping single-writer test was removed. This reduces the suite
from 401 children to two and removes one test definition. Historical slow mocked
operations coincided with the burst, but that correlation does not establish
the cause of the outstanding session or cancellation timeouts.

## Failures already repaired on main

| Failure | Evidence and current repair |
| --- | --- |
| Compiled test products reject rolling macOS patch versions | Eleven restore failures precede `98c7fa046`. Xcode and architecture still must match; an OS patch mismatch now warns. All four restores passed in run 43156875888 attempt 2. |
| Output-cap termination arrives before Foundation marks a child running | Failed heads in runs 42098124157 and 42224676712 lack the post-launch retermination check now present in `Process.runData` and `runCapped`, carried by merged `329d724ec`. |
| Host shutdown fixture assumes task resumption order | The two `shutdownWaitsFor…` failures precede `9522e4b37`, which awaits shutdown's first suspension. |
| Adapter payload fixture gets a libc variant's name | Run 42669165378 used a head without the preferred exact-platform name selection now included in `77d8f2619`. The unchanged current five-layout parameterized test passed locally. |
| Shell session fixture and transcript recovery persistence | `370cc245c` replaces the Xcode Python shim in the session test and awaits persistent warning clearance in the recovery test. |
| Browser viewport assertion includes classic scrollbars | Run 42013866385 precedes the final `5463b063a` viewport test and layout-width repair. The old and merged assertions were compared directly. |
| Nightly simulator-shim assembly failure | Run 42021618805 checked out `cf23c83e`, before `7121e4c09` repaired cross-object subtraction relocations in `ThirdParty/serve-sim-native`. The failed temporary `.s` was preprocessed from that vendored source. Its exact old source reproduced all four assembler errors under CI's Xcode 26.6; the existing release harness passed current assembly and C shims for both arm64 and x86_64. This was a deterministic source failure already repaired later on November 5. |

## Infrastructure and open investigations

- All 192 coverage failures have failed, cancelled, skipped or abandoned upstream
  work. No successful build with four successful shards failed coverage on its
  own. Abandoned runs can have no build job in the listing.
- Eleven formatting failures are deterministic source failures, not flakes.
- SwiftPM failed before running tests twice: an HTTP 400 clone failure and a
  missing shared-cache repository. The missing directory's underlying cause is
  not established.
- A required test-plan upload failed DNS resolution in run 43011388583. Required
  artifacts must remain gates. A Rust toolchain download likewise failed DNS
  resolution in run 42659807169.
- Recurring core session/event timeouts and the SIGTERM-ignoring run cancellation
  timeout remain under investigation. The old broker deadline-open test only
  received a 3-to-30-second assertion allowance, and the subscriber helper changed
  from 10 to 60 seconds; neither change proves a root-cause fix. Successful local
  repetitions do not establish these historical failures fixed. Exact checkout
  comparisons show the cancellation implementation is unchanged. Default local
  Xcode 27.1 and CI's Xcode 26.6 were checked separately.

## Validation status

The original full core baseline passed 1,273 tests in 129 suites. A focused event
baseline passed 241 tests in eight suites. With the startup regression added,
the exact CI toolchain, Xcode 26.6/build 17F113 and Swift 6.3.3, passed 1,274 tests
in 129 suites. A constrained-scheduling run passed the same inventory. The fifth
repeated full run reproduced the preview-loss failure at line 37, leading to the
broker mirror repair above. Its final full core run passed 1,275 tests in 129
suites. Ten subsequent complete runs passed the same inventory, alternating
ordinary and constrained cooperative scheduling, for 12,750 passing definition
executions. Repetition stops at the first failure and retains its evidence.
These results do not establish the other historical event timeouts fixed.

After replacing the process burst, the final core inventory passed 1,274 tests
in 129 suites in 19.169 seconds with the same CI toolchain. Both cap variants
also passed ten focused repetitions. Independent review caught and corrected a
launch-latch ordering gap in the new fixture, then confirmed the post-launch
guards, task-local scope, exact outcomes and reaping assertions.

The final native run executed 272 tests in seven suites with zero failures or
skips. It covers the four complete changed suites and the three already-repaired
historical selectors. All eight audited native selectors executed and passed.
The controlled original hover assertion failed while its response gate was
held, then the restored final test passed. The native test repairs also received
an independent review with no findings.

The startup/framing and shared proxy-fixture selection passed 21 tests in three
suites. The real SIGTERM-ignoring cancellation stress checks completed 256 owned
process trees successfully, half under the strict-pool environment, including
reaping checks for captured descendants. They do not establish the old CI
hang's cause. The exact V1 session fixture also passed 5,600 complete executions,
including 2,000 inside Swift Testing; its historical first-permission timeout
remains unreproduced.
Independent runtime review found no introduced runtime defect and caught a
configuration-dependent test-hook declaration, which was corrected. CI helper
review found an interruption-retry bug, which failed a new regression before
repair and passed reviewer recheck afterward. The acquisition, workflow,
AlasHelper and AlasCLI shell harnesses pass. Scoped SwiftFormat, Rustfmt with the
crate's 2024 edition, shell syntax and `git diff --check` pass. Hosted CI remains
unverified for this branch.
