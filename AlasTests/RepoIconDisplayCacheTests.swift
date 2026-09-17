import Foundation
import Testing
@testable import Alas

@Suite("Repo icon display cache")
struct RepoIconDisplayCacheTests {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func stagedIcon(_ imagePath: String = "project-1/abc.png") -> ProjectIcon {
        ProjectIcon(mode: .image, color: "#112233", imagePath: imagePath)
    }

    private func resolution(
        imagePath: String = "project-1/abc.png",
        source: String? = "/repo/.alas/icon.png",
        modificationDate: Date? = nil,
        fileSize: Int? = nil
    ) -> RepoIconResolver.RepoIconResolution {
        RepoIconResolver.RepoIconResolution(
            icon: stagedIcon(imagePath),
            sourceURL: source.map { URL(fileURLWithPath: $0) },
            sourceModificationDate: modificationDate ?? stamp,
            sourceFileSize: fileSize ?? 2048
        )
    }

    @Test func returnsStoredIconWhileTheSourceIsUnchanged() {
        let cache = RepoIconDisplayCache()
        let resolved = resolution()
        cache.store(resolved, projectID: "project-1")
        #expect(cache.icon(for: resolved, projectID: "project-1") == resolved.icon)
    }

    @Test func missesWhenNothingWasStored() {
        let cache = RepoIconDisplayCache()
        #expect(cache.icon(for: resolution(), projectID: "project-1") == nil)
    }

    @Test func missesWhenSourceIsReplacedAtTheSamePath() {
        let cache = RepoIconDisplayCache()
        cache.store(resolution(), projectID: "project-1")
        let replaced = resolution(modificationDate: stamp.addingTimeInterval(60))
        #expect(cache.icon(for: replaced, projectID: "project-1") == nil)
    }

    @Test func missesWhenSourceSizeChangesWithoutAnMtimeChange() {
        let cache = RepoIconDisplayCache()
        cache.store(resolution(), projectID: "project-1")
        #expect(cache.icon(for: resolution(fileSize: 4096), projectID: "project-1") == nil)
    }

    @Test func missesWhenTheWinningFileChanges() {
        let cache = RepoIconDisplayCache()
        cache.store(resolution(), projectID: "project-1")
        let discovered = resolution(source: "/repo/.alas/icon.jpg")
        #expect(cache.icon(for: discovered, projectID: "project-1") == nil)
    }

    @Test func missesForADifferentProject() {
        let cache = RepoIconDisplayCache()
        let resolved = resolution()
        cache.store(resolved, projectID: "project-1")
        #expect(cache.icon(for: resolved, projectID: "project-2") == nil)
    }

    @Test func neverCachesAnIconThatCameFromNoRepoFile() {
        let cache = RepoIconDisplayCache()
        let appIcon = RepoIconResolver.RepoIconResolution(
            icon: .default(color: "#5fb7c4"),
            sourceURL: nil,
            sourceModificationDate: nil,
            sourceFileSize: nil
        )
        cache.store(appIcon, projectID: "project-1")
        #expect(cache.icon(for: appIcon, projectID: "project-1") == nil)
    }

    @Test func keepsOneEntryPerProject() {
        let cache = RepoIconDisplayCache()
        let superseded = resolution(imagePath: "project-1/first.png")
        cache.store(superseded, projectID: "project-1")
        let current = resolution(
            imagePath: "project-1/second.png",
            modificationDate: stamp.addingTimeInterval(60)
        )
        cache.store(current, projectID: "project-1")
        // The superseded revision is gone rather than accumulating per render.
        #expect(cache.icon(for: current, projectID: "project-1") == current.icon)
        #expect(cache.icon(for: superseded, projectID: "project-1") == nil)
    }
}
