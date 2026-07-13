import Foundation
import Testing
@testable import Alas

struct SSHConfigParserTests {
    /// Writes `config` to `<tmp>/.ssh/config` and returns the tmp home dir.
    private func makeHome(config: String, extraFiles: [String: String] = [:]) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-config-tests-\(UUID().uuidString)")
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try config.write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        for (rel, contents) in extraFiles {
            let url = home.appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return home
    }

    @Test func parsesAliasWithMetadata() throws {
        let home = try makeHome(config: """
        Host devbox
            HostName 10.0.0.7
            User me
            Port 2222
        """)
        let hosts = SSHConfigParser.parse(home: home)
        #expect(hosts == [SSHConfigHost(alias: "devbox", hostName: "10.0.0.7", user: "me", port: 2222)])
    }

    @Test func multiAliasLineSharesMetadata() throws {
        let home = try makeHome(config: """
        Host a b c
            HostName shared.example.com
        """)
        let hosts = SSHConfigParser.parse(home: home)
        #expect(hosts.map(\.alias) == ["a", "b", "c"])
        #expect(hosts.allSatisfy { $0.hostName == "shared.example.com" })
    }

    @Test func skipsWildcardAndNegatedAliases() throws {
        let home = try makeHome(config: """
        Host *
            User default
        Host prod !staging foo?
            HostName prod.example.com
        Host realbox
            HostName real.example.com
        """)
        let hosts = SSHConfigParser.parse(home: home)
        #expect(hosts.map(\.alias) == ["prod", "realbox"])
    }

    @Test func missingConfigYieldsEmpty() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-ssh-\(UUID().uuidString)")
        #expect(SSHConfigParser.parse(home: home).isEmpty)
    }

    @Test func duplicateAliasFirstWins() throws {
        let home = try makeHome(config: """
        Host devbox
            HostName first.example.com
        Host devbox
            HostName second.example.com
        """)
        let hosts = SSHConfigParser.parse(home: home)
        #expect(hosts == [SSHConfigHost(alias: "devbox", hostName: "first.example.com", user: nil, port: nil)])
    }

    @Test func supportsEqualsSeparatorAndComments() throws {
        let home = try makeHome(config: """
        # a comment
        Host=devbox
            HostName=10.0.0.9
        """)
        let hosts = SSHConfigParser.parse(home: home)
        #expect(hosts == [SSHConfigHost(alias: "devbox", hostName: "10.0.0.9", user: nil, port: nil)])
    }
}
