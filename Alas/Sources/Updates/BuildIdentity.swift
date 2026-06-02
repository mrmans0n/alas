import Foundation

/// Which GitHub release stream this build of Alas was published to.
enum ReleaseTrack: String, Equatable {
    case stable
    case nightly
}

/// Build-time identity for the running app. Sourced from Info.plist keys:
/// - `AlasReleaseTrack`: "stable" (default) or "nightly".
/// - `AlasGitSHA`: 40-char hex commit SHA; empty string treated as nil.
/// - `AlasBuildDate`: ISO-8601 UTC timestamp; empty/malformed treated as nil.
/// - `CFBundleShortVersionString`: parsed via `SemanticVersion`.
struct BuildIdentity: Equatable {
    let track: ReleaseTrack
    let version: SemanticVersion
    let gitSHA: String?
    let buildDate: Date?

    init(
        track: ReleaseTrack,
        version: SemanticVersion,
        gitSHA: String? = nil,
        buildDate: Date? = nil
    ) {
        self.track = track
        self.version = version
        self.gitSHA = gitSHA
        self.buildDate = buildDate
    }

    /// Reads identity from a raw Info.plist dictionary. Unknown / missing
    /// values fall back to safe defaults rather than throwing — a misconfigured
    /// build should still behave like a stable build, not crash on launch.
    init(infoDictionary: [String: Any]?) {
        let dict = infoDictionary ?? [:]

        let rawTrack = dict["AlasReleaseTrack"] as? String ?? ""
        self.track = ReleaseTrack(rawValue: rawTrack) ?? .stable

        let rawVersion = dict["CFBundleShortVersionString"] as? String ?? "0.0.0"
        self.version = SemanticVersion(parsing: rawVersion) ?? SemanticVersion(major: 0, minor: 0, patch: 0)

        let rawSHA = (dict["AlasGitSHA"] as? String) ?? ""
        self.gitSHA = rawSHA.isEmpty ? nil : rawSHA

        let rawDate = (dict["AlasBuildDate"] as? String) ?? ""
        if rawDate.isEmpty {
            self.buildDate = nil
        } else {
            let formatter = ISO8601DateFormatter()
            self.buildDate = formatter.date(from: rawDate)
        }
    }

    /// Convenience initializer that reads from `Bundle.main.infoDictionary`.
    static func current() -> BuildIdentity {
        BuildIdentity(infoDictionary: Bundle.main.infoDictionary)
    }
}
