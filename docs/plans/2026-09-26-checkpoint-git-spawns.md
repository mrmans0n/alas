# Checkpoint snapshot/restore: reducing git spawns (plan)

Source of truth: `origin/main` @ `df66239` (fetched 2026-09-26; `FETCH_HEAD`). All `file:line` refs are at that commit.
Paths abbreviated: `Snap` = `Alas/Sources/Checkpoints/WorktreeStateSnapshotter.swift`, `Svc` = `.../WorktreeCheckpointService.swift`,
`Tx` = `.../CheckpointRestoreTransaction.swift`, `Store` = `.../WorktreeCheckpointStore.swift`, `FS` = `.../CheckpointFileSystem.swift`,
`Runner` = `.../CheckpointGitRunner.swift`.

Nothing was built or run in the app. Counts come from reading the code. A throwaway Python replay (`a throwaway replay script`) runs the same
git argv sequence as `snapshot` / `restorePreview` against real scratch repos and counts spawns. It confirmed the snapshot, preview and
createManual formulas exactly (numbers below). The git behaviour the batching proposals depend on was checked with git 2.50.1
(Apple Git-155) in a scratch directory.

Some of the earlier analysis was wrong or imprecise:
- The per-path cost applies to **candidate** paths, not to all tracked paths. Candidates are status and diff changes, untracked files,
  and `includingPaths` (such as the manifest paths). It is 2 spawns per *present HEAD or index entry* when retaining payloads and 1
  otherwise. A path changed only in the worktree has both a HEAD and an index entry with the same OID, so it costs 4 spawns (retaining)
  or 2 (fingerprint-only), and half of those reads are duplicates.
- `restorePreview` makes **7** separate `rev-parse --git-path` calls (6 markers plus `index.lock`). The snapshot inside it adds 2 more
  (the index path is resolved twice per snapshot), so one preview makes 9.
- "~150 per restore" is right for the UI flow of preview sheet, then `restore()`, with 3 dirty tracked files (see the formula).
- `Svc:541-545` (`previewHeadOID`) calls `LiveCheckpointGitRunner()` directly instead of the injected `snapshotter.git`. Any spawn-counting
  wrapper would miss those calls.

Spawn cost: a local shell loop of 200× `git rev-parse --verify HEAD` took 2.53 s, about **12.7 ms per spawn** at load average ≈ 10.
The CI figure of about 20 ms per spawn was not re-measured.

---

## 1. Inventory

Notation: `e` = number of present HEAD plus index entries across snapshot candidates. It is `2×` the number of dirty tracked files,
0 for untracked files, and 1 for a case-only rename source. `K` = number of selected restore paths after `requiredRestorePaths`
expansion. `Ka` = number of selected paths whose desired index state is absent. Unborn HEAD adds +2 to every `headOID` call
(`rev-parse --verify --quiet HEAD` plus `hash-object -t tree /dev/null`).

### 1.1 `WorktreeStateSnapshotter.snapshot` (Snap:73-170)

| # | Command | Call site | Runs |
|---|---|---|---|
| 1 | `rev-parse --verify HEAD` (+2 if unborn) | Snap:78 → Snap:376 (378, 384) | 1 |
| 2 | `symbolic-ref --short -q HEAD` | Snap:79 | 1 |
| 3 | `rev-parse --path-format=absolute --git-path index` | Snap:84 → `checksum` Snap:369 | 1 |
| 4 | `status --porcelain=v2 -z --untracked-files=all` | Snap:85 | 1 |
| 5 | `ls-files --stage -z` | Snap:86 | 1 |
| 6 | `ls-tree -r -z <head>` | Snap:87 | 1 |
| 7 | `ls-files -v -z` | Snap:90 | 1 |
| 8 | `ls-files --debug` (intent-to-add scan) | Snap:93 → Snap:390 | 1 |
| 9 | `-c diff.autoRefreshIndex=false diff --cached --name-status -z --find-renames --no-ext-diff <head> --` | Snap:100-104 | 1 |
| 10 | `-c diff.autoRefreshIndex=false diff --name-status -z --find-renames --no-ext-diff --` | Snap:101-104 | 1 |
| 11 | `ls-files --others --exclude-standard -z` | Snap:114 | 1 |
| 12 | retaining: `cat-file -s <oid>` + `cat-file blob <oid>` | `gitState` Snap:301 → 342, Snap:305 | **2 per entry** (no OID dedup) |
| 12' | fingerprint-only: `cat-file blob <oid>` streamed and SHA-256 hashed | Snap:298 → Runner:31-34 | **1 per entry** |
| 13 | `rev-parse --verify HEAD` (safety re-read) | Snap:160 → 376 | 1 |
| 14 | `rev-parse --git-path index` (for the checksum re-read) | Snap:161 → 369 | 1 |

**Snapshot = 13 + 2e (retaining) or 13 + e (fingerprint-only).** With an unborn HEAD it is 17 + ….
Replay: 3 dirty files gave 25 / 19; 20 dirty files gave 93 / 53; 5 untracked-only files gave 13 / 13.

### 1.2 `restorePreview` (Svc:83-126)

| Command | Call site | Runs |
|---|---|---|
| `rev-parse --verify HEAD` (Live runner, bypasses injection) | Svc:97 → 541 (543, 545) | 1 |
| `rev-parse --git-path <marker>` for MERGE_HEAD, CHERRY_PICK_HEAD, REVERT_HEAD, rebase-merge, rebase-apply, sequencer | Svc:101-102 | 6 (early exit on a hit) |
| `ls-files --unmerged -z` | Svc:107 | 1 |
| `rev-parse --git-path index.lock` | Svc:110 | 1 |
| fingerprint-only snapshot, `includingPaths` = manifest paths | Svc:123 | 13 + e |

**Preview = 22 + e.** Replay: 28 with 3 dirty files, 62 with 20.

### 1.3 `createManual` / `createAutomatic` (Svc:324-356)

For each attempt: a retaining snapshot (Svc:328) plus a fingerprint-only verification snapshot (Svc:330), which is **26 + 3e**.
It retries once on a fingerprint mismatch or `stateChanged`, so the maximum is 52 + 6e. `store.publish` spawns no git.
Replay: 44 with 3 dirty files, 146 with 20.

### 1.4 `prepareRestore` (Svc:368-411)

| Step | Call site | Spawns |
|---|---|---|
| refreshed preview (pre-admission preflight) | Svc:371 | 22 + e1 |
| retaining snapshot after admission, including manifest paths | Svc:384 | 13 + 2e1 |
| `createRecovery` → `store.publish` | Svc:396 | 0 |
| `Tx.prepare`: `gitPath("index")` | Tx:102 → 806 | 1 |
| `makePreparedIndex`: `gitPath("index")` again | Tx:737 | 1 |
| `read-tree --empty` (only when no index file exists) | Tx:741 | 0/1 |
| per selected path: `update-index --force-remove -- p` (desired index absent) | Tx:750 | Ka |
| per selected path: `hash-object -w <tmp>` + `update-index --add --cacheinfo m,oid,p` | Tx:757, Tx:760 | 2(K−Ka) |

**prepareRestore = 37 + 3e1 + 2K − Ka.**

### 1.5 `apply` (Tx:144-226)

| Step | Call site | Spawns |
|---|---|---|
| `validateJournal`: 6× `gitPath(marker)` | Tx:152 → 374-375 | 6 (+1 at Tx:357 if the journal owns a lock, +1 at Tx:361 if a lock is pending; both 0 on first apply) |
| `acquireLock`: `gitPath(index)`, `gitPath(index.lock)` | Tx:414-415 | 2 |
| locked retaining snapshot (**safety re-read**) | Tx:156 | 13 + 2e1 |
| `revalidateIndexAndHead`: `rev-parse --verify HEAD`, `gitPath(index)` | Tx:193 → 404, 408 | 2 |
| `installIndex`: `gitPath(index)` | Tx:464 | 1 |
| verification snapshot (retaining, including selected paths) | Tx:202 | 13 + 2e2 |

**apply = 37 + 2e1 + 2e2.**

### 1.6 Totals

- `restore()` = prepareRestore + apply = **74 + 5e1 + 2e2 + 2K − Ka**
- Full UI flow (one sheet preview, then `restore()`) = **96 + 6e1 + 2e2 + 2K − Ka**. The sheet can refresh the preview more than
  once, and each refresh adds 22 + e1.

| Scenario | preview | createManual (1 attempt) | restore() | full flow |
|---|---|---|---|---|
| 3 dirty tracked files, all restored (e1=e2=6, K=3) | 28 | 44 | 122 | **150** |
| 20 dirty tracked files (e1=e2=40, K=20) | 62 | 146 | 394 | **456** |

The dominant term is the per-entry blob reads, `6e1 + 2e2`: 48 of 150 at N=3 and 320 of 456 at N=20.
Git-path resolution is the largest fixed overhead at 27 per flow (details in §2.1).

Other paths, for completeness:
- **Rollback / recover** (Tx:228-325). `recover` runs `validateJournal` (6–8), then `rollback` runs `validateJournal` again (6–8),
  plus `gitPath` index and index.lock (2), `acquireLock` if needed (0/2), two selected-only retaining snapshots (26 + 4e_sel), and
  revalidate plus install (3). That is about 43–49 + 4e_sel.
- **diffContent** (Svc:128-209): 1–2 selected-only snapshots plus one `diff --no-index`.

Rough test-suite load: the checkpoint test files contain 40 `createManual`, 30 `restorePreview`, 18 `restore`,
10 `recoverInterruptedRestore`, 35 direct `snapshot` and 17 `diffContent` call sites, before counting parameterized fan-out. That is
about 6.5k spawns, or about 130 s serial at 20 ms. This is consistent with the reported 80–130 s given test parallelism, but it is an
estimate, not a measurement.

---

## 2. Batching opportunities

The savings column gives spawns saved in the full UI flow at N=3 / N=20.

### 2.1 O1: Resolve all git paths in one `rev-parse` and reuse the result within an operation (saves ≈27 / 27)

Replacement: `git rev-parse --path-format=absolute --git-path index --git-path index.lock --git-path MERGE_HEAD --git-path CHERRY_PICK_HEAD --git-path REVERT_HEAD --git-path rebase-merge --git-path rebase-apply --git-path sequencer`.
It returns one line per argument, in order (checked in both a main and a **linked** worktree, where per-worktree paths resolve under
`.git/worktrees/<name>/`, identical to the single-argument calls). Put the result in a `CheckpointGitPaths` value and:
- **preview:** replace 7 calls with 1 (Svc:101-110). Saves 6 per preview, 12 per flow.
- **`validateJournal`:** replace 6–8 calls with 1 (Tx:357, 361, 374-375). Pass the value to `acquireLock` (Tx:414-415),
  `revalidateIndexAndHead` (Tx:408) and `installIndex` (Tx:464) within the same `apply` / `rollback`. Saves 9 per apply.
- **`Tx.prepare`:** replace 2 calls with 1 (Tx:102 and Tx:737 both resolve `index`).
- **snapshot:** resolve the index path once per snapshot instead of at both Snap:84 and Snap:161. Saves 1 per snapshot, 5 per flow.
  Optionally, callers could pass in already-resolved paths.

Correctness notes:
- **Only path *strings* are shared.** Every `fileExists` / `fileData` / `lstat` on those paths must stay exactly where it is today:
  the marker checks in preview **and** in `validateJournal`, the `index.lock` check in preview, and the index-bytes reads in prepare,
  revalidate and rollback. Those reads are the safety checks. Resolution depends only on the git dir layout, and the lineage
  validation that brackets each operation already fails closed if the `.git` file changes.
- Parse strictly: the line count must equal the argument count, otherwise `invalidGitOutput`. Errors keep mapping to
  `ProcessError.nonZeroExit`.
- A path containing `\n` breaks line splitting, but the current `trimmingCharacters(in: .newlines)` has the same limitation.
- Do **not** fold `rev-parse --verify HEAD` into the same call. It is a separate safety read with distinct unborn-HEAD exit
  semantics (exit 128 would discard the path output).
- Blocker precedence must stay the same: interruptedRestore → lineage → changedHEAD → gitOperation → index lock.
  Resolve everything first, then check markers in the same order as today.

### 2.2 O2: Deduplicate and batch blob reads in the snapshot (saves 40 / 312; createManual 44→29, 146→29)

- **O2a (trivial):** keep a per-snapshot memo from OID to reference and bytes. For worktree-only edits the HEAD and index OIDs are
  equal, so this halves reads: about 24 / 160 saved per flow.
- **O2b:** gather the unique OIDs first, in sorted-candidate order, HEAD before index:
  - retaining: one `git cat-file --batch-check` gives the sizes. Enforce `retainedPayloadByteLimit` from those sizes, still naming the
    first path in the current order, *before* reading any content. Then one `git cat-file --batch` reads the content.
    That is 2 spawns per snapshot instead of 2e.
  - fingerprint-only: one `git cat-file --batch`, SHA-256 hashing each object as it streams. That is 1 spawn instead of e.
  - skip the spawn entirely when there are no entries.
  - Verified framing: `<oid> blob <size>\n<bytes>\n`. A missing object prints `<oid> missing` **with exit 0**.

Correctness risks:
- **Ordering and consistency.** Git objects are immutable by OID, so reading every blob before the disk reads, instead of interleaved
  with them, observes the same content. The end-of-snapshot re-read of HEAD and the index checksum (Snap:159-161) stays and still
  guards the whole snapshot. Exposure to a concurrent `gc` pruning an object is the same as today.
- **Error mapping.** A `missing` line, a type other than `blob`, or a short read must map to an error. `cat-file blob` on a bad OID
  exits non-zero today and callers catch generically, so keep `ProcessError.nonZeroExit` or `invalidGitOutput`.
  `payloadTooLarge(path:byteCount:limit:)` must keep naming the same path, which `trackedPayloadAboveRetainedLimitFailsBeforeCapture`
  asserts.
- **Pipe deadlock.** Write stdin concurrently with draining stdout. With thousands of OIDs, git blocks on a full stdout pipe while the
  parent is still writing. Process+Git's `StdinPipeWriter` pattern exists, but `Process.run` buffers stdout as a String.
  A new streaming runner method is needed, modelled on `Runner:47-95`.
- **Timeouts.** `Process.runData` defaults to a 30 s timeout per call (Process+Git.swift:517-522). A batch covering many large blobs
  can exceed that, whereas each single call stayed small. The streaming path today has no timeout. Pick one deliberately, for example
  no timeout or one scaled to the total size from `--batch-check`.
- **Memory.** Retaining mode already holds every payload in memory, so nothing changes there. Fingerprint-only mode must never
  buffer a whole object.
- Protocol: add the batch method to `CheckpointGitRunning` with a default per-OID fallback in the extension (Runner:10-16).

### 2.3 O3: Prepared-index construction (`makePreparedIndex`, Tx:734-762) (saves 2 / 19 for O3a; O3b adds 0 / 17)

- **O3a (low risk):** hash all materialized files with one `git hash-object -w --stdin-paths`. Output is one OID per input line, in
  order (verified). This turns K−Ka spawns into 1. Keep the per-path `update-index --add --cacheinfo` and `--force-remove`, in
  `restoreApplicationOrder` order.
- **O3b (medium risk):** one `git update-index --index-info` using `GIT_INDEX_FILE` (mode `0` = remove). **Verified semantic
  difference:** `--index-info` *silently replaces* directory/file conflicts. Adding `f1.txt/child` dropped the `f1.txt` entry.
  `--add --cacheinfo` fails instead ("appears as both a file and as a directory", exit 128). The current failure is part of the
  file↔directory transition safety envelope, so O3b needs both of the following:
  - a pre-check: read the prepared index with `ls-files -s -z`, compute the expected final entry set in Swift, and refuse (with the
    same error class) any directory/file conflict with an unselected entry;
  - a post-verify: `ls-files -s -z` on the prepared index must equal the expected set.

  Net cost is about 4 spawns regardless of K. Only worth it for large K.

### 2.4 O4: Fixed snapshot cost

- **O4a (low–medium risk, saves 1 per snapshot = 5 / 5 per flow, 2 per createManual attempt).** Replace `ls-files --stage -z`
  (Snap:86) and `ls-files -v -z` (Snap:90) with **`ls-files -v -s -z`**. Verified output: `H 100644 <oid> 0\tpath`, with `h` for
  assume-unchanged and `S` for skip-worktree, the same tags the current filter uses (Snap:91). The parser changes to strip the 2-char
  tag before the existing `entries` parse.
- **O4b (medium risk, 1 more per snapshot).** Fold in `--debug` as well: `ls-files -v -s --debug -z`. Verified framing: a
  NUL-terminated entry line followed by exactly 5 `  key: …\n` debug lines, ending in `flags: <hex>`. This also fixes a latent bug:
  today's `--debug` parse (Snap:389-406) splits on `\n` without `-z`, so a tracked path containing a newline confuses it. It is also
  substring-based (`"flags: 2000"` matches the verified ITA value `20004000`). Parse the hex and test bit `0x20000000` instead.
  The risk is that `--debug` is not a porcelain format, but the code already depends on it.
- **O4c: not recommended now (verified behaviour change).** Deriving candidates and renames from `status` alone, instead of the two
  `diff` calls, would save 2 per snapshot. However, `-c diff.autoRefreshIndex=false diff` reports **stat-only-dirty** files
  (checked after a `touch`: `M a`), while `status` refreshes in memory and does not. The candidate set, and therefore the fingerprint
  composition, would change. Relevant area: `capturePreservesIndexBytesWhenOnlyFileMetadataChanged`. Status rename detection also
  follows `status.renames` unless `--find-renames` is passed; `--find-renames` does override `status.renames=false` (verified).
  Revisit only with a dedicated parity study.
- Keep `symbolic-ref` (1).

### 2.5 O5: Reusing snapshots instead of re-taking them (mostly unsafe)

These re-reads exist for safety and **must stay**:
- `Snap:159-161`: re-reading HEAD and the index checksum at the end of every snapshot detects mutation during capture.
- `Svc:330`: the createManual/createAutomatic verification snapshot is the two-read stability check. Test:
  `captureRetriesOneConcurrentChangeAndPublishesOneStableCheckpoint`, which uses `hooks.afterPayloadStaging`.
- `Svc:384`: the post-admission snapshot, taken after the admission journal blocks other Alas writers, compares fingerprints again.
- `Tx:156`: the snapshot taken under the owned `index.lock`, the locked revalidation. Test:
  `lockedRevalidationRejectsChangesAfterPreparation`.
- `Tx:193 → 404/408`: re-reading HEAD and the index bytes immediately before index install.
- `Tx:202`: post-restore verification. `Tx:269/318`: the rollback before/after snapshots.
- The preview inside `prepareRestore` (Svc:371): a fresh preflight of blockers. Tests: `freshPreflightRejectsAnIndexLockAddedAfterPreview`,
  `freshPreflightRejectsCurrentSessionCoordination`.

One candidate remains, as an **optional last step with medium–high risk**. Keep the preflight *blocker* checks in Svc:371 but drop its
*snapshot*:
- take the admission paths from `preview.groups`, which the caller passed in and whose fingerprint must match anyway;
- build the refreshed `CheckpointRestorePreview.make` from the post-admission snapshot. Group IDs are stable because they are SHA-256
  of the manifest ID plus sorted members (CheckpointModels.swift:161-166).

This saves 13 + e1 per restore (about 14 after O2b). The costs:
- stale previews would now create and discard an admission journal and staging directory instead of failing before admission;
- `stalePreview` versus blocker precedence changes;
- it assumes rename grouping is deterministic for equal fingerprints.

Not recommended unless restore latency still matters after the steps above.

### 2.6 Projected totals (full UI flow)

| After | N=3 | N=20 |
|---|---|---|
| baseline | 150 | 456 |
| + O1 git paths | 123 | 429 |
| + O2b batched blobs | 83 | 117 |
| + O3a hash-object --stdin-paths | 81 | 98 |
| + O4a merged ls-files | **76** | **93** |
| + O3b, O4b (optional) | 71 | 71 |

createManual (one attempt) goes from 26 + 3e to about 25 flat. At 20 ms per spawn, a restore flow drops from about 3.0 s (N=3) or
9.1 s (N=20) to about 1.5–1.9 s. The restore flow becomes almost independent of the number of files.

---

## 3. PR sequence (smallest risk first; git stays real in every test)

Each PR runs its focused suites with `-only-testing AlasTests/<Suite>`. New test files need `xcodegen` (project memory).

1. **PR0: spawn-budget harness (no behavior change).**
   - Add a test-only `CountingCheckpointGitRunner` that *wraps* `LiveCheckpointGitRunner`, so git stays real. It records argv and
     forwards `blobReference`.
   - Route `previewHeadOID` (Svc:540-548) through `snapshotter.git`.
   - New suite `CheckpointGitSpawnBudgetTests`. It asserts the current exact counts for snapshot (retaining and fingerprint-only),
     preview, createManual and restore on a 3-file fixture. Later PRs lower these numbers.
   - Coverage gaps to add now:
     - a parameterized test over all 6 git markers. Today only `MERGE_HEAD` and `index.lock` are covered, in
       `CheckpointRestorePreviewTests.realGitMarkersLocksAndInterruptedJournalBlockBeforeMutation`;
     - one preview/restore on a **linked worktree** fixture. `CheckpointTestRepository.make` is a plain repo.
2. **PR1: O1 git-path consolidation.** Covered by:
   - `CheckpointRestorePreviewTests` (realGitMarkers…);
   - `CheckpointRestorePreparationTests` (freshPreflightRejectsAnIndexLockAddedAfterPreview, prepareBuildsDesiredIndexAndLeavesTheWorktreeUntouched);
   - `CheckpointRestoreInterruptionTests` (all: failureAfterIndexLockIntentDoesNotLeaveALock, competingEmptyIndexLockIsNotRemoved,
     recoveryAcceptsPendingEmptyIndexLockCandidateName, lockedRevalidationRejectsChangesAfterPreparation, recoveryRefusesSessionsDirtyBuffersAndReplacedLockInode);
   - `CheckpointRestoreIntegrationTests`;
   - PR0's marker and linked-worktree tests.
3. **PR2: O2a OID dedup.** Covered by `WorktreeStateSnapshotterTests` (snapshotKeepsHeadIndexAndDiskVersionsDistinct,
   stagedRenameGroupsBothPaths, caseOnlyRenameCapturesSourceAndDestinationAsDirtyRename, fingerprintOnlySnapshotDoesNotRetainPayloadBytes,
   trackedPayloadAboveRetainedLimitFailsBeforeCapture) and `WorktreeCheckpointCaptureTests`. New: budget update only.
4. **PR3: O2b `cat-file --batch-check` / `--batch`.** Covered by all of `WorktreeStateSnapshotterTests`, especially:
   - binaryDataSurvives (framing with embedded `\n` and NUL);
   - symlinkCapturesTargetBytes;
   - sha256UnbornRepositoryCapturesInitialWorkAgainstRepositoryEmptyTree (64-hex OIDs);
   - trackedPayloadAboveRetainedLimitFailsBeforeCapture.

   Also covered by `CheckpointDiffLoaderTests` (currentOnlyDiffSnapshotsOnlyRequestedPath) and `CheckpointRestoreIntegrationTests`.
   New tests:
   - the empty blob;
   - enough objects, plus one multi-MB blob, to exceed the pipe buffer (deadlock guard);
   - a deleted loose object, which must still throw;
   - identical content at many paths.
5. **PR4: O4a `ls-files -v -s -z`.** Covered by sparseStateFailsCapture, assumeUnchangedDiskEditFailsCapture, gitlinkFailsCapture,
   unmergedEntryFailsCapture and executableModesSurvive. New: none.
6. **PR5: O3a `hash-object -w --stdin-paths`.** Covered by:
   - `CheckpointRestorePreparationTests.prepareBuildsDesiredIndexAndLeavesTheWorktreeUntouched`;
   - `CheckpointRestoreIntegrationTests` (fullRestorePreservesEverySavedLayerAndPublishesRecovery, selectiveRestorePreservesUnselectedIndexAndDiskBytes).

   New: a restore where several paths share one blob.
7. **PR6/PR7: fsync trims (§4 "incidental" only), split store / transaction.** Covered by:
   - `WorktreeCheckpointStoreTests` (failedJournalLockAttemptPreservesExistingOwner, publishingReplacesCorruptContentAddressedBlob,
     publishingReusedBlobValidatesExistingFileWithoutReadingItIntoMemory, materializingBlobStreamsWithoutCallingBlobFileData,
     recoverableJournals* cleanup tests);
   - `CheckpointFileSystemTests`;
   - `CheckpointRestoreInterruptionTests`.

   Unit tests cannot prove crash safety, so each PR description must carry the crash-ordering argument.
8. **Optional PR8: O3b `--index-info`** with the directory/file pre-check and post-verify. Covered by
   restoreReplacesTrackedFileToDirectoryTransition, restoreReplacesTrackedFileWithSavedDirectoryTransition,
   restoreOrdersStructuralParentsBeforeUnrelatedDeeperPaths and previewShowsStructuralDependenciesForFileDirectoryRestore.
   New (required): a directory/file conflict against an **unselected** index entry must fail as today, not silently drop the entry.
9. **Optional PR9: O4b** (fold `--debug`, parse the ITA bit). Covered by intentToAddEntryFailsCaptureWithoutChangingIndexIntent.
   New: an ITA entry plus a tracked path containing `\n`.
10. **Optional PR10: O5** (drop the pre-admission snapshot). Covered by all of `CheckpointRestorePreparationTests` and
    `RightPaneCheckpointStateTests.previewRestoreAndRecoveryCoordinateUsingConcreteAffectedPaths`. New: a stale preview must leave no
    journal or staging behind, which today holds without admission ever happening.

Independent side fix, found while reading. `Tx.finish` (Tx:596) calls `fileSystem.removeIfPresent(stagingRoot)` on a
**non-empty** directory. `removeIfPresent` does unlink, which gives EPERM, then `rmdir`, which gives ENOTEMPTY (both verified on macOS).
The staging root always holds `original-index` and `index`, so cleanup always throws. The throw is swallowed by `catch { return }`, so
`synchronizeDirectory(target.path)` and `finishJournal` never run after a successful restore. The terminal journal and the
`.alas-checkpoint-restore-*` directory stay in the worktree until the next `recoverableJournals` cleans them.
Fix: use `removeDirectoryTreeIfPresent` (Tx:613). Test: assert the staging root is gone right after
`CheckpointRestoreIntegrationTests.fullRestore…`.

---

## 4. fsync: required vs incidental

Context: `fsync` on macOS does not flush the drive cache (`F_FULLFSYNC` would). The protocol therefore protects write *ordering*
against app and kernel crashes. No change is proposed there.

### Required (keep)

| Site | Why |
|---|---|
| Journal writes: `Store:313-318` → `writeDurable` (FS:112-132: file fsync plus parent-dir fsync after rename) | This is the write-ahead log. Each phase record must be durable before the mutation it describes: `pendingPath` before `moveLeaf`, lock intent before `link`, candidate before handoff, `.rollingBack` before rollback moves. |
| `original-index` (Tx:105) | Rollback's source of truth. Its digest is checked at Tx:272-273. If it were torn after a crash, recovery would stick at `invalidJournal`. |
| Index candidate fsync plus dir sync (Tx:531-532) | The candidate becomes the live index by rename, and its identity is journaled first. |
| Empty lock candidate fsync plus dir sync (Tx:550-551); dir sync after `link` (Tx:435) | Recovery must be able to prove it owns `index.lock` (dev, inode, checksum in `validateLock`). |
| `moveLeaf` source and destination dir syncs (Tx:671-672) | Each rename is followed by a journal write asserting it happened, and rollback depends on the backups existing. These cannot be batched because the order is load-bearing. |
| Replacement materialization file fsync (`materializeBlob` → `copyBlob` Store:659, from Tx:116/769) | The replacement becomes the user's file by rename. A torn replacement would strand recovery at `stalePreview`. |
| Rollback replacement file fsync (Tx:299 → Store:659) | Same reason. |
| Publish: blob file fsync (Store:171), `manifest.json` (Store:182), entry move dir sync (FS:154 via Store:184), catalog plus root dir (Store:561-562) | Checkpoint durability. The *recovery* checkpoint must be durable before `apply` mutates anything, and the catalog write is the commit point for publish and delete ordering. |

### Incidental (safe to trim, with reasoning)

| Site | Why it is not needed |
|---|---|
| Lineage lock release: `removeIfPresent(owner.json)` and `removeIfPresent(lock)` syncs (Store:384 → Store:816-826 → FS:170-178) | Whether a removal is durable does not matter. A lock that reappears after a crash has a durable `owner.json` with a dead PID and is reclaimed at once (Store:413-418). |
| `synchronizeDirectory(lock)` at Store:398 | It duplicates the parent-dir fsync that `writeDurable` already did for `owner.json` in the same directory. |
| **Keep** the acquisition-side syncs (`mkdir` sync, `owner.json` file and dir) | Without them the lock directory can survive a crash with a torn or missing `owner.json`. Reclaim then falls back to the 120 s mtime age (Store:421-423), and store operations fail with `lineageLockUnavailable` for up to 2 minutes after a crash. Removing them needs a redesign (write owner into a temp directory, then rename that directory into place as the lock). |
| Per-blob double dir sync on publish: `writeDurable` renames into `.sha.tmp` and syncs `blobs/`, then `moveExclusively` links and syncs `blobs/` again (Store:171-173, FS:157-166) | The first sync is dead. The second can be done once for all blobs, before the manifest entry move at Store:184. |
| `synchronizeDirectory(temporary)` at Store:183 | It duplicates the parent sync `writeDurable` already did for `manifest.json`. |
| Prepared index `writeDurable` (Tx:739) | `git update-index` then rewrites that file under `GIT_INDEX_FILE`. Git's default `core.fsync` does not cover the index, so the final bytes are not durable anyway. After a crash nothing reads the prepared index: recovery always rolls back from `original-index`, and `apply` digest-checks it in-process (Tx:195-196). |
| Temp files in `makePreparedIndex` (Tx:754-756 → `copyBlob` fsync plus dir sync) | The files are deleted right after `hash-object -w`. Durability of the git object follows git's own `core.fsync` policy, exactly as with `git add`. Use a non-durable, still digest-verified copy. |
| Per-replacement dir sync (Store:663 during Tx:116) | The file fsyncs must stay. The directory entries only need to be durable before the prepared journal write at Tx:126, so one sync of `replacements/` suffices. For rollback replacements the next `moveLeaf` already syncs the staging root. |
| Per-file syncs while deleting trees: staging cleanup (Store:816-826, Tx:613-623), `removeEntry` / `garbageCollect` (Store:751-794) | Cleanup is idempotent and retried while the journal or entry exists. Only "staging gone before journal unlinked" matters, which needs one sync of the parent before `removeIfPresent(journal)`. |
| `removeEmptyDirectoryIfPresent` sync (Tx:680) | The following `moveLeaf` syncs the same parent directory. A crash in between leaves an empty or absent directory, and `leafState` treats a directory as absent. |

Rough scale: every locked store operation costs 6 lock-related fsyncs, and a `writeJournal` costs 8 in total, 2 of them required. The
restore success path performs about 10 + 2K locked journal operations, plus two `recoverableJournals` calls and one `publish`. At K=3
that is about 110 incidental lock fsyncs against about 40 required journal fsyncs. Trimming only the release-side and duplicate lock
syncs (3 of the 6) removes about 55 of them.
