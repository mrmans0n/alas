import Foundation

/// The launchd agent that keeps `alas-host` serving a profile while the user
/// is logged in: started at login, waiting for the data directory while the
/// app holds it, and restarted after a crash but not after a stop.
public struct HostLaunchAgent: Equatable, Sendable {
    public let label: String
    /// `~/Library/LaunchAgents/<label>.plist`.
    public let plistURL: URL
    let executable: URL
    let profile: AlasProfile

    /// The agent for `profile`, running `executable`. The everyday profile's
    /// is `io.nlopez.alas.host`; an isolated one's is suffixed with its
    /// runtime directory's hash, so each profile has its own.
    public init(executable: URL, profile: AlasProfile = .current, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        // The runtime directory is `alas-<uid>-<hash>`.
        let suffix = profile.runtimeDirectory.map { "." + ($0.lastPathComponent.components(separatedBy: "-").last ?? "") } ?? ""
        label = "io.nlopez.alas.host" + suffix
        plistURL = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        self.executable = executable
        self.profile = profile
    }

    /// The agent's property list. Its output goes to `alas-host.log` in the
    /// profile's directory.
    public func propertyList() -> [String: Any] {
        let root = profile.appSupportOverride ?? Paths.standardAppSupportRoot
        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path, "--wait-for-lock"],
            "RunAtLoad": true,
            // A stop (SIGTERM, as `launchctl bootout` sends) exits 0 and stays
            // stopped; a crash or a failed start is retried.
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Background",
            "StandardOutPath": root.appendingPathComponent("alas-host.log").path,
            "StandardErrorPath": root.appendingPathComponent("alas-host.log").path,
        ]
        if let override = profile.appSupportOverride {
            plist["EnvironmentVariables"] = [AlasProfile.environmentKey: override.path]
        }
        return plist
    }

    public func plistData() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: propertyList(), format: .xml, options: 0)
    }
}
