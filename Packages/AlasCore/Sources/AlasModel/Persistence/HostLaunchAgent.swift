import Foundation
import AlasFoundation

/// The launchd agent that keeps `alas-host` serving a profile while the user
/// is logged in: started at login, waiting for the data directory while the
/// app holds it, and restarted whenever it ends while its executable exists.
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

    /// Where the agent's host writes its output: `alas-host.log` in the
    /// profile's directory.
    public var logURL: URL {
        (profile.appSupportOverride ?? Paths.standardAppSupportRoot).appendingPathComponent("alas-host.log")
    }

    /// The agent's property list.
    public func propertyList() -> [String: Any] {
        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path, "--wait-for-lock"],
            "RunAtLoad": true,
            // Kept running, restarted whenever it ends, while its executable
            // exists: an app upgrade keeps the path and the agent, and an app
            // that was deleted stops it rather than leaving launchd retrying.
            // `uninstall-agent` (`launchctl bootout`) is how it is stopped.
            "KeepAlive": ["PathState": [executable.path: true]],
            "ProcessType": "Background",
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
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
