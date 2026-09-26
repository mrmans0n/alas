# Swift test cost baseline, September 2026

Measured from the green `main` run
[36210551200](https://github.com/mrmans0n/alas/actions/runs/36210551200).
Per-test durations come from its result bundles via
`scripts/swift_test_durations.py`. Invocation wall times come from the coverage
summary, and compile times from the build summary artifact.

## Where the time goes

| Cost | Seconds | Notes |
|---|---:|---|
| Compiling the test target | 568 | Active time. The app target takes 439. |
| Running test bodies | 924 | Summed across both shards. |
| Invocation overhead, ordinary lane | 338 | 8 invocations. |
| Invocation overhead, subprocess lane | 906 | 63 invocations, median 10.5s each. |

Overhead is invocation wall time minus the summed durations of its tests. It
covers test host launch, Swift Testing discovery, teardown, and result
extraction.

Three conclusions follow:

1. **The test target costs more to compile than the app.** Line count is the
   lever here, which is where pruning shallow tests pays off.
2. **The subprocess lane spends more time launching than testing.** It runs
   2,480 tests in 523s of test time, but 1,429s of wall time. Several
   invocations run 2 to 4 tests in 45 to 90 seconds. The policy file records
   this list as a conservative baseline, not as proven per-suite hangs.
3. **Runtime is concentrated in a small set of tests.** Deleting cheap tests
   saves compile time and maintenance, not execution time.

## Distribution of test execution time

| Slice | Tests | Share of test time |
|---|---:|---:|
| Slowest 1% | 121 | 40% |
| Slowest 5% | 605 | 73% |
| Slowest 10% | 1,210 | 88% |
| Under 10ms each | 8,724 | about 1% (13s total) |

Only 164 tests take a second or more, and together they account for 420s.

## Slowest suites

| Suite | Seconds | Tests | Avg |
|---|---:|---:|---:|
| CheckpointRestoreInterruptionTests | 78.4 | 14 | 5.60 |
| CheckpointRestoreIntegrationTests | 29.2 | 8 | 3.65 |
| ACPSessionManager attach restore | 23.9 | 123 | 0.19 |
| ACP transcript markdown convergence | 23.7 | 4 | 5.93 |
| GGCommandRunningStreamingTests | 23.3 | 21 | 1.11 |
| GitServiceCommitEditingTests | 19.7 | 34 | 0.58 |
| RunScriptLaunchTests | 18.4 | 37 | 0.50 |
| CheckpointRestorePreparationTests | 17.2 | 6 | 2.87 |
| RemoteAppStateAccessTests | 16.9 | 55 | 0.31 |
| RightPaneStateLoadOlderTests | 16.3 | 10 | 1.63 |
| EditorBufferTests | 15.6 | 84 | 0.19 |
| CheckpointRestorePreviewTests | 15.2 | 8 | 1.90 |
| ACPHorizontalScrollWheelRouterTests | 14.9 | 6 | 2.48 |
| AppStateWorktreeCleanupBatchTests | 14.4 | 23 | 0.63 |
| MergeConflictTabModelTests | 14.1 | 35 | 0.40 |

The checkpoint restore suites alone take about 140s, roughly 15% of all test
time, mostly in parameterized fault-injection tests.

## Slowest individual tests

| Seconds | Test |
|---:|---|
| 18.40 | ACP transcript markdown convergence / head backfill and table wheels converge and release retired hosts and markdown views |
| 10.33 | CheckpointRestoreInterruptionTests / failuresRollBackBothLayers(point:) |
| 8.96 | CheckpointRestoreInterruptionTests / recoveryAcceptsPendingEmptyIndexLockCandidateName() |
| 8.81 | RemoteAppStateAccessTests / approvalConfigurationChangesCancelIncomingWork(setting:) |
| 8.73 | CheckpointRestoreInterruptionTests / selectiveRecoveryPreservesUnrelatedEditsMadeAfterInterruption(replacedByDirectory:) |
| 8.37 | CheckpointRestoreInterruptionTests / indexInstallationInterruptionCanRecoverWithoutTrustingForeignLockBytes(point:tamper:) |
| 7.73 | CheckpointRestoreIntegrationTests / selectiveRestorePreservesUnselectedIndexAndDiskBytes() |
| 7.61 | CheckpointRestoreInterruptionTests / relaunchRecoversUnlessOwnedLockChanged(tamper:point:) |
| 7.20 | CheckpointRestoreIntegrationTests / fullRestorePreservesEverySavedLayerAndPublishesRecovery() |
| 6.10 | GGServiceActionsTests / syncFailsWhenProcessDoesNotExitAfterTerminalSummary() |
| 5.84 | CheckpointRestoreInterruptionTests / recoveryRefusesSessionsDirtyBuffersAndReplacedLockInode() |
| 5.79 | LanguageRegistry / Every mapped extension resolves to a grammar and a compiling query |
| 5.62 | CheckpointRestorePreparationTests / prepareBuildsDesiredIndexAndLeavesTheWorktreeUntouched() |
| 5.52 | GGCommandRunningStreamingTests / watchdogKillsDetachedChildSpawnedByTerminationHandler() |
| 5.37 | GGCommandRunningStreamingTests / watchdogGracefullyTerminatesLateDetachedChild() |

## What to do with this

- **Subprocess lane.** Move suites back to the ordinary lane in batches and
  keep only those that reproduce a hang. This is the largest runtime saving.
- **The slowest few hundred tests.** Review each for a fixed sleep, a real
  process or git repo that a fake could replace, or a parameter matrix wider
  than the behavior needs.
- **The long tail.** Prune by the testing policy in `AGENTS.md`. Expect
  compile-time and maintenance savings, not faster test execution.

To refresh, download the result artifacts of a green run and rerun the script.
Compare against this file before claiming an improvement.
