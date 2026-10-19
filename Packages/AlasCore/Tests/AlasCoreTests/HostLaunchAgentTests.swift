import Foundation
import Testing
@testable import AlasCore

struct HostLaunchAgentTests {
    private let executable = URL(fileURLWithPath: "/Applications/Alas.app/Contents/Resources/alas-host/alas-host")
    private let home = URL(fileURLWithPath: "/Users/someone")

    /// The everyday profile's agent waits for the app, runs only while its
    /// executable exists, and sets no profile.
    @Test func theEverydayProfilesAgentRunsTheHostWaitingForTheApp() throws {
        let agent = HostLaunchAgent(executable: executable, profile: AlasProfile(appSupportOverride: nil, runtimeDirectory: nil), home: home)
        #expect(agent.label == "io.nlopez.alas.host")
        #expect(agent.plistURL.path == "/Users/someone/Library/LaunchAgents/io.nlopez.alas.host.plist")
        let plist = try #require(PropertyListSerialization.propertyList(from: agent.plistData(), format: nil) as? [String: Any])
        #expect(plist["ProgramArguments"] as? [String] == [executable.path, "--wait-for-lock"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect((plist["KeepAlive"] as? [String: [String: Bool]]) == ["PathState": [executable.path: true]])
        #expect(plist["EnvironmentVariables"] == nil)
    }

    /// An isolated profile gets its own agent, which serves that profile.
    @Test func anIsolatedProfilesAgentIsItsOwnAndServesIt() throws {
        let root = URL(fileURLWithPath: "/tmp/alas-e2e", isDirectory: true)
        let profile = AlasProfile(appSupportOverride: root, runtimeDirectory: AlasProfile.runtimeDirectory(for: root, uid: 501))
        let agent = HostLaunchAgent(executable: executable, profile: profile, home: home)
        let hash = try #require(profile.runtimeDirectory?.lastPathComponent.components(separatedBy: "-").last)
        #expect(agent.label == "io.nlopez.alas.host.\(hash)")
        let plist = try #require(PropertyListSerialization.propertyList(from: agent.plistData(), format: nil) as? [String: Any])
        #expect(plist["EnvironmentVariables"] as? [String: String] == [AlasProfile.environmentKey: root.path])
        #expect(plist["StandardErrorPath"] as? String == root.appendingPathComponent("alas-host.log").path)
    }
}
