import Darwin
import Foundation
import Synchronization

/// Which addresses a remote-owned web preview may connect to. A remote page
/// must not reach this Mac: loopback, unspecified, link-local, or any of this
/// Mac's own interface addresses, in any spelling. Addresses are their raw 4
/// or 16 bytes.
public enum WebPreviewEgressPolicy {
    public enum Refusal: Equatable, Sendable {
        case thisMac
        case localAddress

        public var description: String {
            switch self {
            case .thisMac: "resolves to this Mac"
            case .localAddress: "resolves to a local address"
            }
        }
    }

    /// The raw bytes of a numeric address, ignoring brackets and an IPv6 zone.
    public static func address(_ text: String) -> Data? {
        var host = text.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 { return withUnsafeBytes(of: &ipv4) { Data($0) } }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 { return withUnsafeBytes(of: &ipv6) { Data($0) } }
        return nil
    }

    /// IPv4-mapped `::ffff:a.b.c.d` and IPv4-compatible `::a.b.c.d` as the
    /// IPv4 address they embed; anything else unchanged.
    public static func canonical(_ address: Data) -> Data {
        let bytes = [UInt8](address)
        guard bytes.count == 16 else { return address }
        let prefix = bytes[0..<10].allSatisfy { $0 == 0 }
        let mapped = prefix && bytes[10] == 0xff && bytes[11] == 0xff
        let compatible = prefix && bytes[10] == 0 && bytes[11] == 0
        return mapped || compatible ? Data(bytes[12...]) : address
    }

    /// Tailscale's MagicDNS and service addresses, which terminate on this
    /// Mac whenever Tailscale runs, whatever its interface addresses are.
    private static let tailscaleServices: Set<Data> = Set(["100.100.100.100", "fd7a:115c:a1e0::53"].compactMap(address))

    /// Why a remote page may not connect to `address`, or nil if it may.
    /// `localAddresses` are this Mac's interface addresses, canonical.
    public static func refusal(for address: Data, localAddresses: Set<Data>) -> Refusal? {
        let address = canonical(address)
        let bytes = [UInt8](address)
        if localAddresses.contains(address) || tailscaleServices.contains(address) { return .thisMac }
        switch bytes.count {
        case 4:
            if bytes[0] == 127 || bytes[0] == 0 { return .thisMac }
            if bytes[0] == 169, bytes[1] == 254 { return .localAddress }
        case 16:
            if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return .localAddress }
        default:
            return .thisMac
        }
        return nil
    }

    /// Why a remote page may not connect to a name with these addresses, or
    /// nil if it may. Every address must pass, so a name cannot mix a public
    /// answer with one for this Mac.
    public static func refusal(forAny addresses: [Data], localAddresses: Set<Data>) -> Refusal? {
        addresses.lazy.compactMap { refusal(for: $0, localAddresses: localAddresses) }.first
    }
}

public enum WebPreviewHostLookup {
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Web preview DNS"
        queue.maxConcurrentOperationCount = 16
        queue.qualityOfService = .utility
        return queue
    }()

    /// The numeric addresses `host` resolves to, or nil if the system
    /// resolver fails or takes longer than 5 seconds. A numeric host is
    /// returned as is. At most 16 lookups run at once across the app; each
    /// egress proxy uses at most `WebPreviewEgressProxy.maxResolutions` of
    /// them, so one page cannot starve other previews.
    public static func resolve(_ host: String) async -> [String]? {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if WebPreviewEgressPolicy.address(host) != nil { return [host] }
        return await withCheckedContinuation { continuation in
            let pending = Mutex<CheckedContinuation<[String]?, Never>?>(continuation)
            let finish: @Sendable ([String]?) -> Void = { result in pending.withLock { $0.take() }?.resume(returning: result) }
            let operation = BlockOperation { finish(lookupAddresses(host)) }
            queue.addOperation(operation)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                operation.cancel()
                finish(nil)
            }
        }
    }

    private static func lookupAddresses(_ host: String) -> [String]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else { return nil }
        defer { freeaddrinfo(result) }

        // Kept in resolver order, so the first is the one to connect to.
        var addresses: [String] = []
        var entry: UnsafeMutablePointer<addrinfo>? = result
        while let current = entry {
            let info = current.pointee
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard let address = info.ai_addr,
                  getnameinfo(address, info.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0
            else { return nil }
            // getnameinfo NUL-terminates, so decode up to the terminator.
            let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !addresses.contains(text) { addresses.append(text) }
            entry = info.ai_next
        }
        return addresses
    }
}
