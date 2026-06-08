import Testing
@testable import Alas

struct RemoteNetworkTests {
    @Test func advertisedAddressesPreferTailnetThenLanThenLocalhost() {
        let interfaces = [
            RemoteNetworkInterface(name: "lo0", host: "127.0.0.1", isLoopback: true),
            RemoteNetworkInterface(name: "en0", host: "192.168.1.23", isLoopback: false),
            RemoteNetworkInterface(name: "utun4", host: "100.88.1.20", isLoopback: false),
        ]

        let addresses = RemoteNetwork.advertisedAddresses(
            port: 8765,
            interfaces: interfaces,
            allowedHosts: [],
            preferredHost: nil,
            machineHostName: "nacho-mbp"
        )

        #expect(addresses.map(\.host) == ["100.88.1.20", "192.168.1.23", "localhost"])
        #expect(addresses.map(\.kind) == [.tailnet, .lan, .localhost])
        #expect(addresses.first?.isRecommended == true)
        #expect(addresses.first?.url == "http://100.88.1.20:8765")
    }

    @Test func lanIpContinuesToBeAdvertisedWithoutManualAllowedHost() {
        let interfaces = [
            RemoteNetworkInterface(name: "en0", host: "10.0.0.42", isLoopback: false),
        ]

        let addresses = RemoteNetwork.advertisedAddresses(
            port: 8765,
            interfaces: interfaces,
            allowedHosts: [],
            preferredHost: nil,
            machineHostName: nil
        )

        #expect(addresses.contains { $0.host == "10.0.0.42" && $0.kind == .lan })
        #expect(addresses.contains { $0.host == "localhost" && $0.kind == .localhost })
    }

    @Test func preferredHostMarksMatchingAddressRecommended() {
        let interfaces = [
            RemoteNetworkInterface(name: "en0", host: "192.168.1.23", isLoopback: false),
            RemoteNetworkInterface(name: "utun4", host: "100.88.1.20", isLoopback: false),
        ]

        let addresses = RemoteNetwork.advertisedAddresses(
            port: 8765,
            interfaces: interfaces,
            allowedHosts: [],
            preferredHost: "192.168.1.23",
            machineHostName: nil
        )

        #expect(addresses.first?.host == "192.168.1.23")
        #expect(addresses.first?.isRecommended == true)
    }

    @Test func customAllowedHostsAreAdvertisedAsCustom() {
        let addresses = RemoteNetwork.advertisedAddresses(
            port: 8765,
            interfaces: [],
            allowedHosts: ["alas.tailnet.example"],
            preferredHost: nil,
            machineHostName: nil
        )

        #expect(addresses.contains {
            $0.host == "alas.tailnet.example"
                && $0.kind == .custom
                && $0.url == "http://alas.tailnet.example:8765"
        })
    }

    @Test func allowedHostCandidatesIncludeLocalhostDetectedIpsAndMachineNames() {
        let interfaces = [
            RemoteNetworkInterface(name: "en0", host: "192.168.1.23", isLoopback: false),
            RemoteNetworkInterface(name: "utun4", host: "100.88.1.20", isLoopback: false),
        ]

        let hosts = RemoteNetwork.allowedHostCandidates(
            interfaces: interfaces,
            allowedHosts: ["custom.example"],
            machineHostName: "Nacho-MBP.local"
        )

        #expect(hosts.contains("localhost"))
        #expect(hosts.contains("127.0.0.1"))
        #expect(hosts.contains("::1"))
        #expect(hosts.contains("192.168.1.23"))
        #expect(hosts.contains("100.88.1.20"))
        #expect(hosts.contains("custom.example"))
        #expect(hosts.contains("nacho-mbp.local"))
        #expect(hosts.contains("nacho-mbp"))
    }

    @Test func tailscaleIPv4RangeIsTailnetAndOtherHundredDotAddressesAreRejected() {
        let interfaces = [
            RemoteNetworkInterface(name: "en0", host: "100.63.255.255", isLoopback: false),
            RemoteNetworkInterface(name: "en1", host: "100.64.0.0", isLoopback: false),
            RemoteNetworkInterface(name: "en2", host: "100.127.255.255", isLoopback: false),
            RemoteNetworkInterface(name: "en3", host: "100.128.0.0", isLoopback: false),
        ]

        let addresses = RemoteNetwork.advertisedAddresses(
            port: 8765,
            interfaces: interfaces,
            allowedHosts: [],
            preferredHost: nil,
            machineHostName: nil
        )

        #expect(addresses.contains { $0.host == "100.64.0.0" && $0.kind == .tailnet })
        #expect(addresses.contains { $0.host == "100.127.255.255" && $0.kind == .tailnet })
        #expect(!addresses.contains { $0.host == "100.63.255.255" })
        #expect(!addresses.contains { $0.host == "100.128.0.0" })
    }

    @Test func utunPrivateIPv4IsLanNotTailnetWhenOutsideTailscaleRange() {
        let addresses = RemoteNetwork.advertisedAddresses(
            port: 8765,
            interfaces: [
                RemoteNetworkInterface(name: "utun4", host: "10.8.0.2", isLoopback: false),
            ],
            allowedHosts: [],
            preferredHost: nil,
            machineHostName: nil
        )

        #expect(addresses.contains { $0.host == "10.8.0.2" && $0.kind == .lan })
        #expect(!addresses.contains { $0.host == "10.8.0.2" && $0.kind == .tailnet })
    }

    @Test func rfc1918IPv4BoundariesAreLanAndNearbyRangesAreRejected() {
        let interfaces = [
            RemoteNetworkInterface(name: "en0", host: "172.15.255.255", isLoopback: false),
            RemoteNetworkInterface(name: "en1", host: "172.16.0.0", isLoopback: false),
            RemoteNetworkInterface(name: "en2", host: "172.31.255.255", isLoopback: false),
            RemoteNetworkInterface(name: "en3", host: "172.32.0.0", isLoopback: false),
            RemoteNetworkInterface(name: "en4", host: "192.168.0.1", isLoopback: false),
            RemoteNetworkInterface(name: "en5", host: "10.255.255.255", isLoopback: false),
        ]

        let addresses = RemoteNetwork.advertisedAddresses(
            port: 8765,
            interfaces: interfaces,
            allowedHosts: [],
            preferredHost: nil,
            machineHostName: nil
        )

        #expect(addresses.contains { $0.host == "172.16.0.0" && $0.kind == .lan })
        #expect(addresses.contains { $0.host == "172.31.255.255" && $0.kind == .lan })
        #expect(addresses.contains { $0.host == "192.168.0.1" && $0.kind == .lan })
        #expect(addresses.contains { $0.host == "10.255.255.255" && $0.kind == .lan })
        #expect(!addresses.contains { $0.host == "172.15.255.255" })
        #expect(!addresses.contains { $0.host == "172.32.0.0" })
    }

    @Test func malformedIPv4CandidatesAreRejected() {
        let interfaces = [
            RemoteNetworkInterface(name: "en0", host: "10.0.0.999", isLoopback: false),
            RemoteNetworkInterface(name: "en1", host: "10.0.0", isLoopback: false),
            RemoteNetworkInterface(name: "en2", host: "10.0.0.a", isLoopback: false),
            RemoteNetworkInterface(name: "en3", host: "010.0.0.1", isLoopback: false),
        ]

        let addresses = RemoteNetwork.advertisedAddresses(
            port: 8765,
            interfaces: interfaces,
            allowedHosts: [],
            preferredHost: nil,
            machineHostName: nil
        )

        #expect(addresses.map(\.host) == ["localhost"])
    }

    @Test func ipv6TailnetAndLanAddressesAreAdvertisedWithBracketedUrls() {
        let interfaces = [
            RemoteNetworkInterface(name: "utun4", host: "fd7a:115c:a1e0::1", isLoopback: false),
            RemoteNetworkInterface(name: "en0", host: "fd00::42", isLoopback: false),
        ]

        let addresses = RemoteNetwork.advertisedAddresses(
            port: 8765,
            interfaces: interfaces,
            allowedHosts: [],
            preferredHost: nil,
            machineHostName: nil
        )

        #expect(addresses.contains {
            $0.host == "fd7a:115c:a1e0::1"
                && $0.kind == .tailnet
                && $0.url == "http://[fd7a:115c:a1e0::1]:8765"
        })
        #expect(addresses.contains {
            $0.host == "fd00::42"
                && $0.kind == .lan
                && $0.url == "http://[fd00::42]:8765"
        })
    }

    @Test func duplicateHostsAreNormalizedAcrossDetectedAndAllowedHosts() {
        let addresses = RemoteNetwork.advertisedAddresses(
            port: 8765,
            interfaces: [
                RemoteNetworkInterface(name: "en0", host: "192.168.1.23", isLoopback: false),
            ],
            allowedHosts: ["  [192.168.1.23]  ", "LOCALHOST"],
            preferredHost: nil,
            machineHostName: nil
        )

        #expect(addresses.filter { $0.host == "192.168.1.23" }.count == 1)
        #expect(addresses.filter { $0.host == "localhost" }.count == 1)
        #expect(!addresses.contains { $0.kind == .custom })
    }
}
