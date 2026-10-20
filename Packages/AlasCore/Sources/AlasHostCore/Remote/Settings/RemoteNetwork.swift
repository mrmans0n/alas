import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents

public struct RemoteNetworkInterface: Equatable, Sendable {
    public let name: String
    public let host: String
    public let isLoopback: Bool

    public init(name: String, host: String, isLoopback: Bool) {
        self.name = name
        self.host = host
        self.isLoopback = isLoopback
    }
}

public struct RemoteAdvertisedAddress: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case localhost
        case lan
        case tailnet
        case custom
    }

    public let id: String
    public let kind: Kind
    public let interfaceName: String?
    public let host: String
    public let port: UInt16
    public let url: String
    public let isRecommended: Bool

    /// `secure` addresses are HTTPS on the default port, fronted by a proxy
    /// such as Tailscale Serve, so `port` is 443 rather than the bound port.
    public init(kind: Kind, interfaceName: String?, host: String, port: UInt16, isRecommended: Bool, secure: Bool = false) {
        self.kind = kind
        self.interfaceName = interfaceName
        self.host = host
        self.port = secure ? 443 : port
        self.url = secure ? "https://\(Self.urlHost(host))" : "http://\(Self.urlHost(host)):\(port)"
        self.id = "\(kind.rawValue):\(host):\(self.port)"
        self.isRecommended = isRecommended
    }

    public var isSecure: Bool { url.hasPrefix("https://") }

    private static func urlHost(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }
}

public enum RemoteNetwork: Sendable {
    private enum AddressClassification {
        case lan
        case tailnet
    }

    /// Includes link-local addresses (`fe80::/10` — `getnameinfo` reports
    /// these with a `%zone` suffix, e.g. `fe80::1%en0`). `classification`
    /// does not recognize them, so `advertisedAddresses` never lists one;
    /// `allowedHostCandidates` does, via `isLinkLocal`.
    public static func interfaces() -> [RemoteNetworkInterface] {
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

            // `String(cString:)` is deprecated for arrays; getnameinfo NUL-terminates,
            // so decode up to the terminator rather than the whole fixed buffer.
            let value = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !value.isEmpty else { continue }
            output.append(RemoteNetworkInterface(
                name: name,
                host: value,
                isLoopback: (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            ))
        }
        return output
    }

    public static func machineHostName() -> String? {
        let raw = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    public static func advertisedAddresses(
        port: UInt16,
        interfaces: [RemoteNetworkInterface] = interfaces(),
        allowedHosts: [String],
        preferredHost: String?,
        machineHostName: String? = machineHostName(),
        tailnetHTTPSHost: String? = nil,
        tailnetHTTPSOnly: Bool = false
    ) -> [RemoteAdvertisedAddress] {
        var candidates: [(RemoteAdvertisedAddress.Kind, String?, String)] = []
        // Only the HTTPS address and localhost reach a loopback-only listener.
        let interfaces = tailnetHTTPSOnly ? [] : interfaces
        let allowedHosts = tailnetHTTPSOnly ? [] : allowedHosts
        let machineHostName = tailnetHTTPSOnly ? nil : machineHostName
        // The only other candidate is localhost, which no phone can load.
        let preferredHost = tailnetHTTPSOnly && tailnetHTTPSHost != nil ? nil : preferredHost

        if let tailnetHTTPSHost {
            candidates.append((.tailnet, nil, tailnetHTTPSHost))
        }

        for iface in interfaces where !iface.isLoopback && classification(for: iface.host) == .tailnet {
            candidates.append((.tailnet, iface.name, iface.host))
        }

        for iface in interfaces where !iface.isLoopback {
            if classification(for: iface.host) == .lan {
                candidates.append((.lan, iface.name, iface.host))
            }
        }

        candidates.append((.localhost, nil, "localhost"))

        if let host = machineLocalHost(from: machineHostName) {
            candidates.append((.custom, nil, host))
        }

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
                isRecommended: index == 0,
                secure: tailnetHTTPSHost.map(normalizedHost) == normalizedHost(item.2)
            )
        }
    }

    public static func allowedHostCandidates(
        interfaces: [RemoteNetworkInterface] = interfaces(),
        allowedHosts: [String],
        machineHostName: String? = machineHostName(),
        tailnetDNSName: String? = nil
    ) -> Set<String> {
        var hosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
        // Tailscale Serve preserves the MagicDNS Host; the short name is what
        // MagicDNS resolves for bare `http://<machine>:<port>` on the tailnet.
        if let name = tailnetDNSName.map(normalizedHost), !name.isEmpty {
            hosts.insert(name)
            if let label = name.split(separator: ".").first { hosts.insert(String(label)) }
        }
        for iface in interfaces {
            if iface.isLoopback || classification(for: iface.host) != nil || isLinkLocal(iface.host) {
                // A link-local address's zone (`%en0`) names an interface on
                // THIS Mac; whatever zone a connecting peer's own Host header
                // carries names one of ITS interfaces instead, so comparing
                // zones would never match. Store the bare address — the
                // incoming side strips its own zone the same way before
                // comparing (`RemoteAccessPolicy.normalizedHost(from:)`).
                hosts.insert(normalizedHost(stripLinkLocalZone(iface.host)))
            }
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

    public static func normalizedHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
    }

    /// True for hosts a browser on the user's own network would be served
    /// from: loopback, link-local, RFC 1918, Tailscale CGNAT/ULA, and IPv6
    /// unique-local. Public addresses and DNS names are false.
    public static func isPrivateOrLocalHost(_ host: String) -> Bool {
        let normalized = normalizedHost(host)
        if normalized == "localhost" || normalized == "::1" { return true }
        if let octets = ipv4Octets(normalized) {
            if octets[0] == 127 { return true }
            return isLinkLocal(normalized) || isLANIPv4(normalized) || isTailnetIPv4(normalized)
        }
        if let bytes = ipv6Bytes(normalized) {
            return isLinkLocal(normalized) || isLANIPv6(normalized) || isTailnetIPv6(normalized)
        }
        return false
    }

    /// True for IPv4 APIPA (169.254/16) and IPv6 link-local (fe80::/10): the
    /// self-assigned address range two Macs land on when they can reach each
    /// other directly (cable, ad hoc Wi-Fi) but no DHCP server is present.
    /// Bonjour is designed to work on exactly this range, so an own-interface
    /// address here must be treated the same as a classified LAN address by
    /// every caller that already trusts LAN/tailnet interfaces.
    public static func isLinkLocal(_ host: String) -> Bool {
        let normalized = normalizedHost(host)
        if let octets = ipv4Octets(normalized) {
            return octets[0] == 169 && octets[1] == 254
        }
        if let bytes = ipv6Bytes(normalized) {
            return bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
        }
        return false
    }

    private static func normalizedHosts(_ hosts: [String]) -> [String] {
        hosts.map(normalizedHost).filter { !$0.isEmpty }
    }

    private static func machineLocalHost(from machineHostName: String?) -> String? {
        guard let machineHostName else { return nil }
        let normalized = normalizedHost(machineHostName)
        guard !normalized.isEmpty,
              !normalized.contains(":"),
              ipv4Octets(normalized) == nil else { return nil }
        return normalized.hasSuffix(".local") ? normalized : "\(normalized).local"
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

    /// Drops a link-local zone suffix (`%en0`, or its percent-encoded
    /// `%25en0` form per RFC 6874) from an IPv6 literal. The zone names an
    /// interface on whichever machine reported it, so it is never part of
    /// the address value itself: every caller that treats an IPv6 host as a
    /// comparable or classifiable value strips it first.
    public static func stripLinkLocalZone(_ host: String) -> String {
        if let range = host.range(of: "%25") {
            return String(host[host.startIndex..<range.lowerBound])
        }
        if let index = host.firstIndex(of: "%") {
            return String(host[host.startIndex..<index])
        }
        return host
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        let normalized = stripLinkLocalZone(normalizedHost(host))
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
