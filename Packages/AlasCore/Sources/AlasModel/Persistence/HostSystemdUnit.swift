import Foundation
import AlasFoundation

/// The systemd user unit that keeps `alas-host` serving a profile on Linux,
/// as `HostLaunchAgent` does on macOS: restarted whenever it ends while its
/// executable exists. It runs while the user is logged in, or always once
/// lingering is enabled for them (`loginctl enable-linger`).
public struct HostSystemdUnit: Equatable, Sendable {
    /// `alas-host.service`; an isolated profile's is suffixed like its launch agent's label.
    public let name: String
    /// `$XDG_CONFIG_HOME/systemd/user/<name>`, `~/.config` by default.
    public let unitURL: URL
    let executable: URL
    let profile: AlasProfile

    public init(
        executable: URL,
        profile: AlasProfile = .current,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        configHome: String? = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
    ) {
        let suffix = HostLaunchAgent(executable: executable, profile: profile, home: home).label
            .dropFirst("io.nlopez.alas.host".count)
        name = "alas-host\(suffix.replacingOccurrences(of: ".", with: "-")).service"
        let config = configHome.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? home.appendingPathComponent(".config")
        unitURL = config.appendingPathComponent("systemd/user/\(name)")
        self.executable = executable
        self.profile = profile
    }

    /// Where the unit's host writes its output, as the launch agent's does.
    public var logURL: URL {
        (profile.appSupportOverride ?? Paths.standardAppSupportRoot).appendingPathComponent("alas-host.log")
    }

    public var unitText: String {
        var service = [
            "ExecStart=\(Self.quoted(executable.path)) --wait-for-lock",
            // Restarted whenever it ends, including after an upgrade replaces the executable.
            "Restart=always",
            "RestartSec=2",
            "StandardOutput=append:\(logURL.path)",
            "StandardError=append:\(logURL.path)",
        ]
        if let override = profile.appSupportOverride {
            service.append("Environment=\(Self.quoted("\(AlasProfile.environmentKey)=\(override.path)"))")
        }
        return """
        [Unit]
        Description=Alas host
        # A deleted executable stops it rather than leaving systemd retrying.
        ConditionPathExists=\(executable.path)

        [Service]
        \(service.joined(separator: "\n"))

        [Install]
        WantedBy=default.target

        """
    }

    /// systemd's quoting: double quotes, with backslashes and quotes escaped.
    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
