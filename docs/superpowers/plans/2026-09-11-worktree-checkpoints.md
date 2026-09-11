# Recoverable Worktree Checkpoints Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add durable, inspectable, selectively restorable checkpoints for one local Git worktree at a time, with exact index preservation and recoverable restore transactions.

**Architecture:** A content-addressed actor-backed store persists manifests, blobs, catalogs, and restore journals under Application Support. A process-backed snapshotter captures HEAD, index, and filesystem states, while a restore transaction prepares a replacement index and same-volume file replacements before changing user paths. `RightPaneState` coordinates the service with editor and session blockers, and focused SwiftUI views add checkpoint creation, browsing, preview, restore, deletion, and recovery to Changes.

**Tech Stack:** Swift 5.9, Swift Testing, SwiftUI for macOS 15, Foundation, CryptoKit, Darwin filesystem APIs, and Git plumbing commands.

**Spec:** `docs/superpowers/specs/2026-09-11-worktree-checkpoints-design.md`

## Global Constraints

- Keep code, comments, logs, and UI strings in English.
- Support local Git worktrees only in V1. Remote worktrees stay disabled with an explanation.
- A Workspace operation covers one named member worktree only. Do not claim atomic multi-repository behavior.
- Capture may not change HEAD, refs, branch history, the live index, or user files.
- Restore may not use `git reset --hard`, switch branches, create commits, or push.
- Restore requires the current HEAD and persisted Git lineage ID to match the checkpoint.
- Restore stays disabled until the user has stopped relevant terminal and ACP sessions.
- Restore of selected paths must preserve every unselected index entry and filesystem path.
- Publish a loadable recovery checkpoint before the first destructive write.
- Keep at most 20 manual and 5 recovery checkpoints, with 2 GiB total reachable storage per lineage.
- Include tracked changes completely or fail capture. Apply the approved explicit exclusion policy only to untracked files.
- Never log captured contents, symlink targets, or secret-like excluded basenames.
- Use Swift Testing, not XCTest.
- Run `rtk xcodegen` after adding source or test files.
- Prefix Alas build and test commands with `rtk`. Use `ALAS_FFF_TARGET_ARCH=arm64` if the vendored fff build blocks Xcode.

## File map

- `Alas/Sources/Checkpoints/CheckpointModels.swift`: persisted and presentation-neutral checkpoint value types.
- `Alas/Sources/Checkpoints/CheckpointFileSystem.swift`: no-follow filesystem inspection and durable atomic file operations.
- `Alas/Sources/Checkpoints/WorktreeCheckpointStore.swift`: content-addressed persistence, quarantine, retention, catalogs, and journals.
- `Alas/Sources/Checkpoints/CheckpointGitRunner.swift`: local Git command seam with raw-data output and environment overrides.
- `Alas/Sources/Checkpoints/WorktreeStateSnapshotter.swift`: exact HEAD, index, and worktree capture plus fingerprints and exclusions.
- `Alas/Sources/Checkpoints/WorktreeCheckpointService.swift`: capture, preview, delete, diff loading, and operation serialization.
- `Alas/Sources/Checkpoints/CheckpointRestoreTransaction.swift`: replacement-index preparation, apply, rollback, and interrupted recovery.
- `Alas/Sources/Right/Checkpoints/CheckpointRows.swift`: virtualized Changes section rows.
- `Alas/Sources/Right/Checkpoints/CreateCheckpointSheet.swift`: naming and capture-result sheet.
- `Alas/Sources/Right/Checkpoints/RestoreCheckpointSheet.swift`: selectable restore preview.
- `Alas/Sources/Right/Checkpoints/CheckpointRecoveryCard.swift`: interrupted-operation recovery UI.
- `Alas/Sources/Center/CheckpointDiffTabView.swift`: checkpoint-versus-current text, image, and binary inspection.
- `AlasTests/Checkpoints/CheckpointTestRepository.swift`: real temporary Git fixture used only by checkpoint tests.
- `AlasTests/Checkpoints/*Tests.swift`: model, store, capture, preview, restore, state, tab, and presentation regression suites.

---

### Task 1: Define checkpoint models and safe filesystem primitives

**Files:**
- Create: `Alas/Sources/Checkpoints/CheckpointModels.swift`
- Create: `Alas/Sources/Checkpoints/CheckpointFileSystem.swift`
- Modify: `Alas/Sources/Persistence/Paths.swift`
- Create: `AlasTests/Checkpoints/CheckpointModelTests.swift`
- Create: `AlasTests/Checkpoints/CheckpointFileSystemTests.swift`

**Interfaces:**
- Consumes: `Paths.appSupportRoot`, Foundation `Codable`, CryptoKit `SHA256`, and Darwin `lstat`, `open`, `readlink`, `fsync`, `rename`, and `symlink`.
- Produces: `CheckpointWorktreeTarget`, `CheckpointID`, `CheckpointKind`, `CheckpointBlobReference`, `CheckpointFileState`, `CheckpointPathState`, `CheckpointFileGroup`, `CheckpointExclusion`, `WorktreeCheckpointManifest`, `WorktreeCheckpointSummary`, `CheckpointCatalogSnapshot`, `CheckpointRestoreJournal`, `CheckpointLeafRead`, `CheckpointLeafMetadata`, `CheckpointFileSystem`, and `LiveCheckpointFileSystem`.

- [ ] **Step 1: Write failing model and filesystem tests**

Add literal round-trip fixtures and no-follow filesystem assertions. The model suite must prove that absent, regular, and symlink states retain their mode and blob references; invalid non-absent states without a blob fail validation; labels trim to 120 characters; and journal phases survive coding. The filesystem suite must prove that reading a symlink returns the link target instead of target contents, a symlinked parent fails containment, and `writeDurable` replaces bytes and mode.

```swift
@Test func manifestRoundTripPreservesSeparateIndexAndWorktreeStates() throws {
    let index = CheckpointFileState.regular(blob: .init(sha256: String(repeating: "a", count: 64), byteCount: 6), executable: false)
    let disk = CheckpointFileState.regular(blob: .init(sha256: String(repeating: "b", count: 64), byteCount: 8), executable: true)
    let manifest = WorktreeCheckpointManifest.fixture(index: index, worktree: disk)
    let decoded = try JSONDecoder.checkpoints.decode(
        WorktreeCheckpointManifest.self,
        from: JSONEncoder.checkpoints.encode(manifest)
    )
    #expect(decoded == manifest)
    #expect(decoded.paths[0].index != decoded.paths[0].worktree)
}

@Test func filesystemReadsSymlinkWithoutFollowingIt() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("outside".utf8).write(to: root.appendingPathComponent("target"))
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "target")
    let state = try LiveCheckpointFileSystem().readLeaf(root: root, relativePath: "link")
    #expect(state == .symlink(Data("target".utf8)))
}
```

- [ ] **Step 2: Regenerate and run the new suites to verify RED**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/alas-checkpoints-dd -only-testing:AlasTests/CheckpointModelTests -only-testing:AlasTests/CheckpointFileSystemTests test ALAS_FFF_TARGET_ARCH=arm64
```

Expected: compilation fails because the checkpoint types and filesystem seam do not exist.

- [ ] **Step 3: Implement the value types and invariants**

Use UUID-backed identity and explicit file-state kinds. Keep stored modes as Git mode strings so `100644`, `100755`, and `120000` never pass through decimal permission conversion.

```swift
typealias CheckpointID = UUID

enum CheckpointKind: String, Codable, Equatable, Sendable { case manual, recovery }
enum CheckpointLeafKind: String, Codable, Equatable, Sendable { case absent, regular, symlink }

struct CheckpointBlobReference: Codable, Equatable, Hashable, Sendable {
    let sha256: String
    let byteCount: Int64
}

struct CheckpointFileState: Codable, Equatable, Sendable {
    let kind: CheckpointLeafKind
    let mode: String?
    let blob: CheckpointBlobReference?

    static let absent = Self(kind: .absent, mode: nil, blob: nil)
    static func regular(blob: CheckpointBlobReference, executable: Bool) -> Self {
        Self(kind: .regular, mode: executable ? "100755" : "100644", blob: blob)
    }
    static func symlink(blob: CheckpointBlobReference) -> Self {
        Self(kind: .symlink, mode: "120000", blob: blob)
    }
    func validate() throws
}

struct CheckpointWorktreeTarget: Equatable, Sendable {
    let worktreeID: String
    let projectID: String
    let path: URL
    let lineageID: String
    let branch: String
    let repositoryName: String
    let workspaceName: String?
}

enum CheckpointLeafRead: Equatable, Sendable {
    case regular(data: Data, executable: Bool)
    case symlink(Data)
}

struct CheckpointLeafMetadata: Equatable, Sendable {
    let kind: CheckpointLeafKind
    let executable: Bool
    let byteCount: Int64
}
```

Define `CheckpointPathState` with `relativePath`, `head`, `index`, and `worktree`; `CheckpointFileGroup` with a stored UUID, primary path, optional rename source, and all member paths; and `WorktreeCheckpointManifest` with every field named in the spec. Add `schemaVersion = 1` and `capturePolicyVersion = 1`. Define a journal with phases `prepared`, `applyingFiles`, `installingIndex`, `verifying`, `rollingBack`, `completed`, and `recovered`, plus owned-lock checksum fields and completed paths.

- [ ] **Step 4: Implement the no-follow filesystem boundary**

`CheckpointFileSystem` must expose exact operations used later rather than `FileManager` itself:

```swift
protocol CheckpointFileSystem: Sendable {
    func readLeaf(root: URL, relativePath: String) throws -> CheckpointLeafRead
    func metadata(root: URL, relativePath: String) throws -> CheckpointLeafMetadata?
    func validateRelativePath(_ relativePath: String, under root: URL) throws -> URL
    func createDirectoryExclusively(_ url: URL, mode: mode_t) throws
    func writeDurable(_ data: Data, to url: URL, mode: mode_t) throws
    func createSymlink(target: Data, at url: URL) throws
    func move(_ source: URL, to destination: URL) throws
    func removeIfPresent(_ url: URL) throws
    func list(_ url: URL) throws -> [URL]
    func fileData(_ url: URL) throws -> Data
    func synchronizeDirectory(_ url: URL) throws
}
```

Walk every parent component with `lstat`; reject absolute paths, empty components, `.` and `..`, NUL, symlink parents, and destinations outside the standardized root. `readLeaf` uses `lstat`, reads regular bytes, calls `readlink` for symlinks, rejects directories and special files, and never follows a link. `writeDurable` loops until all bytes are written, calls `fsync`, closes, renames within the same directory, and applies `0644` or `0755`.

Add `Paths.checkpointsRoot` and `Paths.checkpointsDirectory(lineageID:)`. Validate lineage IDs as lowercase UUID strings before using them as path components.

- [ ] **Step 5: Run model and filesystem suites to verify GREEN**

Run the Step 2 command. Expected: both suites pass.

- [ ] **Step 6: Commit the foundation**

```bash
git add Alas/Sources/Checkpoints Alas/Sources/Persistence/Paths.swift AlasTests/Checkpoints Alas.xcodeproj/project.pbxproj
git commit -m "feat(checkpoints): add snapshot models and safe file access"
```

---

### Task 2: Build the durable content-addressed store

**Files:**
- Create: `Alas/Sources/Checkpoints/WorktreeCheckpointStore.swift`
- Create: `AlasTests/Checkpoints/WorktreeCheckpointStoreTests.swift`

**Interfaces:**
- Consumes: all Task 1 persisted models and `CheckpointFileSystem`.
- Produces: actor `WorktreeCheckpointStore` with `catalog`, `publish`, `load`, `readBlob`, `delete`, `journal`, `writeJournal`, `finishJournal`, and `recoverableJournals` methods.

- [ ] **Step 1: Write failing publication, relaunch, isolation, and deletion tests**

Use two lineage UUIDs under one temporary root. Publish literal manifests with a shared blob, reconstruct the actor, and assert that each lineage sees only its catalog. Delete one checkpoint and assert the other manifest and shared blob remain readable.

```swift
@Test func publishedCheckpointSurvivesStoreRecreationAndIsIsolatedByLineage() async throws {
    let root = try temporaryDirectory()
    let first = try publication(lineageID: lineageA, label: "Before parser", bytes: Data([0, 255, 1]))
    let store = WorktreeCheckpointStore(root: root)
    _ = try await store.publish(first)

    let reloaded = WorktreeCheckpointStore(root: root)
    #expect(try await reloaded.catalog(lineageID: lineageA).summaries.map(\.label) == ["Before parser"])
    #expect(try await reloaded.catalog(lineageID: lineageB).summaries.isEmpty)
    #expect(try await reloaded.readBlob(first.blobs.keys.first!, lineageID: lineageA) == Data([0, 255, 1]))
}
```

- [ ] **Step 2: Write failing quarantine and retention tests**

Cover these observable results with literal limits injected into the store:

- a manifest whose blob hash mismatches is moved under `quarantine` and its summary becomes unavailable;
- a corrupt catalog is renamed and rebuilt from valid manifests;
- the sixth recovery prunes the oldest recovery;
- the twenty-first manual prunes the oldest manual after recovery candidates are exhausted;
- unique reachable blobs, not the sum of manifest references, determine byte usage;
- an active journal protects its checkpoint, recovery checkpoint, and blobs;
- one publication larger than the byte ceiling fails without changing the previous catalog.

- [ ] **Step 3: Regenerate and run the store suite to verify RED**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/alas-checkpoints-dd -only-testing:AlasTests/WorktreeCheckpointStoreTests test ALAS_FFF_TARGET_ARCH=arm64
```

Expected: compilation fails because `WorktreeCheckpointStore` is missing.

- [ ] **Step 4: Implement atomic publication and reload reconciliation**

Expose this API:

```swift
actor WorktreeCheckpointStore {
    struct Limits: Equatable, Sendable {
        var manualCount = 20
        var recoveryCount = 5
        var bytes: Int64 = 2 * 1024 * 1024 * 1024
    }

    init(root: URL = Paths.checkpointsRoot,
         fileSystem: any CheckpointFileSystem = LiveCheckpointFileSystem(),
         limits: Limits = .init())

    func catalog(lineageID: String) throws -> CheckpointCatalogSnapshot
    func publish(_ publication: CheckpointPublication) throws -> CheckpointCatalogSnapshot
    func load(id: CheckpointID, lineageID: String) throws -> WorktreeCheckpointManifest
    func readBlob(_ reference: CheckpointBlobReference, lineageID: String) throws -> Data
    func delete(id: CheckpointID, lineageID: String) throws -> CheckpointCatalogSnapshot
    func writeJournal(_ journal: CheckpointRestoreJournal) throws
    func journal(id: UUID, lineageID: String) throws -> CheckpointRestoreJournal?
    func recoverableJournals(lineageID: String) throws -> [CheckpointRestoreJournal]
    func finishJournal(id: UUID, lineageID: String) throws
}

struct CheckpointPublication: Sendable {
    let manifest: WorktreeCheckpointManifest
    let blobs: [CheckpointBlobReference: Data]
}
```

Write every blob to `blobs/.<hash>.tmp`, verify SHA-256, fsync, then rename only if the final hash path is absent. Write the manifest into `entries/.<id>.tmp/manifest.json`, fsync the file and directory, then rename the directory. Calculate retention victims without deleting them, atomically publish the next catalog, and only then remove victim manifests and unreachable blobs. This ordering preserves the old catalog if any pre-publication operation fails.

On load, validate UUID lineage, schema, every relative path, state invariant, blob size, and blob hash. Rebuild a missing or corrupt catalog from valid entry manifests. Move invalid entries into `quarantine/<id>-<timestamp>` and retain an unavailable catalog summary containing only safe metadata and the validation error.

- [ ] **Step 5: Implement journal protection and garbage collection**

Journals use the same durable JSON write. Garbage collection computes a set of blob hashes referenced by every valid manifest plus every nonterminal journal. `delete` throws `CheckpointStoreError.operationReferencesCheckpoint` when a journal names the requested checkpoint. `finishJournal` removes only terminal journal state and never removes a worktree staging directory itself.

- [ ] **Step 6: Run the store suite to verify GREEN**

Run the Step 3 command. Expected: all store tests pass.

- [ ] **Step 7: Commit the store**

```bash
git add Alas/Sources/Checkpoints/WorktreeCheckpointStore.swift AlasTests/Checkpoints/WorktreeCheckpointStoreTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(checkpoints): persist bounded content-addressed snapshots"
```

---

### Task 3: Capture exact Git and filesystem state

**Files:**
- Create: `Alas/Sources/Checkpoints/CheckpointGitRunner.swift`
- Create: `Alas/Sources/Checkpoints/WorktreeStateSnapshotter.swift`
- Create: `AlasTests/Checkpoints/CheckpointTestRepository.swift`
- Create: `AlasTests/Checkpoints/WorktreeStateSnapshotterTests.swift`

**Interfaces:**
- Consumes: `GitInvocation`, `Process.run`, `Process.runData`, Task 1 filesystem primitives, and `WorktreeService.existingLocalLineageID`.
- Produces: `CheckpointGitRunning`, `LiveCheckpointGitRunner`, `WorktreeStateSnapshot`, `CheckpointCaptureAttempt`, and `WorktreeStateSnapshotter.snapshot(target:)`.

- [ ] **Step 1: Write the real Git fixture and failing state-matrix tests**

`CheckpointTestRepository` initializes `main`, configures an identity, creates a seed commit, writes raw data or symlinks, stages paths, and reads `HEAD:path`, `:path`, disk bytes, modes, and porcelain status independently. Keep expected values literal.

Create separate tests proving:

- one file can hold `HEAD = original`, `index = staged`, and `worktree = unstaged` simultaneously;
- a tracked deletion records an absent worktree state;
- staged rename groups contain both old and new paths;
- a `100755` index entry and executable disk file remain executable in the snapshot;
- symlink target bytes are captured without reading the target;
- NUL and invalid UTF-8 binary bytes round-trip as `Data`;
- untracked source is included, ignored content is absent from candidates;
- gitlink mode `160000`, an unmerged entry, and a sparse state the snapshotter cannot expand fail the capture attempt.

```swift
@Test func snapshotKeepsHeadIndexAndDiskVersionsDistinct() async throws {
    let repo = try await CheckpointTestRepository.make()
    defer { repo.remove() }
    try repo.write("original\n", to: "file.swift")
    try await repo.commitAll("seed")
    try repo.write("staged\n", to: "file.swift")
    try await repo.stage("file.swift")
    try repo.write("unstaged\n", to: "file.swift")

    let snapshot = try await WorktreeStateSnapshotter.live.snapshot(target: repo.target)
    let path = try #require(snapshot.paths["file.swift"])
    #expect(try snapshot.payload(path.head) == Data("original\n".utf8))
    #expect(try snapshot.payload(path.index) == Data("staged\n".utf8))
    #expect(try snapshot.payload(path.worktree) == Data("unstaged\n".utf8))
}
```

- [ ] **Step 2: Regenerate and run the snapshot suite to verify RED**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/alas-checkpoints-dd -only-testing:AlasTests/WorktreeStateSnapshotterTests test ALAS_FFF_TARGET_ARCH=arm64
```

Expected: compilation fails because the snapshotter and Git runner are missing.

- [ ] **Step 3: Implement the local Git runner**

```swift
protocol CheckpointGitRunning: Sendable {
    func run(_ args: [String], cwd: URL, environment: [String: String]) async throws -> ProcessResult
    func runData(_ args: [String], cwd: URL, environment: [String: String]) async throws -> ProcessResultData
}
```

`LiveCheckpointGitRunner` rejects `cwd.isRemoteAlasPath`, builds a local `GitInvocation`, merges only explicit `GIT_INDEX_FILE` into `Process.gitEnv()`, and calls `Process.run` or `Process.runData`. Never interpolate a path into a shell command.

- [ ] **Step 4: Implement status, tree, index, and disk capture**

Run `rev-parse --verify HEAD`, `symbolic-ref --short -q HEAD`, `status --porcelain=v2 -z --untracked-files=all`, `ls-files --stage -z`, and rename-aware cached and working-tree `diff --name-status -z`. Parse NUL records and fail on invalid UTF-8 paths rather than replacing bytes.

Build the union of changed destinations, rename sources, and allowed untracked candidates. Read HEAD and index blobs with `cat-file blob <oid>` through raw `Data`; read disk leaves through `CheckpointFileSystem`. Convert only modes `100644`, `100755`, and `120000`. Check that `target.lineageID` equals `WorktreeService.existingLocalLineageID` before and after capture.

Return:

```swift
struct WorktreeStateSnapshot: Equatable, Sendable {
    let lineageID: String
    let headOID: String
    let branch: String
    let indexChecksum: String
    let paths: [String: CheckpointPathState]
    let groups: [CheckpointFileGroup]
    let exclusions: [CheckpointExclusion]
    let payloads: [String: Data]
    let fingerprint: String
}
```

Calculate `fingerprint` from sorted path records containing kind, mode, SHA-256, index checksum, HEAD, and lineage. Include clean baseline states only logically; do not materialize every tracked file.

- [ ] **Step 5: Implement the explicit untracked policy**

Match path components and basenames case-sensitively exactly as listed in the spec. Match extensions case-insensitively. Exclude files over 10 MiB, special leaves, symlink-parent paths, and `.alas-checkpoint-restore-<UUID>`. Record one `CheckpointExclusion` per path with `.ignoredByPolicy`, `.likelySecret`, `.tooLarge`, `.specialFile`, `.unsafePath`, or `.internalRestoreDirectory`. Do not read excluded payload bytes.

- [ ] **Step 6: Run the snapshot suite to verify GREEN**

Run the Step 2 command. Expected: all snapshot tests pass and `git status --porcelain=v2` before and after capture is byte-for-byte equal.

- [ ] **Step 7: Commit exact capture**

```bash
git add Alas/Sources/Checkpoints/CheckpointGitRunner.swift Alas/Sources/Checkpoints/WorktreeStateSnapshotter.swift AlasTests/Checkpoints Alas.xcodeproj/project.pbxproj
git commit -m "feat(checkpoints): capture exact worktree and index state"
```

---

### Task 4: Publish stable manual and recovery captures

**Files:**
- Create: `Alas/Sources/Checkpoints/WorktreeCheckpointService.swift`
- Create: `AlasTests/Checkpoints/WorktreeCheckpointCaptureTests.swift`

**Interfaces:**
- Consumes: `WorktreeStateSnapshotter`, `WorktreeCheckpointStore`, and `CheckpointWorktreeTarget`.
- Produces: `WorktreeCheckpointServicing`, actor `WorktreeCheckpointService`, `createManual`, internal `createRecovery`, `summaries`, `manifest`, and `delete`.

- [ ] **Step 1: Write failing service-path tests**

Exercise the real snapshotter and store together. Assert that a successful manual capture has the trimmed label, persisted exclusions, exact staged and unstaged payloads, and unchanged HEAD, index checksum, porcelain status, and disk bytes. Reconstruct both store and service and load the same summary.

Add a capture hook that changes a tracked file after attempt one. Assert the service retries and publishes attempt two only. Change it after both attempts and assert `CheckpointCaptureError.unstableWorktree`, an empty catalog, and no reachable blobs.

```swift
@Test func captureRetriesOneConcurrentChangeAndPublishesOneStableCheckpoint() async throws {
    let fixture = try await CheckpointCaptureFixture.make()
    let hooks = CheckpointCaptureHooks(afterPayloadStaging: { attempt in
        if attempt == 1 { try fixture.repo.write("second\n", to: "file.swift") }
    })
    let service = fixture.service(hooks: hooks)
    let summary = try await service.createManual(target: fixture.target, label: "  Before edit  ")
    #expect(summary.label == "Before edit")
    #expect(try await service.summaries(target: fixture.target).summaries.count == 1)
    #expect(try await fixture.payload(checkpoint: summary.id, path: "file.swift", side: .worktree) == Data("second\n".utf8))
}
```

- [ ] **Step 2: Run the capture suite to verify RED**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/alas-checkpoints-dd -only-testing:AlasTests/WorktreeCheckpointCaptureTests test ALAS_FFF_TARGET_ARCH=arm64
```

Expected: compilation fails because the service is missing.

- [ ] **Step 3: Implement the service protocol and stable capture loop**

```swift
protocol WorktreeCheckpointServicing: Sendable {
    func summaries(target: CheckpointWorktreeTarget) async throws -> CheckpointCatalogSnapshot
    func createManual(target: CheckpointWorktreeTarget, label: String) async throws -> WorktreeCheckpointSummary
    func manifest(target: CheckpointWorktreeTarget, id: CheckpointID) async throws -> WorktreeCheckpointManifest
    func delete(target: CheckpointWorktreeTarget, id: CheckpointID) async throws -> CheckpointCatalogSnapshot
}

actor WorktreeCheckpointService: WorktreeCheckpointServicing {
    init(store: WorktreeCheckpointStore = .init(),
         snapshotter: WorktreeStateSnapshotter = .live,
         hooks: CheckpointCaptureHooks = .none)
}

struct CheckpointCaptureHooks: Sendable {
    let afterPayloadStaging: @Sendable (Int) async throws -> Void

    static let none = Self(afterPayloadStaging: { _ in })
}
```

Validate labels before running Git. Capture an attempt, invoke the hook, capture a verification attempt, and compare fingerprints. On mismatch, discard in-memory payloads and repeat once. On equality, derive SHA-256 references, file counts, byte accounting, and the manifest, then call one `store.publish`. `createRecovery` takes selected current path states and a fixed label and uses the same publication path with kind `.recovery`.

- [ ] **Step 4: Run capture and store suites to verify GREEN**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/alas-checkpoints-dd -only-testing:AlasTests/WorktreeCheckpointCaptureTests -only-testing:AlasTests/WorktreeCheckpointStoreTests test ALAS_FFF_TARGET_ARCH=arm64
```

Expected: both suites pass.

- [ ] **Step 5: Commit stable publication**

```bash
git add Alas/Sources/Checkpoints/WorktreeCheckpointService.swift AlasTests/Checkpoints/WorktreeCheckpointCaptureTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(checkpoints): publish stable manual captures"
```

---

### Task 5: Build restore previews and checkpoint diffs

**Files:**
- Modify: `Alas/Sources/Checkpoints/CheckpointModels.swift`
- Modify: `Alas/Sources/Checkpoints/WorktreeCheckpointService.swift`
- Create: `AlasTests/Checkpoints/CheckpointRestorePreviewTests.swift`
- Create: `AlasTests/Checkpoints/CheckpointDiffLoaderTests.swift`

**Interfaces:**
- Consumes: captured manifest, fresh `WorktreeStateSnapshot`, stored blobs, `DiffParser`, `ImageFileType`, and `ImageDiffPair`.
- Produces: `CheckpointCoordinationSnapshot`, `CheckpointRestoreBlocker`, `CheckpointRestoreEffect`, `CheckpointRestorePreview`, `CheckpointDiffContent`, `restorePreview`, and `diffContent`.

- [ ] **Step 1: Write failing preview tests**

Use a checkpoint where `a.swift` was staged, `b.swift` was unstaged, and `old.swift -> new.swift` was renamed. Then create later changes to `clean-at-capture.swift` and `unselected.swift`. Assert that the preview:

- contains the union of checkpoint-dirty and current-dirty paths;
- selects every group by default;
- groups both rename paths under one UUID;
- describes index and worktree effects separately with literal strings;
- removes a later untracked file when the clean baseline group is selected;
- preserves both states when its group is omitted from `selectedGroupIDs`.

Add blocker tests with literal priority: interrupted journal, lineage mismatch, changed HEAD, Git operation, index lock, active session, selected dirty buffer, corrupt checkpoint. Assert remote support text and Workspace member scope text exactly match the spec.

- [ ] **Step 2: Write failing text, image, and binary diff tests**

Assert `diffContent` returns:

- `.text(ParsedDiff)` whose added line is the current text and deleted line is checkpoint text;
- `.image(ImageDiffPair)` with checkpoint bytes on `before` and current bytes on `after`;
- `.binary` with literal before and after byte counts for non-image binary data;
- `.unavailable` for a deleted checkpoint or missing required blob.

- [ ] **Step 3: Run preview suites to verify RED**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/alas-checkpoints-dd -only-testing:AlasTests/CheckpointRestorePreviewTests -only-testing:AlasTests/CheckpointDiffLoaderTests test ALAS_FFF_TARGET_ARCH=arm64
```

Expected: compilation fails because preview and diff APIs are missing.

- [ ] **Step 4: Implement preview value types and candidate union**

```swift
struct CheckpointCoordinationSnapshot: Equatable, Sendable {
    let dirtyEditorPaths: Set<String>
    let activeTerminalCount: Int
    let activeACPCount: Int
    let otherGitMutationActive: Bool
    let scopeDescription: String

    static let clear = Self(
        dirtyEditorPaths: [],
        activeTerminalCount: 0,
        activeACPCount: 0,
        otherGitMutationActive: false,
        scopeDescription: "This repository only"
    )
}

struct CheckpointRestoreGroup: Identifiable, Equatable, Sendable {
    let id: UUID
    let primaryPath: String
    let memberPaths: [String]
    let renameSource: String?
    let effects: [CheckpointRestoreEffect]
}

struct CheckpointRestorePreview: Identifiable, Equatable, Sendable {
    let id: UUID
    let checkpointID: CheckpointID
    let checkpointLabel: String
    let currentFingerprint: String
    let groups: [CheckpointRestoreGroup]
    let blocker: CheckpointRestoreBlocker?
    let scopeDescription: String
}

enum CheckpointDiffContent: Sendable {
    case text(ParsedDiff)
    case image(ImageDiffPair)
    case binary(beforeByteCount: Int64?, afterByteCount: Int64?)
    case unavailable(String)
}
```

For current-only paths, obtain the clean checkpoint state from the matching HEAD tree and set both desired index and desired worktree to that state. For manifest paths, use stored states. Compare kind, mode, and blob hash, not status letters. Sort groups by primary path. Keep rename pairs indivisible. Generate user-facing effect text through pure `CheckpointRestoreEffect.description` functions so tests do not need to host SwiftUI.

- [ ] **Step 5: Implement diff loading without changing the repository**

For text, write checkpoint and current bytes into a temporary directory and run local `git diff --no-index --no-ext-diff --src-prefix=checkpoint/ --dst-prefix=current/ -- <before> <after>`. Exit 1 means differences and is successful; parse stdout with `DiffParser`. Decode supported images into `NSImage` and count frames through the same helpers as existing image loaders. Do not decode other binary bytes as text.

- [ ] **Step 6: Run preview and diff suites to verify GREEN**

Run the Step 3 command. Expected: both suites pass.

- [ ] **Step 7: Commit preview behavior**

```bash
git add Alas/Sources/Checkpoints AlasTests/Checkpoints
git commit -m "feat(checkpoints): preview selective restore effects"
```

---

### Task 6: Prepare replacement indexes and same-volume file operations

**Files:**
- Create: `Alas/Sources/Checkpoints/CheckpointRestoreTransaction.swift`
- Create: `AlasTests/Checkpoints/CheckpointRestorePreparationTests.swift`

**Interfaces:**
- Consumes: `CheckpointRestorePreview`, selected group IDs, checkpoint blobs, `CheckpointGitRunning`, `CheckpointFileSystem`, and store journals.
- Produces: `CheckpointRestorePreparation`, `CheckpointRestoreFaultInjector`, and `CheckpointRestoreTransaction.prepare`.

- [ ] **Step 1: Write failing non-destructive preparation tests**

Prepare a restore containing a staged deletion, executable file, symlink, and untracked removal. Assert before apply that:

- HEAD, porcelain status, current index checksum, and every user path remain unchanged;
- a recovery checkpoint exists and reloads with the pre-restore bytes and index states;
- the prepared index produces exact desired entries when queried through `GIT_INDEX_FILE`;
- replacement and backup roots are inside `.alas-checkpoint-restore-<operation UUID>` at the worktree root;
- the durable journal is `.prepared` and names the recovery checkpoint;
- an operation that would exceed retention fails before creating the staging directory.

- [ ] **Step 2: Run the preparation suite to verify RED**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/alas-checkpoints-dd -only-testing:AlasTests/CheckpointRestorePreparationTests test ALAS_FFF_TARGET_ARCH=arm64
```

Expected: compilation fails because `CheckpointRestoreTransaction` is missing.

- [ ] **Step 3: Implement recovery capture and prepared-index construction**

```swift
struct CheckpointRestorePreparation: Equatable, Sendable {
    let operationID: UUID
    let target: CheckpointWorktreeTarget
    let checkpointID: CheckpointID
    let recoveryCheckpointID: CheckpointID
    let selectedPaths: [String]
    let expectedFingerprint: String
    let expectedIndexChecksum: String
    let preparedIndex: URL
    let stagingRoot: URL
}

enum CheckpointRestoreFaultPoint: Equatable, Sendable {
    case afterRecoveryPublication
    case afterJournalPrepared
    case afterFileMove(path: String)
    case beforeIndexInstall
    case afterIndexInstall
    case beforeVerification
    case duringRollback(path: String)
}

struct CheckpointRestoreFaultInjector: Sendable {
    let hit: @Sendable (CheckpointRestoreFaultPoint) throws -> Void

    static let none = Self(hit: { _ in })
}
```

Recompute the preview fingerprint before preparation. Publish and reload the recovery checkpoint before creating live staging. Copy the current index to the operation area, or run `read-tree --empty` with `GIT_INDEX_FILE` when no index exists. For each selected desired index state, run `update-index --force-remove -- <path>` for absence. For regular files and symlinks, materialize stored bytes, run `hash-object -w <file>`, then `update-index --add --cacheinfo <mode> <oid> <path>` against the prepared index.

- [ ] **Step 4: Materialize same-volume replacements and a durable journal**

Create `.alas-checkpoint-restore-<UUID>` with `mkdir` exclusive mode `0700`. Put replacements and backups under encoded UUID filenames, never under user-controlled relative paths. Record a path-to-staging-name map in the journal. Verify each prepared replacement hash, kind, and mode, then write and reload the `.prepared` journal. If preparation fails, remove only the exclusively created staging root and leave the published recovery checkpoint visible.

- [ ] **Step 5: Run the preparation suite to verify GREEN**

Run the Step 2 command. Expected: all tests pass.

- [ ] **Step 6: Commit restore preparation**

```bash
git add Alas/Sources/Checkpoints/CheckpointRestoreTransaction.swift AlasTests/Checkpoints/CheckpointRestorePreparationTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(checkpoints): prepare recoverable restore transactions"
```

---

### Task 7: Apply, roll back, and recover interrupted restores

**Files:**
- Modify: `Alas/Sources/Checkpoints/CheckpointRestoreTransaction.swift`
- Modify: `Alas/Sources/Checkpoints/WorktreeCheckpointService.swift`
- Create: `AlasTests/Checkpoints/CheckpointRestoreIntegrationTests.swift`
- Create: `AlasTests/Checkpoints/CheckpointRestoreInterruptionTests.swift`

**Interfaces:**
- Consumes: Task 6 preparation and fault points.
- Produces: `restore`, `recoverInterruptedRestore`, `CheckpointRestoreResult`, exact Git index lock ownership, rollback, verification, and journal cleanup.

- [ ] **Step 1: Write failing selective and full restore integration tests**

Use real repositories and the public service path. Cover untracked additions, tracked additions and deletions, distinct staged and unstaged contents, rename pairs, executable bits, symlinks, and binary bytes. In the selective case, omit one group and assert its index OID and disk SHA-256 are unchanged. In the full case, assert every selected index and worktree state equals the checkpoint and HEAD is unchanged. Assert a visible recovery checkpoint contains the exact replaced state.

```swift
@Test func selectiveRestorePreservesUnselectedIndexAndDiskBytes() async throws {
    let fixture = try await RestoreFixture.makeWithTwoChangedFiles()
    let checkpoint = try await fixture.capture("Before experiment")
    try await fixture.makeSecondState()
    let preview = try await fixture.preview(checkpoint)
    let selected = Set(preview.groups.filter { $0.primaryPath == "selected.bin" }.map(\.id))
    let unselectedBefore = try await fixture.exactState("keep.swift")

    let result = try await fixture.service.restore(target: fixture.target, preview: preview, selectedGroupIDs: selected, coordination: .clear)

    #expect(result.restoredPaths == ["selected.bin"])
    #expect(try await fixture.exactState("keep.swift") == unselectedBefore)
    #expect(try await fixture.head() == fixture.originalHead)
}
```

- [ ] **Step 2: Write failing stale-state, lock, rollback, and relaunch tests**

Assert no live write occurs when the preview fingerprint, index checksum, HEAD, lineage, or selected-path hash changes. Create an unrelated `index.lock` and assert it remains byte-for-byte unchanged.

Inject failure after each file move, before index install, after index install, and before verification. Assert either full rollback to the pre-restore state or a nonterminal journal plus intact backups. Recreate the store and service, list the journal, call explicit recovery, and assert pre-restore index and disk state. Change the owned lock bytes before recovery and assert recovery refuses to remove it.

- [ ] **Step 3: Run restore suites to verify RED**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/alas-checkpoints-dd -only-testing:AlasTests/CheckpointRestoreIntegrationTests -only-testing:AlasTests/CheckpointRestoreInterruptionTests test ALAS_FFF_TARGET_ARCH=arm64
```

Expected: tests fail because apply and recovery are not implemented.

- [ ] **Step 4: Implement apply and index installation**

Add service methods:

```swift
func restore(target: CheckpointWorktreeTarget,
             preview: CheckpointRestorePreview,
             selectedGroupIDs: Set<UUID>,
             coordination: CheckpointCoordinationSnapshot) async throws -> CheckpointRestoreResult

func recoverInterruptedRestore(target: CheckpointWorktreeTarget,
                               operationID: UUID,
                               coordination: CheckpointCoordinationSnapshot) async throws -> CheckpointRestoreResult
```

After `prepare`, create the real Git `index.lock` with `O_CREAT | O_EXCL`, record its empty-file checksum and ownership in the journal, and revalidate the current index and selected path fingerprints. For each path, move the current leaf to its operation backup, move the replacement into place or leave it absent, fsync both directories, append the completed path, and persist `.applyingFiles`.

Copy the prepared index bytes into the owned lock, fsync it, persist `.installingIndex`, and rename it atomically to `index`. Persist `.verifying`, snapshot selected states, and compare to the desired manifest states. On equality, persist `.completed`, remove the staging root, finish the journal, and return the retained recovery checkpoint ID.

- [ ] **Step 5: Implement rollback and explicit relaunch recovery**

On any post-write error, persist `.rollingBack`. Restore paths from operation backups in reverse completed order and install an index built from the recovery checkpoint. Verify the pre-restore fingerprint. A successful rollback removes only an owned unchanged `index.lock`, persists `.recovered`, cleans staging, finishes the journal, and throws `restoreFailedButRecovered`.

If rollback fails, retain every artifact and throw `recoveryRequired(operationID:paths:phase:)`. `recoverInterruptedRestore` accepts only a nonterminal journal whose target lineage and staging-root UUID match, refuses active sessions and dirty selected buffers, verifies any operation-owned lock checksum, then runs rollback. It never acts automatically during catalog load or app launch.

- [ ] **Step 6: Run all restore suites to verify GREEN**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/alas-checkpoints-dd -only-testing:AlasTests/CheckpointRestorePreparationTests -only-testing:AlasTests/CheckpointRestoreIntegrationTests -only-testing:AlasTests/CheckpointRestoreInterruptionTests test ALAS_FFF_TARGET_ARCH=arm64
```

Expected: all restore suites pass.

- [ ] **Step 7: Commit transaction recovery**

```bash
git add Alas/Sources/Checkpoints AlasTests/Checkpoints
git commit -m "feat(checkpoints): restore files through recoverable transactions"
```

---

### Task 8: Connect editor, session, Workspace, and RightPane state

**Files:**
- Modify: `Alas/Sources/Center/TabsManager.swift`
- Modify: `Alas/Sources/ACP/Session/ACPSessionManager.swift`
- Modify: `Alas/Sources/App/AppState.swift`
- Modify: `Alas/Sources/Right/RightPaneStore.swift`
- Modify: `Alas/Sources/Right/RightPaneState.swift`
- Create: `AlasTests/Checkpoints/CheckpointCoordinationTests.swift`
- Create: `AlasTests/Checkpoints/RightPaneCheckpointStateTests.swift`

**Interfaces:**
- Consumes: public checkpoint service methods and existing `TabsManager`, `SessionRegistry`, ACP managers, Workspace navigation, watcher, and Git-operation state.
- Produces: `TabsManager.unsavedRelativePaths`, `ACPSessionManager.hasActiveCheckpointWriter`, `AppState.checkpointCoordination`, and observable checkpoint state/actions on `RightPaneState`.

- [ ] **Step 1: Write failing coordination tests**

Assert `unsavedRelativePaths` includes a live dirty editor and an unloaded hot-exit snapshot but excludes clean and external files. Assert ACP attach-in-progress and attached runners count as active writers, while persisted history without a runner does not. Assert AppState counts normal worktree terminals plus shared Workspace checkout terminals and agents when the focused member matches. Assert the scope description names the repository and Workspace without claiming other members.

- [ ] **Step 2: Write failing RightPane state tests**

With a recording `WorktreeCheckpointServicing` fake, assert:

- start or refresh loads catalog summaries and nonterminal journals;
- create rejects blank labels, serializes duplicate clicks, updates the catalog, and retains exclusions;
- preview passes a fresh coordination snapshot;
- restore rechecks coordination, pauses watcher refreshes, refreshes Git once, then restarts watching;
- delete updates summaries only after service success;
- remote worktrees never call the service and expose the approved disabled reason;
- checkpoint mutation disables stage, unstage, discard, stash, pull, merge, and GG entry points.

- [ ] **Step 3: Regenerate and run coordination suites to verify RED**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/alas-checkpoints-dd -only-testing:AlasTests/CheckpointCoordinationTests -only-testing:AlasTests/RightPaneCheckpointStateTests test ALAS_FFF_TARGET_ARCH=arm64
```

Expected: compilation fails because coordination accessors and RightPane checkpoint state are absent.

- [ ] **Step 4: Add read-only coordination accessors**

```swift
func unsavedRelativePaths(forWorktree worktreeID: String) -> Set<String>

var hasActiveCheckpointWriter: Bool {
    !runners.isEmpty || !attachingSessions.isEmpty
}

func checkpointCoordination(for worktree: Worktree,
                            selectedPaths: Set<String>) -> CheckpointCoordinationSnapshot
```

In AppState, include `terminal.registry.sessions(forWorktree:)` and `.worktree` ACP ownership. When the selected Workspace checkout's focused member resolves to this worktree, also include its `SessionOwnerID.workspaceCheckout` terminal and ACP writers. Intersect unsaved paths with selected restore paths. Build scope copy from `ProjectConfig.name`, `selectedWorkspaceCheckout`, and the focused member only.

- [ ] **Step 5: Add checkpoint state and operations to RightPaneState**

Add summaries, storage usage, expansion IDs, manifest cache, create sheet state, restore preview state, pending deletion, nonterminal journal summaries, in-flight kind, and last error. Inject `any WorktreeCheckpointServicing` through the initializer with a production default, preserving existing call sites.

Load checkpoint summaries alongside stashes in `performRefresh`. Keep a checkpoint load failure separate from Git status failure so Changes still renders. Route capture, preview, restore, delete, and recovery through one in-flight guard. Before restore and recovery call the AppState-provided coordination closure again. Stop `watcher` immediately before service mutation, restart it in `defer`, call `markSnapshotUnknown`, then await one `refresh` on success or recovered failure.

Guard every existing local Git mutation entry point while a checkpoint operation is active and include checkpoint activity in existing disabled-reason calculations.

- [ ] **Step 6: Run coordination and existing RightPane mutation suites to verify GREEN**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/alas-checkpoints-dd -only-testing:AlasTests/CheckpointCoordinationTests -only-testing:AlasTests/RightPaneCheckpointStateTests -only-testing:AlasTests/RightPaneOptimisticStageTests -only-testing:AlasTests/RightPaneStateDiscardTests test ALAS_FFF_TARGET_ARCH=arm64
```

Expected: all selected suites pass.

- [ ] **Step 7: Commit application coordination**

```bash
git add Alas/Sources/Center/TabsManager.swift Alas/Sources/ACP/Session/ACPSessionManager.swift Alas/Sources/App/AppState.swift Alas/Sources/Right/RightPaneStore.swift Alas/Sources/Right/RightPaneState.swift AlasTests/Checkpoints Alas.xcodeproj/project.pbxproj
git commit -m "feat(checkpoints): coordinate restore blockers and right pane state"
```

---

### Task 9: Add checkpoint creation, browsing, exclusions, and deletion UI

**Files:**
- Modify: `Alas/Sources/Right/SectionHeader.swift`
- Modify: `Alas/Sources/Right/ChangesTabView.swift`
- Modify: `Alas/Sources/Right/RightPaneView.swift`
- Create: `Alas/Sources/Right/Checkpoints/CheckpointRows.swift`
- Create: `Alas/Sources/Right/Checkpoints/CreateCheckpointSheet.swift`
- Create: `AlasTests/Checkpoints/CheckpointPresentationTests.swift`

**Interfaces:**
- Consumes: Task 8 observable state and actions.
- Produces: `.checkpoints` section role, checkpoint rows in `AppKitDiffRowPlan`, creation sheet, exclusion disclosure, storage footer, and delete confirmation.

- [ ] **Step 1: Write failing pure presentation and hosted-view tests**

Assert compact dates omit the date for today and include it for older checkpoints; byte formatting uses binary units; summary text distinguishes staged, unstaged, and untracked counts; manual and recovery labels remain distinct; the 20, 5, and 2 GiB limits appear in footer text; the remote reason is exact; and UUID row IDs remain stable when labels change.

Host `CreateCheckpointSheet` and assert its default action is disabled for whitespace, enabled for a trimmed valid label, caps input at 120 characters, says unsaved buffers are not captured, and renders every exclusion path with its reason after success.

- [ ] **Step 2: Regenerate and run presentation tests to verify RED**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/alas-checkpoints-dd -only-testing:AlasTests/CheckpointPresentationTests test ALAS_FFF_TARGET_ARCH=arm64
```

Expected: compilation fails because checkpoint views are missing.

- [ ] **Step 3: Add the virtualized Checkpoints section**

Add `.checkpoints` with `clock.arrow.circlepath` to `SectionHeaderRole`. In `ChangesTabView.appKitScrollPlan`, append checkpoint rows after Working tree and before Stashes. Keep the header present for an empty catalog. Use checkpoint UUID and group UUID in row IDs and equality tokens. The create action must be a real `Button` in the header trailing content with its own accessibility label so it does not toggle expansion.

Expanded checkpoint rows call `rps.loadCheckpointManifest` once, show a spinner or inline error, then render logical file groups with index and working-tree badges. The menu calls restore preview or delete request. Add a footer row for storage usage and fixed limits.

- [ ] **Step 4: Add item-driven creation and deletion presentation**

Use `@State private` only inside focused views. `RightPaneView` presents creation through `.sheet(item:)` state and deletion through `.alert(..., presenting:)`. The sheet owns dismiss through `@Environment(\.dismiss)` after a successful capture; it keeps errors visible without closing. The delete alert names the checkpoint label, marks Delete destructive, and states that the worktree is unchanged.

- [ ] **Step 5: Run presentation and row-plan suites to verify GREEN**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/alas-checkpoints-dd -only-testing:AlasTests/CheckpointPresentationTests -only-testing:AlasTests/AppKitDiffScrollerTests test ALAS_FFF_TARGET_ARCH=arm64
```

Expected: selected suites pass.

- [ ] **Step 6: Commit capture and browse UI**

```bash
git add Alas/Sources/Right AlasTests/Checkpoints Alas.xcodeproj/project.pbxproj
git commit -m "feat(checkpoints): add checkpoint history to Changes"
```

---

### Task 10: Add checkpoint diff tabs

**Files:**
- Modify: `Alas/Sources/Center/Tab.swift`
- Modify: `Alas/Sources/Center/TabsManager.swift`
- Modify: `Alas/Sources/Center/CenterPaneView.swift`
- Modify: `Alas/Sources/App/AppState.swift`
- Modify: `Alas/Sources/Right/ChangesTabView.swift`
- Create: `Alas/Sources/Center/CheckpointDiffTabView.swift`
- Create: `AlasTests/Checkpoints/CheckpointDiffTabTests.swift`

**Interfaces:**
- Consumes: `WorktreeCheckpointService.diffContent`, existing `DiffPaneView`, `ImageDiffView`, and center-tab persistence.
- Produces: `Tab.checkpointDiff`, `CheckpointDiffTabState`, `TabsManager.appendCheckpointDiff`, `AppState.openCheckpointDiffTab`, and the center view.

- [ ] **Step 1: Write failing tab coding, deduplication, and content-routing tests**

Assert a checkpoint tab round-trips through `TabsFile`, has icon `clock.arrow.circlepath`, returns its primary relative path, disables system-open actions, and completes startup recovery only after loading. Opening the same worktree, checkpoint UUID, and group UUID twice must focus one tab; a different checkpoint or group creates another. Assert text, image, binary, missing-blob, and deleted-checkpoint loader results choose the correct view model.

- [ ] **Step 2: Run the tab suite to verify RED**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/alas-checkpoints-dd -only-testing:AlasTests/CheckpointDiffTabTests test ALAS_FFF_TARGET_ARCH=arm64
```

Expected: compilation fails because the tab case and view are missing.

- [ ] **Step 3: Add the persisted tab state and routing**

```swift
struct CheckpointDiffTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let worktreeID: String
    let checkpointID: CheckpointID
    let groupID: UUID
    let primaryPath: String
    let title: String

    init(worktreeID: String, checkpointID: CheckpointID, groupID: UUID,
         primaryPath: String, checkpointLabel: String) {
        self.id = "checkpoint-diff:\(worktreeID):\(checkpointID.uuidString):\(groupID.uuidString)"
        self.worktreeID = worktreeID
        self.checkpointID = checkpointID
        self.groupID = groupID
        self.primaryPath = primaryPath
        self.title = "\((primaryPath as NSString).lastPathComponent) @ \(checkpointLabel)"
    }
}
```

Update every exhaustive `Tab` projection, `supportsSystemOpenActions`, `StartupRecoveryPaneCompletionPolicy`, TabsManager append path, AppState open/focus logic, and CenterPaneView switch. Existing default-only switches need no checkpoint-specific behavior.

- [ ] **Step 4: Render checkpoint diff content**

`CheckpointDiffTabView` owns private loading, error, layout, wrapping, whitespace, and retry state. It resolves the current worktree and calls the service by checkpoint and group UUID. Render `.text` through `DiffDisplayModelBuilder` and `DiffPaneView`, `.image` through `ImageDiffView` with the checkpoint label as source badge, `.binary` as a centered notice with before and after byte counts, and `.unavailable` as an inline error with Retry. Call `onStartupRecoveryReady` after every terminal load result.

- [ ] **Step 5: Run tab, coding, and startup-recovery suites to verify GREEN**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/alas-checkpoints-dd -only-testing:AlasTests/CheckpointDiffTabTests -only-testing:AlasTests/TabsManagerTests -only-testing:AlasTests/StartupRecoveryTests test ALAS_FFF_TARGET_ARCH=arm64
```

Expected: selected suites pass.

- [ ] **Step 6: Commit checkpoint inspection tabs**

```bash
git add Alas/Sources/Center Alas/Sources/App/AppState.swift Alas/Sources/Right/ChangesTabView.swift AlasTests/Checkpoints Alas.xcodeproj/project.pbxproj
git commit -m "feat(checkpoints): inspect checkpoint files in diff tabs"
```

---

### Task 11: Add selective restore and interrupted-recovery UI

**Files:**
- Modify: `Alas/Sources/Right/ChangesTabView.swift`
- Modify: `Alas/Sources/Right/RightPaneView.swift`
- Create: `Alas/Sources/Right/Checkpoints/RestoreCheckpointSheet.swift`
- Create: `Alas/Sources/Right/Checkpoints/CheckpointRecoveryCard.swift`
- Create: `AlasTests/Checkpoints/CheckpointRestorePresentationTests.swift`

**Interfaces:**
- Consumes: Task 5 preview models and Task 8 RightPane actions.
- Produces: selected-group restore confirmation, blocker presentation, in-flight progress, and explicit interrupted recovery.

- [ ] **Step 1: Write failing restore-presentation tests**

Assert the sheet starts with all group UUIDs selected, toggling a rename affects source and destination together, zero selection disables Restore, and the confirmation count counts physical paths while rows count logical groups. Assert index and working-tree effect strings both remain visible for a path with two states.

Assert blocker copy for changed HEAD, lineage mismatch, active terminal count, active ACP count, dirty selected buffers, Git operation, index lock, stale preview, and corrupt blob. Host `CheckpointRecoveryCard` and assert it names phase and affected paths, exposes **Recover pre-restore state**, and never starts recovery on appear.

- [ ] **Step 2: Regenerate and run restore-presentation tests to verify RED**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/alas-checkpoints-dd -only-testing:AlasTests/CheckpointRestorePresentationTests test ALAS_FFF_TARGET_ARCH=arm64
```

Expected: compilation fails because restore and recovery views are missing.

- [ ] **Step 3: Implement the restore sheet**

Use `List(selection:)` or per-row `Toggle` controls keyed by stable group UUIDs. Show checkpoint label, repository or Workspace member scope, selected path count, and the fixed statement that both index and working-tree state will change. Render the service-provided blocker above the actions and disable Restore while blocked or in flight. The destructive confirmation button must read **Restore Selected Files** and pass the exact preview plus selected UUID set back to RightPaneState.

If the service returns stale preview, keep the sheet open, show the error, and expose **Refresh Preview**. On success, dismiss and leave the recovery checkpoint visible in the Checkpoints section.

- [ ] **Step 4: Implement interrupted-operation recovery presentation**

Insert one retained row directly below the Checkpoints header when a nonterminal journal exists. Show operation UUID suffix, phase, and affected paths in a disclosure. **Recover pre-restore state** runs only after a fresh coordination check. Keep capture, restore, delete, staging, and other Git mutations disabled until recovery finishes. Surface successful recovery as an inline status and refresh Changes; retain exact failure details and the journal when recovery is still blocked.

- [ ] **Step 5: Run restore UI and RightPane suites to verify GREEN**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/alas-checkpoints-dd -only-testing:AlasTests/CheckpointRestorePresentationTests -only-testing:AlasTests/RightPaneCheckpointStateTests test ALAS_FFF_TARGET_ARCH=arm64
```

Expected: selected suites pass.

- [ ] **Step 6: Commit selective restore UI**

```bash
git add Alas/Sources/Right/Checkpoints Alas/Sources/Right/ChangesTabView.swift Alas/Sources/Right/RightPaneView.swift AlasTests/Checkpoints Alas.xcodeproj/project.pbxproj
git commit -m "feat(checkpoints): add selective restore and recovery UI"
```

---

### Task 12: Run the complete acceptance and verification pass

**Files:**
- No planned source changes. If a command fails, return to the task that owns that behavior, add a regression to its named test file, apply the focused fix in its named source file, and rerun that task's GREEN command before continuing here.

**Interfaces:**
- Consumes: the complete checkpoint implementation.
- Produces: fresh focused tests, full build and test evidence, format evidence, and a clean diff check.

- [ ] **Step 1: Run the entire checkpoint suite**

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/alas-checkpoints-final -only-testing:AlasTests/CheckpointModelTests -only-testing:AlasTests/CheckpointFileSystemTests -only-testing:AlasTests/WorktreeCheckpointStoreTests -only-testing:AlasTests/WorktreeStateSnapshotterTests -only-testing:AlasTests/WorktreeCheckpointCaptureTests -only-testing:AlasTests/CheckpointRestorePreviewTests -only-testing:AlasTests/CheckpointDiffLoaderTests -only-testing:AlasTests/CheckpointRestorePreparationTests -only-testing:AlasTests/CheckpointRestoreIntegrationTests -only-testing:AlasTests/CheckpointRestoreInterruptionTests -only-testing:AlasTests/CheckpointCoordinationTests -only-testing:AlasTests/RightPaneCheckpointStateTests -only-testing:AlasTests/CheckpointPresentationTests -only-testing:AlasTests/CheckpointDiffTabTests -only-testing:AlasTests/CheckpointRestorePresentationTests test ALAS_FFF_TARGET_ARCH=arm64
```

Expected: every checkpoint suite passes with zero failures.

- [ ] **Step 2: Run nearby regression suites**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/alas-checkpoints-final -only-testing:AlasTests/RightPaneOptimisticStageTests -only-testing:AlasTests/RightPaneStateDiscardTests -only-testing:AlasTests/TabsManagerTests -only-testing:AlasTests/StartupRecoveryTests -only-testing:AlasTests/AppKitDiffScrollerTests -only-testing:AlasTests/WorktreeServiceCreatedAtTests test ALAS_FFF_TARGET_ARCH=arm64
```

Expected: all selected regression suites pass.

- [ ] **Step 3: Run SwiftFormat lint and diff validation**

```bash
swiftformat Alas AlasTests --lint
git diff --check
```

Expected: both commands exit 0 with no formatting or whitespace errors.

- [ ] **Step 4: Run the required macOS build**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/alas-checkpoints-final -quiet build ALAS_FFF_TARGET_ARCH=arm64
```

Expected: exit 0.

- [ ] **Step 5: Run the full macOS test suite**

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/alas-checkpoints-final test ALAS_FFF_TARGET_ARCH=arm64
```

Expected: the command reaches `xctest`, exits 0, and reports zero failures.

- [ ] **Step 6: Inspect the final repository state and commit verification fixes only if needed**

```bash
git status --short
git diff --stat main...HEAD
git diff --check main...HEAD
```

Expected: only issue #1158 implementation, tests, generated Xcode project membership, the approved spec, and this plan differ from `main`; no unstaged verification fix remains. Any focused fix discovered by Steps 1 through 5 has already been handled through the owning task's test, GREEN command, and commit step.
