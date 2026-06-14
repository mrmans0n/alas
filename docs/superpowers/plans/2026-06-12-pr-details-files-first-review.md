# PR Details Files-First Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make PR/MR details open to a files-first review surface backed by provider diff output, while preserving CI and feedback evidence sections.

**Architecture:** Add a provider diff capability to `CodeHostProvider`, parse provider unified diff into file-level models with a new `ReviewRequestDiffLoader`, extend `ReviewEvidenceModel` with independent file-session state, then update `ReviewEvidenceTabView` to render `DiffReviewSurface` as the default Files section. CI and Feedback keep the existing evidence list/detail browser and actions.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit-backed diff renderer, Swift Testing, `gh`/`glab` CLI providers.

---

## File Structure

- Modify `Alas/Sources/Integrations/CodeHost/CodeHostProvider.swift` to add `reviewDiff(remote:request:cwd:)`.
- Modify `Alas/Sources/Integrations/CodeHost/GitHubCLIProvider.swift` and `Alas/Sources/Integrations/CodeHost/GitLabCLIProvider.swift` to call provider CLI diff commands.
- Create `Alas/Sources/Integrations/CodeHost/ReviewRequestDiffLoader.swift` for provider unified diff splitting and `DiffReviewLoadedSession` construction.
- Modify `Alas/Sources/Integrations/CodeHost/ReviewEvidence.swift` to add `.files`.
- Modify `Alas/Sources/Integrations/CodeHost/ReviewEvidenceModel.swift` to load files independently from CI/feedback evidence.
- Modify `Alas/Sources/Center/ReviewEvidence/ReviewEvidenceTabView.swift` to render Files, CI, and Feedback sections.
- Add/modify tests under `AlasTests/Integrations`, `AlasTests`, and `AlasTests/Center` matching the existing test organization.
- Regenerate `Alas.xcodeproj` after adding source/test files.

---

### Task 1: Provider Diff Capability

**Files:**
- Modify: `Alas/Sources/Integrations/CodeHost/CodeHostProvider.swift`
- Modify: `Alas/Sources/Integrations/CodeHost/GitHubCLIProvider.swift`
- Modify: `Alas/Sources/Integrations/CodeHost/GitLabCLIProvider.swift`
- Test: `AlasTests/Integrations/GitHubCLIProviderTests.swift`
- Test: `AlasTests/Integrations/GitLabCLIProviderTests.swift`

- [ ] **Step 1: Write failing GitHub provider test**

Add this test near other command-argument tests in `AlasTests/Integrations/GitHubCLIProviderTests.swift`:

```swift
@Test func reviewDiffUsesPRDiffCommand() async throws {
    let runner = FakeRunner(results: [
        ProcessResult(exitCode: 0, stdout: "diff --git a/A.swift b/A.swift\n", stderr: ""),
    ])
    let request = try #require(try GitHubCLIProvider.parsePRList(Self.prListOutput, remote: Self.remote))

    let diff = try await GitHubCLIProvider(runner: runner).reviewDiff(
        remote: Self.remote,
        request: request,
        cwd: Self.cwd
    )

    #expect(diff == "diff --git a/A.swift b/A.swift\n")
    #expect(await runner.commands == [
        FakeRunner.Command(
            executable: "gh",
            args: ["pr", "diff", "42", "-R", "mrmans0n/alas"],
            cwd: Self.cwd
        ),
    ])
}

@Test func reviewDiffSurfacesGitHubCommandFailure() async throws {
    let runner = FakeRunner(results: [
        ProcessResult(exitCode: 1, stdout: "", stderr: "not found"),
    ])
    let request = try #require(try GitHubCLIProvider.parsePRList(Self.prListOutput, remote: Self.remote))

    await #expect(throws: CodeHostProviderError.commandFailed(command: "gh pr diff", stderr: "not found")) {
        _ = try await GitHubCLIProvider(runner: runner).reviewDiff(
            remote: Self.remote,
            request: request,
            cwd: Self.cwd
        )
    }
}
```

- [ ] **Step 2: Write failing GitLab provider test**

Add this test near other command-argument tests in `AlasTests/Integrations/GitLabCLIProviderTests.swift`:

```swift
@Test func reviewDiffUsesMRDiffCommand() async throws {
    let runner = FakeRunner(results: [
        ProcessResult(exitCode: 0, stdout: "diff --git a/A.swift b/A.swift\n", stderr: ""),
    ])
    let request = try GitLabCLIProvider.parseMRView(Self.mrViewOutput, remote: Self.remote)

    let diff = try await GitLabCLIProvider(runner: runner).reviewDiff(
        remote: Self.remote,
        request: request,
        cwd: Self.cwd
    )

    #expect(diff == "diff --git a/A.swift b/A.swift\n")
    #expect(await runner.commands == [
        FakeRunner.Command(
            executable: "glab",
            args: ["mr", "diff", "44", "-R", "platform/mobile/alas"],
            cwd: Self.cwd
        ),
    ])
}

@Test func reviewDiffSurfacesGitLabCommandFailure() async throws {
    let runner = FakeRunner(results: [
        ProcessResult(exitCode: 1, stdout: "", stderr: "not found"),
    ])
    let request = try GitLabCLIProvider.parseMRView(Self.mrViewOutput, remote: Self.remote)

    await #expect(throws: CodeHostProviderError.commandFailed(command: "glab mr diff", stderr: "not found")) {
        _ = try await GitLabCLIProvider(runner: runner).reviewDiff(
            remote: Self.remote,
            request: request,
            cwd: Self.cwd
        )
    }
}
```

- [ ] **Step 3: Run focused provider tests red**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GitHubCLIProviderTests/reviewDiffUsesPRDiffCommand -only-testing:AlasTests/GitLabCLIProviderTests/reviewDiffUsesMRDiffCommand test
```

Expected: compile failure because `reviewDiff(remote:request:cwd:)` is not defined.

- [ ] **Step 4: Implement provider capability**

Add to `CodeHostProvider`:

```swift
func reviewDiff(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> String
```

Add this default implementation in the `CodeHostProvider` extension:

```swift
func reviewDiff(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> String {
    throw CodeHostProviderError.unsupportedProvider(remote.kind)
}
```

Add this method to `GitHubCLIProvider`:

```swift
func reviewDiff(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> String {
    let result = try await runner.run(
        "gh",
        args: ["pr", "diff", "\(request.number)", "-R", remote.repositorySlug],
        cwd: cwd
    )
    guard result.exitCode == 0 else {
        throw CodeHostProviderError.commandFailed(command: "gh pr diff", stderr: result.stderr)
    }
    return result.stdout
}
```

Add this method to `GitLabCLIProvider`:

```swift
func reviewDiff(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> String {
    let result = try await runner.run(
        "glab",
        args: ["mr", "diff", "\(request.number)", "-R", remote.repositorySlug],
        cwd: cwd
    )
    guard result.exitCode == 0 else {
        throw CodeHostProviderError.commandFailed(command: "glab mr diff", stderr: result.stderr)
    }
    return result.stdout
}
```

- [ ] **Step 5: Run focused provider tests green**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GitHubCLIProviderTests -only-testing:AlasTests/GitLabCLIProviderTests test
```

Expected: provider tests pass.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Integrations/CodeHost/CodeHostProvider.swift Alas/Sources/Integrations/CodeHost/GitHubCLIProvider.swift Alas/Sources/Integrations/CodeHost/GitLabCLIProvider.swift AlasTests/Integrations/GitHubCLIProviderTests.swift AlasTests/Integrations/GitLabCLIProviderTests.swift
git commit -m "feat(review): fetch provider review diffs"
```

---

### Task 2: Review Request Diff Loader

**Files:**
- Create: `Alas/Sources/Integrations/CodeHost/ReviewRequestDiffLoader.swift`
- Test: `AlasTests/Integrations/ReviewRequestDiffLoaderTests.swift`
- Modify generated project: `Alas.xcodeproj/project.pbxproj` after `xcodegen`

- [ ] **Step 1: Write failing loader tests**

Create `AlasTests/Integrations/ReviewRequestDiffLoaderTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

@MainActor
struct ReviewRequestDiffLoaderTests {
    @Test func providerUnifiedDiffBuildsReviewSessionInProviderOrder() async throws {
        let provider = FakeDiffProvider(diff: Self.sampleDiff)
        let loader = ReviewRequestDiffLoader(provider: provider)

        let session = try await loader.load(
            remote: Self.remote(),
            request: Self.reviewRequest(),
            cwd: URL(fileURLWithPath: "/tmp/repo")
        )

        #expect(session.files.map(\.summary.path) == ["Sources/App.swift", "Sources/NewName.swift", "Assets/logo.png"])
        #expect(session.files.map(\.summary.namespace) == ["github-pr", "github-pr", "github-pr"])
        #expect(session.summary.groupsEnabled == false)
        #expect(session.files[0].summary.status == .modified)
        #expect(session.files[1].summary.status == .renamed)
        #expect(session.files[1].summary.originalPath == "Sources/OldName.swift")
        #expect(session.files[2].summary.isRenderable == false)
        #expect(session.files[2].placeholderMessage == "Image changes are not available in this review view yet.")
        #expect(session.summary.totalAdditions == 3)
        #expect(session.summary.totalDeletions == 2)
    }

    @Test func emptyProviderDiffProducesEmptyUngroupedSession() async throws {
        let provider = FakeDiffProvider(diff: "")
        let loader = ReviewRequestDiffLoader(provider: provider)

        let session = try await loader.load(
            remote: Self.remote(),
            request: Self.reviewRequest(),
            cwd: URL(fileURLWithPath: "/tmp/repo")
        )

        #expect(session.files.isEmpty)
        #expect(session.summary.files.isEmpty)
        #expect(session.summary.groupsEnabled == false)
    }

    private static let sampleDiff = """
    diff --git a/Sources/App.swift b/Sources/App.swift
    index 111..222 100644
    --- a/Sources/App.swift
    +++ b/Sources/App.swift
    @@ -1,2 +1,3 @@
     struct App {
    -    let old = true
    +    let new = true
    +    let added = true
     }
    diff --git a/Sources/OldName.swift b/Sources/NewName.swift
    similarity index 88%
    rename from Sources/OldName.swift
    rename to Sources/NewName.swift
    --- a/Sources/OldName.swift
    +++ b/Sources/NewName.swift
    @@ -1 +1 @@
    -let oldName = true
    +let newName = true
    diff --git a/Assets/logo.png b/Assets/logo.png
    index 111..222 100644
    --- a/Assets/logo.png
    +++ b/Assets/logo.png
    @@ -1 +1 @@
    -binary old
    +binary new
    """

    private static func remote() -> CodeHostRemote {
        CodeHostRemote(
            kind: .github,
            host: "github.com",
            owner: "mrmans0n",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://github.com/mrmans0n/alas")!
        )
    }

    private static func reviewRequest() -> ReviewRequest {
        ReviewRequest(
            remote: remote(),
            number: 516,
            title: "Files first",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/516")!,
            state: .open,
            isDraft: false,
            headRefName: "feature/files",
            baseRefName: "main",
            reviewDecision: .unknown,
            mergeState: .unknown,
            checks: [],
            threads: []
        )
    }
}

private struct FakeDiffProvider: CodeHostProvider {
    let diff: String
    var kind: CodeHostKind { .github }
    func isAvailable() async -> Bool { true }
    func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool { true }
    func currentReviewRequest(remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String, cwd: URL) async throws -> ReviewRequest? { nil }
    func createReviewRequest(remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String, title: String, body: String, isDraft: Bool, cwd: URL) async throws -> URL { URL(fileURLWithPath: "/tmp/pr") }
    func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] { [] }
    func reviewDiff(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> String { diff }
    func rerunFailedChecks(remote: CodeHostRemote, branch: String, headSHA: String, request: ReviewRequest?, cwd: URL) async throws {}
}
```

- [ ] **Step 2: Run loader tests red**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewRequestDiffLoaderTests test
```

Expected: compile failure because `ReviewRequestDiffLoader` is missing.

- [ ] **Step 3: Implement loader**

Create `Alas/Sources/Integrations/CodeHost/ReviewRequestDiffLoader.swift` with:

```swift
import Foundation

struct ReviewRequestDiffLoader {
    let provider: any CodeHostProvider

    init(provider: any CodeHostProvider) {
        self.provider = provider
    }

    func load(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> DiffReviewLoadedSession {
        try Task.checkCancellation()
        let rawDiff = try await provider.reviewDiff(remote: remote, request: request, cwd: cwd)
        try Task.checkCancellation()

        var sections: [DiffReviewFileSectionModel] = []
        for file in ProviderDiffSplitter.split(rawDiff) {
            try Task.checkCancellation()
            sections.append(try await fileSection(for: file, namespace: namespace(for: request.provider)))
        }

        return DiffReviewLoadedSession(
            files: sections,
            summary: DiffReviewSessionModel(files: sections.map(\.summary), groupsEnabled: false)
        )
    }

    private func namespace(for provider: CodeHostKind) -> String {
        switch provider {
        case .github: "github-pr"
        case .gitlab: "gitlab-mr"
        }
    }

    private func fileSection(for file: ProviderDiffFile, namespace: String) async throws -> DiffReviewFileSectionModel {
        let parsedDiff = DiffParser.parse(file.rawDiff)
        let canRender = !parsedDiff.hunks.isEmpty && !ImageFileType.isSupported(relativePath: file.path)
        let counts = lineCounts(in: parsedDiff)
        let summary = DiffReviewFileSummary(
            path: file.path,
            namespace: namespace,
            groupID: nil,
            groupTitle: nil,
            status: DiffReviewFileStatus(gitStatus: file.status),
            additions: counts.additions,
            deletions: counts.deletions,
            isRenderable: canRender,
            originalPath: file.originalPath
        )

        return DiffReviewFileSectionModel(
            summary: summary,
            parsedDiff: parsedDiff,
            displayModel: canRender ? try await buildDisplayModel(diff: parsedDiff, filePath: file.path) : nil,
            placeholderMessage: canRender ? nil : placeholderMessage(for: file, parsedDiff: parsedDiff),
            openFile: nil
        )
    }

    private func buildDisplayModel(diff: ParsedDiff, filePath: String) async throws -> DiffDisplayModel {
        try Task.checkCancellation()
        let model = await Task.detached(priority: .userInitiated) {
            DiffDisplayModelBuilder.build(diff: diff, filePath: filePath)
        }.value
        try Task.checkCancellation()
        return model
    }

    private func lineCounts(in diff: ParsedDiff) -> (additions: Int, deletions: Int) {
        diff.hunks.reduce(into: (additions: 0, deletions: 0)) { counts, hunk in
            for line in hunk.lines {
                switch line.kind {
                case .add: counts.additions += 1
                case .delete: counts.deletions += 1
                case .context: break
                }
            }
        }
    }

    private func placeholderMessage(for file: ProviderDiffFile, parsedDiff: ParsedDiff) -> String {
        if ImageFileType.isSupported(relativePath: file.path) {
            return "Image changes are not available in this review view yet."
        }
        if parsedDiff.hunks.isEmpty {
            return "No text diff is available for this file."
        }
        return "This file cannot be rendered in the review view."
    }
}

struct ProviderDiffFile: Equatable {
    let path: String
    let originalPath: String?
    let status: String
    let rawDiff: String
}

enum ProviderDiffSplitter {
    static func split(_ rawDiff: String) -> [ProviderDiffFile] {
        let lines = rawDiff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var files: [ProviderDiffFile] = []
        var current: [String] = []

        func flush() {
            guard !current.isEmpty, let file = parseFile(current) else {
                current.removeAll()
                return
            }
            files.append(file)
            current.removeAll()
        }

        for line in lines {
            if line.hasPrefix("diff --git ") {
                flush()
            }
            current.append(line)
        }
        flush()
        return files
    }

    private static func parseFile(_ lines: [String]) -> ProviderDiffFile? {
        guard let header = lines.first, header.hasPrefix("diff --git ") else { return nil }
        let paths = parseDiffGitPaths(header)
        let renameFrom = lines.first { $0.hasPrefix("rename from ") }.map { String($0.dropFirst("rename from ".count)) }
        let renameTo = lines.first { $0.hasPrefix("rename to ") }.map { String($0.dropFirst("rename to ".count)) }
        let deleted = lines.contains { $0.hasPrefix("deleted file mode") }
        let added = lines.contains { $0.hasPrefix("new file mode") }
        let path = renameTo ?? paths?.newPath
        guard let path else { return nil }

        let status: String
        if renameFrom != nil || renameTo != nil {
            status = "R"
        } else if added {
            status = "A"
        } else if deleted {
            status = "D"
        } else {
            status = "M"
        }

        return ProviderDiffFile(
            path: path,
            originalPath: renameFrom ?? (deleted ? paths?.oldPath : nil),
            status: status,
            rawDiff: lines.joined(separator: "\n")
        )
    }

    private static func parseDiffGitPaths(_ header: String) -> (oldPath: String, newPath: String)? {
        let prefix = "diff --git "
        guard header.hasPrefix(prefix) else { return nil }
        let remainder = String(header.dropFirst(prefix.count))
        let parts = remainder.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (stripGitPrefix(parts[0]), stripGitPrefix(parts[1]))
    }

    private static func stripGitPrefix(_ path: String) -> String {
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            return String(path.dropFirst(2))
        }
        return path
    }
}
```

- [ ] **Step 4: Regenerate project**

Run:

```bash
xcodegen
```

Expected: `Alas.xcodeproj/project.pbxproj` includes the new source and test files.

- [ ] **Step 5: Run loader tests green**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewRequestDiffLoaderTests test
```

Expected: loader tests pass.

- [ ] **Step 6: Commit**

```bash
git add Alas.xcodeproj/project.pbxproj Alas/Sources/Integrations/CodeHost/ReviewRequestDiffLoader.swift AlasTests/Integrations/ReviewRequestDiffLoaderTests.swift
git commit -m "feat(review): build file sessions from provider diffs"
```

---

### Task 3: Files Section Model State

**Files:**
- Modify: `Alas/Sources/Integrations/CodeHost/ReviewEvidence.swift`
- Modify: `Alas/Sources/Integrations/CodeHost/ReviewEvidenceModel.swift`
- Test: `AlasTests/Integrations/ReviewEvidenceModelTests.swift`

- [ ] **Step 1: Write failing model tests**

Add these tests to `ReviewEvidenceModelTests`:

```swift
@Test func modelDefaultsToFilesAndLoadsFileSessionIndependently() async {
    let provider = FakeCodeHostProvider(reviewDiff: """
    diff --git a/A.swift b/A.swift
    --- a/A.swift
    +++ b/A.swift
    @@ -1 +1,2 @@
     let a = 1
    +let b = 2
    """)
    let model = ReviewEvidenceModel(
        snapshot: Self.snapshot(),
        provider: provider,
        cwd: URL(fileURLWithPath: "/tmp/alas"),
        initialSection: nil
    )

    await model.load()

    #expect(model.selectedSection == .files)
    #expect(model.fileSession?.summary.files.map(\.path) == ["A.swift"])
    #expect(model.ciItems.count == 1)
    #expect(model.feedbackItems.count == 1)
    #expect(model.fileErrorMessage == nil)
}

@Test func fileLoadFailureDoesNotEraseEvidenceItems() async {
    let provider = FakeCodeHostProvider(
        reviewDiffError: CodeHostProviderError.commandFailed(command: "gh pr diff", stderr: "boom")
    )
    let model = ReviewEvidenceModel(
        snapshot: Self.snapshot(),
        provider: provider,
        cwd: URL(fileURLWithPath: "/tmp/alas"),
        initialSection: nil
    )

    await model.load()

    #expect(model.selectedSection == .files)
    #expect(model.fileSession == nil)
    #expect(model.fileErrorMessage?.contains("gh pr diff failed: boom") == true)
    #expect(model.ciItems.count == 1)
    #expect(model.feedbackItems.count == 1)
}

@Test func restoredCISectionIsPreserved() async {
    let model = ReviewEvidenceModel(
        snapshot: Self.snapshot(),
        provider: FakeCodeHostProvider(),
        cwd: URL(fileURLWithPath: "/tmp/alas"),
        initialSection: .ci
    )

    await model.load()

    #expect(model.selectedSection == .ci)
    #expect(model.selectedItem?.id == "ci:test")
}
```

Update the local `FakeCodeHostProvider` initializer in the same file to accept:

```swift
let reviewDiff: String
let reviewDiffError: Error?
```

with defaults:

```swift
reviewDiff: String = "",
reviewDiffError: Error? = nil
```

and implement:

```swift
func reviewDiff(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> String {
    if let reviewDiffError { throw reviewDiffError }
    return reviewDiff
}
```

- [ ] **Step 2: Run model tests red**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewEvidenceModelTests test
```

Expected: compile failures for `.files`, `fileSession`, and `fileErrorMessage`.

- [ ] **Step 3: Add files section and model state**

Update `ReviewEvidenceSection`:

```swift
enum ReviewEvidenceSection: String, Codable, Equatable, Sendable, CaseIterable {
    case files
    case ci
    case feedback

    var displayName: String {
        switch self {
        case .files: "Files"
        case .ci: "CI"
        case .feedback: "Feedback"
        }
    }
}
```

Update `ReviewEvidenceModel`:

- `selectedSection` should default to `initialSection ?? .files`.
- Add:

```swift
private(set) var fileSession: DiffReviewLoadedSession?
private(set) var isLoadingFiles = false
private(set) var fileErrorMessage: String?
private var selectedFileID: DiffReviewFileID?
```

- In `load()`, load files and evidence independently:

```swift
async let loadedFiles: Void = loadFiles(remote: remote, request: request)
async let loadedEvidence: Void = loadEvidenceLists(remote: remote, request: request)
_ = await (loadedFiles, loadedEvidence)
chooseInitialSelection()
```

Implement `loadFiles(remote:request:)`:

```swift
private func loadFiles(remote: CodeHostRemote, request: ReviewRequest) async {
    isLoadingFiles = true
    fileErrorMessage = nil
    do {
        fileSession = try await ReviewRequestDiffLoader(provider: provider).load(
            remote: remote,
            request: request,
            cwd: cwd
        )
    } catch {
        fileSession = nil
        fileErrorMessage = error.localizedDescription
    }
    isLoadingFiles = false
}
```

Move the existing CI/feedback loading body into `loadEvidenceLists(remote:request:)`, preserving `ciItems`, `feedbackItems`, `isLoadingList`, and `errorMessage`.

Update `chooseInitialSelection()` so `.files` remains selected when requested/defaulted. Only run item selection logic when selected section is `.ci` or `.feedback`.

Update `items(for:)`:

```swift
func items(for section: ReviewEvidenceSection) -> [ReviewEvidenceItem] {
    switch section {
    case .files:
        []
    case .ci:
        ciItems
    case .feedback:
        feedbackItems
    }
}
```

- [ ] **Step 4: Run model tests green**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewEvidenceModelTests -only-testing:AlasTests/ReviewRequestDiffLoaderTests test
```

Expected: model and loader tests pass.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Integrations/CodeHost/ReviewEvidence.swift Alas/Sources/Integrations/CodeHost/ReviewEvidenceModel.swift AlasTests/Integrations/ReviewEvidenceModelTests.swift
git commit -m "feat(review): load files-first evidence state"
```

---

### Task 4: Files-First Review Evidence Tab

**Files:**
- Modify: `Alas/Sources/Center/ReviewEvidence/ReviewEvidenceTabView.swift`
- Modify: `Alas/Sources/Center/Tab.swift`
- Create: `AlasTests/ReviewEvidenceTabViewTests.swift`

- [ ] **Step 1: Write failing view tests**

Create `AlasTests/ReviewEvidenceTabViewTests.swift` with these section/default tests. This avoids brittle SwiftUI reflection while still locking the behavior that the view consumes:

```swift
import Foundation
import Testing
@testable import Alas

struct ReviewEvidenceTabViewTests {
    @Test func sectionListIncludesFilesFirst() {
        #expect(ReviewEvidenceSection.allCases.map(\.displayName) == ["Files", "CI", "Feedback"])
    }

    @Test func tabStateDefaultsToFilesForNewReviewEvidenceTabs() {
        let snapshot = ReviewLoopSnapshot(
            local: ReviewLoopLocalState(
                branchName: "feature/files",
                headSHA: "abc",
                baseBranch: "main",
                hasWorkingTreeChanges: false,
                hasStagedChanges: false,
                aheadCommitCount: 1,
                hasUpstream: true,
                needsPush: false
            ),
            remote: remote(),
            reviewRequest: request(),
            providerAvailable: true,
            providerAuthenticated: true,
            providerCapabilities: .githubCLI,
            errorMessage: nil
        )

        let state = ReviewEvidenceTabState(
            worktreeId: "worktree-1",
            snapshot: snapshot,
            initialSection: nil
        )

        #expect(state.selectedSection == .files)
    }

    private static func remote() -> CodeHostRemote {
        CodeHostRemote(
            kind: .github,
            host: "github.com",
            owner: "mrmans0n",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://github.com/mrmans0n/alas")!
        )
    }

    private static func request() -> ReviewRequest {
        ReviewRequest(
            remote: remote(),
            number: 516,
            title: "Files first",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/516")!,
            state: .open,
            isDraft: false,
            headRefName: "feature/files",
            baseRefName: "main",
            reviewDecision: .unknown,
            mergeState: .unknown,
            checks: [],
            threads: []
        )
    }
}
```

- [ ] **Step 2: Run view/section tests red**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewEvidenceTabViewTests test
```

Expected: compile failure if the new test file is not in the project yet, or failure until `.files` is implemented and ordered first.

- [ ] **Step 3: Render Files section**

In `ReviewEvidenceTabView`:

- Keep `header` unchanged.
- Keep `statusChips`, detail actions, rerun, copy, and handoff functions unchanged.
- Update `evidenceBrowser(model:)` so the segmented picker includes Files, CI, Feedback.
- Replace the body routing with:

```swift
switch selectedSection {
case .files:
    filesPane(model: model)
case .ci, .feedback:
    evidencePane(model: model)
}
```

Add:

```swift
@State private var selectedFileID: DiffReviewFileID?
@State private var railCollapsed = false
@State private var layoutMode: DiffLayoutMode = .split
@State private var wrapLines = true
@State private var showWhitespace = false
```

Initialize these from `appState.config.diff` using the same binding/save pattern used by `CommitTabView` for commit details. The bindings must persist changes through `appState.saveConfig()`.

Implement `filesPane(model:)`:

```swift
@ViewBuilder
private func filesPane(model: ReviewEvidenceModel) -> some View {
    if model.isLoadingFiles {
        Spinner()
            .frame(width: 20, height: 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let session = model.fileSession {
        DiffReviewSurface(
            session: session,
            selectedFileID: $selectedFileID,
            railCollapsed: $railCollapsed,
            layoutMode: diffLayoutBinding,
            wrapLines: diffWrapBinding,
            showWhitespace: diffWhitespaceBinding,
            codeFontFamily: appState.config.code.fontFamily,
            codeFontSize: CGFloat(appState.config.code.fontSize),
            showsSourceBadges: false,
            showsRailDisplayControls: true
        )
    } else {
        unavailableState(message: model.fileErrorMessage ?? "No file diff is available for this review request.")
    }
}
```

Extract the existing `HStack` list/detail browser into `evidencePane(model:)` and leave its internals unchanged for `.ci` and `.feedback`.

Update `applySelectedSection(_:,loadDetail:)`:

- If section is `.files`, persist `.files` with `itemID: nil` and do not select evidence item.
- For `.ci`/`.feedback`, keep current behavior.

Update `emptyText(for:)` to return `"No file diffs"` for `.files`, although `filesPane` handles the Files empty state directly.

- [ ] **Step 4: Regenerate project if a new test file was added**

Run:

```bash
xcodegen
```

Expected: project contains `AlasTests/ReviewEvidenceTabViewTests.swift`.

- [ ] **Step 5: Run focused view/model tests green**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ReviewEvidenceModelTests -only-testing:AlasTests/ReviewEvidenceTabViewTests test
```

Expected: focused tests pass.

- [ ] **Step 6: Commit**

```bash
git add Alas.xcodeproj/project.pbxproj Alas/Sources/Center/ReviewEvidence/ReviewEvidenceTabView.swift Alas/Sources/Center/Tab.swift AlasTests/ReviewEvidenceTabViewTests.swift
git commit -m "feat(review): show files first in PR details"
```

---

### Task 5: Final Integration Verification

**Files:**
- No planned source edits unless verification exposes a regression.

- [ ] **Step 1: Run provider and diff-review focused suites**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GitHubCLIProviderTests -only-testing:AlasTests/GitLabCLIProviderTests -only-testing:AlasTests/ReviewRequestDiffLoaderTests -only-testing:AlasTests/ReviewEvidenceModelTests -only-testing:AlasTests/DiffReviewSurfaceTests test
```

Expected: all focused suites pass.

- [ ] **Step 2: Run project generation**

Run:

```bash
xcodegen
```

Expected: completes successfully. Commit any legitimate `Alas.xcodeproj/project.pbxproj` updates caused by new files.

- [ ] **Step 3: Run quiet build**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: build exits 0.

- [ ] **Step 4: Run full test suite**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: full suite exits 0. If it fails, inspect the failing test. Fix regressions caused by this work; if a known unrelated flake fails, rerun that exact test once and report the caveat honestly.

- [ ] **Step 5: Commit verification fixes**

If verification required source changes, stage the exact files changed by those fixes. Example for a view/model hardening fix:

```bash
git add Alas/Sources/Center/ReviewEvidence/ReviewEvidenceTabView.swift Alas/Sources/Integrations/CodeHost/ReviewEvidenceModel.swift
git commit -m "fix(review): harden files-first PR details"
```

If no source changes were needed, do not create an empty commit.
