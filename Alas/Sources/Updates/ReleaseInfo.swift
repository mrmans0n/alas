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

/// Decoded subset of GitHub's release payload (`releases/latest` and
/// `releases/tags/{tag}` share the same shape).
/// Decode with `keyDecodingStrategy = .convertFromSnakeCase` and
/// `dateDecodingStrategy = .iso8601`.
struct GitHubRelease: Decodable {
    let tagName: String
    let body: String?
    let htmlUrl: URL
    let prerelease: Bool
    let draft: Bool
    let targetCommitish: String
    let publishedAt: Date
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: URL
    }
}

/// Normalized release info the UI consumes. Two variants:
/// - `.stable` for SemVer-tagged releases from `/releases/latest`.
/// - `.nightly` for the rolling pre-release from `/releases/tags/nightly`.
enum ReleaseInfo: Equatable, Identifiable {
    case stable(StableReleaseInfo)
    case nightly(NightlyReleaseInfo)

    var id: String {
        switch self {
        case .stable(let s): return "stable-\(s.version.description)"
        case .nightly(let n): return "nightly-\(n.shortSHA)"
        }
    }

    /// Shared fields the sheet always renders.
    var releaseNotes: String {
        switch self {
        case .stable(let s): return s.releaseNotes
        case .nightly(let n): return n.releaseNotes
        }
    }

    var htmlURL: URL {
        switch self {
        case .stable(let s): return s.htmlURL
        case .nightly(let n): return n.htmlURL
        }
    }

    var dmgURL: URL? {
        switch self {
        case .stable(let s): return s.dmgURL
        case .nightly(let n): return n.dmgURL
        }
    }

    static func makeStable(from release: GitHubRelease, arch: String) -> ReleaseInfo? {
        guard let version = SemanticVersion(parsing: release.tagName) else { return nil }
        let dmgName = "Alas-\(version)-\(arch).dmg"
        let dmg = release.assets.first { $0.name == dmgName }?.browserDownloadUrl
        return .stable(StableReleaseInfo(
            version: version,
            releaseNotes: release.body ?? "",
            htmlURL: release.htmlUrl,
            dmgURL: dmg
        ))
    }

    /// Maps the rolling `nightly` release. `arch` is intentionally ignored —
    /// nightlies publish a single `Alas-nightly.dmg` today. Returns nil if
    /// `target_commitish` is empty (no SHA to compare against).
    static func makeNightly(from release: GitHubRelease) -> ReleaseInfo? {
        let sha = release.targetCommitish
        guard !sha.isEmpty else { return nil }
        let shortSHA = String(sha.prefix(7))
        let dmg = release.assets.first { $0.name == "Alas-nightly.dmg" }?.browserDownloadUrl
        return .nightly(NightlyReleaseInfo(
            shortSHA: shortSHA,
            fullSHA: sha,
            publishedAt: release.publishedAt,
            releaseNotes: release.body ?? "",
            htmlURL: release.htmlUrl,
            dmgURL: dmg
        ))
    }
}

struct StableReleaseInfo: Equatable {
    let version: SemanticVersion
    let releaseNotes: String
    let htmlURL: URL
    let dmgURL: URL?
}

struct NightlyReleaseInfo: Equatable {
    let shortSHA: String
    let fullSHA: String
    let publishedAt: Date
    let releaseNotes: String
    let htmlURL: URL
    let dmgURL: URL?
}
