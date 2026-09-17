import Foundation
import Testing
@testable import Alas

@Suite("Repo icon display cache")
struct RepoIconDisplayCacheTests {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func stagedIcon(_ imagePath: String = "project-1/abc.png") -> ProjectIcon {
        ProjectIcon(mode: .image, color: "#112233", imagePath: imagePath)
    }

    private func appIcon(color: String = "#112233") -> ProjectIcon {
        ProjectIcon.default(color: color)
    }

    private func identity(
        source: String = "/repo/.alas/icon.png",
        modificationDate: Date? = nil,
        fileSize: Int? = nil
    ) -> RepoIconResolver.SourceIdentity {
        RepoIconResolver.SourceIdentity(
            url: URL(fileURLWithPath: source),
            modificationDate: modificationDate ?? stamp,
            fileSize: fileSize ?? 2048
        )
    }

    private func chain(_ identities: RepoIconResolver.SourceIdentity...) -> [RepoIconResolver.SourceIdentity] {
        identities
    }

    private func key(
        _ chain: [RepoIconResolver.SourceIdentity]? = nil,
        appIcon: ProjectIcon? = nil
    ) -> RepoIconDisplayCache.Key {
        RepoIconDisplayCache.Key(
            chain: chain ?? [identity()],
            appIcon: appIcon ?? self.appIcon()
        )
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

    /// A resolution that fell back to the app icon: it names no repo file, so
    /// there is nothing to key a cache entry on.
    private func appIconResolution() -> RepoIconResolver.RepoIconResolution {
        RepoIconResolver.RepoIconResolution(
            icon: .default(color: "#5fb7c4"),
            sourceURL: nil,
            sourceModificationDate: nil,
            sourceFileSize: nil
        )
    }

    @Test func returnsStoredIconWhileTheSourceIsUnchanged() {
        let cache = RepoIconDisplayCache()
        cache.store(resolution(), chain: chain(identity()), appIcon: appIcon(), projectID: "project-1")
        #expect(cache.icon(for: key(), projectID: "project-1") == stagedIcon())
    }

    @Test func missesWhenNothingWasStored() {
        let cache = RepoIconDisplayCache()
        #expect(cache.icon(for: key(), projectID: "project-1") == nil)
    }

    @Test func missesWhenSourceIsReplacedAtTheSamePath() {
        let cache = RepoIconDisplayCache()
        cache.store(resolution(), chain: chain(identity()), appIcon: appIcon(), projectID: "project-1")
        #expect(cache.icon(for: key(chain(identity(modificationDate: stamp.addingTimeInterval(60)))), projectID: "project-1") == nil)
    }

    @Test func missesWhenSourceSizeChangesWithoutAnMtimeChange() {
        let cache = RepoIconDisplayCache()
        cache.store(resolution(), chain: chain(identity()), appIcon: appIcon(), projectID: "project-1")
        #expect(cache.icon(for: key(chain(identity(fileSize: 4096))), projectID: "project-1") == nil)
    }

    @Test func missesWhenTheWinningFileChanges() {
        let cache = RepoIconDisplayCache()
        cache.store(resolution(), chain: chain(identity()), appIcon: appIcon(), projectID: "project-1")
        #expect(cache.icon(for: key(chain(identity(source: "/repo/.alas/icon.jpg"))), projectID: "project-1") == nil)
    }

    @Test func missesWhenAFallbackCandidateChanges() {
        // The stored outcome came from the head candidate, but the chain also
        // names a fallback. Editing the fallback must invalidate the entry:
        // a head file that cannot be used makes resolve take the fallback, and
        // keying that outcome on the fallback alone (or on nothing) would keep
        // serving a stale image while the fallback file changes.
        let cache = RepoIconDisplayCache()
        let stored = chain(identity(source: "/repo/.alas/logo.png"), identity(source: "/repo/.alas/icon.png"))
        cache.store(resolution(), chain: stored, appIcon: appIcon(), projectID: "project-1")

        let fallbackEdited = chain(
            identity(source: "/repo/.alas/logo.png"),
            identity(source: "/repo/.alas/icon.png", modificationDate: stamp.addingTimeInterval(60))
        )
        #expect(cache.icon(for: key(fallbackEdited), projectID: "project-1") == nil)
        #expect(cache.icon(for: key(stored), projectID: "project-1") == stagedIcon())
    }

    @Test func missesWhenTheChainGainsOrLosesACandidate() {
        // An .alas/icon.png added after the fact changes the chain even though
        // the winner's stamp is untouched, so the cached outcome must not keep
        // hiding the new file.
        let cache = RepoIconDisplayCache()
        let withoutFallback = chain(identity(source: "/repo/.alas/logo.png"))
        cache.store(resolution(), chain: withoutFallback, appIcon: appIcon(), projectID: "project-1")

        #expect(cache.icon(for: key(chain(identity(source: "/repo/.alas/logo.png"), identity(source: "/repo/.alas/icon.png"))), projectID: "project-1") == nil)
    }

    @Test func missesForADifferentProject() {
        let cache = RepoIconDisplayCache()
        cache.store(resolution(), chain: chain(identity()), appIcon: appIcon(), projectID: "project-1")
        #expect(cache.icon(for: key(), projectID: "project-2") == nil)
    }

    @Test func missesWhenTheAppIconPreferencesChange() {
        // The staged file did not move, but the colour carried onto the
        // rendered icon did, so the cached icon is no longer the right answer.
        let cache = RepoIconDisplayCache()
        cache.store(resolution(), chain: chain(identity()), appIcon: appIcon(color: "#112233"), projectID: "project-1")
        #expect(cache.icon(for: key(appIcon: appIcon(color: "#ff0000")), projectID: "project-1") == nil)
        #expect(cache.icon(for: key(appIcon: appIcon(color: "#112233")), projectID: "project-1") != nil)
    }

    @Test func neverCachesAnIconThatCameFromNoRepoFile() {
        let cache = RepoIconDisplayCache()
        cache.store(appIconResolution(), chain: [], appIcon: appIcon(), projectID: "project-1")

        #expect(cache.storedEntryCount == 0)
        #expect(cache.icon(for: key(), projectID: "project-1") == nil)
    }

    @Test func replacesTheEntryForTheSameKeyInsteadOfAccumulating() {
        let cache = RepoIconDisplayCache()
        cache.store(stagedIcon("project-1/first.png"), for: key(), projectID: "project-1")
        cache.store(stagedIcon("project-1/second.png"), for: key(), projectID: "project-1")

        #expect(cache.storedEntryCount == 1)
        #expect(cache.icon(for: key(), projectID: "project-1") == stagedIcon("project-1/second.png"))
    }

    @Test func keepsOneEntryPerProject() {
        let cache = RepoIconDisplayCache()
        let superseded = resolution(imagePath: "project-1/first.png")
        cache.store(superseded, chain: chain(identity()), appIcon: appIcon(), projectID: "project-1")
        let current = resolution(
            imagePath: "project-1/second.png",
            modificationDate: stamp.addingTimeInterval(60)
        )
        cache.store(current, chain: chain(identity(modificationDate: stamp.addingTimeInterval(60))), appIcon: appIcon(), projectID: "project-1")

        // The superseded revision is gone rather than accumulating per render.
        #expect(cache.storedEntryCount == 1)
        #expect(cache.icon(for: key(chain(identity(modificationDate: stamp.addingTimeInterval(60)))), projectID: "project-1") == current.icon)
        #expect(cache.icon(for: key(), projectID: "project-1") == nil)
    }
}
