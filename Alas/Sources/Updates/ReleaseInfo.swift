import Foundation

/// The current host's GitHub release asset arch slug.
enum HostArch {
    static var assetSlug: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}

/// Decoded subset of GitHub's `releases/latest` payload.
/// Decode with `keyDecodingStrategy = .convertFromSnakeCase`.
struct GitHubRelease: Decodable {
    let tagName: String
    let body: String?
    let htmlUrl: URL
    let prerelease: Bool
    let draft: Bool
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: URL
    }
}

/// Normalized release info the UI consumes.
struct ReleaseInfo: Equatable, Identifiable {
    let version: SemanticVersion
    let releaseNotes: String
    let htmlURL: URL
    let dmgURL: URL?

    var id: String { version.description }

    /// Maps a decoded release to `ReleaseInfo`, resolving the DMG asset for
    /// `arch`. Returns nil when the tag isn't a parseable version.
    static func make(from release: GitHubRelease, arch: String) -> ReleaseInfo? {
        guard let version = SemanticVersion(parsing: release.tagName) else { return nil }
        let dmgName = "Alas-\(version)-\(arch).dmg"
        let dmg = release.assets.first { $0.name == dmgName }?.browserDownloadUrl
        return ReleaseInfo(
            version: version,
            releaseNotes: release.body ?? "",
            htmlURL: release.htmlUrl,
            dmgURL: dmg
        )
    }
}
