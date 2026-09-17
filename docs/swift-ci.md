# Swift CI coverage

CI builds the test target once, then asks Xcode to enumerate the compiled tests
with `test-without-building -enumerate-tests -test-enumeration-style flat
-test-enumeration-format json`. No Swift source is parsed. The inventory and
execution therefore use the same toolchain, target, configuration, and canonical
test identifiers.

`scripts/ci_swift_tests.py plan` rejects enumeration errors even if Xcode returns
zero, empty inventories, duplicate identifiers, stale policy selectors, overlapping
policies of the same kind, and disabled tests without an explicit exclusion. Every discovered test
is assigned once to execution or an exclusion in `scripts/ci-swift-test-policy.tsv`.
New tests default to ordinary execution without editing that file or the workflow.

The policy records selectors, execution requirements, reasons, and tracking issues.
Ghostty runtime smoke, SSH integration, live LSP verification, and Gemini E2E
remain explicit opt-ins outside PR CI. The three historically disabled subprocess
suites retain #23 as their follow-up. The subprocess list preserves the conservative
isolation baseline gathered during #1277; it does not assert every listed suite
individually reproduced a hang. Shrink it using measured runs, not source heuristics.

Six ordinary batches run sequentially on the build runner after it publishes the
compiled products. Two additional runners split the subprocess invocations by
measured duration, preserving invocations of at most three suites. Each invocation
has a wall-clock deadline, including startup and teardown: 360 seconds ordinary,
120 seconds subprocess. The explicit `slow-subprocess` policy allows 360 seconds
for measured longer-running suites: the checkpoint fault-injection suite passed
locally in 229 seconds (286 seconds for its three-suite invocation). Planning
checks that invocation limits plus termination and result-extraction allowances
fit each 30-minute subprocess step. Tests retain Xcode's 60-second execution allowance.
Failures do not prevent later invocations or batches from collecting evidence.

Quarantine overrides execution requirements independently of policy order. For
partially excluded suites, Xcode receives individual runnable test identifiers;
the remaining tests retain their suite's subprocess isolation. Known failures
exposed by the expanded baseline are tracked in #1297, and the earlier workspace
undo timeout in #1292. Removing an exclusion restores automatic execution.

The first native-discovery run, [35216158495](https://github.com/mrmans0n/alas/actions/runs/35216158495),
discovered 10,657 definitions, excluded 189, and executed 10,255 with no runtime
skips. It reported 34 failed definitions and 213 unaccounted definitions in four
timed-out invocations. All twelve batches ran and their diagnostics were uploaded.
These are baseline measurements, not a passing result; subsequent runs publish
their own counts and per-invocation durations in the job summary and artifacts.

The next run, [35222266640](https://github.com/mrmans0n/alas/actions/runs/35222266640),
accounted for all 10,305 scheduled definitions: 355 explicitly excluded, zero
runtime skips, zero unaccounted results, and zero invocation timeouts. Eleven
definitions failed assertions or Xcode's individual-test deadline. The follow-up
policy excludes ten exact definitions under #1297; the remaining fixture replaces
a fixed refresh sleep with a bounded condition wait. Measured batch totals:

| Batch | Executed definitions | Seconds |
|---|---:|---:|
| ordinary-1 | 1414 | 105.43 |
| ordinary-2 | 1206 | 76.49 |
| ordinary-3 | 1247 | 181.21 |
| ordinary-4 | 1253 | 71.22 |
| ordinary-5 | 1577 | 91.95 |
| ordinary-6 | 1253 | 63.19 |
| subprocess-1 | 466 | 448.98 |
| subprocess-2 | 314 | 125.89 |
| subprocess-3 | 354 | 209.96 |
| subprocess-4 | 391 | 175.43 |
| subprocess-5 | 379 | 146.56 |
| subprocess-6 | 451 | 175.63 |

The following run, [35228291381](https://github.com/mrmans0n/alas/actions/runs/35228291381),
again assigned every definition, produced no runtime skips or missing results,
and passed all six subprocess batches. Its sole failure was
`RenameFeatureTests/unopenedPreviewTargetsHaveNormalUndoInInitiatingEditor(resourceOnly:)`:
it passed focused execution but failed in ordinary batch 3. That exact parameterized
definition is quarantined under #1297; its sibling rename tests remain scheduled.

The successful unsharded run
[35234212370](https://github.com/mrmans0n/alas/actions/runs/35234212370) is the
distribution comparison baseline. Its `build-test` job used 38m48s of wall and
runner time. Checkout, preparation, the single build, and discovery took 13m57s.
The twelve sequential test steps took 24m02s: 7m35s ordinary and 16m27s
subprocess-sensitive. Uploading 625 MB of result diagnostics took another 43s.

Run [35241461269](https://github.com/mrmans0n/alas/actions/runs/35241461269)
validated a build-once, two-shard prototype against the same runner image. The
compiled products restored and passed toolchain validation on fresh shard
runners, but the end-to-end run took 1h21m55s from workflow creation to the final
coverage audit failure. The build job took 21m51s, including 30s to package the
compiled products and 6s to upload them. Shard queue delay dominated the result:
shard 1 started 16m46s after the build job completed, and shard 0 started 33m
after the build job completed. The shard test steps then ran 14m26s and 17m25s.
This does not meet the adoption bar of saving at least five minutes of wall time.

That same prototype also failed because of existing flaky tests, not because the
compiled products were non-portable. `TabActivityIconTintTests/
acpTabAddsAgentLogoWhenAgentIsResolved()` and
`ACPTerminalTests/releaseReachesOrphans()` failed in both the sharded prototype
and unrelated PR #1293's ordinary `build-test` run
[35244403629](https://github.com/mrmans0n/alas/actions/runs/35244403629).
PR #1293 also failed
`AgentTerminalLaunchTests/launchingCopilotForRemoteWorktreeSkipsLocalHookInstall()`.
The sharded prototype additionally timed out `subprocess-1-3` after 360s before
Xcode produced a readable result bundle, leaving 28 scheduled definitions
unaccounted in the final audit.

After the test reliability fixes in #1302 and #1303, passing run
[35254121181](https://github.com/mrmans0n/alas/actions/runs/35254121181) provides a
new baseline: 48m30s of macOS runner time, or 50m39s including initial queue time.
Preparation and discovery took 2m15s, compilation 18m34s, ordinary tests 8m47s,
subprocess tests 17m47s, and diagnostics/cleanup about one minute.

The next experiment prioritizes elapsed time with three execution lanes. The
builder publishes a tar archive of compiled products and runs ordinary tests
itself. Two workers queue at workflow start and wait up to 60 minutes for that
attempt's artifact. They stop early if the builder completes without publishing.
This avoids the second macOS queue that dominated the previous experiment, at
the cost of paying for idle workers during compilation. With similar runner
speed and short initial queues, the target is 31–34 minutes elapsed and roughly
90–100 macOS runner minutes, versus 48m30s in the baseline. These are estimates;
the old prototype's runner-minute adoption criterion does not fit this deliberate
tradeoff. Record actual queue, wait, setup, transfer, test, and upload durations
before declaring the experiment successful.

`scripts/ci-swift-test-timings.json` records exact invocation selectors and elapsed
seconds from that passing baseline. Planning places the longest subprocess
invocations first on the least-loaded worker. Baseline estimates are 535.36s and
530.57s. Changed or new selector groups use their invocation timeout as a
conservative estimate and remain scheduled. Ordinary work stays on lane zero.
No global Swift Testing parallelism is enabled. Each worker executes sequentially,
so host preferences, environment, pasteboard, and process state are not shared
between simultaneously executing invocations on the same host.

Workers use `test-without-building -xctestrun` with the archived products, including
embedded runtime resources. The tar archive preserves executable permissions and
symlinks. Xcode version, macOS version, and architecture must match the builder.
The coverage audit runs even after a failed lane, requires every Swift job to
succeed, and reconciles all invocation reports. Every lane uploads diagnostics
even on failure. Artifact names include the run attempt to reject stale evidence;
use **Re-run all jobs**, not a partial rerun, for this coordinated experiment.

Each invocation stores its selectors, expected tests, duration, exit status, logs,
result bundle, and structured test outcomes. The final audit rejects missing tests,
unexpected tests, failed tests, unapproved runtime skips, and incomplete invocations.
Counts refer to test definitions, so a parameterized function counts once; its
individual arguments remain visible in the result bundle. Quarantine counts and
runtime skip counts are separate. GitHub's job summary publishes counts and timings.
The always-run artifact step uploads `.build/xcode/results`, including partial
evidence from failed or timed-out invocations.

Local checks:

```sh
bash scripts/tests/swift-test-inventory/run.sh
bash scripts/tests/ci-workflow/run.sh
```

To validate an existing Xcode JSON inventory without building or executing tests:

```sh
python3 scripts/ci_swift_tests.py plan --enumeration /path/to/enumeration.json --directory /tmp/swift-plan
```

Use a fresh output directory per run. `SWIFT_TEST_DERIVED_DATA` can select an
existing local build for focused verification. CI uses `.build/xcode/DerivedData`.
Local sequential execution remains available through `run --lane … --batch …`.
CI workers use `run-shard --shard 1` and `run-shard --shard 2` with the shared plan.
