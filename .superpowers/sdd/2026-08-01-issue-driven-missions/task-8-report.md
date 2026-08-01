# Task 8: Mission Tab Identity, Navigation, and Detail UI

## Scope delivered

- Added a persisted `MissionTabState` and `Tab.mission` case with stable Mission identity, title refresh, unknown-case-tolerant decoding, and ordinary tab close/drag behavior without file or export actions.
- Added `TabsManager.openOrFocusMission`, including cross-worktree deduplication when reconciliation changes the Mission leg's worktree.
- Added Mission navigation to `AppState`: it switches to the containing Space, resolves linked or optimistic rows from all known worktrees, preserves archived visibility state, and returns typed failures when the Mission or worktree is unavailable.
- Opened the Mission detail tab immediately after the durable worktree checkpoint, before ACP startup completes, so ACP failures remain visible in Mission context.
- Added pure `MissionTabPresentation` state and the Mission detail hierarchy for issue context, leg/agent/diff/review state, activity, readiness, retries, worktree recovery, and explicitly confirmed completion.
- Wired issue/review refresh, ACP session opening, Changes navigation, canonical issue/review URLs, agent replacement, checkpoint retry, and explicit archived-worktree recovery through existing application services.

## TDD evidence

1. Added Mission tab, presentation, navigation, controller-checkpoint, and hidden-selection tests before the corresponding production types and wiring.
2. RED: the focused command failed during test-target compilation because `MissionTabPresentation` and the Mission tab APIs did not exist.
3. GREEN: the focused command completed with 75 passed tests, 0 failed, and 0 skipped.

## Verification

- PASS: `rtk xcodegen`
- PASS: `rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/MissionTabTests -only-testing:AlasTests/MissionPresentationTests -only-testing:AlasTests/TabsManagerTests -only-testing:AlasTests/CenterSelectionStateResolverTests` (75 passed, 0 failed, 0 skipped)
- PASS: `rtk swiftformat --lint` on all 13 changed Swift files (0 files require formatting)
- PASS: `rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build` (exit 0)
- PASS: `git diff --check`

A repository-wide test run was started and reached the active test host without reporting a failure, then was interrupted at the task owner's request to finalize from the focused evidence. No full-suite result is claimed.

## Review notes

- Hidden worktrees remain hidden. Center selection resolves a hidden row only while its explicit Mission tab is active; ordinary hidden-worktree selection behavior is unchanged.
- Issue refresh and remote review refresh run independently. Existing Mission source refresh errors preserve the stored issue snapshot and surface stale-source copy.
- Mission completion only mutates Mission state after confirmation. The detail view does not stop ACP sessions, archive worktrees, merge code, or mutate provider issue state.
