# CI flake audit: November 13–16, 2026

## Scope

The fixed audit window is November 13 at 21:19 UTC through November 16 at
21:19 UTC. It includes main and every pull-request branch, successful reruns'
earlier attempts, and failures recorded before cancellation.

The inventory contains 489 workflow runs: 289 Build runs, 195 Test growth
runs, three Nightly Build runs, one iOS Release run and one Release Artifacts
run. Build includes 75 main pushes and 214 PR runs. Its snapshot has 104
successes, 25 failures, 157 cancellations and three unfinished runs.

Job metadata for all failed, cancelled, unfinished or retried runs covers 227
attempts and 2,325 jobs. There are 81 failed jobs outside the downstream Swift
coverage gate and 188 failed coverage jobs. The audit also read the logs of
154 cancelled jobs whose test step had started but did not succeed. Two had
already recorded test failures, including the pipe-write case below.

All 14,053 available older workflow records were checked for retries during
the window; none added a failed attempt. One earlier main run completed in
the window and succeeded. Comparisons use the actual checkout SHA from job
logs, including synthetic PR merges. Original attempt-qualified result bundles
were used where successful reruns had replaced compact report artifacts.

## Repairs

| Cause | Evidence | Repair |
| --- | --- | --- |
| Process-source callback reads a destroyed Swift wrapper | [43943288348, attempt 1](https://github.com/mrmans0n/alas/actions/runs/43943288348/attempts/1), `ACPStdioClientTests.roundtrip`, aborts with an unowned-reference fatal error. An actual-source process-exit/cancellation probe reproduces the same abort and identifies `ForkWatch.start` in the crash stack. | Capture the dispatch source weakly and retain it only during callback delivery. A bounded regression exercises actual process exit and concurrent observer cancellation. |
| Explicit broker replay joins an older ACK-triggered page | [43938115349](https://github.com/mrmans0n/alas/actions/runs/43938115349), Linux aarch64, observes nil instead of a newer same-key outcome. A held attach reproduces it deterministically. | Explicit replay requires a fresh page after joining an older poll. The existing consumption-authority test now controls that ordering. Cursor-specific consumption protection remains intact. |
| Harness fixture blocks in Foundation's exit wait | [43911893741](https://github.com/mrmans0n/alas/actions/runs/43911893741), main checkout `3e4ea493`, watchdog sample identifies deferred `Process.waitUntilExit` in `detectsCodexBehindNodeLauncher`. The child is absent from the captured descendants. | Use the existing `SpawnedProcess` reaper and await its termination state. The original Foundation hang was not reproduced locally; the CI stack directly identifies its blocking cleanup. |
| Old symbol-index consumer is cancelled before it drains the final snapshot | [43914460784, attempt 1](https://github.com/mrmans0n/alas/actions/runs/43914460784/attempts/1), `newerRefreshWins`, observes an incomplete old snapshot. A controlled stream schedule reproduces cancellation discarding the final buffered value. | Drain the finite stream naturally while the superseded listing remains gated. |
| Queue handoff is observed before prompt completion | [43812042978, attempt 1](https://github.com/mrmans0n/alas/actions/runs/43812042978/attempts/1), `detachBeforeQueuedPromptHandoffKeepsPromptEligible`, observes `.sending` after the mock records the prompt. | Await the queue's completed state before flushing and checking persistence. Retain the operation-key and actual-send assertions. |
| Released preferred port is taken before the forwarder binds | [43783459761](https://github.com/mrmans0n/alas/actions/runs/43783459761), localhost case returns a valid fallback URL. A controlled competing listener makes the original assertion fail. | Let the real forwarder allocate port zero, then use its returned port. Preserve URL components, bidirectional payload, occupied-port fallback and shutdown checks. |
| Freshly written fixture executable is busy at exec | Android tests fail repeatedly, including [43940862769](https://github.com/mrmans0n/alas/actions/runs/43940862769). Host upgrade and bundle tests report Linux POSIX 26, including [43951447383](https://github.com/mrmans0n/alas/actions/runs/43951447383). | Use a checked-in adb script and copy the host in a short-lived `cp` process, which exits before the new executable launches. Hosted Linux verification is required; Darwin cannot reproduce Linux ETXTBSY itself. |
| Socket fixture abandons its reader on an interrupted syscall | [43791293848](https://github.com/mrmans0n/alas/actions/runs/43791293848) and [43767692760](https://github.com/mrmans0n/alas/actions/runs/43767692760) time out waiting for events or replies. A directed-signal probe makes the original reader exit with its response still unread; the repaired loop delivers it. The hosted logs do not establish that a signal caused those particular failures. | Retry EINTR while retaining EOF and genuine-error termination. Forward each wait's source location so another failure identifies the actual request or event wait. |

The cancelled Linux run [43940214134](https://github.com/mrmans0n/alas/actions/runs/43940214134)
also recorded `ordinaryPipeFailureEndsObservationInsteadOfLeavingAPoisonedAdapterAlive`:
the first write succeeded after the adapter closed stdin. The pipe factory's
plain `pipe()` followed by `fcntl(FD_CLOEXEC)` permits an unrelated concurrent
spawn to retain a reader. A controlled POSIX probe reproduces a successful
write while that child lives, followed by EPIPE when it exits. The hosted log
does not capture the descriptor holder, so that individual attribution remains
an inference. The Linux factory now replaces its unpublished Foundation pipe
with endpoints created by `pipe2(O_CLOEXEC)` and installed with
`dup3(O_CLOEXEC)`. An inherited placeholder cannot hold the real transport
open. The C shim compiles for both hosted Linux architectures; hosted execution
of the Linux-only inherited-reader regression is still required.

## Existing repairs and other failures

- PR #2519 already repairs the earlier listener starvation, Rust HTTP framing,
  Rust executable-script launch, native process-output and browser-startup
  failures. The original failures remain in this window; they are not new fixes.
- PR #2509 updates the five native source-contract assertions for `ForkWatch`
  and `ProcessTable`. PR #2533 updates the phone git capability assertion.
  These were deterministic branch failures, not new flakes.
- The Linux port in PR #2517 closes git pipe read ends, marks child descriptors
  close-on-exec and bounds Linux test parallelism below Foundation's descriptor
  scan limit. It also treats unreaped zombies as dead in cancellation tests.
  The earlier Linux crashes, descriptor-count assertion and process-cleanup
  failures precede those final changes. Some repository-creation failures in
  the same earlier runs have no captured unique cause.
- PR #2538 replaces an unsafe closed-descriptor-number assertion with peer EOF.
  The earlier SSH setup fixture launch failures already have the inline-shell
  repair at `343e122c`.
- Three macOS file-byte failures immediately follow a 30-second
  `git cat-file --batch-check` stdin watchdog. Their checkouts exclude PR #2544's
  synchronous small-stdin repair. The current starvation regression and actual
  file-read test both pass locally.
- A session/event timeout cluster in run 43850823877 occurred after #2519 but
  before #2544. Its Harness suite passed. Scheduling or stdin starvation is
  consistent with the logs, but those logs do not prove a unique cause. The
  separate Linux socket-session timeout also remains historically unattributed.
- Dependency constraints and outdated pins, formatting, Linux compile errors,
  an iOS compiler crash, a missing scrcpy fixture and notarization failures were
  classified separately. The scrcpy harness now has the required fixture and
  passes locally. Synthetic `S0` failures printed by the inventory harness are
  expected harness inputs, not actual app test failures.

## Local verification before submission

The final integrated checkout on main `2903c4b25`, with these repairs, passed
all 1,529 Core tests in 165 suites in 19.589 seconds using Xcode 26.6. The
focused Android, host executable, port-forward and fork-observer selection
also passed all 51 tests. The writer selection passed six tests, and socket
server plus the exact socket-session scenario passed four tests. The broker
and Harness selection passed 56 tests, including related raw helper tests.

The pipe C shim compiles for both `x86_64-linux-gnu` and
`aarch64-linux-gnu` with `-Wall -Wextra -Werror`. Its exact substitution and
failure-cleanup body also passes controlled POSIX probes on Darwin with
Linux syscall shims. This is not a substitute for the hosted Linux-only test.

Scoped SwiftFormat, `git diff --check` and the resource-embedding shell harness
pass. Native app tests and hosted Linux execution are separate shipping gates;
these local results do not establish their outcome. No production deadline,
coverage exclusion or test retry policy is relaxed by these repairs.
