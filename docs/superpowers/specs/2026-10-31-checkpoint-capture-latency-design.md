# Faster automatic checkpoints before a prompt — design

## Intent

Before every agent prompt, the app and `alas-host` take an automatic checkpoint, and the prompt waits for it. On a large dirty tree that wait is seconds, felt on every prompt. The checkpoint must reflect the tree before the agent writes, and agents write within hundreds of milliseconds, so the capture can't simply move after the send. This design cuts the work the capture repeats, without changing what a checkpoint contains or when it's taken. The user asked for this to run unattended, so the calls below are mine.

## Current state (from recon, origin/main d846c143f)

`WorktreeCheckpointService.createAutomatic` does the following, in up to 2 attempts:

1. **A retaining snapshot** (`WorktreeStateSnapshotter.snapshot`).
   - 13 git spawns: `status`, `ls-files`, `ls-tree`, two `diff`s, untracked listing and others.
   - It hashes the index file twice.
   - It reads and SHA-256s every dirty tracked file and every untracked, non-excluded file.
   - It loads each candidate's HEAD and index blobs through `cat-file`.
2. **A verification snapshot** (`retainingPayloads: false`). It repeats the 12 git spawns, the index hashing, and a streamed re-hash of every dirty file, only to prove the tree didn't change during the capture.
3. **The state key, then publish** (`publishAutomaticIfAbsent`). An unchanged state skips the write, but only after both passes ran.
   - On a miss, `makePublication` and `publishUnlocked` hash every payload again.
   - Every already-stored blob is re-read and re-hashed (`blobMatchesReference`) before being skipped.
   - Each new blob, the directory, the manifest and the catalog are each fsynced.
4. **The app path** also awaits a right-pane `refreshCheckpoints()` inside the prompt's wait.

So each dirty file is read 2 or 3 times and hashed 4 or more times per prompt, and a mostly unchanged tree pays all of it again on the next prompt.

## Goals

1. **Measure first.** Time the capture on a large dirty fixture, split into git, the retaining pass, the verify pass and publish, before and after. Report the numbers.
2. **Hash each payload once per capture.** `makePublication` and `publishUnlocked` reuse the references the snapshot computed.
3. **Don't re-read a stored blob that is already known good.** Publish trusts an existing `blobs/<sha>` whose size matches and whose identity the store has already verified (`verifiedBlobReferences`). It re-hashes only when unsure.
4. **A cheap verification pass that still catches a change.**
   - Instead of re-hashing every file's content, the verify pass compares each candidate's stat identity (size, mtime and ctime in nanoseconds, inode), captured during the retaining pass, plus the git state the fingerprint covers.
   - If a candidate's mtime or ctime falls within the racy window (2 seconds) before the capture started, it falls back to a content hash for that file only.
   - Any stat difference fails verification exactly as a content difference does today, and the existing retry applies.
5. **The app doesn't wait for UI work.** The right-pane checkpoint refresh after an automatic capture runs after the checkpoint id is returned, not inside the prompt's wait.
6. **Nothing a checkpoint contains changes,** nor what restore, preview or diff see. Every existing checkpoint test passes unchanged, except spawn or count budgets that legitimately drop.

## Non-goals

- A persistent stat cache across prompts. It's the next step if measurement shows hashing still dominates, and it changes publish's contract.
- A point-in-time copy (APFS clone) with background publishing.
- Cutting git spawns. If measurement shows git dominates, that is the follow-up, reported with numbers.

## Anti-goals

- **No checkpoint can be missing a change that happened before the prompt.** The racy-window fallback exists for this.
- **No weaker verification.** A file that changed during the capture must still fail verification.

## Decisions (my calls)

- **Single PR** in the core package, plus the small app change for goal 5.
- **The stat identity** is added to `CheckpointLeafMetadata`, recorded by `LiveCheckpointFileSystem`.
- **`streamFileReference` goes through `fileSystem`,** so test doubles can count reads.
- **Tests pin the behaviour,** extending the existing suites:
  - a counting file system shows each dirty file is read once per capture, not 2 or 3 times;
  - `blobHashValidationCountForTesting` shows an existing known blob isn't re-hashed on publish;
  - a file edited during the capture still fails verification. The existing `afterPayloadStaging` hook covers this, including a same-size edit within the racy window.
