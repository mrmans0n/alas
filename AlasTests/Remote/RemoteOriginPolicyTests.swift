import Testing
@testable import Alas

struct RemoteOriginPolicyTests {
    private let policy = RemoteOriginPolicy(
        hostPolicy: RemoteAccessPolicy(allowedHosts: ["localhost", "127.0.0.1", "::1", "proxy.example.com"]),
        allowedOrigins: ["https://app.alas.build"]
    )

    @Test func allowsAbsentOrigin() {
        #expect(policy.allows(originHeader: nil))
        #expect(policy.allows(originHeader: ""))
        #expect(policy.allows(originHeader: "   "))
    }

    @Test func allowsPrivateNetworkOrigins() {
        for origin in [
            "http://192.168.1.20:8765", "http://10.0.0.5:8765", "http://172.16.4.4:8765",
            "http://100.64.1.5:8765", "http://[fd7a:115c:a1e0::1]:8765", "http://[fc00::1]:8765",
            "http://localhost:8765", "http://127.0.0.1:8765", "http://[::1]:8765",
            "http://169.254.1.1:8765", "http://[fe80::1]:8765",
        ] {
            #expect(policy.allows(originHeader: origin), "\(origin)")
        }
    }

    @Test func allowsDotLocalAndHostAllowlistedNames() {
        #expect(policy.allows(originHeader: "http://nacho-mbp.local:8765"))
        #expect(policy.allows(originHeader: "https://proxy.example.com"))
        #expect(policy.allows(originHeader: "https://PROXY.example.com:443"))
    }

    @Test func allowsConfiguredOriginsExactly() {
        #expect(policy.allows(originHeader: "https://app.alas.build"))
        #expect(!policy.allows(originHeader: "https://app.alas.build:444"))
        #expect(!policy.allows(originHeader: "http://app.alas.build"))
    }

    @Test func rejectsPublicAndMalformedOrigins() {
        for origin in [
            "https://evil.example", "http://8.8.8.8:8765", "null", "file://",
            "http://192.168.1.20:8765/path", "ftp://192.168.1.20", "http://user@192.168.1.20:8765",
        ] {
            #expect(!policy.allows(originHeader: origin), "\(origin)")
        }
    }

    @Test func parseNormalizesSchemeHostAndPort() {
        #expect(RemoteOriginPolicy.parse("HTTP://Nacho-MBP.local:8765")?.normalized == "http://nacho-mbp.local:8765")
        #expect(RemoteOriginPolicy.parse("http://[::1]:8765")?.host == "::1")
        #expect(RemoteOriginPolicy.parse("http://[::1]:8765")?.normalized == "http://[::1]:8765")
        #expect(RemoteOriginPolicy.parse("https://app.alas.build")?.port == nil)
    }

    // Regression (Codex review, PR #1337): a browser's Origin header never
    // carries a scheme-default port, so a configured allowlist entry typed
    // or pasted with one (a common copy-paste from an address bar) must
    // canonicalize the same way or it can never match a real request.
    @Test func parseCanonicalizesSchemeDefaultPorts() {
        #expect(RemoteOriginPolicy.parse("https://example.com:443")?.normalized == "https://example.com")
        #expect(RemoteOriginPolicy.parse("http://example.com:80")?.normalized == "http://example.com")
        #expect(RemoteOriginPolicy.parse("https://example.com:8443")?.port == 8443, "a non-default port is preserved")

        let withDefaultPort = RemoteOriginPolicy(hostPolicy: .loopback, allowedOrigins: ["https://example.com:443"])
        #expect(withDefaultPort.allows(originHeader: "https://example.com"), "the browser's own Origin header omits the default port")
    }

    @Test func privateHostClassifierCoversLoopbackLinkLocalAndPrivateRanges() {
        for host in ["localhost", "127.0.0.1", "127.5.5.5", "::1", "10.1.1.1", "192.168.0.1", "172.31.0.1",
                     "100.64.0.1", "100.127.255.255", "169.254.9.9", "fe80::1", "fd7a:115c:a1e0::1", "fc00::1"] {
            #expect(RemoteNetwork.isPrivateOrLocalHost(host), "\(host)")
        }
        for host in ["8.8.8.8", "100.128.0.1", "example.com", "2001:db8::1", ""] {
            #expect(!RemoteNetwork.isPrivateOrLocalHost(host), "\(host)")
        }
    }
}
