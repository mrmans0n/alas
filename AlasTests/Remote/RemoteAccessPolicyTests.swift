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
        #expect(RemoteAccessPolicy.normalizedHost(from: "::1") == "::1")
        #expect(RemoteAccessPolicy.normalizedHost(from: "192.168.1.23:8765") == "192.168.1.23")
        #expect(RemoteAccessPolicy.normalizedHost(from: "nacho-mbp.local:8765") == "nacho-mbp.local")
    }
}
