import Foundation
import Testing
@testable import Alas

@Suite("Provider review original path resolver")
struct ProviderReviewOriginalPathResolverTests {
    private func summary(path: String, originalPath: String?, status: DiffReviewFileStatus) -> DiffReviewFileSummary {
        DiffReviewFileSummary(
            path: path,
            namespace: "github-pr",
            groupID: nil,
            groupTitle: nil,
            status: status,
            additions: 1,
            deletions: 0,
            isRenderable: true,
            originalPath: originalPath
        )
    }

    @Test func returnsOriginalPathForARenamedFile() {
        let files = [
            summary(path: "Sources/New.swift", originalPath: "Sources/Old.swift", status: .renamed),
            summary(path: "Sources/Other.swift", originalPath: nil, status: .modified),
        ]
        #expect(
            ProviderReviewOriginalPathResolver.originalPath(forRelativePath: "Sources/New.swift", in: files)
                == "Sources/Old.swift"
        )
    }

    @Test func returnsOriginalPathForACopiedFile() {
        let files = [summary(path: "Sources/Copy.swift", originalPath: "Sources/Source.swift", status: .copied)]
        #expect(
            ProviderReviewOriginalPathResolver.originalPath(forRelativePath: "Sources/Copy.swift", in: files)
                == "Sources/Source.swift"
        )
    }

    @Test func returnsNilForANonRenamedFile() {
        let files = [summary(path: "Sources/App.swift", originalPath: nil, status: .modified)]
        #expect(ProviderReviewOriginalPathResolver.originalPath(forRelativePath: "Sources/App.swift", in: files) == nil)
    }

    @Test func returnsNilWhenPathIsNotInTheReview() {
        let files = [summary(path: "Sources/New.swift", originalPath: "Sources/Old.swift", status: .renamed)]
        #expect(ProviderReviewOriginalPathResolver.originalPath(forRelativePath: "Sources/Missing.swift", in: files) == nil)
    }

    @Test func returnsNilForAnEmptyFileList() {
        #expect(ProviderReviewOriginalPathResolver.originalPath(forRelativePath: "Sources/New.swift", in: []) == nil)
    }
}
