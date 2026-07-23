import Foundation
import Testing
@testable import Alas

@MainActor
struct ReviewRequestDiffLoaderTests {
    @Test func providerUnifiedDiffBuildsReviewSessionInProviderOrder() async throws {
        let provider = FakeHostedImageProvider(diff: Self.sampleDiff)
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
        let image = try #require(session.files.first { $0.summary.path == "Assets/logo.png" })
        #expect(image.summary.isRenderable)
        #expect(image.placeholderMessage == nil)
        let imageProvider = try #require(image.imageProvider)
        #expect(await provider.fileRequests.isEmpty)

        let pair = await imageProvider.load()

        #expect(pair.kind == .modified)
        #expect(pair.beforeImage != nil)
        #expect(pair.afterImage != nil)
        #expect(await provider.revisionRequests.count == 1)
        #expect(await provider.fileRequests.map(\.revision) == ["base-sha", "head-sha"])
        #expect(session.summary.totalAdditions == 4)
        #expect(session.summary.totalDeletions == 3)
    }

    @Test func hostedAddedImageLoadsOnlyHeadSide() async throws {
        let provider = FakeHostedImageProvider(diff: Self.imageDiff(status: .added))
        let session = try await ReviewRequestDiffLoader(provider: provider).load(
            remote: Self.remote(), request: Self.reviewRequest(number: 517), cwd: URL(fileURLWithPath: "/tmp/repo")
        )

        let imageProvider = try #require(session.files.first?.imageProvider)
        let pair = await imageProvider.load()

        #expect(pair.kind == .added)
        #expect(pair.beforeImage == nil)
        #expect(pair.afterImage != nil)
        #expect(await provider.fileRequests.map(\.revision) == ["head-sha"])
    }

    @Test func hostedDeletedImageLoadsOnlyBaseSide() async throws {
        let provider = FakeHostedImageProvider(diff: Self.imageDiff(status: .deleted))
        let session = try await ReviewRequestDiffLoader(provider: provider).load(
            remote: Self.remote(), request: Self.reviewRequest(number: 518), cwd: URL(fileURLWithPath: "/tmp/repo")
        )

        let imageProvider = try #require(session.files.first?.imageProvider)
        let pair = await imageProvider.load()

        #expect(pair.kind == .deleted)
        #expect(pair.beforeImage != nil)
        #expect(pair.afterImage == nil)
        #expect(await provider.fileRequests.map(\.revision) == ["base-sha"])
    }

    @Test func hostedRenamedImageUsesOriginalPathForBaseSide() async throws {
        let provider = FakeHostedImageProvider(diff: Self.imageDiff(status: .renamed))
        let session = try await ReviewRequestDiffLoader(provider: provider).load(
            remote: Self.remote(), request: Self.reviewRequest(number: 519), cwd: URL(fileURLWithPath: "/tmp/repo")
        )

        let imageProvider = try #require(session.files.first?.imageProvider)
        let pair = await imageProvider.load()

        #expect(pair.kind == .renamed)
        #expect(pair.oldPath == "Assets/old-logo.png")
        #expect(await provider.fileRequests == [
            .init(revision: "base-sha", path: "Assets/old-logo.png"),
            .init(revision: "head-sha", path: "Assets/logo.png"),
        ])
    }

    @Test func hostedCopiedImageUsesCopiedKindAndOriginalPathForBaseSide() async throws {
        let provider = FakeHostedImageProvider(diff: Self.imageDiff(status: .copied))
        let session = try await ReviewRequestDiffLoader(provider: provider).load(
            remote: Self.remote(), request: Self.reviewRequest(number: 520), cwd: URL(fileURLWithPath: "/tmp/repo")
        )

        let imageProvider = try #require(session.files.first?.imageProvider)
        let pair = await imageProvider.load()

        #expect(pair.kind == .copied)
        #expect(pair.oldPath == "Assets/old-logo.png")
        #expect(await provider.fileRequests == [
            .init(revision: "base-sha", path: "Assets/old-logo.png"),
            .init(revision: "head-sha", path: "Assets/logo.png"),
        ])
    }

    @Test func hostedRevisionAuthenticationFailureStaysInsideImageProvider() async throws {
        let provider = FakeHostedImageProvider(
            diff: Self.imageDiff(status: .modified),
            revisionError: CodeHostProviderError.unauthenticated("github.com")
        )
        let session = try await ReviewRequestDiffLoader(provider: provider).load(
            remote: Self.remote(), request: Self.reviewRequest(number: 521), cwd: URL(fileURLWithPath: "/tmp/repo")
        )

        let imageProvider = try #require(session.files.first?.imageProvider)
        let pair = await imageProvider.load()

        guard case .failed(let beforeFailure) = pair.before else {
            Issue.record("Expected the unavailable base revision to fail.")
            return
        }
        guard case .failed(let afterFailure) = pair.after else {
            Issue.record("Expected the unavailable head revision to fail.")
            return
        }
        #expect(beforeFailure.message == "Authentication required.")
        #expect(afterFailure.message == "Authentication required.")
        #expect(await provider.fileRequests.isEmpty)
    }

    @Test func hostedForkImageDoesNotRequireALocalHeadRemote() async throws {
        let provider = FakeHostedImageProvider(diff: Self.imageDiff(status: .modified))
        let request = Self.reviewRequest(
            number: 522,
            headRepositoryOwner: "fork-owner",
            headRepositoryName: "alas-fork"
        )
        let session = try await ReviewRequestDiffLoader(provider: provider).load(
            remote: Self.remote(), request: request, cwd: URL(fileURLWithPath: "/tmp/no-local-head-remote")
        )

        let imageProvider = try #require(session.files.first?.imageProvider)
        let pair = await imageProvider.load()

        #expect(pair.beforeImage != nil)
        #expect(pair.afterImage != nil)
        #expect(await provider.fileRequests.map(\.revision) == ["base-sha", "head-sha"])
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

    @Test func unquotedPathHeadersDropTabMetadata() async throws {
        let provider = FakeDiffProvider(diff: """
        diff --git a/Foo Bar.swift b/Foo Bar.swift
        index 111..222 100644
        --- a/Foo Bar.swift\t2026-06-13 12:00:00
        +++ b/Foo Bar.swift\t2026-06-13 12:00:01
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
        #expect(file.summary.path == "Foo Bar.swift")
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

    @Test func quotedPathHeadersDecodeUtf8OctalEscapes() async throws {
        let provider = FakeDiffProvider(diff: """
        diff --git "a/\\303\\251.swift" "b/\\303\\251.swift"
        index 111..222 100644
        --- "a/\\303\\251.swift"
        +++ "b/\\303\\251.swift"
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
        #expect(file.summary.path == "é.swift")
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

    private enum ImageStatus {
        case added, deleted, renamed, copied, modified
    }

    private static func imageDiff(status: ImageStatus) -> String {
        switch status {
        case .added:
            """
            diff --git a/Assets/logo.png b/Assets/logo.png
            new file mode 100644
            index 0000000..1111111
            --- /dev/null
            +++ b/Assets/logo.png
            """
        case .deleted:
            """
            diff --git a/Assets/logo.png b/Assets/logo.png
            deleted file mode 100644
            index 1111111..0000000
            --- a/Assets/logo.png
            +++ /dev/null
            """
        case .renamed:
            """
            diff --git a/Assets/old-logo.png b/Assets/logo.png
            similarity index 100%
            rename from Assets/old-logo.png
            rename to Assets/logo.png
            """
        case .copied:
            """
            diff --git a/Assets/old-logo.png b/Assets/logo.png
            similarity index 100%
            copy from Assets/old-logo.png
            copy to Assets/logo.png
            """
        case .modified:
            """
            diff --git a/Assets/logo.png b/Assets/logo.png
            index 1111111..2222222 100644
            --- a/Assets/logo.png
            +++ b/Assets/logo.png
            """
        }
    }

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

    private static func reviewRequest(
        kind: CodeHostKind = .github,
        number: Int = 516,
        headRepositoryOwner: String? = nil,
        headRepositoryName: String? = nil
    ) -> ReviewRequest {
        ReviewRequest(
            remote: remote(kind: kind),
            number: number,
            title: "Files first",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/516")!,
            state: .open,
            isDraft: false,
            headRefName: "feature/files",
            baseRefName: "main",
            reviewDecision: .unknown,
            mergeState: .unknown,
            checks: [],
            threads: [],
            headRepositoryOwner: headRepositoryOwner,
            headRepositoryName: headRepositoryName
        )
    }
}

private struct FakeDiffProvider: CodeHostProvider {
    let diff: String
    var kind: CodeHostKind = .github
    func isAvailable(cwd: URL) async -> Bool { true }
    func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool { true }
    func currentReviewRequest(remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String, cwd: URL) async throws -> ReviewRequest? { nil }
    func createReviewRequest(remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String, title: String, body: String, isDraft: Bool, cwd: URL) async throws -> URL { URL(fileURLWithPath: "/tmp/pr") }
    func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] { [] }
    func reviewDiff(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> String { diff }
    func rerunFailedChecks(remote: CodeHostRemote, branch: String, headSHA: String, request: ReviewRequest?, cwd: URL) async throws {}
}

private actor FakeHostedImageProvider: CodeHostProvider {
    struct FileRequest: Equatable, Sendable {
        let revision: String
        let path: String
    }

    nonisolated let kind: CodeHostKind = .github
    let diff: String
    let revisionError: CodeHostProviderError?
    private(set) var revisionRequests: [CodeHostRemote] = []
    private(set) var fileRequests: [FileRequest] = []

    init(diff: String, revisionError: CodeHostProviderError? = nil) {
        self.diff = diff
        self.revisionError = revisionError
    }

    func isAvailable(cwd: URL) async -> Bool { true }
    func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool { true }
    func currentReviewRequest(remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String, cwd: URL) async throws -> ReviewRequest? { nil }
    func createReviewRequest(remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String, title: String, body: String, isDraft: Bool, cwd: URL) async throws -> URL { URL(fileURLWithPath: "/tmp/pr") }
    func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] { [] }
    func reviewDiff(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> String { diff }

    func reviewImageRevisions(
        remote: CodeHostRemote,
        request: ReviewRequest,
        cwd: URL
    ) async throws -> CodeHostReviewImageRevisions {
        revisionRequests.append(remote)
        if let revisionError { throw revisionError }
        return CodeHostReviewImageRevisions(beforeSHA: "base-sha", afterSHA: "head-sha")
    }

    func reviewFileData(
        remote: CodeHostRemote,
        revision: String,
        path: String,
        cwd: URL
    ) async throws -> Data {
        fileRequests.append(FileRequest(revision: revision, path: path))
        return Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }

    func rerunFailedChecks(remote: CodeHostRemote, branch: String, headSHA: String, request: ReviewRequest?, cwd: URL) async throws {}
}
