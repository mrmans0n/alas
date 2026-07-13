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

    @Test func followsIncludeGlobInOrder() throws {
        let home = try makeHome(
            config: """
            Include config.d/*.conf
            Host local-tail
                HostName tail.example.com
            """,
            extraFiles: [
                ".ssh/config.d/10-a.conf": "Host from-a\n    HostName a.example.com\n",
                ".ssh/config.d/20-b.conf": "Host from-b\n    HostName b.example.com\n",
                ".ssh/config.d/skip.txt": "Host should-not-load\n",
            ]
        )
        let hosts = SSHConfigParser.parse(home: home)
        #expect(hosts.map(\.alias) == ["from-a", "from-b", "local-tail"])
    }

    @Test func expandsTildeInclude() throws {
        let home = try makeHome(
            config: "Include ~/.ssh/extra\n",
            extraFiles: [".ssh/extra": "Host tilde-host\n    HostName t.example.com\n"]
        )
        #expect(SSHConfigParser.parse(home: home).map(\.alias) == ["tilde-host"])
    }

    @Test func includeCycleTerminates() throws {
        let home = try makeHome(config: "Include config.d/loop\nHost base\n",
            extraFiles: [".ssh/config.d/loop": "Include ../config\nHost loop-host\n"]
        )
        let hosts = SSHConfigParser.parse(home: home)
        // Terminates (no infinite recursion) and captures each alias once.
        #expect(Set(hosts.map(\.alias)) == ["base", "loop-host"])
    }

    @Test func handlesCRLFLineEndings() throws {
        let home = try makeHome(config: "Host crlfbox\r\n    HostName 10.0.0.9\r\n    User me\r\n")
        #expect(SSHConfigParser.parse(home: home) == [SSHConfigHost(alias: "crlfbox", hostName: "10.0.0.9", user: "me", port: nil)])
    }

    @Test func stripsInlineComments() throws {
        let home = try makeHome(config: """
        Host devbox # staging box
            HostName 10.0.0.7 # main interface
        """)
        // The inline comments must not become extra aliases or corrupt HostName.
        #expect(SSHConfigParser.parse(home: home)
            == [SSHConfigHost(alias: "devbox", hostName: "10.0.0.7", user: nil, port: nil)])
    }

    @Test func expandsGlobInEveryIncludeComponent() throws {
        let home = try makeHome(
            config: "Include config.d/*/*.conf\n",
            extraFiles: [
                ".ssh/config.d/providerA/prod.conf": "Host a-prod\n    HostName a.example.com\n",
                ".ssh/config.d/providerB/prod.conf": "Host b-prod\n    HostName b.example.com\n",
                ".ssh/config.d/providerA/notes.txt": "Host should-not-load\n",
            ]
        )
        #expect(Set(SSHConfigParser.parse(home: home).map(\.alias)) == ["a-prod", "b-prod"])
    }

    @Test func skipsIncludeInsideConditionalHostBlock() throws {
        let home = try makeHome(
            config: """
            Host top
                HostName top.example.com
            Host bastion
                Include bastion.conf
            """,
            extraFiles: [".ssh/bastion.conf": "Host internal\n    HostName 10.1.1.1\n"]
        )
        // `internal` is conditionally included under `Host bastion`, so it is
        // not a usable top-level alias and must not appear in the picker.
        #expect(SSHConfigParser.parse(home: home).map(\.alias) == ["top", "bastion"])
    }

    @Test func followsIncludeUnderWildcardHost() throws {
        let home = try makeHome(
            config: "Host *\n    Include common.conf\n",
            extraFiles: [".ssh/common.conf": "Host common\n    HostName c.example.com\n"]
        )
        // `Host *` is unconditional, so its Include applies to every host.
        #expect(SSHConfigParser.parse(home: home).map(\.alias) == ["common"])
    }
}
