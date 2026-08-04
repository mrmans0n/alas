# Worktree Import Timestamps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every discovered worktree the commit time of its own HEAD so packed Git refs cannot collapse last-update display and sorting onto one shared timestamp.

**Architecture:** Keep `parsePorcelain` synchronous and retain its current filesystem/ref-derived `lastActivity` as a fallback. After parsing, enrich every local or SSH worktree concurrently with `git log -1 --format=%ct HEAD`; successful lookups replace the fallback while failures leave it unchanged.

**Tech Stack:** Swift 5.9, Foundation `Process`, Swift structured concurrency, Swift Testing, Git CLI, macOS 15+

## Global Constraints

- Keep code, comments, logs, and UI strings in English.
- Tests use Swift Testing (`import Testing`), not XCTest.
- Do not add dependencies or persistence fields.
- Preserve folder creation-date semantics for `createdAt`.
- Preserve filesystem/ref-derived `lastActivity` as the fallback for empty repositories or failed Git lookups.
- Use each worktree's HEAD commit time consistently for local and SSH repositories.

---

### Task 1: Resolve Worktree Last Activity From HEAD Commit Time

**Files:**
- Modify: `AlasTests/WorktreeServiceTests.swift`
- Modify: `Alas/Sources/Git/WorktreeService.swift:32-42`
- Modify: `Alas/Sources/Git/WorktreeService.swift:123-147`

**Interfaces:**
- Consumes: `Process.git(_:cwd:stdin:timeout:)`, `Process.run(_:args:cwd:env:stdin:timeout:)`, `Process.gitEnv()`, `GitInvocation.build(gitArgs:cwd:host:)`, and `WorktreeService.date(fromEpochOutput:)`.
- Produces: `WorktreeService.list(repoPath:projectId:) async throws -> [Worktree]` whose successful rows use the checked-out HEAD commit time for `lastActivity` on both local and SSH repositories.
- Internal helper: rename `fillingRemoteLastActivity(_:host:)` to `fillingHeadCommitTimes(_:host:)` and change `host` from `String` to `String?`.

- [ ] **Step 1: Write the packed-refs regression test**

Add this test inside `WorktreeServiceTests` after `listFindsMain()`:

```swift
@Test func listUsesEachHeadCommitTimeWhenRefsArePacked() async throws {
    let repo = try await makeRepo()
    let root = repo.deletingLastPathComponent()
    let one = root.appendingPathComponent("\(repo.lastPathComponent)-packed-one")
    let two = root.appendingPathComponent("\(repo.lastPathComponent)-packed-two")
    defer {
        try? FileManager.default.removeItem(at: one)
        try? FileManager.default.removeItem(at: two)
        try? FileManager.default.removeItem(at: repo)
    }

    _ = try await Process.git(["branch", "packed-one"], cwd: repo)
    _ = try await Process.git(["branch", "packed-two"], cwd: repo)
    _ = try await Process.git(["worktree", "add", "-q", one.path, "packed-one"], cwd: repo)
    _ = try await Process.git(["worktree", "add", "-q", two.path, "packed-two"], cwd: repo)

    let oneEpoch: TimeInterval = 1_738_411_200
    let twoEpoch: TimeInterval = 1_740_830_400

    var oneEnv = Process.gitEnv()
    oneEnv["GIT_AUTHOR_DATE"] = "2025-02-01T12:00:00Z"
    oneEnv["GIT_COMMITTER_DATE"] = "2025-02-01T12:00:00Z"
    let oneCommit = try await Process.run(
        "/usr/bin/env",
        args: ["git", "commit", "-q", "--allow-empty", "-m", "one"],
        cwd: one,
        env: oneEnv
    )
    try #require(oneCommit.exitCode == 0)

    var twoEnv = Process.gitEnv()
    twoEnv["GIT_AUTHOR_DATE"] = "2025-03-01T12:00:00Z"
    twoEnv["GIT_COMMITTER_DATE"] = "2025-03-01T12:00:00Z"
    let twoCommit = try await Process.run(
        "/usr/bin/env",
        args: ["git", "commit", "-q", "--allow-empty", "-m", "two"],
        cwd: two,
        env: twoEnv
    )
    try #require(twoCommit.exitCode == 0)

    let packed = try await Process.git(["pack-refs", "--all", "--prune"], cwd: repo)
    try #require(packed.exitCode == 0)

    let trees = try await WorktreeService().list(repoPath: repo, projectId: "p")
    let byBranch = Dictionary(uniqueKeysWithValues: trees.map { ($0.branch, $0) })

    #expect(byBranch["packed-one"]?.lastActivity == Date(timeIntervalSince1970: oneEpoch))
    #expect(byBranch["packed-two"]?.lastActivity == Date(timeIntervalSince1970: twoEpoch))
}
```

This test catches a regression where `list` returns the shared `packed-refs` mtime instead of each worktree's commit time. Its expected epoch values are fixed literals derived from the fixture dates, independent of production parsing.

- [ ] **Step 2: Run the regression test and verify RED**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/WorktreeServiceTests/listUsesEachHeadCommitTimeWhenRefsArePacked test
```

Expected: FAIL because both linked worktrees receive the current shared `packed-refs` modification time rather than `2025-02-01T12:00:00Z` and `2025-03-01T12:00:00Z`.

- [ ] **Step 3: Enrich every discovered worktree from its HEAD commit**

Change `WorktreeService.list` to pass the optional host into one shared enrichment path:

```swift
func list(repoPath: URL, projectId: String) async throws -> [Worktree] {
    let result = try await Process.git(["worktree", "list", "--porcelain"], cwd: repoPath)
    guard result.exitCode == 0 else { throw WorktreeError.gitFailed(result.stderr) }
    let trees = Self.parsePorcelain(result.stdout, projectId: projectId)
    let host = RemoteHostRegistry.shared.host(forPath: repoPath.path)
    return await Self.fillingHeadCommitTimes(trees, host: host)
}
```

Rename and generalize the existing helper without changing its fallback behavior:

```swift
private static func fillingHeadCommitTimes(_ trees: [Worktree], host: String?) async -> [Worktree] {
    await withTaskGroup(of: (Int, Date?).self) { group in
        for (index, tree) in trees.enumerated() {
            group.addTask {
                let invocation = GitInvocation.build(
                    gitArgs: ["log", "-1", "--format=%ct", "HEAD"],
                    cwd: tree.path,
                    host: host
                )
                let result = try? await Process.run(
                    invocation.executable,
                    args: invocation.args,
                    cwd: invocation.cwd,
                    env: invocation.env
                )
                return (
                    index,
                    result.flatMap {
                        $0.exitCode == 0 ? date(fromEpochOutput: $0.stdout) : nil
                    }
                )
            }
        }
        var trees = trees
        for await (index, date) in group where date != nil {
            trees[index].lastActivity = date!
        }
        return trees
    }
}
```

Do not remove `lastActivity(forWorktreeAt:)`: `parsePorcelain` still uses it to provide a value when a repository is empty or the HEAD lookup fails.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/WorktreeServiceTests \
  -only-testing:AlasTests/WorktreeServiceCreatedAtTests test
```

Expected: PASS, including the packed-refs regression and the existing timestamp fallback/parser coverage.

- [ ] **Step 5: Run project-required verification**

Run:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: all commands exit successfully. If `xcodegen` changes `Alas.xcodeproj/project.pbxproj`, include that generated change in the implementation commit as required by the project instructions.

- [ ] **Step 6: Commit the implementation**

```bash
git add Alas/Sources/Git/WorktreeService.swift AlasTests/WorktreeServiceTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "fix: use HEAD commit times for worktree activity"
```

If `Alas.xcodeproj/project.pbxproj` is unchanged, omit it from `git add`.
