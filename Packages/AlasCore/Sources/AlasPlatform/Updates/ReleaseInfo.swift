import Foundation
import AlasFoundation
import AlasModel

/// The current host's GitHub release asset arch slug.
public enum HostArch: Sendable {
    public static var assetSlug: String {
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
public struct GitHubRelease: Decodable, Sendable {
    public let tagName: String
    public let body: String?
    public let htmlUrl: URL
    public let prerelease: Bool
    public let draft: Bool
    public let targetCommitish: String
    public let publishedAt: Date
    public let assets: [Asset]

    public struct Asset: Decodable, Sendable {
        public let name: String
        public let browserDownloadUrl: URL

        public init(name: String, browserDownloadUrl: URL) {
            self.name = name
            self.browserDownloadUrl = browserDownloadUrl
        }
    }

    public init(tagName: String, body: String?, htmlUrl: URL, prerelease: Bool, draft: Bool, targetCommitish: String, publishedAt: Date, assets: [Asset]) {
        self.tagName = tagName
        self.body = body
        self.htmlUrl = htmlUrl
        self.prerelease = prerelease
        self.draft = draft
        self.targetCommitish = targetCommitish
        self.publishedAt = publishedAt
        self.assets = assets
    }
}

/// Decoded subset of GitHub's `git/ref/tags/{tag}` payload. Used to resolve
/// the true commit SHA a tag points to — `GitHubRelease.target_commitish` is
/// unreliable for rolling tags (GitHub keeps it at the original branch name
/// when the tag already exists).
public struct GitRef: Decodable, Sendable {
    public let object: Object

    public struct Object: Decodable, Sendable {
        public let sha: String
        public let type: String

        public init(sha: String, type: String) {
            self.sha = sha
            self.type = type
        }
    }

    public init(object: Object) {
        self.object = object
    }
}

/// Normalized release info the UI consumes. Two variants:
/// - `.stable` for SemVer-tagged releases from `/releases/latest`.
/// - `.nightly` for the rolling pre-release from `/releases/tags/nightly`.
public enum ReleaseInfo: Equatable, Identifiable, Sendable {
    case stable(StableReleaseInfo)
    case nightly(NightlyReleaseInfo)

    public var id: String {
        switch self {
        case .stable(let s): return "stable-\(s.version.description)"
        case .nightly(let n): return "nightly-\(n.shortSHA)"
        }
    }

    /// Shared fields the sheet always renders.
    public var releaseNotes: String {
        switch self {
        case .stable(let s): return s.releaseNotes
        case .nightly(let n): return n.releaseNotes
        }
    }

    public var htmlURL: URL {
        switch self {
        case .stable(let s): return s.htmlURL
        case .nightly(let n): return n.htmlURL
        }
    }

    public var dmgURL: URL? {
        switch self {
        case .stable(let s): return s.dmgURL
        case .nightly(let n): return n.dmgURL
        }
    }

    /// Whether a build with `identity` includes this release, such as the
    /// bundle Homebrew just wrote to disk.
    public func isContained(in identity: BuildIdentity) -> Bool {
        switch self {
        case .stable(let s): return identity.version >= s.version
        case .nightly(let n): return identity.gitSHA == n.fullSHA
        }
    }

    public static func makeStable(from release: GitHubRelease, arch: String) -> ReleaseInfo? {
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
    /// nightlies publish a single `Alas-nightly.dmg` today. `tagSHA` must be
    /// the commit SHA the `nightly` git tag actually points to (resolved via
    /// the git refs API), not `release.targetCommitish`. Returns nil if the
    /// SHA is empty.
    public static func makeNightly(from release: GitHubRelease, tagSHA: String) -> ReleaseInfo? {
        guard !tagSHA.isEmpty else { return nil }
        let shortSHA = String(tagSHA.prefix(7))
        let dmg = release.assets.first { $0.name == "Alas-nightly.dmg" }?.browserDownloadUrl
        return .nightly(NightlyReleaseInfo(
            shortSHA: shortSHA,
            fullSHA: tagSHA,
            releaseNotes: release.body ?? "",
            htmlURL: release.htmlUrl,
            dmgURL: dmg
        ))
    }
}

public struct StableReleaseInfo: Equatable, Sendable {
    public let version: SemanticVersion
    public let releaseNotes: String
    public let htmlURL: URL
    public let dmgURL: URL?

    public init(version: SemanticVersion, releaseNotes: String, htmlURL: URL, dmgURL: URL?) {
        self.version = version
        self.releaseNotes = releaseNotes
        self.htmlURL = htmlURL
        self.dmgURL = dmgURL
    }
}

public struct NightlyReleaseInfo: Equatable, Sendable {
    public let shortSHA: String
    public let fullSHA: String
    public let releaseNotes: String
    public let htmlURL: URL
    public let dmgURL: URL?

    public init(shortSHA: String, fullSHA: String, releaseNotes: String, htmlURL: URL, dmgURL: URL?) {
        self.shortSHA = shortSHA
        self.fullSHA = fullSHA
        self.releaseNotes = releaseNotes
        self.htmlURL = htmlURL
        self.dmgURL = dmgURL
    }
}

/// Selects released sections from the target tag's Keep a Changelog document.
public enum ReleaseNotesHistory: Sendable {
    private struct Section {
        let version: SemanticVersion
        let heading: String
        var lines: [String] = []

        var body: String { lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }

        public init(version: SemanticVersion, heading: String, lines: [String] = []) {
            self.version = version
            self.heading = heading
            self.lines = lines
        }
    }

    public static func appendingSkippedVersions(
        to latestNotes: String, changelog: String,
        installed: SemanticVersion, latest: SemanticVersion
    ) -> String {
        var sections: [Section] = []
        var current: Section?
        let normalized = changelog.replacingOccurrences(of: "\r\n", with: "\n")
        for line in normalized.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                if let current { sections.append(current) }
                current = nil
                guard line.hasPrefix("## ["), let closingBracket = line.firstIndex(of: "]") else { continue }
                let rawVersion = String(line[line.index(line.startIndex, offsetBy: 4)..<closingBracket])
                // SemanticVersion accepts suffixes and shortened versions;
                // changelog history includes only full stable version headings.
                guard let version = SemanticVersion(parsing: rawVersion),
                      rawVersion == version.description else { continue }
                current = Section(version: version, heading: line)
            } else {
                current?.lines.append(line)
            }
        }
        if let current { sections.append(current) }

        guard let latestSection = sections.first(where: { $0.version == latest }) else { return latestNotes }
        var history: [Section] = []
        for section in sections where section.version > installed && section.version < latest {
            guard !section.body.isEmpty,
                  !history.contains(where: { $0.version == section.version }) else { continue }
            history.append(section)
        }
        guard !history.isEmpty else { return latestNotes }
        history.sort { $0.version > $1.version }
        return (["\(latestSection.heading)\n\n\(latestNotes)"] + history.map {
            "\($0.heading)\n\n\($0.body)"
        }).joined(separator: "\n\n")
    }
}
