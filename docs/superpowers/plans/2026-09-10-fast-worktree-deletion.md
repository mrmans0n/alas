# Fast local worktree deletion implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make local worktree deletion return after a same-filesystem rename and Git registry update while a detached process removes the staged files.

**Architecture:** AppState will call a new opt-in `WorktreeService.removeFastLocal` method for local worktrees. That method stages the directory under the repository's common Git directory and returns a validated cleanup ticket. AppState tears down its worktree-owned state, launches detached cleanup, and starts a best-effort stale-trash sweep. Existing `WorktreeService.remove` callers keep synchronous behavior.

**Tech stack:** Swift 5.9, Foundation `Process` and `FileManager`, Swift Testing, Git worktree plumbing, macOS 15+

**Spec:** `docs/superpowers/specs/2026-09-10-fast-worktree-deletion-design.md`

## Global constraints

- Keep code, comments, logs, and UI strings in English.
- Use Swift Testing with `import Testing`, not XCTest.
- Do not change the deletion preflight policy or confirmation copy.
- Do not stage SSH deletions or Workspace Checkout removals.
- Pass cleanup paths as process arguments. Never interpolate them into shell source.
- Do not edit `project.yml`. Run `xcodegen` after creating Swift files so the generated Xcode project records them.
- Do not add agent attribution to code, docs, or commits.
- Run `xcodegen`, the macOS build, and the full test command before finishing.

---

### Task 1: Trash paths and cleanup tickets

**Files:**

- Create: `Alas/Sources/Git/WorktreeTrash.swift`
- Create: `AlasTests/WorktreeTrashTests.swift`

**Interfaces:**

- Produces: `WorktreeTrashCleanupTicket`, an `Equatable` and `Sendable` value containing `trashRoot` and `stagedPath`.
- Produces: `WorktreeRemovalOutcome` with `.synchronous` and `.staged(WorktreeTrashCleanupTicket)` cases.
- Produces: `WorktreeTrash.root(commonGitDirectory:)`, `makeTicket(commonGitDirectory:originalPath:now:id:)`, `isValid(_:)`, and `staleTickets(commonGitDirectories:olderThan:)`.
- Consumes: Foundation URL and file resource values only.

- [ ] **Step 1: Write failing tests for naming, validation, and stale selection**

Create a serialized Swift Testing suite. Use fixed dates and UUIDs so every assertion is deterministic:

```swift
import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
struct WorktreeTrashTests {
    @Test func ticketIsAnImmediateRecognizableChildOfTrashRoot() throws {
        let common = URL(fileURLWithPath: "/tmp/repo/.git")
        let original = URL(fileURLWithPath: "/tmp/feature/odd name")
        let id = try #require(UUID(uuidString: "12345678-1234-1234-1234-123456789abc"))

        let ticket = WorktreeTrash.makeTicket(
            commonGitDirectory: common,
            originalPath: original,
            now: Date(timeIntervalSince1970: 1_789_041_600),
            id: id
        )

        #expect(ticket.trashRoot == common.appendingPathComponent("alas/trash").standardizedFileURL)
        #expect(ticket.stagedPath.deletingLastPathComponent() == ticket.trashRoot)
        #expect(ticket.stagedPath.lastPathComponent.hasSuffix(".1789041600.12345678-1234-1234-1234-123456789abc"))
        #expect(WorktreeTrash.isValid(ticket))
        #expect(!WorktreeTrash.isValid(.init(
            trashRoot: ticket.trashRoot,
            stagedPath: ticket.trashRoot.appendingPathComponent("nested/entry")
        )))
        #expect(!WorktreeTrash.isValid(.init(
            trashRoot: URL(fileURLWithPath: "/tmp"),
            stagedPath: URL(fileURLWithPath: "/tmp/worktree.alas-worktree.1.12345678-1234-1234-1234-123456789abc")
        )))
    }

    @Test func staleTicketsKeepOnlyOldValidDirectoriesAndDeduplicateRoots() throws {
        let common = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-trash-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: common) }
        let old = WorktreeTrash.makeTicket(
            commonGitDirectory: common,
            originalPath: URL(fileURLWithPath: "/tmp/old"),
            now: Date(timeIntervalSince1970: 100),
            id: UUID()
        )
        let young = WorktreeTrash.makeTicket(
            commonGitDirectory: common,
            originalPath: URL(fileURLWithPath: "/tmp/young"),
            now: Date(timeIntervalSince1970: 200),
            id: UUID()
        )
        try FileManager.default.createDirectory(at: old.stagedPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: young.stagedPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: old.trashRoot.appendingPathComponent("unrecognized"),
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: old.stagedPath.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: young.stagedPath.path
        )

        let tickets = WorktreeTrash.staleTickets(
            commonGitDirectories: [common, common],
            olderThan: Date(timeIntervalSince1970: 150)
        )

        #expect(tickets == [old])
    }
}
```

- [ ] **Step 2: Run the new suite and verify it fails to compile**

Run:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/WorktreeTrashTests
```

Expected: compilation fails because `WorktreeTrash`, `WorktreeTrashCleanupTicket`, and `WorktreeRemovalOutcome` do not exist.

- [ ] **Step 3: Implement the value types and path rules**

Create `WorktreeTrash.swift` with these declarations and behavior:

```swift
import Foundation

struct WorktreeTrashCleanupTicket: Equatable, Sendable {
    let trashRoot: URL
    let stagedPath: URL
}

enum WorktreeRemovalOutcome: Equatable, Sendable {
    case synchronous
    case staged(WorktreeTrashCleanupTicket)
}

enum WorktreeTrash {
    static let relativeDirectory = "alas/trash"
    private static let marker = "alas-worktree"

    static func root(commonGitDirectory: URL) -> URL {
        commonGitDirectory
            .appendingPathComponent(relativeDirectory, isDirectory: true)
            .standardizedFileURL
    }

    static func makeTicket(
        commonGitDirectory: URL,
        originalPath: URL,
        now: Date = Date(),
        id: UUID = UUID()
    ) -> WorktreeTrashCleanupTicket {
        let trashRoot = root(commonGitDirectory: commonGitDirectory)
        let safeBase = sanitizedBaseName(originalPath.lastPathComponent)
        let name = "\(safeBase).\(marker).\(Int(now.timeIntervalSince1970)).\(id.uuidString.lowercased())"
        return WorktreeTrashCleanupTicket(
            trashRoot: trashRoot,
            stagedPath: trashRoot.appendingPathComponent(name, isDirectory: true)
        )
    }

    static func isValid(_ ticket: WorktreeTrashCleanupTicket) -> Bool {
        let root = ticket.trashRoot.standardizedFileURL
        let target = ticket.stagedPath.standardizedFileURL
        return root.lastPathComponent == "trash"
            && root.deletingLastPathComponent().lastPathComponent == "alas"
            && target.deletingLastPathComponent() == root
            && isRecognizedEntryName(target.lastPathComponent)
    }

    static func staleTickets(
        commonGitDirectories: [URL],
        olderThan cutoff: Date,
        fileManager: FileManager = .default
    ) -> [WorktreeTrashCleanupTicket] {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]
        let commonDirectories = Set(commonGitDirectories.map { $0.standardizedFileURL.path })
        var tickets: [WorktreeTrashCleanupTicket] = []
        for commonPath in commonDirectories.sorted() {
            let trashRoot = root(commonGitDirectory: URL(fileURLWithPath: commonPath))
            guard let entries = try? fileManager.contentsOfDirectory(
                at: trashRoot,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries {
                let ticket = WorktreeTrashCleanupTicket(
                    trashRoot: trashRoot,
                    stagedPath: entry.standardizedFileURL
                )
                guard isValid(ticket),
                      let values = try? entry.resourceValues(forKeys: keys),
                      values.isDirectory == true,
                      values.isSymbolicLink != true,
                      let modified = values.contentModificationDate,
                      modified < cutoff
                else { continue }
                tickets.append(ticket)
            }
        }
        return tickets.sorted { $0.stagedPath.path < $1.stagedPath.path }
    }

    private static func sanitizedBaseName(_ value: String) -> String {
        var result = ""
        var needsSeparator = false
        for scalar in value.unicodeScalars {
            let byte = scalar.value
            let allowed = (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || byte == 45
                || byte == 95
            if allowed {
                if needsSeparator, !result.isEmpty { result.append("-") }
                result.unicodeScalars.append(scalar)
                needsSeparator = false
            } else {
                needsSeparator = true
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        let limited = String(trimmed.prefix(48))
        return limited.isEmpty ? "worktree" : limited
    }

    private static func isRecognizedEntryName(_ value: String) -> Bool {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 4,
              fields[1] == Substring(marker),
              let epoch = Int(fields[2]),
              epoch >= 0,
              UUID(uuidString: String(fields[3])) != nil
        else { return false }
        return !fields[0].isEmpty
    }
}
```

The helper code keeps ASCII letters, digits, `_`, and `-`, replaces other runs with `-`, trims separators, limits the result to 48 characters, and falls back to `worktree`. The four dot-separated fields make stale-entry validation unambiguous.

- [ ] **Step 4: Run the focused suite**

Run `xcodegen`, then run the Task 1 test command again. Expected: both tests pass and the generated project contains the new source and test files.

- [ ] **Step 5: Commit the path model**

```bash
git add Alas/Sources/Git/WorktreeTrash.swift AlasTests/WorktreeTrashTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat: define worktree trash paths"
```

---

### Task 2: Staged local removal

**Files:**

- Modify: `Alas/Sources/Git/WorktreeService.swift:22-31,746-783,854-876,950-1085`
- Modify: `AlasTests/WorktreeServiceTests.swift:242-278,603-642`

**Interfaces:**

- Consumes: `WorktreeTrash.makeTicket` and `WorktreeRemovalOutcome` from Task 1.
- Produces: `WorktreeService.removeFastLocal(repoPath:worktree:deleteBranchIfMerged:force:usesRemoteHostRegistry:moveItem:) async throws -> WorktreeRemovalOutcome`.
- Preserves: `WorktreeService.remove(...) async throws -> Void` without changing its behavior or callers.

- [ ] **Step 1: Add failing integration tests for the commit boundary**

Add tests beside the existing removal tests. Reuse the suite's `makeRepo()` helper:

```swift
private struct LinkedWorktreeFixture {
    let repo: URL
    let service: WorktreeService
    let worktree: Worktree

    func removeFiles() {
        try? FileManager.default.removeItem(at: worktree.path)
        try? FileManager.default.removeItem(at: repo)
    }
}

private func makeLinkedWorktree(suffix: String) async throws -> LinkedWorktreeFixture {
    let repo = try await makeRepo()
    let destination = repo.deletingLastPathComponent()
        .appendingPathComponent("\(repo.lastPathComponent)-\(suffix)")
    let service = WorktreeService()
    let worktree = try await service.add(
        repoPath: repo,
        base: "main",
        branch: "feature/\(suffix)",
        destination: destination,
        projectId: "p"
    )
    return LinkedWorktreeFixture(repo: repo, service: service, worktree: worktree)
}

@Test func fastLocalRemoveReturnsStagedTicketBeforeFilesAreDeleted() async throws {
    let repo = try await makeRepo()
    let destination = repo.deletingLastPathComponent()
        .appendingPathComponent("\(repo.lastPathComponent)-fast")
    defer {
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.removeItem(at: repo)
    }
    let service = WorktreeService()
    let worktree = try await service.add(
        repoPath: repo,
        base: "main",
        branch: "feature/fast",
        destination: destination,
        projectId: "p"
    )
    try "keep until cleaner".write(
        to: destination.appendingPathComponent("marker.txt"),
        atomically: true,
        encoding: .utf8
    )

    let outcome = try await service.removeFastLocal(
        repoPath: repo,
        worktree: worktree,
        deleteBranchIfMerged: false,
        force: true
    )
    guard case .staged(let ticket) = outcome else {
        Issue.record("Expected staged removal")
        return
    }
    defer { try? FileManager.default.removeItem(at: ticket.trashRoot) }

    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(FileManager.default.fileExists(
        atPath: ticket.stagedPath.appendingPathComponent("marker.txt").path
    ))
    #expect(try await service.list(repoPath: repo, projectId: "p").count == 1)
}

@Test func fastLocalRemoveFailsClosedWhenWorktreeBecameDirty() async throws {
    let fixture = try await makeLinkedWorktree(suffix: "became-dirty")
    defer { fixture.removeFiles() }
    try "dirty".write(
        to: fixture.worktree.path.appendingPathComponent("new.txt"),
        atomically: true,
        encoding: .utf8
    )

    await #expect(throws: WorktreeService.WorktreeError.self) {
        try await fixture.service.removeFastLocal(
            repoPath: fixture.repo,
            worktree: fixture.worktree,
            deleteBranchIfMerged: false,
            force: false
        )
    }
    #expect(FileManager.default.fileExists(atPath: fixture.worktree.path.path))
}
```

- [ ] **Step 2: Run the focused tests and verify the missing API failure**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/WorktreeServiceTests/fastLocalRemoveReturnsStagedTicketBeforeFilesAreDeleted \
  -only-testing:AlasTests/WorktreeServiceTests/fastLocalRemoveFailsClosedWhenWorktreeBecameDirty
```

Expected: compilation fails because `removeFastLocal` does not exist.

- [ ] **Step 3: Implement staging, registry removal, and rollback**

Add the method next to `remove`. Keep all Git work under the caller's existing `ProjectMutationGate`:

```swift
func removeFastLocal(
    repoPath: URL,
    worktree: Worktree,
    deleteBranchIfMerged: Bool,
    force: Bool = false,
    usesRemoteHostRegistry: Bool = true,
    moveItem: @Sendable (URL, URL) throws -> Void = {
        try WorktreeService.renameAtomically(from: $0, to: $1)
    }
) async throws -> WorktreeRemovalOutcome
```

Add `import Darwin` and this helper:

```swift
private static func renameAtomically(from source: URL, to destination: URL) throws {
    let result: (status: Int32, error: Int32) = source.withUnsafeFileSystemRepresentation { sourcePath in
        destination.withUnsafeFileSystemRepresentation { destinationPath in
            guard let sourcePath, let destinationPath else { return (-1, EINVAL) }
            let status = Darwin.rename(sourcePath, destinationPath)
            return (status, status == 0 ? 0 : errno)
        }
    }
    guard result.status == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(result.error))
    }
}
```

Do not use `FileManager.moveItem` in the live default because it may perform a
cross-volume copy instead of failing immediately. Tests may inject
`FileManager.moveItem` for controlled same-volume moves.

The method must perform this exact sequence:

1. Reject remote Alas paths by calling the existing synchronous `remove` with `usesRemoteHostRegistry` and returning `.synchronous`.
2. Run `git worktree list --porcelain` with `usesRemoteHostRegistry: false`. Require one entry matching `worktree.path` after URL standardization. Record whether that entry is locked.
3. Unless `force` is true, call `isWorktreeClean`. Throw `gitFailed("Worktree contains modified or untracked files.")` if it returns false. If it fails because Git LFS is missing, preserve the existing behavior by calling `canForceRemoveAfterMissingLFS`; proceed with one internal force only when that complete audit succeeds.
4. Run `git fsmonitor--daemon stop` in the worktree with a two-second timeout and ignore its result.
5. Resolve `git rev-parse --git-common-dir`. Resolve relative output against `repoPath`, standardize it, make a ticket, and create the trash root with intermediate directories.
6. Call `moveItem(worktree.path, ticket.stagedPath)`. If common-dir resolution, trash creation, or this first move fails, call existing `remove` with the user's force value and return `.synchronous`.
7. Call `git worktree remove` with the original path. Add one `--force` for an audited LFS-clean fallback or user force, and add two `--force` arguments when the registration was locked and the user approved force.
8. If registry removal fails, call `moveItem(ticket.stagedPath, worktree.path)`. If rollback succeeds, throw `gitFailed` with Git's original stderr. If rollback fails, throw `gitFailed` with the original path, staged path, Git stderr, and rollback error. Do not invoke synchronous fallback after the first move succeeds.
9. Preserve the existing best-effort `git branch -d` behavior, then return `.staged(ticket)`.

Add a private porcelain parser that returns both registration presence and locked state for one standardized path. Do not infer the branch from the directory name.

- [ ] **Step 4: Add failure-path and locked-worktree tests**

Add these cases with real temporary repositories:

```swift
@Test func fastLocalRemoveFallsBackWhenRenameFails() async throws {
    let fixture = try await makeLinkedWorktree(suffix: "rename-fallback")
    defer { fixture.removeFiles() }

    let outcome = try await fixture.service.removeFastLocal(
        repoPath: fixture.repo,
        worktree: fixture.worktree,
        deleteBranchIfMerged: false,
        force: false,
        moveItem: { _, _ in throw CocoaError(.fileWriteNoPermission) }
    )

    #expect(outcome == .synchronous)
    #expect(!FileManager.default.fileExists(atPath: fixture.worktree.path.path))
}

@Test func fastLocalRemoveRestoresPathWhenRegistryRemovalFails() async throws {
    let fixture = try await makeLinkedWorktree(suffix: "rollback")
    defer { fixture.removeFiles() }
    _ = try await Process.git(["worktree", "lock", fixture.worktree.path.path], cwd: fixture.repo)

    await #expect(throws: WorktreeService.WorktreeError.self) {
        try await fixture.service.removeFastLocal(
            repoPath: fixture.repo,
            worktree: fixture.worktree,
            deleteBranchIfMerged: false,
            force: false
        )
    }

    #expect(FileManager.default.fileExists(atPath: fixture.worktree.path.path))
}

@Test func fastLocalRemoveUsesDoubleForceForApprovedLockedWorktree() async throws {
    let fixture = try await makeLinkedWorktree(suffix: "locked-fast")
    defer { fixture.removeFiles() }
    _ = try await Process.git(["worktree", "lock", fixture.worktree.path.path], cwd: fixture.repo)

    let outcome = try await fixture.service.removeFastLocal(
        repoPath: fixture.repo,
        worktree: fixture.worktree,
        deleteBranchIfMerged: false,
        force: true
    )
    guard case .staged(let ticket) = outcome else {
        Issue.record("Expected staged removal")
        return
    }
    defer { try? FileManager.default.removeItem(at: ticket.trashRoot) }
    #expect(!FileManager.default.fileExists(atPath: fixture.worktree.path.path))
}

@Test func fastLocalRemoveNeverStagesARegisteredRemotePath() async throws {
    let fixture = try await makeLinkedWorktree(suffix: "remote-fallback")
    defer { fixture.removeFiles() }
    RemoteHostRegistry.shared.register(root: fixture.worktree.path.path, host: "test-host")
    defer { RemoteHostRegistry.shared.unregister(root: fixture.worktree.path.path) }

    let outcome = try await fixture.service.removeFastLocal(
        repoPath: fixture.repo,
        worktree: fixture.worktree,
        deleteBranchIfMerged: false,
        force: false,
        usesRemoteHostRegistry: false
    )

    #expect(outcome == .synchronous)
    #expect(!FileManager.default.fileExists(atPath: fixture.worktree.path.path))
}
```

Add a staged counterpart to `removeWithDeleteBranchUsesRealBranchName`. Pass
the fixture's `repoPath` and `Worktree`, set `deleteBranchIfMerged: true`, and
leave `force` false. Require a staged ticket, then assert
`git branch --list feature/name` is empty. This protects the current
branch-name behavior when a path template replaces `/` in directory names.

Add the rollback-failure case with a direction-based injected move:

```swift
@Test func fastLocalRemoveReportsBothPathsWhenRollbackFails() async throws {
    let fixture = try await makeLinkedWorktree(suffix: "rollback-fails")
    defer { fixture.removeFiles() }
    _ = try await Process.git(["worktree", "lock", fixture.worktree.path.path], cwd: fixture.repo)

    do {
        _ = try await fixture.service.removeFastLocal(
            repoPath: fixture.repo,
            worktree: fixture.worktree,
            deleteBranchIfMerged: false,
            force: false,
            moveItem: { source, destination in
                if source.standardizedFileURL == fixture.worktree.path.standardizedFileURL {
                    try FileManager.default.moveItem(at: source, to: destination)
                    try "collision".write(to: source, atomically: true, encoding: .utf8)
                } else {
                    throw CocoaError(.fileWriteFileExists)
                }
            }
        )
        Issue.record("Expected registry and rollback failure")
    } catch {
        let message = error.localizedDescription
        #expect(message.contains(fixture.worktree.path.path))
        let trash = WorktreeTrash.root(
            commonGitDirectory: fixture.repo.appendingPathComponent(".git")
        )
        let staged = try #require(
            FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil).first
        )
        #expect(message.contains(staged.path))
        #expect(FileManager.default.fileExists(atPath: staged.appendingPathComponent(".git").path))
        try? FileManager.default.removeItem(at: trash)
    }
}
```

- [ ] **Step 5: Cover Git LFS and submodule compatibility**

Extract the setup body in `removeRetriesWithoutLFSFiltersWhenGitStatusRequiresMissingLFS` into `makeMissingLFSFixture(suffix:)`. Return the repo, destination, `Worktree`, and marker URL. Keep the existing test by calling the helper and `remove`. Add these assertions for the staged variant:

```swift
@Test func fastLocalRemovePreservesMissingLFSCleanSemantics() async throws {
    let fixture = try await makeMissingLFSFixture(suffix: "fast-missing-lfs")
    defer { fixture.removeFiles() }

    let outcome = try await WorktreeService().removeFastLocal(
        repoPath: fixture.repo,
        worktree: fixture.worktree,
        deleteBranchIfMerged: false
    )
    guard case .staged(let ticket) = outcome else {
        Issue.record("Expected staged removal")
        return
    }
    defer { try? FileManager.default.removeItem(at: ticket.trashRoot) }
    #expect(!FileManager.default.fileExists(atPath: fixture.worktree.path.path))
    #expect(FileManager.default.fileExists(
        atPath: ticket.stagedPath.appendingPathComponent(fixture.marker.lastPathComponent).path
    ))
}

@Test func fastLocalRemoveSupportsInitializedSubmodulesAfterForceApproval() async throws {
    let fixture = try await makeRepoWithInitializedSubmodule(suffix: "fast-submodule")
    defer { fixture.removeFiles() }

    let outcome = try await fixture.service.removeFastLocal(
        repoPath: fixture.repo,
        worktree: fixture.worktree,
        deleteBranchIfMerged: false,
        force: true
    )
    guard case .staged(let ticket) = outcome else {
        Issue.record("Expected staged removal")
        return
    }
    defer { try? FileManager.default.removeItem(at: ticket.trashRoot) }
    let listed = try await fixture.service.list(repoPath: fixture.repo, projectId: "p")
    #expect(listed.count == 1)
}
```

Add `removeFiles()` methods to both fixtures. Each method removes only its own temporary worktree, repository, and submodule source URLs.

- [ ] **Step 6: Run all WorktreeService tests**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/WorktreeServiceTests
```

Expected: all tests pass, including existing synchronous removal, local-only submodule safety, and LFS cases.

- [ ] **Step 7: Commit staged removal**

```bash
git add Alas/Sources/Git/WorktreeService.swift AlasTests/WorktreeServiceTests.swift
git commit -m "feat: stage local worktrees before removal"
```

---

### Task 3: Detached cleanup and stale recovery

**Files:**

- Create: `Alas/Sources/Git/WorktreeTrashCleaner.swift`
- Modify: `Alas/Sources/Git/WorktreeService.swift:185-199`
- Modify: `AlasTests/WorktreeTrashTests.swift`

**Interfaces:**

- Consumes: cleanup tickets and stale selection from Task 1.
- Produces: `WorktreeTrashCleaner.launch(_:,delaySeconds:) throws` and `sweep(projects:now:launcher:)`.
- Produces: `WorktreeService.localCommonGitDirectory(forWorktreeAt:) -> URL?` for local configured-project recovery.

- [ ] **Step 1: Write failing tests for detached invocation and project-root recovery**

Add tests that inject the process-spawn closure and sweep launcher:

```swift
@Test func cleanerPassesTheValidatedPathAsAnArgument() throws {
    let ticket = WorktreeTrash.makeTicket(
        commonGitDirectory: URL(fileURLWithPath: "/tmp/repo/.git"),
        originalPath: URL(fileURLWithPath: "/tmp/a name; touch nope")
    )
    var capturedExecutable: URL?
    var capturedArguments: [String] = []

    try WorktreeTrashCleaner.launch(ticket, delaySeconds: 1) { executable, arguments in
        capturedExecutable = executable
        capturedArguments = arguments
    }

    #expect(capturedExecutable?.path == "/usr/bin/nice")
    #expect(capturedArguments.last == ticket.stagedPath.path)
    #expect(capturedArguments.dropLast().allSatisfy { !$0.contains(ticket.stagedPath.path) })
}

@Test func sweepLaunchesOnlyOldTicketsFromUniqueLocalProjects() async throws {
    let repo = FileManager.default.temporaryDirectory
        .appendingPathComponent("alas-sweep-\(UUID().uuidString)")
    let linked = repo.deletingLastPathComponent()
        .appendingPathComponent("\(repo.lastPathComponent)-linked")
    defer {
        try? FileManager.default.removeItem(at: linked)
        try? FileManager.default.removeItem(at: repo)
    }
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
    _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repo)
    _ = try await Process.git(["worktree", "add", "-q", "-b", "linked", linked.path], cwd: repo)

    let common = repo.appendingPathComponent(".git")
    let old = WorktreeTrash.makeTicket(
        commonGitDirectory: common,
        originalPath: linked,
        now: Date(timeIntervalSince1970: 100),
        id: UUID()
    )
    let young = WorktreeTrash.makeTicket(
        commonGitDirectory: common,
        originalPath: linked,
        now: Date(timeIntervalSince1970: 250),
        id: UUID()
    )
    try FileManager.default.createDirectory(at: old.stagedPath, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: young.stagedPath, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 100)],
        ofItemAtPath: old.stagedPath.path
    )
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 99_990)],
        ofItemAtPath: young.stagedPath.path
    )

    let addedAt = Date(timeIntervalSince1970: 1)
    let projects = [
        ProjectConfig(id: "main", name: "main", path: repo.path, color: "#000000", addedAt: addedAt),
        ProjectConfig(id: "linked", name: "linked", path: linked.path, color: "#000000", addedAt: addedAt),
        ProjectConfig(id: "remote", name: "remote", path: "/repo", color: "#000000", addedAt: addedAt, host: "host"),
        ProjectConfig(id: "missing", name: "missing", path: "/missing", color: "#000000", addedAt: addedAt),
    ]
    var launched: [WorktreeTrashCleanupTicket] = []

    WorktreeTrashCleaner.sweep(
        projects: projects,
        now: Date(timeIntervalSince1970: 100_000),
        launcher: { launched.append($0) }
    )

    #expect(launched == [old])
}
```

- [ ] **Step 2: Run the focused suite and verify the cleaner API is missing**

Run the Task 1 focused suite command. Expected: compilation fails on `WorktreeTrashCleaner` and `localCommonGitDirectory`.

- [ ] **Step 3: Expose local common-directory resolution**

Change `localGitDirectory(forWorktreeAt:)` from `private` to internal and add:

```swift
static func localCommonGitDirectory(forWorktreeAt path: URL) -> URL? {
    guard let gitDirectory = localGitDirectory(forWorktreeAt: path) else { return nil }
    let marker = gitDirectory.appendingPathComponent("commondir")
    guard let raw = try? String(contentsOf: marker, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty
    else { return gitDirectory.standardizedFileURL }
    return (raw as NSString).isAbsolutePath
        ? URL(fileURLWithPath: raw).standardizedFileURL
        : gitDirectory.appendingPathComponent(raw).standardizedFileURL
}
```

- [ ] **Step 4: Implement the detached launcher**

Create `WorktreeTrashCleaner.swift` with the complete launcher and sweep structure below:

```swift
import Foundation
import os

enum WorktreeTrashCleaner {
    typealias Launcher = (WorktreeTrashCleanupTicket) throws -> Void
    typealias Spawn = (URL, [String]) throws -> Void

    private static let logger = Logger(
        subsystem: "io.nlopez.alas",
        category: "worktree-trash"
    )

    enum CleanerError: LocalizedError {
        case invalidTicket

        var errorDescription: String? {
            "Refusing to clean a path outside the Alas worktree trash directory."
        }
    }

    static func launch(
        _ ticket: WorktreeTrashCleanupTicket,
        delaySeconds: Int = 1,
        spawn: Spawn = spawnDetached
    ) throws {
        guard WorktreeTrash.isValid(ticket) else { throw CleanerError.invalidTicket }
        try spawn(URL(fileURLWithPath: "/usr/bin/nice"), [
            "-n", "10", "/bin/sh", "-c",
            "/bin/sleep \"$1\"; exec /bin/rm -rf -- \"$2\"",
            "alas-worktree-cleaner",
            String(max(0, delaySeconds)),
            ticket.stagedPath.path,
        ])
    }

    static func sweep(
        projects: [ProjectConfig],
        now: Date = Date(),
        launcher: Launcher = { try launch($0) }
    ) {
        let commonDirectories = projects.compactMap { project -> URL? in
            guard project.host == nil else { return nil }
            let path = URL(fileURLWithPath: project.path)
            guard !path.isRemoteAlasPath else { return nil }
            return WorktreeService.localCommonGitDirectory(forWorktreeAt: path)
        }
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        for ticket in WorktreeTrash.staleTickets(
            commonGitDirectories: commonDirectories,
            olderThan: cutoff
        ) {
            do {
                try launcher(ticket)
            } catch {
                logger.error(
                    "Could not launch stale worktree cleanup for \(ticket.stagedPath.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private static func spawnDetached(executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility
        try process.run()
    }
}
```

Call `WorktreeTrash.isValid` before spawning and throw a localized error for an invalid ticket. The static shell source is constant. The delay and path occupy `$1` and `$2`; neither value is interpolated into the script.

`WorktreeTrash.staleTickets` deduplicates the common directories before scanning. `sweep` skips missing repositories because `localCommonGitDirectory` returns nil when `.git` cannot be resolved.

- [ ] **Step 5: Add an eventual deletion test for the live launcher**

Add this test. Its deadline prevents a broken cleaner from hanging the suite; it is not a performance threshold:

```swift
@Test func liveCleanerEventuallyDeletesTheTicketDirectory() async throws {
    let common = FileManager.default.temporaryDirectory
        .appendingPathComponent("alas-cleaner-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: common) }
    let ticket = WorktreeTrash.makeTicket(
        commonGitDirectory: common,
        originalPath: URL(fileURLWithPath: "/tmp/clean-me")
    )
    try FileManager.default.createDirectory(at: ticket.stagedPath, withIntermediateDirectories: true)
    try "marker".write(
        to: ticket.stagedPath.appendingPathComponent("marker.txt"),
        atomically: true,
        encoding: .utf8
    )

    try WorktreeTrashCleaner.launch(ticket, delaySeconds: 0)
    let deadline = Date().addingTimeInterval(5)
    while FileManager.default.fileExists(atPath: ticket.stagedPath.path), Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }

    #expect(!FileManager.default.fileExists(atPath: ticket.stagedPath.path))
}
```

- [ ] **Step 6: Run the focused trash suite**

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/WorktreeTrashTests
```

Expected: all path, validation, spawn, live cleanup, deduplication, and cutoff tests pass.

- [ ] **Step 7: Commit cleanup and recovery**

```bash
git add Alas/Sources/Git/WorktreeTrashCleaner.swift \
  Alas/Sources/Git/WorktreeService.swift AlasTests/WorktreeTrashTests.swift \
  Alas.xcodeproj/project.pbxproj
git commit -m "feat: clean staged worktrees in background"
```

---

### Task 4: AppState orchestration

**Files:**

- Modify: `Alas/Sources/App/AppState.swift:49-120,628-766,7338-7833`
- Modify: `AlasTests/AppStateCleanupTests.swift:900-1085`

**Interfaces:**

- Consumes: `WorktreeService.removeFastLocal`, `WorktreeRemovalOutcome`, and `WorktreeTrashCleaner`.
- Produces: AppState cleanup ordering and startup stale recovery.
- Preserves: existing confirmation, pending-force, branch deletion, selection, and refresh behavior.

- [ ] **Step 1: Write a failing AppState test for the cleanup boundary**

Add a main-actor probe and test:

```swift
@MainActor
private final class WorktreeCleanupProbe {
    weak var state: AppState?
    var worktreeID = ""
    var launchedTickets: [WorktreeTrashCleanupTicket] = []
    var tabsWereEmptyAtLaunch = false
}

@Test @MainActor
func deleteWorktreeCleansAppStateBeforeLaunchingFileCleanup() async throws {
    let repo = try await makeRepo(name: "delete-staged")
    let linked = repo.deletingLastPathComponent().appendingPathComponent("delete-staged-linked")
    defer {
        try? FileManager.default.removeItem(at: linked)
        try? FileManager.default.removeItem(at: repo)
    }
    let probe = WorktreeCleanupProbe()
    let state = AppState(
        worktreeCleanupLauncher: { ticket in
            probe.launchedTickets.append(ticket)
            probe.tabsWereEmptyAtLaunch = probe.state?.tabs.tabs(forWorktree: probe.worktreeID).isEmpty == true
        }
    )
    probe.state = state
    let project = try await state.projectsManager.addProject(
        path: repo,
        displayName: "delete-staged",
        color: "#5fb7c4"
    )
    let worktree = try await WorktreeService().add(
        repoPath: repo,
        base: "main",
        branch: "feature/staged",
        destination: linked,
        projectId: project.id
    )
    probe.worktreeID = worktree.id
    try await state.projectsManager.refreshWorktrees(projectId: project.id)
    state.tabs.appendTerminal(worktreeId: worktree.id, title: "term", sessionId: "session")

    #expect(await state.cliDeleteWorktree(worktree, force: true, keepBranch: true) == .ok)
    try await waitForOperationState(state.projectsManager, id: worktree.id, equals: nil)

    let ticket = try #require(probe.launchedTickets.first)
    defer { try? FileManager.default.removeItem(at: ticket.trashRoot) }
    #expect(probe.launchedTickets.count == 1)
    #expect(probe.tabsWereEmptyAtLaunch)
    #expect(FileManager.default.fileExists(atPath: ticket.stagedPath.path))
    #expect(!state.projectsManager.worktrees(projectId: project.id).contains { $0.id == worktree.id })
}
```

Add a second test whose injected `worktreeCleanupLauncher` throws `CocoaError(.fileWriteUnknown)`. Assert the operation state still clears, the removed worktree does not return, and the staged path remains for stale recovery.

- [ ] **Step 2: Run the AppState tests and verify the initializer failure**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/AppStateCleanupTests/deleteWorktreeCleansAppStateBeforeLaunchingFileCleanup
```

Expected: compilation fails because AppState has no `worktreeCleanupLauncher` initializer parameter.

- [ ] **Step 3: Add cleanup injection and startup recovery**

Add:

```swift
typealias WorktreeCleanupLauncher = @MainActor (WorktreeTrashCleanupTicket) throws -> Void

@ObservationIgnored
private let worktreeCleanupLauncher: WorktreeCleanupLauncher
```

Extend `AppState.init` with this default:

```swift
worktreeCleanupLauncher: @escaping WorktreeCleanupLauncher = {
    try WorktreeTrashCleaner.launch($0)
}
```

After all stored properties are initialized, capture `projectsFile.projects` by value and start this utility task:

```swift
let cleanupProjects = projectsFile.projects
Task.detached(priority: .utility) {
    WorktreeTrashCleaner.sweep(projects: cleanupProjects)
}
```

This is the application-startup recovery required by the spec. It must not await cleanup or block `AppState.init`.

- [ ] **Step 4: Return removal outcomes through the mutation gate**

Change `performRemoveWorktree` to return `WorktreeRemovalOutcome`. Inside its detached task, call existing `remove` and return `.synchronous` for remote worktrees. Call `removeFastLocal` for local worktrees. Keep the whole selection under `ProjectMutationGate.shared.withMutation(projectID:)`.

```swift
if worktree.path.isRemoteAlasPath {
    try await WorktreeService().remove(
        repoPath: repoPath,
        worktree: worktree,
        deleteBranchIfMerged: deleteBranchIfMerged,
        force: force
    )
    return .synchronous
}
return try await WorktreeService().removeFastLocal(
    repoPath: repoPath,
    worktree: worktree,
    deleteBranchIfMerged: deleteBranchIfMerged,
    force: force
)
```

- [ ] **Step 5: Launch cleanup after owned-state teardown**

Store the successful outcome in `performDeleteWorktree`. Keep all current error handling. On success, use this order:

1. Call `cleanupWorktreeState(worktreeId:)`.
2. If the outcome is `.staged(ticket)`, call the injected launcher in `do/catch`. Log a launch failure without changing deletion state.
3. Start a detached stale sweep using a snapshot of current projects.
4. Clear operation state, remove persisted GG mode, refresh worktrees, and resolve selection through the existing code.

The launcher call returns after process spawn. AppState must never await the cleaner process.

The success section of `performDeleteWorktree` should have this shape:

```swift
let outcome: WorktreeRemovalOutcome
do {
    outcome = try await Self.performRemoveWorktree(
        repoPath: repoPath,
        worktree: worktree,
        deleteBranchIfMerged: deleteBranchIfMerged,
        force: force
    )
} catch let WorktreeService.WorktreeError.gitFailed(stderr) {
    if !force,
       let pending = Self.pendingForceDelete(
           for: worktree,
           repoPath: repoPath,
           deleteBranchIfMerged: deleteBranchIfMerged,
           removedIndex: removedIndex,
           stderr: stderr
       ) {
        projectsManager.setOperationState(id: worktree.id, state: nil)
        pendingForceDeleteWorktree = pending
        return
    }
    projectsManager.setOperationState(
        id: worktree.id,
        state: .deleteFailed(message: stderr)
    )
    return
} catch {
    projectsManager.setOperationState(
        id: worktree.id,
        state: .deleteFailed(message: "\(error)")
    )
    return
}

cleanupWorktreeState(worktreeId: worktree.id)
if case .staged(let ticket) = outcome {
    do {
        try worktreeCleanupLauncher(ticket)
    } catch {
        Self.logger.error(
            "Could not launch worktree cleanup for \(ticket.stagedPath.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
    }
    let cleanupProjects = projects
    Task.detached(priority: .utility) {
        WorktreeTrashCleaner.sweep(projects: cleanupProjects)
    }
}
projectsManager.setOperationState(id: worktree.id, state: nil)
removePersistedGGWorktreeMode(
    projectId: worktree.projectId,
    worktreeId: worktree.id
)
_ = try? await refreshProjectWorktrees(projectId: worktree.projectId)
if selectedWorktreeId == worktree.id {
    selectWorktree(id: selectionAfterRemoval(
        removedFromProjectId: worktree.projectId,
        removedAtIndex: removedIndex
    ))
}
```

- [ ] **Step 6: Run AppState cleanup and deletion policy tests**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/AppStateCleanupTests
```

Expected: all tests pass. Existing confirmation strings and pending-force behavior remain unchanged.

- [ ] **Step 7: Commit AppState integration**

```bash
git add Alas/Sources/App/AppState.swift AlasTests/AppStateCleanupTests.swift
git commit -m "feat: finish worktree deletion before file cleanup"
```

---

### Task 5: Regression verification and behavioral benchmark

**Files:**

- Modify only if verification finds a defect in files already listed above.

**Interfaces:**

- Consumes: the completed staged deletion path.
- Produces: evidence that code generation, build, focused tests, and the repository test suite behave as expected.

- [ ] **Step 1: Regenerate the Xcode project and check for unintended changes**

```bash
xcodegen
git status --short
git diff --check
```

Expected: `xcodegen` succeeds. Earlier tasks already regenerated the project after adding files, so `Alas.xcodeproj` should not change now.

- [ ] **Step 2: Run focused deletion suites**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test \
  -only-testing:AlasTests/WorktreeTrashTests \
  -only-testing:AlasTests/WorktreeServiceTests \
  -only-testing:AlasTests/AppStateCleanupTests
```

Expected: all focused tests pass.

- [ ] **Step 3: Run the required build**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: exit code 0. Existing Swift concurrency warnings may remain, but no new warnings should point at the changed files.

- [ ] **Step 4: Run the required full test suite**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: exit code 0. The untouched baseline hung in `ACPTerminalTests.descendantCleanupRunsOffMainActor` while opening `ACPTerminal.swift`. If that exact hang repeats, capture a process sample and the xcresult path, stop the run, execute that test alone once, and report the baseline issue separately. Do not classify a new failure in changed code as baseline noise.

- [ ] **Step 5: Exercise the file-count boundary without a timing assertion**

Run the focused fast-removal integration test after increasing its temporary untracked marker set locally to at least 50,000 files without committing that test edit. Confirm the test returns a `.staged` ticket while the marker files still exist under `ticket.stagedPath`, then let the test cleanup remove them. The proof is the ordering boundary, not a duration threshold. Restore the temporary test edit with `apply_patch` before continuing.

- [ ] **Step 6: Review the final diff**

```bash
git diff 4bee44f0..HEAD --stat
git diff 4bee44f0..HEAD --check
git status --short
```

Confirm the diff contains only the staged-removal implementation, focused tests, and the committed planning documents. Confirm `/Volumes/Ambrosio/repos/alas` remains clean on `main`.

- [ ] **Step 7: Commit any verification fixes**

If verification required code changes, stage only those files and commit them with a message describing the concrete fix. If no files changed, do not create an empty commit.
