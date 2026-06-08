import Foundation

struct RemoteNetworkInterface: Equatable, Sendable {
    let name: String
    let host: String
    let isLoopback: Bool
}

struct RemoteAdvertisedAddress: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case localhost
        case lan
        case tailnet
        case custom
    }

    let id: String
    let kind: Kind
    let interfaceName: String?
    let host: String
    let port: UInt16
    let url: String
    let isRecommended: Bool

    init(kind: Kind, interfaceName: String?, host: String, port: UInt16, isRecommended: Bool) {
        self.kind = kind
        self.interfaceName = interfaceName
        self.host = host
        self.port = port
        self.url = "http://\(Self.urlHost(host)):\(port)"
        self.id = "\(kind.rawValue):\(host):\(port)"
        self.isRecommended = isRecommended
    }

    private static func urlHost(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }
}

enum RemoteNetwork {
    private enum AddressClassification {
        case lan
        case tailnet
    }

    static func interfaces() -> [RemoteNetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var output: [RemoteNetworkInterface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            defer { cursor = ptr.pointee.ifa_next }
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP else { continue }
            guard let addr = ptr.pointee.ifa_addr else { continue }
            guard addr.pointee.sa_family == sa_family_t(AF_INET)
                    || addr.pointee.sa_family == sa_family_t(AF_INET6) else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let value = String(cString: host)
            guard !value.isEmpty, !value.hasPrefix("fe80:") else { continue }
            output.append(RemoteNetworkInterface(
                name: name,
                host: value,
                isLoopback: (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            ))
        }
        return output
    }

    static func machineHostName() -> String? {
        let raw = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    static func advertisedAddresses(
        port: UInt16,
        interfaces: [RemoteNetworkInterface] = interfaces(),
        allowedHosts: [String],
        preferredHost: String?,
        machineHostName: String? = machineHostName()
    ) -> [RemoteAdvertisedAddress] {
        var candidates: [(RemoteAdvertisedAddress.Kind, String?, String)] = []

        for iface in interfaces where !iface.isLoopback && classification(for: iface.host) == .tailnet {
            candidates.append((.tailnet, iface.name, iface.host))
        }

        for iface in interfaces where !iface.isLoopback {
            if classification(for: iface.host) == .lan {
                candidates.append((.lan, iface.name, iface.host))
            }
        }

        candidates.append((.localhost, nil, "localhost"))

        for host in normalizedHosts(allowedHosts) {
            if !candidates.contains(where: { normalizedHost($0.2) == host }) {
                candidates.append((.custom, nil, host))
            }
        }

        var unique: [(RemoteAdvertisedAddress.Kind, String?, String)] = []
        var seen = Set<String>()
        for item in candidates {
            let key = normalizedHost(item.2)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(item)
        }

        if let preferred = preferredHost.map(normalizedHost),
           let index = unique.firstIndex(where: { normalizedHost($0.2) == preferred }) {
            let preferredItem = unique.remove(at: index)
            unique.insert(preferredItem, at: 0)
        }

        return unique.enumerated().map { index, item in
            RemoteAdvertisedAddress(
                kind: item.0,
                interfaceName: item.1,
                host: item.2,
                port: port,
                isRecommended: index == 0
            )
        }
    }

    static func allowedHostCandidates(
        interfaces: [RemoteNetworkInterface] = interfaces(),
        allowedHosts: [String],
        machineHostName: String? = machineHostName()
    ) -> Set<String> {
        var hosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
        for iface in interfaces {
            hosts.insert(normalizedHost(iface.host))
        }
        for host in normalizedHosts(allowedHosts) {
            hosts.insert(host)
        }
        if let machine = machineHostName {
            let normalized = normalizedHost(machine)
            hosts.insert(normalized)
            if normalized.hasSuffix(".local") {
                hosts.insert(String(normalized.dropLast(".local".count)))
            } else {
                hosts.insert("\(normalized).local")
            }
        }
        return hosts
    }

    static func normalizedHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
    }

    private static func normalizedHosts(_ hosts: [String]) -> [String] {
        hosts.map(normalizedHost).filter { !$0.isEmpty }
    }

    private static func classification(for host: String) -> AddressClassification? {
        if isTailnetIPv4(host) || isTailnetIPv6(host) {
            return .tailnet
        }
        if isLANIPv4(host) || isLANIPv6(host) {
            return .lan
        }
        return nil
    }

    private static func isTailnetIPv4(_ host: String) -> Bool {
        guard let parts = ipv4Octets(host) else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }

    private static func isTailnetIPv6(_ host: String) -> Bool {
        guard let bytes = ipv6Bytes(host) else { return false }
        return bytes.starts(with: [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0])
    }

    private static func isLANIPv4(_ host: String) -> Bool {
        guard let parts = ipv4Octets(host) else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        return false
    }

    private static func isLANIPv6(_ host: String) -> Bool {
        guard let bytes = ipv6Bytes(host), !isTailnetIPv6(host) else { return false }
        return (bytes[0] & 0xfe) == 0xfc
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = normalizedHost(host).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }

        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty else { return nil }
            guard part.allSatisfy(\.isNumber) else { return nil }
            guard part == "0" || !part.hasPrefix("0") else { return nil }
            guard let value = Int(part), (0...255).contains(value) else { return nil }
            octets.append(value)
        }
        return octets
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        let normalized = normalizedHost(host)
        guard normalized.contains(":") else { return nil }

        var address = in6_addr()
        let result = normalized.withCString { pointer in
            inet_pton(AF_INET6, pointer, &address)
        }
        guard result == 1 else { return nil }

        return withUnsafeBytes(of: &address) { buffer in
            Array(buffer)
        }
    }
}
