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
        #expect(session.summary.totalAdditions == 4)
        #expect(session.summary.totalDeletions == 3)
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

    @Test func noHunkPlaceholderFileWithSpacesKeepsHeaderPath() async throws {
        let provider = FakeDiffProvider(diff: """
        diff --git a/Assets/logo file.png b/Assets/logo file.png
        index 111..222 100644
        """)
        let loader = ReviewRequestDiffLoader(provider: provider)

        let session = try await loader.load(
            remote: Self.remote(),
            request: Self.reviewRequest(),
            cwd: URL(fileURLWithPath: "/tmp/repo")
        )

        let file = try #require(session.files.first)
        #expect(file.summary.path == "Assets/logo file.png")
        #expect(file.summary.isRenderable == false)
        #expect(file.placeholderMessage == "Image changes are not available in this review view yet.")
    }

    @Test func noHunkPlaceholderFileWithBSlashSegmentKeepsHeaderPath() async throws {
        let provider = FakeDiffProvider(diff: """
        diff --git a/foo b/bar.png b/foo b/bar.png
        index 111..222 100644
        """)
        let loader = ReviewRequestDiffLoader(provider: provider)

        let session = try await loader.load(
            remote: Self.remote(),
            request: Self.reviewRequest(),
            cwd: URL(fileURLWithPath: "/tmp/repo")
        )

        let file = try #require(session.files.first)
        #expect(file.summary.path == "foo b/bar.png")
        #expect(file.summary.isRenderable == false)
    }

    @Test func quotedPathHeadersDecodeEscapedTab() async throws {
        let provider = FakeDiffProvider(diff: """
        diff --git "a/tab\\tfile.swift" "b/tab\\tfile.swift"
        index 111..222 100644
        --- "a/tab\\tfile.swift"
        +++ "b/tab\\tfile.swift"
        @@ -1 +1 @@
        -let old = true
        +let new = true
        """)
        let loader = ReviewRequestDiffLoader(provider: provider)

        let session = try await loader.load(
            remote: Self.remote(),
            request: Self.reviewRequest(),
            cwd: URL(fileURLWithPath: "/tmp/repo")
        )

        let file = try #require(session.files.first)
        #expect(file.summary.path == "tab\tfile.swift")
    }

    @Test func quotedRenameHeadersDecodeEscapedPaths() async throws {
        let provider = FakeDiffProvider(diff: """
        diff --git "a/old\\tfile.swift" "b/new\\tfile.swift"
        similarity index 88%
        rename from "old\\tfile.swift"
        rename to "new\\tfile.swift"
        --- "a/old\\tfile.swift"
        +++ "b/new\\tfile.swift"
        @@ -1 +1 @@
        -let oldName = true
        +let newName = true
        """)
        let loader = ReviewRequestDiffLoader(provider: provider)

        let session = try await loader.load(
            remote: Self.remote(),
            request: Self.reviewRequest(),
            cwd: URL(fileURLWithPath: "/tmp/repo")
        )

        let file = try #require(session.files.first)
        #expect(file.summary.path == "new\tfile.swift")
        #expect(file.summary.originalPath == "old\tfile.swift")
        #expect(file.summary.status == .renamed)
    }

    @Test func gitLabNewFileUsesMergeRequestNamespaceAndAddedStatus() async throws {
        let provider = FakeDiffProvider(
            diff: """
            diff --git a/Sources/NewFile.swift b/Sources/NewFile.swift
            new file mode 100644
            index 0000000..1111111
            --- /dev/null
            +++ b/Sources/NewFile.swift
            @@ -0,0 +1 @@
            +let value = true
            """,
            kind: .gitlab
        )
        let loader = ReviewRequestDiffLoader(provider: provider)

        let session = try await loader.load(
            remote: Self.remote(kind: .gitlab),
            request: Self.reviewRequest(kind: .gitlab),
            cwd: URL(fileURLWithPath: "/tmp/repo")
        )

        let file = try #require(session.files.first)
        #expect(file.summary.namespace == "gitlab-mr")
        #expect(file.summary.status == .added)
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

    private static func remote(kind: CodeHostKind = .github) -> CodeHostRemote {
        CodeHostRemote(
            kind: kind,
            host: "github.com",
            owner: "mrmans0n",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://github.com/mrmans0n/alas")!
        )
    }

    private static func reviewRequest(kind: CodeHostKind = .github) -> ReviewRequest {
        ReviewRequest(
            remote: remote(kind: kind),
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
    var kind: CodeHostKind = .github
    func isAvailable() async -> Bool { true }
    func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool { true }
    func currentReviewRequest(remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String, cwd: URL) async throws -> ReviewRequest? { nil }
    func createReviewRequest(remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String, title: String, body: String, isDraft: Bool, cwd: URL) async throws -> URL { URL(fileURLWithPath: "/tmp/pr") }
    func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] { [] }
    func reviewDiff(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> String { diff }
    func rerunFailedChecks(remote: CodeHostRemote, branch: String, headSHA: String, request: ReviewRequest?, cwd: URL) async throws {}
}
