# CI flake audit: October 7–11, 2026

## Coverage

Inspected 659 Actions runs created from October 7, 00:00 UTC through the October 11 morning snapshot, across main and pull requests. Build outcomes: 27 failures, 122 successes and 225 cancellations. Inspected every available attempt of 42 Build runs that failed or had been retried, including successful retries. Cancellations are not counted as test failures.

One historical Build log ([37655036345](https://github.com/mrmans0n/alas/actions/runs/37655036345)) was unavailable. This audit does not establish its cause or promise that the repository has no other flakes.

## Repairs

These changes retain the existing assertions and configured CI coverage. They add no exclusions, serialization or production behavior changes. The only app change corrects a comment about task resumption order.

| Failure | Evidence | Repair |
| --- | --- | --- |
| Visual-aid concurrent answers | Seven runs, including [38089877514](https://github.com/mrmans0n/alas/actions/runs/38089877514); reproduced locally on iteration 14 | Register both waiters before releasing the first write, then require exactly one winner and the same winning answer in memory and SQLite. Continuation resumption order is unspecified. |
| Bootstrap overdue scheduled queue | Three runs, including [38081470884](https://github.com/mrmans0n/alas/actions/runs/38081470884) | Wait for prompt dispatch and in-memory queue consumption, then flush persistence before reading SQLite. Dispatch alone is not completion. |
| Completed output at lease takeover | [37722896023](https://github.com/mrmans0n/alas/actions/runs/37722896023) persisted only `hello ` | Wait for both emitted chunks to reach the runner's pending buffer. Keep the coalescer pending until immediate takeover and stop, rather than relying on a 250 ms sleep. |
| Retired transcript views | [38054719525](https://github.com/mrmans0n/alas/actions/runs/38054719525), on a commit containing the prior deadline fix: 571 text views against a bound of 559 | Wait for all three existing detached/host/text bounds together, using the same ten-second deadline. Report counts on failure. |
| Detached process cleanup fixtures | [37842899403](https://github.com/mrmans0n/alas/actions/runs/37842899403): both child PID prerequisites missing | Wait for fixture signal handlers and launcher readiness before invoking the real process tree's termination path. Block SIGTERM during the first child fork setup. Separate streaming tests retain watchdog timeout and grace coverage. |
| ZMX PTY leadership sizing | Four runs, including post-fix [38103246021](https://github.com/mrmans0n/alas/actions/runs/38103246021), saw `55 123` instead of `40 120` for the entire deadline | Disable interactive bash line editing and await ZMX task completion before testing leadership. Readline's terminal-size read/write can overwrite a daemon resize. Retain all leadership/geometry assertions and add stage diagnostics. |

The ZMX race was reproduced using the actual Swift fixture and production IPC/client sources, and independently using raw IPC. The original raw host-reclaim case logged a successful daemon resize to `40 120` followed by a shell reporting `55 123`. The revised Swift fixture passed 50 consecutive runs; the revised raw fixture passed 200 transitions with delayed dimension replies. [Apple's bash source](https://github.com/apple-oss-distributions/bash/blob/main/bash-3.2/lib/readline/rltty.c) contains the terminal-size read/write involved. These standalone checks do not substitute for hosted native CI.

## Failures already addressed on main

- SQLite lock waiting: the lock fixture now waits for an explicit release instead of sleeping (#1866).
- Auth-required attach cleanup: the test now waits for client shutdown as well as runner removal (#1898).
- Sidebar pull notification: prior fix increased the error-observation deadline (#1898); the observed failures precede that fix.
- Scheduled persist rollback: the failed PR revision ran sequence-gap repair even for an empty transcript and consumed the fixture's first lease fence. The final #1868 change skips that repair. The unchanged rollback test passed 20 local iterations on current main.
- Cold CI batch watchdog: the observed 365.67-second batch preceded the 480-second watchdog adjustment (#1898).
- Draft-cleanup hosted skips: this feature and its evaluation were explicitly reverted for v0.21.0. No removed feature or exclusion is restored here.

## Other findings and limits

Formatting and compilation failures are deterministic failures, not flakes. An artifact-upload DNS failure ([37961327635](https://github.com/mrmans0n/alas/actions/runs/37961327635)) is infrastructure failure.

One real browser integration test timed out in [37584956326](https://github.com/mrmans0n/alas/actions/runs/37584956326). Its artifact reports only the generic automation deadline, without identifying which operation failed. No specific browser bug or safe repair was established from that evidence; it remains an investigation item rather than a timeout increase or quarantine.

## Local validation

- Visual-aid answer test: original current-main test failed on iteration 14; revised test passed 20 iterations.
- Unchanged scheduled rollback test: 20 iterations passed alongside the answer test.
- ZMX: actual Swift fixture red/green and raw IPC stress results described above; native app-host validation is reported separately in the pull request.
- Focused native app-host run: 222 tests across `ACPSessionManagerTests`, `ACPSessionManagerAttachRestoreTests`, the completed-chunk takeover regression, `ACPTranscriptScrollerConvergenceTests` and `GGCommandRunningStreamingTests` passed.
- Detached-process fixtures: 40 repeated real-process checks passed. Disabling descendant SIGKILL in a temporary copy failed the child-exit assertion, confirming fixture cleanup does not mask the regression.
- SwiftFormat lint: 0 of 2,239 files require formatting. `git diff --check` passed.
- Further repetition, native ZMX and exact-head CI results are reported in the pull request.
