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
}
