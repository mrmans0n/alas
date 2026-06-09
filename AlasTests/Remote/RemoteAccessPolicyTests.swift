import Testing
@testable import Alas

struct RemoteAccessPolicyTests {
    @Test func allowsLoopbackHosts() {
        let policy = RemoteAccessPolicy(allowedHosts: ["localhost", "127.0.0.1", "::1"])

        #expect(policy.allows(hostHeader: "localhost"))
        #expect(policy.allows(hostHeader: "localhost:8765"))
        #expect(policy.allows(hostHeader: "127.0.0.1:8765"))
        #expect(policy.allows(hostHeader: "[::1]:8765"))
    }

    @Test func allowsDetectedLanAndTailnetIps() {
        let policy = RemoteAccessPolicy(allowedHosts: ["192.168.1.23", "100.88.1.20"])

        #expect(policy.allows(hostHeader: "192.168.1.23:8765"))
        #expect(policy.allows(hostHeader: "100.88.1.20:8765"))
    }

    @Test func allowsConfiguredHostnameCaseInsensitively() {
        let policy = RemoteAccessPolicy(allowedHosts: ["Nacho-MBP.local"])

        #expect(policy.allows(hostHeader: "nacho-mbp.local:8765"))
        #expect(policy.allows(hostHeader: "NACHO-MBP.LOCAL"))
    }

    @Test func rejectsMissingOrUnrecognizedHost() {
        let policy = RemoteAccessPolicy(allowedHosts: ["localhost"])

        #expect(!policy.allows(hostHeader: nil))
        #expect(!policy.allows(hostHeader: ""))
        #expect(!policy.allows(hostHeader: "evil.example"))
        #expect(!policy.allows(hostHeader: "evil.example:8765"))
    }

    @Test func normalizesIpv6HostWithAndWithoutPort() {
        #expect(RemoteAccessPolicy.normalizedHost(from: "[::1]:8765") == "::1")
        #expect(RemoteAccessPolicy.normalizedHost(from: "[::1]") == "::1")
        #expect(RemoteAccessPolicy.normalizedHost(from: "::1") == "::1")
        #expect(RemoteAccessPolicy.normalizedHost(from: "192.168.1.23:8765") == "192.168.1.23")
        #expect(RemoteAccessPolicy.normalizedHost(from: "nacho-mbp.local:8765") == "nacho-mbp.local")
    }

    @Test func rejectsMalformedBracketedIpv6Suffixes() {
        #expect(!RemoteAccessPolicy.loopback.allows(hostHeader: "[::1]evil"))
        #expect(!RemoteAccessPolicy.loopback.allows(hostHeader: "[::1].example"))
        #expect(RemoteAccessPolicy.normalizedHost(from: "[::1]evil") == nil)
        #expect(RemoteAccessPolicy.normalizedHost(from: "[::1].example") == nil)
    }

    @Test func rejectsMalformedNonBracketedHostPortsAndBrackets() {
        #expect(!RemoteAccessPolicy.loopback.allows(hostHeader: "localhost:evil"))
        #expect(!RemoteAccessPolicy.loopback.allows(hostHeader: "localhost:"))
        #expect(!RemoteAccessPolicy.loopback.allows(hostHeader: "localhost]"))
        #expect(!RemoteAccessPolicy.loopback.allows(hostHeader: "]localhost["))
        #expect(RemoteAccessPolicy.normalizedHost(from: "localhost:evil") == nil)
        #expect(RemoteAccessPolicy.normalizedHost(from: "localhost:") == nil)
        #expect(RemoteAccessPolicy.normalizedHost(from: "localhost]") == nil)
        #expect(RemoteAccessPolicy.normalizedHost(from: "]localhost[") == nil)
    }

    @Test func rejectsBracketedNonIpv6HostsAndEmptyIpv6Hosts() {
        #expect(!RemoteAccessPolicy.loopback.allows(hostHeader: "[localhost]"))
        #expect(!RemoteAccessPolicy.loopback.allows(hostHeader: "[127.0.0.1]"))
        #expect(RemoteAccessPolicy.normalizedHost(from: "[localhost]") == nil)
        #expect(RemoteAccessPolicy.normalizedHost(from: "[127.0.0.1]") == nil)
        #expect(RemoteAccessPolicy.normalizedHost(from: "[]") == nil)
        #expect(RemoteAccessPolicy.normalizedHost(from: "[]:8765") == nil)
    }

    @Test func rejectsNonAsciiPortsAndEmptyNonBracketedHosts() {
        #expect(!RemoteAccessPolicy.loopback.allows(hostHeader: "localhost:１２３"))
        #expect(RemoteAccessPolicy.normalizedHost(from: "localhost:１２３") == nil)
        #expect(RemoteAccessPolicy.normalizedHost(from: ":8765") == nil)
    }

    @Test func rejectsMalformedMultiColonHostsButAllowsRawIpv6() {
        let policy = RemoteAccessPolicy(allowedHosts: ["localhost:8765:9000"])

        #expect(!policy.allows(hostHeader: "localhost:8765:9000"))
        #expect(RemoteAccessPolicy.normalizedHost(from: "localhost:8765:9000") == nil)
        #expect(RemoteAccessPolicy.normalizedHost(from: "foo:bar:baz") == nil)
        #expect(RemoteAccessPolicy.normalizedHost(from: "example.com::8765") == nil)
        #expect(RemoteAccessPolicy.normalizedHost(from: "2001:db8::1") == "2001:db8::1")
    }
}
