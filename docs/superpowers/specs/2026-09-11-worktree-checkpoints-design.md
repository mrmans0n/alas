# Recoverable worktree checkpoints

## Summary

Add manual, per-worktree checkpoints to the Changes pane. A checkpoint records
the selected local worktree's index and on-disk state without changing its
branch, HEAD, index, or files. Users can name checkpoints, inspect their scope,
preview changes against the current worktree, restore selected files or the
full supported scope, and delete old checkpoints.

Restore is transactional at the application level. Alas captures a recovery
checkpoint before the first destructive write, verifies that the preview is
still current, prepares the replacement index and file contents away from the
live worktree, and records progress in a durable journal. A failed or
interrupted restore remains recoverable and is never reported as complete.

## Goals

- Create a named checkpoint without commits, refs, stashes, branch changes, or
  edits to the worktree and index.
- Preserve staged and unstaged states independently.
- Preserve regular file bytes, executable bits, symlinks, additions,
  deletions, rename pairs, and binary files.
- Capture ordinary untracked files under an explicit policy and report every
  excluded path.
- Persist checkpoints across relaunch and isolate them by durable worktree
  identity.
- Preview the exact paths, index states, and working-tree states a restore will
  change.
- Restore selected files without touching unselected paths.
- Create a usable pre-restore recovery checkpoint before any destructive
  write.
- Detect stale previews and incomplete operations instead of overwriting
  concurrent work silently.
- Bound retention and disk use, and show both in the UI.

## Non-goals

- No automatic checkpoint around agent turns.
- No attribution of a change to an agent, chat, provider, or editor.
- No capture of ignored files, databases, running processes, terminals,
  simulator or device state, or machine state outside the worktree.
- No SSH or other remote worktree capture or restore in V1.
- No atomic multi-repository Workspace checkpoint.
- No restore across a different HEAD commit.
- No submodule working-tree capture.
- No background synchronization or export format.

## User experience

### Checkpoints section

Changes gains an always-visible **Checkpoints** section between **Working tree**
and **Stashes**. Its sticky header shows the checkpoint count and a create
button. The empty state says `no checkpoints` and keeps the create action
available.

Each checkpoint row shows:

- its user label;
- a compact creation time;
- manual or recovery status;
- changed-file counts split into staged, unstaged, and untracked scope;
- stored bytes.

The section footer shows current storage use and the policy: 20 manual
checkpoints, 5 recovery checkpoints, and 2 GiB per worktree.

Expanding a row loads its manifest and shows its logical file groups. A rename
appears as one group with its source and destination. Other paths appear once
even when they have both index and working-tree changes. Each row has separate
index and working-tree badges. Selecting a file opens a checkpoint diff in the
center pane against the current worktree. Text files use the existing unified
diff presentation. Supported images use the existing image comparison. Other
binary files show their type and byte sizes instead of pretending to have a
text diff.

The checkpoint menu contains **Restore...** and **Delete...**. Deletion uses a
destructive confirmation and does not affect the worktree.

### Creating a checkpoint

The create button opens a focused sheet with a required label. The sheet states
that the checkpoint captures the Git index and on-disk files, not unsaved
editor buffers or running process state. The label is trimmed, must contain at
least one non-whitespace character, and is capped at 120 characters.

Creation remains available for a clean worktree. A clean checkpoint can later
remove changes made after capture as part of a full restore.

While capture runs, the sheet shows progress and disables duplicate submission.
On success it shows included file count and bytes plus an exclusions disclosure.
The disclosure remains available from the checkpoint row. If capture fails,
the sheet shows the reason and creates no visible checkpoint.

### Restore preview

Restore opens a sheet only after Alas has loaded a fresh current-state
snapshot. The candidate set is the union of:

- paths whose checkpoint index or working-tree state differs from the
  checkpoint's HEAD baseline; and
- paths whose current index or working-tree state differs from that same HEAD
  baseline.

All differing logical file groups are selected initially. Users can deselect
groups. Deselecting a group preserves all current index and on-disk states for
its paths. Rename source and destination paths form one indivisible group.

For every selected path, the preview names both outcomes. Examples include
`index: staged modification -> clean`, `index: clean -> staged deletion`,
`working tree: modified -> checkpoint contents`, and `untracked file will be
removed`. The confirmation summary repeats the selected path count and states
that both the index and working tree will be restored for those paths.

The preview offers **Restore Selected Files** when at least one group is
selected. It never uses `git reset --hard`, branch switching, checkout of a
different commit, or force-push.

### Restore blockers

Capture and restore are disabled for remote worktrees with:

> Checkpoints are not available for remote worktrees yet.

In a Workspace, the UI names the member repository and says that only its
selected worktree is in scope.

Restore is disabled when:

- current HEAD differs from the checkpoint's captured HEAD;
- the durable worktree lineage differs or cannot be verified;
- a merge, rebase, cherry-pick, revert, unresolved conflict, or Git index lock
  is present;
- another checkpoint or Git mutation is active;
- any selected path has an unsaved Alas editor buffer;
- any terminal or ACP agent session is active for the worktree;
- the checkpoint is corrupt, incomplete, or missing a required blob;
- an earlier restore journal still needs recovery.

The UI reports the specific blocker. It does not offer to terminate sessions.
Users stop relevant terminal and agent sessions themselves, then refresh the
preview. Dirty editor buffers must be saved or discarded before their paths can
be selected for restore.

## Capture policy

### Tracked state

Alas obtains changed paths from Git using NUL-delimited output. It captures the
HEAD, index, and on-disk states needed for every tracked changed path. Failure
to read any required tracked state fails the whole checkpoint.

Each file state is one of:

- absent;
- regular file with raw bytes and Git mode `100644` or `100755`;
- symlink with its link target bytes and Git mode `120000`.

The manifest records the Git blob object ID when one exists, but the checkpoint
store also owns a copy of every required payload. Inspection and recovery do
not depend on unreachable Git objects surviving garbage collection.

Gitlinks with mode `160000`, sparse-index states that cannot be expanded, and
unmerged index entries are unsupported. Capture fails with the affected paths
rather than omitting them.

### Untracked state

Untracked candidates come from `git ls-files --others --exclude-standard -z`.
Gitignored paths never become candidates. Alas does not follow symlinks while
enumerating or reading candidates.

V1 excludes these untracked candidates and records a reason for each:

- any component named `.git`, `.build`, `build`, `DerivedData`,
  `node_modules`, `.swiftpm`, `.gradle`, `Pods`, or `Carthage`;
- an Alas-owned restore directory named `.alas-checkpoint-restore-<UUID>`;
- basenames `.env`, `.env.*`, `.netrc`, `credentials`, or
  `credentials.json`;
- filename extensions `key`, `pem`, `p12`, `pfx`, `mobileprovision`, or
  `keystore`;
- a regular file larger than 10 MiB;
- sockets, FIFOs, devices, and other special filesystem objects;
- a path with a symlinked parent component or a path that fails containment
  validation.

The filename policy reduces common accidental secret capture but does not
claim to detect secrets by content. The creation sheet says this directly.
Users must move a deliberately excluded file into tracked Git state before V1
will include it; V1 has no per-path exclusion override.

If included payloads would make one checkpoint larger than 2 GiB, capture
fails before publication. Exclusions do not make capture partial because they
are part of the declared untracked policy. Any other unreadable candidate
fails capture.

### Stable capture

Capture records a full state fingerprint before reading payloads and repeats
the fingerprint after all payloads are staged. The fingerprint covers HEAD,
the index checksum and entries, candidate path identities, file kinds, modes,
sizes, and content hashes. If it changes, Alas discards the staged capture and
retries once. A second change fails with `The worktree changed while the
checkpoint was being created.`

Unsaved Alas editor buffers are outside the on-disk worktree state. The create
sheet lists their count as not captured. They do not block non-destructive
capture.

## Storage format

### Layout

Checkpoints live under:

```text
Application Support/Alas/checkpoints/
  <lineage-id>/
    catalog.json
    blobs/<sha256>
    entries/<checkpoint-id>/manifest.json
    operations/<operation-id>/journal.json
    quarantine/
```

The lineage ID is the random marker already persisted in the concrete
worktree's Git administrative directory. A worktree path and the existing
path-derived `Worktree.id` remain display and lookup metadata only. Load,
preview, restore, and delete require the manifest lineage to match the current
Git marker. Deleting and recreating a repository or linked worktree at the same
path therefore cannot attach old checkpoints to the new worktree.

`catalog.json` contains only summaries needed by the Changes pane. A checkpoint
manifest contains:

- schema version and checkpoint UUID;
- kind, label, creation time, and byte accounting;
- lineage ID, captured path, repository display name, branch, and full HEAD
  object ID;
- capture policy version and exclusions;
- logical file groups and per-path HEAD, index, and working-tree states;
- each payload's SHA-256 blob key, byte count, kind, and mode.

The store writes blobs by content hash so equal payloads are shared. It writes
new manifests and catalogs through temporary sibling files, synchronizes their
contents, and renames them into place. A checkpoint becomes visible only after
its manifest and every referenced blob are durable. Blob garbage collection
runs after catalog publication and removes only blobs unreachable from all
published manifests and active operation journals.

Malformed manifests, path traversal, hash mismatches, missing blobs, and
unsupported schema versions move the entry to `quarantine`. The catalog shows
an unavailable summary with the error and permits deletion, but restore remains
disabled.

### Retention

Each lineage keeps at most 20 manual checkpoints and 5 recovery checkpoints,
with a combined 2 GiB ceiling measured from reachable blobs and manifests.
Before publishing a new checkpoint, the store calculates the post-publication
usage. It prunes the oldest recovery checkpoints first, then the oldest manual
checkpoints, until count and byte limits are satisfied. It never prunes the
checkpoint currently being restored, its recovery checkpoint, or blobs named
by an active journal.

If the new checkpoint cannot fit by itself, capture or restore fails before a
destructive write. The Changes footer and creation result show current use and
the fixed limits. There is no pinning in V1.

## Restore transaction

### Preflight and preparation

The restore service receives a checkpoint ID, selected logical group IDs, and
the exact preview fingerprint. It then:

1. Reloads the manifest and verifies its lineage, schema, blobs, and HEAD.
2. Rechecks Git-operation, index-lock, session, and editor-buffer blockers.
3. Recomputes current state and rejects a stale preview before writing.
4. Captures the selected paths' current HEAD, index, and working-tree states as
   a recovery checkpoint labeled `Before restoring <label>`.
5. Publishes that recovery checkpoint and verifies it can be loaded.
6. Builds the complete replacement index in an operation directory by copying
   the current index and applying only selected path states through a temporary
   `GIT_INDEX_FILE`.
7. Creates an exclusively owned `.alas-checkpoint-restore-<UUID>` directory at
   the worktree root, materializes every replacement regular file and symlink
   there, and verifies its hash, kind, and mode. Keeping replacements and
   backups on the worktree volume makes later renames atomic even when
   Application Support or the repository Git directory is on another volume.
8. Writes a journal containing the recovery checkpoint ID, selected paths,
   expected current fingerprint, prepared index checksum, and phase.

No user path or index byte has changed at this point. The owned restore
directory is an internal, policy-excluded untracked path. The service removes
it after completion or successful recovery.

### Apply

Alas creates `.git/index.lock` exclusively using Git's normal lock convention.
If it already exists, restore aborts without a write. With the lock held, Alas
rechecks the index checksum and selected on-disk path fingerprints.

For each selected path, the service first moves an existing leaf into the
operation backup directory, then atomically renames the prepared replacement
into place or records the intended absence. It refuses absolute paths, `..`,
NULs, a symlinked parent, directory replacement, and any resolved destination
outside the worktree. The journal is synchronized after every completed path.

After all selected working-tree paths are in place, the service moves the fully
prepared index into `index.lock` and atomically renames the lock to `index`.
It then verifies the resulting selected states against the checkpoint, marks
the journal complete, removes operation backups, refreshes Git status, and
retains the recovery checkpoint as the undo path.

Unselected paths and their index entries are copied unchanged into the
prepared index and receive no filesystem operation.

### Failure and interruption

An error before the first live-file move deletes the prepared operation and
leaves the recovery checkpoint available. An error after a live-file move
starts rollback immediately from the recovery checkpoint and operation backup.
Rollback uses the same path safety and index lock rules.

If rollback completes, the UI reports that restore failed and the original
state was recovered. If rollback cannot complete, Alas keeps the journal,
backup files, prepared index, and recovery checkpoint. It reports the exact
paths and phase that need recovery and blocks further checkpoint and Git
mutations for that worktree.

On relaunch, the store discovers nonterminal journals before enabling
checkpoint actions. The Changes section presents **Restore interrupted** with
**Recover pre-restore state** and operation details. Recovery is explicit; Alas
does not mutate the worktree merely because the app launched. A successful
recovery verifies the selected paths, clears the journal and backups, and
refreshes Git status.

An interrupted journal records whether its operation created `index.lock` and
the checksum of the original index. Recovery may remove only that exact owned
lock after verifying both facts. An unrelated or changed lock remains a blocker
and is never deleted by checkpoint recovery.

The journal phases are `prepared`, `applyingFiles`, `installingIndex`,
`verifying`, `rollingBack`, `completed`, and `recovered`. Every transition is
durable. Tests can inject interruption after each phase and after any file move.

## Components and ownership

### `WorktreeCheckpointStore`

Owns paths, manifest and catalog coding, content-addressed blob reads and
writes, atomic publication, quarantine, retention, byte accounting, operation
journals, and blob garbage collection. It accepts an injected root and file
operations in tests.

### `WorktreeCheckpointService`

Owns Git and filesystem inspection, capture policy, state fingerprints,
checkpoint diffs, restore previews, blockers, temporary index construction,
transaction apply, rollback, and interrupted-operation recovery. It accepts an
injected process runner and restore fault injector in tests. Production uses
the existing `Process.git` and Git invocation conventions.

### `RightPaneState`

Owns observable checkpoint summaries and presentation state for the selected
worktree. It loads summaries alongside existing status and stash probes,
serializes checkpoint operations with other Git mutations, presents errors,
and refreshes status after restore or recovery. It does not encode manifests or
write files.

### SwiftUI

`ChangesTabView` adds checkpoint rows to the existing virtualized row plan.
Focused views own the section header, summary rows, create sheet, restore
preview, and interruption card. Model-based presentation uses item-driven
sheets. Buttons provide native keyboard and accessibility behavior, and list
identity comes from checkpoint and logical group UUIDs rather than mutable
labels or array positions.

A checkpoint diff tab follows the existing stash-diff tab pattern. Its state
identifies the worktree, checkpoint, and logical file group. Opening the same
group focuses the existing tab.

### `AppState`

Supplies read-only coordination facts needed by preflight:

- dirty editor paths for the selected worktree;
- active terminal sessions from `SessionRegistry`;
- active ACP session state for the worktree owner;
- local versus SSH-backed worktree support;
- Workspace member repository display context.

It does not stop sessions on behalf of restore. Existing Git-operation state
and a checkpoint mutation lease prevent overlapping Alas mutations.

## Preview semantics

The checkpoint's captured HEAD is the baseline for both saved states. Restore
requires current HEAD to match it exactly, so a path omitted from the manifest
has a known checkpoint state: clean index and working tree at that HEAD.

The preview snapshots current states for the union of saved dirty paths and
currently dirty paths. It compares raw kind, mode, and content identity for the
index and working tree separately. A selected path receives the checkpoint
state even when that state is clean, which lets a clean checkpoint remove later
changes. An unselected path keeps its current state.

Display status is derived from those exact states. It is not used as the source
of truth for restore. This avoids losing information when one path has both a
staged version and a different unstaged version.

## Error handling

User-facing errors distinguish:

- unsupported capture state;
- policy exclusion;
- unstable concurrent capture;
- stale restore preview;
- worktree lineage mismatch;
- changed HEAD;
- active session or dirty buffer blocker;
- storage limit or disk-full failure;
- corrupt checkpoint;
- failure before mutation;
- restore failure followed by successful rollback;
- restore failure with recovery still required.

Logs may contain checkpoint and operation UUIDs, Git exit status, phases, and
relative paths. They must not contain captured file contents, symlink targets,
or secret-like excluded basenames.

## Testing

Integration tests create temporary real Git repositories and exercise
`WorktreeCheckpointService` through the real `WorktreeCheckpointStore`. They
do not replace capture or restore with manifest fixtures for the acceptance
path.

The core matrix covers:

- a clean checkpoint followed by later tracked and untracked changes;
- separate staged and unstaged contents for the same file;
- tracked and untracked additions, tracked deletions, and rename pairs;
- executable-bit changes;
- symlink creation, replacement, and deletion without following targets;
- binary bytes containing NULs and invalid UTF-8;
- ignored paths and every explicit untracked exclusion reason;
- unreadable or unsupported tracked state failing the whole capture;
- stable relaunch load and isolation between two lineage IDs;
- rejection after deleting and recreating a worktree at the same path;
- changed HEAD, active Git operation, and index-lock rejection;
- selected restore preserving an unselected file's index and disk contents;
- full restore matching the checkpoint's index and working-tree states;
- a published and loadable pre-restore recovery checkpoint;
- stale preview detection after a concurrent file or index edit;
- injected failure before mutation, after each file move, during index install,
  and during verification;
- successful rollback and retained-journal recovery when rollback fails;
- relaunch discovery and explicit recovery of every nonterminal journal phase;
- manual and recovery count limits, byte-limit pruning, protected journal
  blobs, and an oversized checkpoint refusal.

Focused model and presentation tests cover summary counts, byte formatting,
compact timestamps, restore-effect wording, rename selection grouping,
blocker priority, remote support copy, Workspace member scope copy, stable row
identity, and sheet validation.

Verification runs focused checkpoint tests first, then SwiftFormat, `xcodegen`,
the full macOS build and test commands required by `AGENTS.md`, and
`git diff --check`.

## Acceptance mapping

- Create, name, inspect, and delete: Checkpoints section, create sheet,
  manifest-backed inspection, and confirmed deletion.
- Visible capture scope: policy version, inclusion totals, and stored
  exclusions in every checkpoint.
- Relaunch and isolation: atomic catalog storage partitioned and verified by
  Git lineage ID.
- Selective restore preview: logical groups with explicit index and disk
  outcomes.
- Recovery point: durable recovery checkpoint published before the first live
  write.
- Concurrent and partial failure safety: stable capture, stale-preview checks,
  session and buffer blockers, index locking, durable journals, rollback, and
  explicit relaunch recovery.
- Real path coverage: temporary repository integration tests spanning index,
  disk, untracked files, modes, symlinks, binaries, failures, and interruption.
- Bounded storage: fixed counts and byte ceiling shown in Changes.
- Support boundary: local worktrees only with explicit remote disablement.
- Workspace boundary: one named member worktree at a time with no atomic
  multi-repository claim.
